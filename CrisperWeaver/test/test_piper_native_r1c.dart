import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crispasr/crispasr.dart' as crispasr;
import 'package:jarvisol/services/audiobook_service.dart';
import 'package:jarvisol/services/baked_catalog_loader.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testDllDir = r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST';
  final piperGgufPath = r'D:\Antigravity\AgentFolder\CrisperWeaver\scratch\piper_r1c\piper-fr_FR-gilles-low.gguf';
  final outDir = Directory(r'D:\Antigravity\AgentFolder\CrisperWeaver\scratch\piper_r1c');

  setUpAll(() async {
    await BakedCatalogLoader.load();
    for (final dll in ['whisper.dll', 'crispasr.dll']) {
      final pth = p.join(testDllDir, dll);
      if (File(pth).existsSync()) {
        try {
          DynamicLibrary.open(pth);
          print('Opened DLL: $pth');
        } catch (e) {
          print('Failed opening $pth: $e');
        }
      }
    }
  });

  tearDownAll(() => BakedCatalogLoader.reset());

  test('TEST NATIF PIPER GILLES GGUF & BENCHMARK', () async {
    print('\n======================================================');
    print('  VOICE I/O R1c : TEST NATIF CRISPASR PIPER GILLES');
    print('======================================================\n');

    expect(File(piperGgufPath).existsSync(), isTrue, reason: 'Le GGUF Piper Gilles doit exister');

    final backends = crispasr.CrispasrSession.availableBackends();
    print('Backends disponibles dans crispasr.dll : $backends');
    expect(backends.contains('piper'), isTrue, reason: 'Le backend piper doit être supporté par CrispASR');

    // 1. TEST OUVERTURE (COLD START)
    print('\n--- 1. Cold Start : Ouverture du modèle ---');
    final swOpen = Stopwatch()..start();
    final session = crispasr.CrispasrSession.open(piperGgufPath, backend: 'piper');
    swOpen.stop();
    final openMs = swOpen.elapsedMilliseconds;
    print('Session open status: backend=${session.backend}, nSpeakers=${session.nSpeakers}');
    print('Temps d\'ouverture cold start: ${openMs} ms (${(openMs / 1000.0).toStringAsFixed(3)} s)');

    expect(session.backend, equals('piper'));
    const piperSampleRate = 16000;

    // 2. SYNTHESE TEXTE COURT
    const textShort = 'Bonjour Olivier. Ceci est un test de la voix Piper dans Jarvisol.';
    print('\n--- 2. Synthèse texte court ---');
    print('Texte : "$textShort"');
    final swShort = Stopwatch()..start();
    final pcmShort = session.synthesize(textShort);
    swShort.stop();
    final synthShortMs = swShort.elapsedMilliseconds;
    final durShortSec = pcmShort.length / piperSampleRate;
    final rtfShort = (synthShortMs / 1000.0) / durShortSec;
    print('PCM court : ${pcmShort.length} samples, durée audio = ${durShortSec.toStringAsFixed(2)} s');
    print('Temps de synthèse = ${synthShortMs} ms (${(synthShortMs / 1000.0).toStringAsFixed(3)} s)');
    print('RTF = ${rtfShort.toStringAsFixed(3)} (plus c\'est bas, plus c\'est rapide)');

    // Écriture du WAV court
    final wavShortFile = File(p.join(outDir.path, 'piper_gilles_short.wav'));
    final wavShortBytes = _encodeWav(pcmShort, piperSampleRate);
    wavShortFile.writeAsBytesSync(wavShortBytes);
    print('WAV court écrit : ${wavShortFile.path} (${wavShortBytes.length} octets)');

    // 3. SYNTHESE TEXTE CONVERSATIONNEL (3 RUNS WARM)
    const textConv = 'Bonjour Olivier. J\'ai terminé l\'analyse de ta demande. Je peux maintenant te présenter les principaux résultats et expliquer les points qui méritent ton attention.';
    print('\n--- 3. Synthèse texte conversationnel & Warm Benchmark (3 runs) ---');
    print('Texte : "$textConv"');

    final warmTimesMs = <int>[];
    late Float32List lastPcmConv;

    for (int run = 1; run <= 3; run++) {
      final sw = Stopwatch()..start();
      lastPcmConv = session.synthesize(textConv);
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      warmTimesMs.add(ms);
      final durSec = lastPcmConv.length / piperSampleRate;
      final rtf = (ms / 1000.0) / durSec;
      print('Run #$run: ${ms} ms (${(ms / 1000.0).toStringAsFixed(3)} s) | Audio: ${durSec.toStringAsFixed(2)} s | RTF: ${rtf.toStringAsFixed(3)}');
    }

    warmTimesMs.sort();
    final medianWarmMs = warmTimesMs[1];
    final durConvSec = lastPcmConv.length / piperSampleRate;
    final medianRtf = (medianWarmMs / 1000.0) / durConvSec;
    print('\nRésultats Piper Conversationnel :');
    print('  - Runs : $warmTimesMs ms');
    print('  - Médiane synthèse : $medianWarmMs ms (${(medianWarmMs / 1000.0).toStringAsFixed(3)} s)');
    print('  - Durée audio : ${durConvSec.toStringAsFixed(2)} s');
    print('  - RTF médian : ${medianRtf.toStringAsFixed(3)}');

    // Écriture du WAV conversationnel Piper
    final wavConvFile = File(p.join(outDir.path, 'piper_gilles_conversation.wav'));
    final wavConvBytes = _encodeWav(lastPcmConv, piperSampleRate);
    wavConvFile.writeAsBytesSync(wavConvBytes);
    print('WAV conversationnel écrit : ${wavConvFile.path} (${wavConvBytes.length} octets)');

    session.close();

    // 4. BENCHMARK COMPARATIF AVEC LE TTS ACTUEL (QWEN3-TTS NARRATEUR)
    print('\n======================================================');
    print('  COMPARAISON AVEC LE MOTEUR NARRATEUR ACTUEL (Qwen3-TTS)');
    print('======================================================\n');

    final testInstanceDir = Directory(testDllDir);
    AppPaths.setTestOverride(testInstanceDir);
    addTearDown(AppPaths.resetTestOverride);

    final testPrefsFile = File(p.join(testInstanceDir.path, 'data', 'preferences.json'));
    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    final jsonMap = jsonDecode(testPrefsFile.readAsStringSync()) as Map<String, dynamic>;
    for (final entry in jsonMap.entries) {
      if (entry.value is String) await prefs.setString(entry.key, entry.value as String);
      if (entry.value is bool) await prefs.setBool(entry.key, entry.value as bool);
      if (entry.value is int) await prefs.setInt(entry.key, entry.value as int);
      if (entry.value is double) await prefs.setDouble(entry.key, entry.value as double);
    }
    final settingsService = SettingsService(prefs);

    final defaultNarrator = settingsService.defaultNarratorVoice;
    print('Voix narrateur actuelle : $defaultNarrator');
    final savedConfig = settingsService.getSpeakerVoiceConfig('narrator');
    final narratorSpeaker = AudiobookSpeaker.fromJson(savedConfig).copyWith(
      voiceModelName: defaultNarrator,
    );

    final container = ProviderContainer(
      overrides: [
        settingsServiceProvider.overrideWithValue(settingsService),
      ],
    );
    addTearDown(container.dispose);

    final audiobookSvc = container.read(audiobookServiceProvider);

    final dummyLine = AudiobookLine(
      id: 'bench_${DateTime.now().millisecondsSinceEpoch}',
      speakerId: 'narrator',
      speakerName: 'Narrateur',
      text: textConv,
    );

    final swCurrent = Stopwatch()..start();
    final wavBytes = await audiobookSvc.synthesizeLinesToMemory(
      lines: [dummyLine],
      speakers: {'narrator': narratorSpeaker},
    );
    swCurrent.stop();
    final currentMs = swCurrent.elapsedMilliseconds;
    const currentSampleRate = 24000;
    final pcmBytesLen = wavBytes.length > 44 ? wavBytes.length - 44 : 0;
    final currentSamplesCount = pcmBytesLen ~/ 2;
    final currentDurSec = currentSamplesCount / currentSampleRate;
    final currentRtf = (currentMs / 1000.0) / (currentDurSec > 0 ? currentDurSec : 1.0);

    print('\nRésultats Moteur Actuel (Qwen3-TTS) sur le même texte conversationnel :');
    print('  - Temps total (préparation + génération) : ${currentMs} ms (${(currentMs / 1000.0).toStringAsFixed(3)} s)');
    print('  - Durée audio générée : ${currentDurSec.toStringAsFixed(2)} s');
    print('  - RTF global : ${currentRtf.toStringAsFixed(3)}');

    // Écriture du WAV narrateur actuel
    final wavCurrentFile = File(p.join(outDir.path, 'current_narrator_conversation.wav'));
    wavCurrentFile.writeAsBytesSync(wavBytes);
    print('WAV moteur actuel écrit : ${wavCurrentFile.path} (${wavBytes.length} octets)');

    // 5. RAPPORT COMPARATIF DIRECT
    final speedupFactor = (currentMs / 1000.0) / (medianWarmMs / 1000.0);
    print('\n======================================================');
    print('  BILAN DU GAIN EN TEMPS RÉEL');
    print('======================================================');
    print('  - Moteur Actuel Qwen3-TTS : ${(currentMs / 1000.0).toStringAsFixed(2)} s');
    print('  - Piper Gilles (Warm)     : ${(medianWarmMs / 1000.0).toStringAsFixed(2)} s');
    print('  - Facteur d\'accélération   : ${speedupFactor.toStringAsFixed(1)}x plus rapide !');
    print('======================================================\n');

    // Écrire un fichier JSON de benchmark
    final benchResults = {
      'timestamp': DateTime.now().toIso8601String(),
      'text_short': textShort,
      'text_conv': textConv,
      'piper_gilles': {
        'open_ms': openMs,
        'short_synth_ms': synthShortMs,
        'short_audio_sec': durShortSec,
        'short_rtf': rtfShort,
        'conv_runs_ms': warmTimesMs,
        'conv_median_ms': medianWarmMs,
        'conv_audio_sec': durConvSec,
        'conv_rtf': medianRtf,
        'sample_rate': piperSampleRate,
      },
      'current_narrator_qwen3': {
        'model': 'qwen3-tts-12hz-0.6b-base',
        'voice': defaultNarrator,
        'conv_total_ms': currentMs,
        'conv_audio_sec': currentDurSec,
        'conv_rtf': currentRtf,
        'sample_rate': currentSampleRate,
      },
      'speedup_factor': speedupFactor,
    };
    final jsonFile = File(p.join(outDir.path, 'benchmark_results.json'));
    jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(benchResults));
    print('Fichier JSON de benchmark écrit : ${jsonFile.path}');
  });
}

