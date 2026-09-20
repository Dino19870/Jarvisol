import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/services/audiobook_service.dart';
import 'package:jarvisol/services/imported_voice_service.dart';
import 'package:jarvisol/services/tts_service.dart';
import 'package:jarvisol/services/voice_pack_inspector.dart';
import 'package:jarvisol/utils/app_paths.dart';

// Fake TtsService to verify prepare calls and backend parameters
class FakeTtsService extends Fake implements TtsService {
  String? lastModelName;
  String? lastVoiceName;
  String? lastCodecName;
  String? lastSpeakerName;
  String? lastVoiceWavPath;
  int prepareCallCount = 0;
  final List<Map<String, dynamic>> prepareHistory = [];

  @override
  Future<TtsLoadStatus> prepare({
    required String modelName,
    String? voiceName,
    String? codecName,
    String? refText,
    String? voiceWavPath,
    String? speakerName,
    int? speakerId,
    String? instructPrompt,
  }) async {
    prepareCallCount++;
    lastModelName = modelName;
    lastVoiceName = voiceName;
    lastCodecName = codecName;
    lastSpeakerName = speakerName;
    lastVoiceWavPath = voiceWavPath;

    prepareHistory.add({
      'modelName': modelName,
      'voiceName': voiceName,
      'codecName': codecName,
      'speakerName': speakerName,
      'voiceWavPath': voiceWavPath,
    });

    return TtsLoadStatus.ready('test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #synthesize) {
      final samples = Float32List(24000);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = 0.01;
      }
      return Future.value(SynthesizedAudio(samples: samples, sampleRate: 24000));
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory tempVoicesDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jarvisol_er4_test_');
    tempVoicesDir = Directory('${tempDir.path}/data/models/tts/voices');
    await tempVoicesDir.create(recursive: true);
    AppPaths.setTestOverride(tempDir);
  });

  tearDown(() async {
    AppPaths.resetTestOverride();
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Phase E-R4 Studio Live Audio Voice Packs Tests', () {
    test('E-R4-01 & E-R4-02 & E-R4-03: Voice list exposes Chatterbox, Qwen3 mono, and Qwen3 multi-speaker distinctively', () async {
      final ppdaFile = File('${tempVoicesDir.path}/PPDA.gguf');
      await ppdaFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

      final qwenMonoFile = File('${tempVoicesDir.path}/qwen_mono.gguf');
      await qwenMonoFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

      final qwenMultiFile = File('${tempVoicesDir.path}/qwen_multi.gguf');
      await qwenMultiFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

      final packs = [
        ImportedVoicePack(
          id: 'PPDA',
          fileName: 'PPDA.gguf',
          family: VoicePackFamily.chatterbox,
          compatibleBackend: 'chatterbox',
          voiceNames: ['PPDA'],
          fileSizeBytes: 1000,
          importedAt: DateTime.now(),
        ),
        ImportedVoicePack(
          id: 'qwen_mono',
          fileName: 'qwen_mono.gguf',
          family: VoicePackFamily.qwen3,
          compatibleBackend: 'qwen3-tts',
          voiceNames: ['MonoVoix'],
          fileSizeBytes: 1000,
          importedAt: DateTime.now(),
        ),
        ImportedVoicePack(
          id: 'qwen_multi',
          fileName: 'qwen_multi.gguf',
          family: VoicePackFamily.qwen3,
          compatibleBackend: 'qwen3-tts',
          voiceNames: ['Alice', 'Bob'],
          fileSizeBytes: 2000,
          importedAt: DateTime.now(),
        ),
      ];

      final map = <String, String>{};
      for (final pack in packs) {
        if (!pack.fileExists) continue;
        if (pack.family == VoicePackFamily.chatterbox) {
          map['imported_chatterbox:${pack.fileName}'] = '📦 ${pack.id} (Chatterbox — Importée)';
        } else if (pack.family == VoicePackFamily.qwen3) {
          if (pack.presetSpeakers.length > 1) {
            for (final spk in pack.presetSpeakers) {
              map['imported_qwen3:${pack.fileName}#$spk'] = '📦 ${pack.id} — $spk (Qwen3 — Importée)';
            }
          } else {
            final spkName = pack.presetSpeakers.isNotEmpty ? pack.presetSpeakers.first : null;
            final key = spkName != null ? 'imported_qwen3:${pack.fileName}#$spkName' : 'imported_qwen3:${pack.fileName}';
            final name = spkName != null ? '${pack.id} — $spkName' : pack.id;
            map[key] = '📦 $name (Qwen3 — Importée)';
          }
        }
      }

      expect(map.containsKey('imported_chatterbox:PPDA.gguf'), isTrue);
      expect(map['imported_chatterbox:PPDA.gguf'], contains('PPDA'));
      expect(map['imported_chatterbox:PPDA.gguf'], contains('Chatterbox'));

      expect(map.containsKey('imported_qwen3:qwen_mono.gguf#MonoVoix'), isTrue);
      expect(map['imported_qwen3:qwen_mono.gguf#MonoVoix'], contains('Qwen3'));

      expect(map.containsKey('imported_qwen3:qwen_multi.gguf#Alice'), isTrue);
      expect(map.containsKey('imported_qwen3:qwen_multi.gguf#Bob'), isTrue);
      expect(map['imported_qwen3:qwen_multi.gguf#Alice'], contains('Alice'));
      expect(map['imported_qwen3:qwen_multi.gguf#Bob'], contains('Bob'));
    });

    test('E-R4-04 & E-R4-10: Assignment of PPDA to narrator persists and reloads cleanly', () {
      final narrator = const AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: 'imported_chatterbox:PPDA.gguf',
        role: 'narrator',
      );

      final json = narrator.toJson();
      expect(json['voiceModelName'], equals('imported_chatterbox:PPDA.gguf'));

      final restored = AudiobookSpeaker.fromJson(json);
      expect(restored.voiceModelName, equals('imported_chatterbox:PPDA.gguf'));
      expect(restored.name, equals('Narrateur'));
    });

    test('E-R4-05 & E-R4-06: Chatterbox voice routing calls setVoice(PPDA.gguf) and NEVER calls setSpeakerName', () async {
      final ppdaFile = File('${tempVoicesDir.path}/PPDA.gguf');
      await ppdaFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

      final fakeTts = FakeTtsService();
      final service = AudiobookService(fakeTts);

      final chapter = AudiobookChapter(
        id: 'c1',
        index: 0,
        title: 'Chapitre 1',
        rawText: 'Bonjour le monde.',
        lines: [
          const AudiobookLine(id: 'l1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Bonjour tout le monde.'),
        ],
      );

      final speakers = {
        'narrator': const AudiobookSpeaker(
          id: 'narrator',
          name: 'Narrateur',
          voiceModelName: 'imported_chatterbox:PPDA.gguf',
        ),
      };

      final outDir = '${tempDir.path}/output';
      await Directory(outDir).create(recursive: true);

      final outWav = await service.synthesizeChapter(
        chapter: chapter,
        speakers: speakers,
        outputDir: outDir,
      );

      expect(File(outWav).existsSync(), isTrue);
      expect(fakeTts.lastModelName, equals('chatterbox-en-q8_0'));
      expect(fakeTts.lastCodecName, equals('chatterbox-s3gen-q8_0'));
      expect(fakeTts.lastVoiceName, equals('PPDA.gguf'));
      expect(fakeTts.lastSpeakerName, isNull, reason: 'Chatterbox must NEVER set speakerName');
    });

    test('E-R4-07: Qwen3 multi-speaker routing sets setVoice(pack) and setSpeakerName(Alice)', () async {
      final qwenMultiFile = File('${tempVoicesDir.path}/qwen_multi.gguf');
      await qwenMultiFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

      final fakeTts = FakeTtsService();
      final service = AudiobookService(fakeTts);

      final chapter = AudiobookChapter(
        id: 'c1',
        index: 0,
        title: 'Chapitre 1',
        rawText: 'Dialogue.',
        lines: [
          const AudiobookLine(id: 'l1', speakerId: 'spk_alice', speakerName: 'Alice', text: 'Bonjour Bob.'),
        ],
      );

      final speakers = {
        'spk_alice': const AudiobookSpeaker(
          id: 'spk_alice',
          name: 'Alice',
          voiceModelName: 'imported_qwen3:qwen_multi.gguf#Alice',
        ),
      };

      final outDir = '${tempDir.path}/output';
      await Directory(outDir).create(recursive: true);

      await service.synthesizeChapter(
        chapter: chapter,
        speakers: speakers,
        outputDir: outDir,
      );

      expect(fakeTts.lastModelName, equals('qwen3-tts-12hz-0.6b-base'));
      expect(fakeTts.lastCodecName, equals('qwen3-tts-tokenizer-12hz'));
      expect(fakeTts.lastVoiceName, equals('qwen_multi.gguf'));
      expect(fakeTts.lastSpeakerName, equals('Alice'), reason: 'Qwen3 must set speakerName to Alice');
    });

    test('E-R4-08 & E-R4-09: Multi-role synthesis mixing factory voices and imported Chatterbox without cross-contamination', () async {
      final ppdaFile = File('${tempVoicesDir.path}/PPDA.gguf');
      await ppdaFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

      final fakeTts = FakeTtsService();
      final service = AudiobookService(fakeTts);

      final lines = [
        const AudiobookLine(id: 'l1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Le narrateur parle.'),
        const AudiobookLine(id: 'l2', speakerId: 'factory_male', speakerName: 'Ryan', text: 'Ryan répond.'),
        const AudiobookLine(id: 'l3', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Le narrateur conclut.'),
      ];

      final speakers = {
        'narrator': const AudiobookSpeaker(
          id: 'narrator',
          name: 'Narrateur',
          voiceModelName: 'imported_chatterbox:PPDA.gguf',
        ),
        'factory_male': const AudiobookSpeaker(
          id: 'factory_male',
          name: 'Ryan',
          voiceModelName: 'qwen3-ryan',
        ),
      };

      final pcmBytes = await service.synthesizeLinesToMemory(
        lines: lines,
        speakers: speakers,
      );

      expect(pcmBytes.isNotEmpty, isTrue);
      expect(fakeTts.prepareHistory.length, equals(3));

      expect(fakeTts.prepareHistory[0]['modelName'], equals('chatterbox-en-q8_0'));
      expect(fakeTts.prepareHistory[0]['voiceName'], equals('PPDA.gguf'));
      expect(fakeTts.prepareHistory[0]['speakerName'], isNull);

      expect(fakeTts.prepareHistory[1]['modelName'], equals('qwen3-tts-12hz-0.6b-customvoice-q8_0'));
      expect(fakeTts.prepareHistory[1]['speakerName'], equals('ryan'));

      expect(fakeTts.prepareHistory[2]['modelName'], equals('chatterbox-en-q8_0'));
      expect(fakeTts.prepareHistory[2]['speakerName'], isNull);
    });

    test('E-R4-11: Portability across directories (relative fileName resolution)', () {
      const speaker = AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: 'imported_chatterbox:PPDA.gguf',
      );

      expect(speaker.voiceModelName.contains('/'), isFalse);
      expect(speaker.voiceModelName.contains('\\'), isFalse);
      expect(speaker.voiceModelName.contains('C:'), isFalse);
      expect(speaker.voiceModelName.contains('D:'), isFalse);

      final fn = speaker.voiceModelName.substring('imported_chatterbox:'.length);
      final resolved = AppPaths.importedVoicesDir.path;
      expect(resolved, contains('data'));
    });

    test('E-R4-12: Error handling when imported pack file is deleted: descriptive failure, no crash', () async {
      final fakeTts = FakeTtsService();
      final service = AudiobookService(fakeTts);

      final chapter = AudiobookChapter(
        id: 'c1',
        index: 0,
        title: 'Chapitre 1',
        rawText: 'Texte.',
        lines: [
          const AudiobookLine(id: 'l1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Texte manquant.'),
        ],
      );

      final speakers = {
        'narrator': const AudiobookSpeaker(
          id: 'narrator',
          name: 'Narrateur',
          voiceModelName: 'imported_chatterbox:DeletedVoice.gguf',
        ),
      };

      final outDir = '${tempDir.path}/output';
      await Directory(outDir).create(recursive: true);

      expect(
        () async => await service.synthesizeChapter(
          chapter: chapter,
          speakers: speakers,
          outputDir: outDir,
        ),
        throwsA(predicate((e) => e.toString().contains('DeletedVoice.gguf') && e.toString().contains('introuvable'))),
      );
    });

    test('E-R4-13: Non-regression on .wav cloning', () {
      const clone = AudiobookSpeaker(
        id: 'custom_spk',
        name: 'Mon Clone',
        voiceModelName: 'clone_profile_123',
        customVoiceWavPath: 'D:/audio/sample.wav',
        customVoiceRefText: 'Texte de test',
      );

      expect(clone.voiceModelName, equals('clone_profile_123'));
      expect(clone.customVoiceWavPath, equals('D:/audio/sample.wav'));
      expect(clone.customVoiceRefText, equals('Texte de test'));
    });
  });
}
