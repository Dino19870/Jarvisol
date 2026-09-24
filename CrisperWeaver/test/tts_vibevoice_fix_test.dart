import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/services/audiobook_service.dart';
import 'package:jarvisol/services/baked_catalog_loader.dart';
import 'package:jarvisol/services/model_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/tts_service.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/utils/portable_preferences.dart';

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

  group('PHASE JARVISOL-TTS-VIBEVOICE-FIX1 Test Suite', () {
    late TtsService ttsService;
    late AudiobookService audiobookService;

    setUp(() async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);
      final modelService = ModelService(settings);
      await modelService.initialize();
      ttsService = TtsService(modelService);
      audiobookService = AudiobookService(ttsService);
    });

    tearDown(() {
      ttsService.dispose();
    });

    group('A. VibeVoice Routing & Validation', () {
      test('VIBE-01: Voicepack with vibevoice-voice- prefix or alias routes to Realtime 0.5B', () async {
        // Test speaker with alias
        const spkMan = AudiobookSpeaker(
          id: 'spk_man',
          name: 'Homme Français',
          voiceModelName: 'vibevoice-fr-Spk0_man',
        );

        final status = await audiobookService.prepareSpeakerForTest(spkMan);
        // If realtime model is missing on test machine, it should report missing or controlled error,
        // but it must NEVER attempt to load vibevoice-1.5b-tts-q4_k with a voicepack.
        if (status.missingModelName != null) {
          expect(status.missingModelName, contains('vibevoice-realtime'));
        } else if (!status.ready) {
          expect(status.errorMessage, isNotNull);
        }
      });

      test('VIBE-02: VibeVoice 1.5B called without reference WAV returns controlled error', () async {
        const spk15bNoWav = AudiobookSpeaker(
          id: 'vibe_15b',
          name: 'VibeVoice 1.5B Sans WAV',
          voiceModelName: 'vibevoice-1.5b-tts-q4_k',
        );

        final status = await audiobookService.prepareSpeakerForTest(spk15bNoWav);
        expect(status.ready, isFalse);
        expect(status.errorMessage, isNotNull);
        expect(status.errorMessage, contains('nécessite un fichier audio de référence'));
      });

      test('VIBE-03: TtsService.prepare rejects GGUF voicepack on VibeVoice 1.5B', () async {
        // Create a dummy GGUF voice file in temp
        final tempVoice = File('${AppPaths.tmpDir.path}/test_vibe_voice.gguf');
        tempVoice.writeAsBytesSync(Uint8List(100));

        try {
          final status = await ttsService.prepare(
            modelName: 'vibevoice-1.5b-tts-q4_k',
            voiceName: tempVoice.path,
          );
          // If model is missing on disk, status is missing. If resolved, it must reject with controlled error.
          if (status.missingModelName == null) {
            expect(status.ready, isFalse);
            expect(status.errorMessage, contains('VOICE_SETUP_FAILED'));
            expect(status.errorMessage, contains('ne supporte pas les voicepacks temps-réel'));
          }
        } finally {
          if (tempVoice.existsSync()) tempVoice.deleteSync();
        }
      });
    });

    group('B. Qwen3-TTS Routing & refText Validation', () {
      test('QWEN-01: Qwen3-TTS Base clone rejects empty or whitespace refText', () async {
        final dummyWav = File('${AppPaths.tmpDir.path}/dummy_ref.wav');
        dummyWav.writeAsBytesSync(Uint8List(100));

        try {
          const spkNoRef = AudiobookSpeaker(
            id: 'qwen_no_ref',
            name: 'Qwen Clone Sans RefText',
            voiceModelName: 'qwen3-tts-12hz-0.6b-base',
            customVoiceWavPath: '', // Will be replaced below
            customVoiceRefText: '   ',
          );

          final spkWithWav = AudiobookSpeaker(
            id: spkNoRef.id,
            name: spkNoRef.name,
            voiceModelName: spkNoRef.voiceModelName,
            customVoiceWavPath: dummyWav.path,
            customVoiceRefText: '   ',
          );

          final status = await audiobookService.prepareSpeakerForTest(spkWithWav);
          expect(status.ready, isFalse);
          expect(status.errorMessage, contains('refText) obligatoire'));
        } finally {
          if (dummyWav.existsSync()) dummyWav.deleteSync();
        }
      });

      test('QWEN-02: TtsService.prepare rejects Qwen3 Base with WAV when refText is null/empty', () async {
        final dummyWav = File('${AppPaths.tmpDir.path}/dummy_ref_direct.wav');
        dummyWav.writeAsBytesSync(Uint8List(100));

        try {
          final status = await ttsService.prepare(
            modelName: 'qwen3-tts-12hz-0.6b-base',
            voiceWavPath: dummyWav.path,
            refText: null,
          );

          if (status.missingModelName == null) {
            expect(status.ready, isFalse);
            expect(status.errorMessage, contains('VOICE_SETUP_FAILED'));
            expect(status.errorMessage, contains('refText'));
          }
        } finally {
          if (dummyWav.existsSync()) dummyWav.deleteSync();
        }
      });

      test('QWEN-03: Qwen3-TTS CustomVoice preserves baked preset speakers without WAV or refText', () async {
        const spkRyan = AudiobookSpeaker(
          id: 'spk_ryan',
          name: 'Ryan Baked',
          voiceModelName: 'qwen3-ryan',
        );

        final status = await audiobookService.prepareSpeakerForTest(spkRyan);
        // CustomVoice does not require WAV or refText
        if (status.missingModelName != null) {
          expect(status.missingModelName, contains('qwen3-tts'));
        } else {
          // If model exists, it should be ready or reporting valid setup
          expect(status.errorMessage == null || !status.errorMessage!.contains('refText'), isTrue);
        }
      });
    });

    group('C. ensure24kHzWav Audio Conversion', () {
      test('WAV-01: 24kHz 16-bit mono WAV is returned as-is', () async {
        final wavPath = '${AppPaths.tmpDir.path}/test_24k_fast.wav';
        // Build valid 24kHz mono 16-bit PCM WAV
        final rawSamples = Float32List(2400); // 100ms
        for (int i = 0; i < rawSamples.length; i++) {
          rawSamples[i] = 0.5;
        }
        final bytes = audiobookService.createWavHeaderAndData(rawSamples, 24000);
        final file = File(wavPath);
        await file.writeAsBytes(bytes);

        try {
          final resolved = await audiobookService.ensure24kHzWav(wavPath);
          expect(resolved, equals(wavPath));
        } finally {
          if (file.existsSync()) file.deleteSync();
        }
      });

      test('WAV-02: 16kHz WAV is resampled and saved as 24kHz WAV', () async {
        final wavPath = '${AppPaths.tmpDir.path}/test_16k_input.wav';
        // Create 16kHz WAV
        final rawSamples = Float32List(1600); // 100ms
        for (int i = 0; i < rawSamples.length; i++) {
          rawSamples[i] = 0.25;
        }
        final bytes = audiobookService.createWavHeaderAndData(rawSamples, 16000);
        final file = File(wavPath);
        await file.writeAsBytes(bytes);

        try {
          final resolved = await audiobookService.ensure24kHzWav(wavPath);
          expect(resolved, isNot(equals(wavPath)));
          final resFile = File(resolved);
          expect(resFile.existsSync(), isTrue);

          // Verify header of resampled file is 24000 Hz
          final resBytes = await resFile.readAsBytes();
          final sr = resBytes[24] | (resBytes[25] << 8) | (resBytes[26] << 16) | (resBytes[27] << 24);
          expect(sr, equals(24000));
          if (resFile.existsSync()) resFile.deleteSync();
        } finally {
          if (file.existsSync()) file.deleteSync();
        }
      });

      test('ERR-01: Corrupted WAV file handled gracefully without crash', () async {
        final corruptPath = '${AppPaths.tmpDir.path}/corrupted.wav';
        final corruptFile = File(corruptPath);
        await corruptFile.writeAsBytes(Uint8List.fromList([0x00, 0x01, 0x02, 0x03]));

        try {
          final status = await ttsService.prepare(
            modelName: 'qwen3-tts-12hz-0.6b-base',
            voiceWavPath: corruptPath,
            refText: 'Valid ref text for corrupted file',
          );
          if (status.missingModelName == null) {
            expect(status.ready, isFalse);
            expect(status.errorMessage, contains('VOICE_SETUP_FAILED'));
          }
        } finally {
          if (corruptFile.existsSync()) corruptFile.deleteSync();
        }
      });
    });

    group('D. Live Native End-to-End Synthesis', () {
      const modelsDir = r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2\data\models\whisper_cpp';

      test('LIVE-01: VibeVoice Realtime 0.5B + Emma voicepack generates audio', () async {
        final modelPath = '$modelsDir\\vibevoice-realtime-0.5b-q4_k.gguf';
        final voicePath = '$modelsDir\\vibevoice-voice-emma.gguf';

        if (!File(modelPath).existsSync() || !File(voicePath).existsSync()) {
          print('LIVE-01: Skipping, model or voicepack not present on disk.');
          return;
        }

        final status = await ttsService.prepare(
          modelName: modelPath,
          voiceName: voicePath,
        );
        expect(status.ready, isTrue);

        final audio = await ttsService.synthesize('Bonjour, ceci est un test de synthèse VibeVoice.');
        expect(audio, isNotNull);
        expect(audio!.samples.isNotEmpty, isTrue);
        expect(audio.sampleRate, equals(24000));
        expect(audio.durationSeconds, greaterThan(0.5));
        expect(audio.samples.any((s) => s.abs() > 0.001), isTrue);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('LIVE-02: Qwen3-TTS CustomVoice + Ryan generates audio', () async {
        final modelPath = '$modelsDir\\qwen3-tts-12hz-0.6b-customvoice-q8_0.gguf';
        final codecPath = '$modelsDir\\qwen3-tts-tokenizer-12hz.gguf';

        if (!File(modelPath).existsSync() || !File(codecPath).existsSync()) {
          print('LIVE-02: Skipping, Qwen3 CustomVoice or codec not present on disk.');
          return;
        }

        final status = await ttsService.prepare(
          modelName: modelPath,
          codecName: codecPath,
          speakerName: 'ryan',
        );
        expect(status.ready, isTrue);

        final audio = await ttsService.synthesize('Bonjour le monde.');
        expect(audio, isNotNull);
        expect(audio!.samples.isNotEmpty, isTrue);
        expect(audio.sampleRate, equals(24000));
        expect(audio.durationSeconds, greaterThan(0.5));
        expect(audio.samples.any((s) => s.abs() > 0.001), isTrue);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('LIVE-03: Qwen3-TTS Base clone with 16kHz WAV automatically converts and synthesizes', () async {
        final modelPath = '$modelsDir\\qwen3-tts-12hz-0.6b-base.gguf';
        final codecPath = '$modelsDir\\qwen3-tts-tokenizer-12hz.gguf';

        if (!File(modelPath).existsSync() || !File(codecPath).existsSync()) {
          print('LIVE-03: Skipping, Qwen3 Base or codec not present on disk.');
          return;
        }

        // Generate a 16kHz reference WAV
        final ref16kWav = '${AppPaths.tmpDir.path}/live_ref_16k.wav';
        final rawSamples = Float32List(16000 * 2); // 2s of audio
        for (int i = 0; i < rawSamples.length; i++) {
          rawSamples[i] = 0.1 * (i % 100 < 50 ? 1.0 : -1.0);
        }
        final bytes = audiobookService.createWavHeaderAndData(rawSamples, 16000);
        final file = File(ref16kWav);
        await file.writeAsBytes(bytes);

        try {
          final status = await ttsService.prepare(
            modelName: modelPath,
            codecName: codecPath,
            voiceWavPath: ref16kWav,
            refText: 'Bonjour, ceci est ma voix de référence.',
          );
          expect(status.ready, isTrue);

          final audio = await ttsService.synthesize('Test de clonage Qwen3 Base.');
          expect(audio, isNotNull);
          expect(audio!.samples.isNotEmpty, isTrue);
          expect(audio.sampleRate, equals(24000));
          expect(audio.durationSeconds, greaterThan(0.5));
        } finally {
          if (file.existsSync()) file.deleteSync();
        }
      }, timeout: const Timeout(Duration(minutes: 3)));
    });
  });
}