Uint8List _encodeWav(Float32List samples, int sampleRate) {
  final numSamples = samples.length;
  final numChannels = 1;
  final bitsPerSample = 16;
  final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
  final blockAlign = numChannels * (bitsPerSample ~/ 8);
  final dataSize = numSamples * (bitsPerSample ~/ 8);
  final chunkSize = 36 + dataSize;

  final b = BytesBuilder();
  b.add(ascii.encode('RIFF'));
  b.add(_int32(chunkSize));
  b.add(ascii.encode('WAVE'));
  b.add(ascii.encode('fmt '));
  b.add(_int32(16)); // Subchunk1Size
  b.add(_int16(1));  // AudioFormat (PCM = 1)
  b.add(_int16(numChannels));
  b.add(_int32(sampleRate));
  b.add(_int32(byteRate));
  b.add(_int16(blockAlign));
  b.add(_int16(bitsPerSample));
  b.add(ascii.encode('data'));
  b.add(_int32(dataSize));

  final pcm16 = Int16List(numSamples);
  for (int i = 0; i < numSamples; i++) {
    final s = samples[i].clamp(-1.0, 1.0);
    pcm16[i] = (s * 32767.0).round();
  }
  b.add(pcm16.buffer.asUint8List());
  return b.toBytes();
}

Uint8List _int16(int value) => Uint8List(2)..buffer.asByteData().setInt16(0, value, Endian.little);
Uint8List _int32(int value) => Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);
