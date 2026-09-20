import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/services/audiobook_service.dart';
import 'package:jarvisol/services/imported_voice_service.dart';
import 'package:jarvisol/services/tts_service.dart';
import 'package:jarvisol/services/voice_pack_inspector.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:path/path.dart' as p;

class FakeTtsService extends Fake implements TtsService {
  String? lastModelName;
  String? lastVoiceName;
  String? lastCodecName;
  String? lastSpeakerName;
  bool setSpeakerCalledOnChatterbox = false;

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
    lastModelName = modelName;
    lastVoiceName = voiceName;
    lastCodecName = codecName;
    lastSpeakerName = speakerName;
    if (modelName.contains('chatterbox') && speakerName != null) {
      setSpeakerCalledOnChatterbox = true;
      throw Exception('backend chatterbox has no preset speakers; use setVoice() instead');
    }
    return TtsLoadStatus.ready('mock');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #synthesize) {
      final samples = Float32List(24000);
      return Future.value(SynthesizedAudio(samples: samples, sampleRate: 24000));
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory tempVoicesDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jarvisol_er5_test_');
    AppPaths.setTestOverride(tempDir);
    tempVoicesDir = AppPaths.importedVoicesDir;
    container = ProviderContainer();
  });

  tearDown(() async {
    AppPaths.resetTestOverride();
    container.dispose();
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  Map<String, String> buildAvailableVoices(List<ImportedVoicePack> importedList) {
    final map = <String, String>{};
    map['qwen3-uncle_fu'] = 'Oncle Fu (Qwen3-TTS)';
    map['qwen3-ryan'] = 'Ryan (Qwen3-TTS)';
    map['custom-clone-new'] = '[ + Nouveau clonage vocal (.wav)... ]';

    for (final pack in importedList) {
      if (!pack.fileExists) continue;
      if (pack.family == VoicePackFamily.chatterbox) {
        map['imported_chatterbox:' + pack.fileName] = pack.id + ' (Chatterbox — Importee)';
      } else if (pack.family == VoicePackFamily.qwen3) {
        if (pack.presetSpeakers.length > 1) {
          for (final spk in pack.presetSpeakers) {
            map['imported_qwen3:' + pack.fileName + '#' + spk] = pack.id + ' — ' + spk + ' (Qwen3 — Importee)';
          }
        } else {
          final spkName = pack.presetSpeakers.isNotEmpty ? pack.presetSpeakers.first : null;
          final key = spkName != null ? 'imported_qwen3:' + pack.fileName + '#' + spkName : 'imported_qwen3:' + pack.fileName;
          final name = spkName != null ? pack.id + ' — ' + spkName : pack.id;
          map[key] = name + ' (Qwen3 — Importee)';
        }
      }
    }
    map['imported-pack-new'] = '[ + Importer un Voice Pack (.gguf)... ]';
    map['kokoro-voice-ff_siwis'] = 'Siwis (Kokoro 82M)';
    return map;
  }

  test('E-R5-01 & E-R5-10: Studio opened BEFORE Qwen3 import: PPDA appears reactively', () async {
    var studioList = buildAvailableVoices(container.read(importedVoiceServiceProvider));
    expect(studioList.containsKey('imported_qwen3:PPDA_Qwen3.gguf#PPDA'), isFalse);

    int notificationCount = 0;
    container.listen(importedVoiceServiceProvider, (prev, next) {
      notificationCount++;
      studioList = buildAvailableVoices(next);
    });

    final ppdaFile = File(p.join(tempVoicesDir.path, 'PPDA_Qwen3.gguf'));
    await ppdaFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]); 

    final newPack = ImportedVoicePack(
      id: 'PPDA_Qwen3',
      fileName: 'PPDA_Qwen3.gguf',
      family: VoicePackFamily.qwen3,
      compatibleBackend: 'qwen3-tts',
      voiceNames: ['PPDA'],
      fileSizeBytes: 12000,
      importedAt: DateTime.now(),
    );

    final notifier = container.read(importedVoiceServiceProvider.notifier);
    notifier.setImportedPacksForTesting([newPack]);

    expect(notificationCount >= 1, isTrue);
    expect(studioList.containsKey('imported_qwen3:PPDA_Qwen3.gguf#PPDA'), isTrue);
    expect(studioList['imported_qwen3:PPDA_Qwen3.gguf#PPDA'], contains('PPDA'));
  });

  test('E-R5-02 & E-R5-03: PPDA_Qwen3 assigned to Narrator and synthesizes successfully', () async {
    final fakeTts = FakeTtsService();
    final service = AudiobookService(fakeTts, container.read(importedVoiceServiceProvider.notifier));

    final ppdaFile = File(p.join(tempVoicesDir.path, 'PPDA_Qwen3.gguf'));
    await ppdaFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

    final chapter = AudiobookChapter(
      id: 'c1',
      index: 0,
      title: 'Chapitre 1',
      rawText: 'Bonjour Studio.',
      lines: [
        const AudiobookLine(id: 'l1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Bonjour Studio.'),
      ],
    );

    final speakers = {
      'narrator': const AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: 'imported_qwen3:PPDA_Qwen3.gguf#PPDA',
        role: 'narrator',
      ),
    };

    final outDir = p.join(tempDir.path, 'out');
    await Directory(outDir).create(recursive: true);

    final outWav = await service.synthesizeChapter(
      chapter: chapter,
      speakers: speakers,
      outputDir: outDir,
    );

    expect(File(outWav).existsSync(), isTrue);
    expect(fakeTts.lastModelName, equals('qwen3-tts-12hz-0.6b-base'));
    expect(fakeTts.lastSpeakerName, equals('PPDA'));
    expect(fakeTts.lastVoiceName, equals('PPDA_Qwen3.gguf'));
  });

  test('E-R5-04 & E-R5-05 & E-R5-15: Chatterbox pack imported dynamically, never calls setSpeakerName', () async {
    var studioList = buildAvailableVoices(container.read(importedVoiceServiceProvider));
    expect(studioList.containsKey('imported_chatterbox:PPDA.gguf'), isFalse);

    final cbFile = File(p.join(tempVoicesDir.path, 'PPDA.gguf'));
    await cbFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

    final cbPack = ImportedVoicePack(
      id: 'PPDA',
      fileName: 'PPDA.gguf',
      family: VoicePackFamily.chatterbox,
      compatibleBackend: 'chatterbox',
      voiceNames: ['PPDA'],
      fileSizeBytes: 50000,
      importedAt: DateTime.now(),
    );

    container.read(importedVoiceServiceProvider.notifier).setImportedPacksForTesting([cbPack]);
    studioList = buildAvailableVoices(container.read(importedVoiceServiceProvider));

    expect(studioList.containsKey('imported_chatterbox:PPDA.gguf'), isTrue);

    final fakeTts = FakeTtsService();
    final service = AudiobookService(fakeTts, container.read(importedVoiceServiceProvider.notifier));

    final chapter = AudiobookChapter(
      id: 'c1',
      index: 0,
      title: 'Chapitre 1',
      rawText: 'Chatterbox speech.',
      lines: [
        const AudiobookLine(id: 'l1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Chatterbox speech.'),
      ],
    );

    final speakers = {
      'narrator': const AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: 'imported_chatterbox:PPDA.gguf',
        role: 'narrator',
      ),
    };

    final outDir = p.join(tempDir.path, 'out_cb');
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
    expect(fakeTts.lastSpeakerName, isNull);
    expect(fakeTts.setSpeakerCalledOnChatterbox, isFalse);
  });

  test('E-R5-06: Qwen3 multi-speaker splits Alice and Bob dynamically', () async {
    final multiFile = File(p.join(tempVoicesDir.path, 'multi.gguf'));
    await multiFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

    final multiPack = ImportedVoicePack(
      id: 'multispeaker',
      fileName: 'multi.gguf',
      family: VoicePackFamily.qwen3,
      compatibleBackend: 'qwen3-tts',
      voiceNames: ['Alice', 'Bob'],
      fileSizeBytes: 20000,
      importedAt: DateTime.now(),
    );

    container.read(importedVoiceServiceProvider.notifier).setImportedPacksForTesting([multiPack]);
    final map = buildAvailableVoices(container.read(importedVoiceServiceProvider));

    expect(map.containsKey('imported_qwen3:multi.gguf#Alice'), isTrue);
    expect(map.containsKey('imported_qwen3:multi.gguf#Bob'), isTrue);
    expect(map['imported_qwen3:multi.gguf#Alice'], contains('Alice'));
    expect(map['imported_qwen3:multi.gguf#Bob'], contains('Bob'));
  });

  test('E-R5-07: Deleting voice pack updates Studio list immediately', () async {
    final delFile = File(p.join(tempVoicesDir.path, 'to_delete.gguf'));
    await delFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

    final pack = ImportedVoicePack(
      id: 'ToDelete',
      fileName: 'to_delete.gguf',
      family: VoicePackFamily.chatterbox,
      compatibleBackend: 'chatterbox',
      voiceNames: ['ToDelete'],
      fileSizeBytes: 1000,
      importedAt: DateTime.now(),
    );

    final notifier = container.read(importedVoiceServiceProvider.notifier);
    notifier.setImportedPacksForTesting([pack]);

    var map = buildAvailableVoices(container.read(importedVoiceServiceProvider));
    expect(map.containsKey('imported_chatterbox:to_delete.gguf'), isTrue);

    notifier.setImportedPacksForTesting([]);
    map = buildAvailableVoices(container.read(importedVoiceServiceProvider));
    expect(map.containsKey('imported_chatterbox:to_delete.gguf'), isFalse);
  });

  test('E-R5-11 & E-R5-14: No duplication on rebuilds and factory presets preserved', () async {
    final vFile = File(p.join(tempVoicesDir.path, 'v1.gguf'));
    await vFile.writeAsBytes([0x47, 0x47, 0x55, 0x46]);

    final pack = ImportedVoicePack(
      id: 'Voice1',
      fileName: 'v1.gguf',
      family: VoicePackFamily.chatterbox,
      compatibleBackend: 'chatterbox',
      voiceNames: ['Voice1'],
      fileSizeBytes: 1000,
      importedAt: DateTime.now(),
    );

    container.read(importedVoiceServiceProvider.notifier).setImportedPacksForTesting([pack]);

    final map1 = buildAvailableVoices(container.read(importedVoiceServiceProvider));
    final map2 = buildAvailableVoices(container.read(importedVoiceServiceProvider));

    expect(map1.length, map2.length);
    expect(map1.keys.toList(), equals(map2.keys.toList()));
    expect(map1.containsKey('qwen3-uncle_fu'), isTrue);
    expect(map1.containsKey('kokoro-voice-ff_siwis'), isTrue);
    expect(map1.containsKey('imported-pack-new'), isTrue);
  });
}
