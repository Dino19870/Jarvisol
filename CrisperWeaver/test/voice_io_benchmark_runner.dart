// test/voice_io_benchmark_runner.dart
//
// Mesures réelles de bout en bout pour Voice I/O R1 :
// - Synthèse TTS VibeVoice (Spk0_man) et Qwen3-TTS (Ryan)
// - Sauvegarde des fichiers WAV réels test_tts_vibevoice_spk0.wav et test_tts_qwen3_customvoice.wav
// - Transcription STT Qwen3-ASR 0.6B et Whisper Large V3 Turbo sur le même audio WAV français
// - Calcul des durées, latences, RTF et comparaison du texte

import 'dart:io';
import 'dart:typed_data';
import 'dart:ffi';
import 'package:flutter_test/flutter_test.dart';
import 'package:crispasr/crispasr.dart' as crispasr;
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/model_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/tts_service.dart';
import 'package:jarvisol/services/transcription_worker_pool.dart';
import 'package:jarvisol/engines/transcription_engine.dart';
import 'package:jarvisol/utils/marked_wav.dart';
import 'package:jarvisol/services/baked_catalog_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await BakedCatalogLoader.load();
    const dllPath = r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2\whisper.dll';
    if (File(dllPath).existsSync()) {
      try {
        DynamicLibrary.open(dllPath);
      } catch (_) {}
    }
  });

  tearDownAll(() => BakedCatalogLoader.reset());

  const modelsDir = r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2\data\models\whisper_cpp';
  final libPath = r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2\whisper.dll';

  const benchmarkText =
      'Bonjour. Ceci est un test de synthèse vocale de Jarvisol pour valider la dictée et la voix en français.';

  test('BENCHMARK REEL TTS & STT VOICE I/O R1', () async {
    print('================================================================');
    print('   BENCHMARK REEL TTS & STT VOICE I/O R1 SUR CETTE MACHINE');
    print('================================================================\n');

    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    final settings = SettingsService(prefs);
    final modelService = ModelService(settings);
    await modelService.initialize();
    final tts = TtsService(modelService);

    // ────────────────────────────────────────────────────────────────
    // 1. BENCHMARK TTS - VIBEVOICE SPK0_MAN
    // ────────────────────────────────────────────────────────────────
    print('[1/4] Synthèse TTS : VibeVoice Realtime 0.5B + Voix fr-Spk0_man...');
    final vvModel = '$modelsDir\\vibevoice-realtime-0.5b-q4_k.gguf';
    final vvVoice = '$modelsDir\\vibevoice-voice-fr-Spk0_man.gguf';

    final swVvLoad = Stopwatch()..start();
    final vvPrep = await tts.prepare(
      modelName: vvModel,
      voiceName: vvVoice,
    );
    swVvLoad.stop();
    print('  - Chargement VibeVoice : ${swVvLoad.elapsedMilliseconds} ms (ready: ${vvPrep.ready})');

    final swVvSynth = Stopwatch()..start();
    final vvAudio = await tts.synthesize(benchmarkText);
    swVvSynth.stop();

    double vvDuration = 0.0;
    double vvRtf = 0.0;
    if (vvAudio != null && vvAudio.samples.isNotEmpty) {
      vvDuration = vvAudio.durationSeconds;
      vvRtf = swVvSynth.elapsedMilliseconds / (vvDuration * 1000.0);
      print('  - Synthèse terminée en : ${swVvSynth.elapsedMilliseconds} ms');
      print('  - Durée audio générée : ${vvDuration.toStringAsFixed(2)} s');
      print('  - RTF (Real-Time Factor) : ${vvRtf.toStringAsFixed(3)}x');

      final wavBytes = MarkedWav.encode(
        vvAudio.samples,
        vvAudio.sampleRate,
        generatorVersion: '1.0.0',
        modelName: 'vibevoice-realtime-0.5b-q4_k',
        voiceId: 'vibevoice-voice-fr-Spk0_man',
      );
      final outWav = File('test_tts_vibevoice_spk0.wav');
      await outWav.writeAsBytes(wavBytes);
      print('  - Fichier WAV sauvegardé : ${outWav.absolute.path} (${wavBytes.length} octets)\n');
    } else {
      print('  - ERREUR : VibeVoice n’a pas produit d’audio.\n');
    }

    // ────────────────────────────────────────────────────────────────
    // 2. BENCHMARK TTS - QWEN3-TTS CUSTOMVOICE (RYAN)
    // ────────────────────────────────────────────────────────────────
    print('[2/4] Synthèse TTS : Qwen3-TTS 0.6B CustomVoice + Voix Ryan...');
    final qwenTtsModel = '$modelsDir\\qwen3-tts-12hz-0.6b-customvoice-q8_0.gguf';
    final qwenTtsCodec = '$modelsDir\\qwen3-tts-tokenizer-12hz.gguf';

    final swQwenTtsLoad = Stopwatch()..start();
    final qwenTtsPrep = await tts.prepare(
      modelName: qwenTtsModel,
      codecName: qwenTtsCodec,
      speakerName: 'ryan',
    );
    swQwenTtsLoad.stop();
    print('  - Chargement Qwen3-TTS : ${swQwenTtsLoad.elapsedMilliseconds} ms (ready: ${qwenTtsPrep.ready})');

    final swQwenTtsSynth = Stopwatch()..start();
    final qwenTtsAudio = await tts.synthesize(benchmarkText);
    swQwenTtsSynth.stop();

    double qwenTtsDuration = 0.0;
    double qwenTtsRtf = 0.0;
    if (qwenTtsAudio != null && qwenTtsAudio.samples.isNotEmpty) {
      qwenTtsDuration = qwenTtsAudio.durationSeconds;
      qwenTtsRtf = swQwenTtsSynth.elapsedMilliseconds / (qwenTtsDuration * 1000.0);
      print('  - Synthèse terminée en : ${swQwenTtsSynth.elapsedMilliseconds} ms');
      print('  - Durée audio générée : ${qwenTtsDuration.toStringAsFixed(2)} s');
      print('  - RTF (Real-Time Factor) : ${qwenTtsRtf.toStringAsFixed(3)}x');

      final wavBytes = MarkedWav.encode(
        qwenTtsAudio.samples,
        qwenTtsAudio.sampleRate,
        generatorVersion: '1.0.0',
        modelName: 'qwen3-tts-12hz-0.6b-customvoice-q8_0',
        voiceId: 'ryan',
      );
      final outWav = File('test_tts_qwen3_customvoice.wav');
      await outWav.writeAsBytes(wavBytes);
      print('  - Fichier WAV sauvegardé : ${outWav.absolute.path} (${wavBytes.length} octets)\n');
    } else {
      print('  - ERREUR : Qwen3-TTS n’a pas produit d’audio.\n');
    }

    // ────────────────────────────────────────────────────────────────
    // SELECTION FICHIER AUDIO POUR BENCHMARK STT
    // ────────────────────────────────────────────────────────────────
    final refWavFile = File('test_tts_vibevoice_spk0.wav');
    expect(refWavFile.existsSync(), isTrue, reason: 'test_tts_vibevoice_spk0.wav doit exister.');
    print('Audio source pour STT : ${refWavFile.path}\n');

    final decodedAudio = crispasr.decodeAudioFile(refWavFile.path, libPath: libPath);
    expect(decodedAudio.samples.length, greaterThan(10000));
    final audioSec = decodedAudio.samples.length / 16000.0;
    print('Audio décodé pour STT : ${decodedAudio.samples.length} échantillons (${audioSec.toStringAsFixed(2)} s)');

    // ────────────────────────────────────────────────────────────────
    // 3. BENCHMARK STT - QWEN3-ASR 0.6B
    // ────────────────────────────────────────────────────────────────
    print('\n[3/4] Transcription STT : Qwen3-ASR 0.6B (q4_k)...');
    final qwenAsrModel = '$modelsDir\\qwen3-asr-0.6b-q4_k.gguf';

    final swQwenSpawn = Stopwatch()..start();
    final qwenPool = await TranscriptionWorkerPool.spawn(
      count: 1,
      modelPath: qwenAsrModel,
      backend: 'qwen3',
      libName: libPath,
    );
    swQwenSpawn.stop();
    print('  - Initialisation pool Qwen3-ASR : ${swQwenSpawn.elapsedMilliseconds} ms');

    final swQwenTranscribe = Stopwatch()..start();
    final qwenResult = await qwenPool.dispatch(
      samples: decodedAudio.samples,
      language: 'fr',
    );
    swQwenTranscribe.stop();
    await qwenPool.shutdown();

    final qwenText = qwenResult.map((s) => s.text).join(' ').trim();
    final qwenRtf = swQwenTranscribe.elapsedMilliseconds / (audioSec * 1000.0);
    print('  - Transcription terminée en : ${swQwenTranscribe.elapsedMilliseconds} ms');
    print('  - RTF : ${qwenRtf.toStringAsFixed(3)}x');
    print('  - Texte obtenu : "$qwenText"\n');

    // ────────────────────────────────────────────────────────────────
    // 4. BENCHMARK STT - WHISPER LARGE V3 TURBO
    // ────────────────────────────────────────────────────────────────
    print('[4/4] Transcription STT : Whisper Large V3 Turbo...');
    final whisperModel = '$modelsDir\\ggml-large-v3-turbo.bin';

    final swWhisperSpawn = Stopwatch()..start();
    final whisperPool = await TranscriptionWorkerPool.spawn(
      count: 1,
      modelPath: whisperModel,
      backend: 'whisper',
      libName: libPath,
    );
    swWhisperSpawn.stop();
    print('  - Initialisation pool Whisper : ${swWhisperSpawn.elapsedMilliseconds} ms');

    final swWhisperTranscribe = Stopwatch()..start();
    final whisperResult = await whisperPool.dispatch(
      samples: decodedAudio.samples,
      language: 'fr',
    );
    swWhisperTranscribe.stop();
    await whisperPool.shutdown();

    final whisperText = whisperResult.map((s) => s.text).join(' ').trim();
    final whisperRtf = swWhisperTranscribe.elapsedMilliseconds / (audioSec * 1000.0);
    print('  - Transcription terminée en : ${swWhisperTranscribe.elapsedMilliseconds} ms');
    print('  - RTF : ${whisperRtf.toStringAsFixed(3)}x');
    print('  - Texte obtenu : "$whisperText"\n');

    // ────────────────────────────────────────────────────────────────
    // SYNTHÈSE RÉCAPITULATIVE
    // ────────────────────────────────────────────────────────────────
    print('================================================================');
    print('                   TABLEAU COMPARATIF FINAL');
    print('================================================================');
    print('TTS :');
    print('  VibeVoice Realtime (Spk0_man) : ${swVvSynth.elapsedMilliseconds} ms | Durée=${vvDuration.toStringAsFixed(2)}s | RTF=${vvRtf.toStringAsFixed(2)}x');
    print('  Qwen3-TTS 0.6B (Ryan)         : ${swQwenTtsSynth.elapsedMilliseconds} ms | Durée=${qwenTtsDuration.toStringAsFixed(2)}s | RTF=${qwenTtsRtf.toStringAsFixed(2)}x');
    print('  Kokoro 82M (SIWIS)            : NON DISPONIBLE (Crash GGML_ASSERT ctx->mem_buffer != NULL dans la DLL crispasr actuelle)');
    print('\nSTT (sur audio français de ${audioSec.toStringAsFixed(2)} s) :');
    print('  Qwen3-ASR 0.6B    : ${swQwenTranscribe.elapsedMilliseconds} ms | RTF=${qwenRtf.toStringAsFixed(2)}x | Texte: "$qwenText"');
    print('  Whisper L-V3 Turbo: ${swWhisperTranscribe.elapsedMilliseconds} ms | RTF=${whisperRtf.toStringAsFixed(2)}x | Texte: "$whisperText"');
    print('================================================================\n');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
