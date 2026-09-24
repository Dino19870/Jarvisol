import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crispasr/crispasr.dart' as crispasr;
import 'package:jarvisol/services/voice_pack_inspector.dart';
import 'package:jarvisol/services/imported_voice_service.dart';

void main() {
  const candidateDir = r'D:\Antigravity\AgentFolder\Jarvisol_V1_EXT03_Candidate';
  const dllPath = r'D:\Antigravity\AgentFolder\Jarvisol_V1_EXT03_Candidate\crispasr.dll';
  const sampleWav = r'D:\Antigravity\AgentFolder\VoiceBake\fixtures\test_sample.wav';
  const multiGguf = r'D:\Antigravity\AgentFolder\VoiceBake\fixtures\multispeaker_qwen3_alice_bob.gguf';

  group('Phase E-R3 End-to-End Live TTS Routing & Synthesis', () {
    test('E-R3-01 to E-R3-06: Chatterbox Baked Voice Pack import, routing, and real synthesis', () {
      final cbT3 = '\\data\\models\\whisper_cpp\\chatterbox-t3-q8_0.gguf';
      final cbS3 = '\\data\\models\\whisper_cpp\\chatterbox-s3gen-q8_0.gguf';
      final cbVoice = '\\VoiceBake\\output\\er2_cand_chatterbox.gguf';

      expect(File(dllPath).existsSync(), isTrue);
      expect(File(cbT3).existsSync(), isTrue);
      expect(File(cbS3).existsSync(), isTrue);
      expect(File(cbVoice).existsSync(), isTrue);

      // E-R3-01 & E-R3-02: Inspect pack
      final inspection = VoicePackInspector.inspect(cbVoice);
      expect(inspection.isValid, isTrue);
      expect(inspection.family, VoicePackFamily.chatterbox);
      expect(inspection.architecture, 'chatterbox-voice');

      final importedPack = ImportedVoicePack(
        id: 'er2_cand_chatterbox',
        fileName: 'er2_cand_chatterbox.gguf',
        family: inspection.family!,
        compatibleBackend: inspection.compatibleBackend!,
        voiceNames: inspection.voiceNames,
        fileSizeBytes: inspection.fileSizeBytes,
        importedAt: DateTime.now(),
      );

      // E-R3-03: presetSpeakers must be empty for Chatterbox
      expect(importedPack.presetSpeakers, isEmpty);

      // E-R3-04 & E-R3-05: Real synthesis using exact routing: setVoice only, NO setSpeakerName
      final s = crispasr.CrispasrSession.open(
        cbT3,
        backend: 'chatterbox',
        libPath: dllPath,
      );

      try {
        s.setCodecPath(cbS3);
        // E-R3-04: setVoice is called with GGUF path
        s.setVoice(cbVoice);

        // Verify that s.speakers() is empty
        expect(s.speakers(), isEmpty);

        // E-R3-05: Real synthesis produces audio without exception
        final pcm = s.synthesize('Test synthese Chatterbox voix importee.');
        expect(pcm, isNotNull);
        expect(pcm.length, greaterThan(24000), reason: 'Must produce at least 1s of audio at 24kHz');
        print('Chatterbox PCM produced: \ samples (\s)');
      } finally {
        s.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('E-R3-07 to E-R3-09: Qwen3 multi-speaker voice pack with Alice and Bob', () {
      final qwen3Base = '\\data\\models\\whisper_cpp\\qwen3-tts-12hz-0.6b-base.gguf';
      final qwen3Codec = '\\data\\models\\whisper_cpp\\qwen3-tts-tokenizer-12hz.gguf';

      expect(File(qwen3Base).existsSync(), isTrue);
      expect(File(qwen3Codec).existsSync(), isTrue);
      expect(File(multiGguf).existsSync(), isTrue);

      final s = crispasr.CrispasrSession.open(
        qwen3Base,
        backend: 'qwen3-tts',
        libPath: dllPath,
      );

      try {
        s.setCodecPath(qwen3Codec);
        s.setVoice(multiGguf);

        final speakers = s.speakers();
        print('Qwen3 multi-speaker names: ');
        expect(speakers.length, 2);
        expect(speakers, contains('Alice'));
        expect(speakers, contains('Bob'));

        // E-R3-08: Alice
        s.setSpeakerName('Alice');
        final pcmAlice = s.synthesize('Bonjour, test Alice.');
        expect(pcmAlice.length, greaterThan(1000));
        print('Alice PCM produced: \ samples');

        // E-R3-09: Bob
        s.setSpeakerName('Bob');
        final pcmBob = s.synthesize('Bonjour, test Bob.');
        expect(pcmBob.length, greaterThan(1000));
        print('Bob PCM produced: \ samples');
      } finally {
        s.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('E-R3-10: Qwen3 WAV clone + refText', () {
      final qwen3Base = '\\data\\models\\whisper_cpp\\qwen3-tts-12hz-0.6b-base.gguf';
      final qwen3Codec = '\\data\\models\\whisper_cpp\\qwen3-tts-tokenizer-12hz.gguf';

      final s = crispasr.CrispasrSession.open(
        qwen3Base,
        backend: 'qwen3-tts',
        libPath: dllPath,
      );

      try {
        s.setCodecPath(qwen3Codec);
        s.setVoice(sampleWav, refText: 'Sample reference text');
        final pcm = s.synthesize('Test clonage WAV direct.');
        expect(pcm.length, greaterThan(1000));
        print('WAV clone PCM produced: \ samples');
      } finally {
        s.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('E-R3-11: Kokoro + af_heart baseline', () {
      final kokoroModel = '\\data\\models\\whisper_cpp\\kokoro-82m-q8_0.gguf';
      final kokoroVoice = '\\data\\models\\whisper_cpp\\kokoro-voice-af_heart.gguf';

      final s = crispasr.CrispasrSession.open(
        kokoroModel,
        backend: 'kokoro',
        libPath: dllPath,
      );

      try {
        s.setVoice(kokoroVoice);
        final pcm = s.synthesize('Hello from Kokoro baseline.');
        expect(pcm.length, greaterThan(1000));
        print('Kokoro PCM produced: \ samples');
      } finally {
        s.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
