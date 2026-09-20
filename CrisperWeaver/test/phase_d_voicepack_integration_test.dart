import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:jarvisol/services/imported_voice_service.dart';
import 'package:jarvisol/services/voice_pack_inspector.dart';
import 'package:jarvisol/utils/app_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final chatterboxSample = r'C:\Jarvisol_Test\VoiceBake\output\C2_Chatterbox_Test.gguf';
  final qwen3Sample = r'C:\Jarvisol_Test\VoiceBake\output\C2_Qwen3_Test.gguf';
  final qwen3MultiSample = r'C:\Jarvisol_Test\VoiceBake\output\test_multispeaker_qwen3.gguf';
  final nonVoicepackModel = r'C:\Jarvisol_Test\candidate_release_c85_ext02_p4_nomodels\data\models\whisper_cpp\chatterbox-t3-q8_0.gguf';

  group('Phase D — Tests d''intégration Voice Packs GGUF', () {
    late Directory tempTestDir;
    late ImportedVoiceService service;

    setUp(() {
      tempTestDir = Directory.systemTemp.createTempSync('jarvisol_phase_d_test_');
      AppPaths.setTestOverride(tempTestDir);
      service = ImportedVoiceService();
    });

    tearDown(() {
      AppPaths.resetTestOverride();
      if (tempTestDir.existsSync()) {
        try {
          tempTestDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('D-01: Import Chatterbox valide', () async {
      if (!File(chatterboxSample).existsSync()) return;
      final imported = await service.importVoicePack(chatterboxSample);
      expect(imported.family, equals(VoicePackFamily.chatterbox));
      expect(imported.compatibleBackend, equals('chatterbox'));
      expect(File(imported.localPath).existsSync(), isTrue);
      expect(imported.fileName, equals('C2_Chatterbox_Test.gguf'));
    });

    test('D-02: Import Qwen3 valide', () async {
      if (!File(qwen3Sample).existsSync()) return;
      final imported = await service.importVoicePack(qwen3Sample);
      expect(imported.family, equals(VoicePackFamily.qwen3));
      expect(imported.compatibleBackend, equals('qwen3-tts'));
      expect(File(imported.localPath).existsSync(), isTrue);
      expect(imported.fileName, equals('C2_Qwen3_Test.gguf'));
    });

    test('D-03: Rejet GGUF non voice-pack (modèle principal t3)', () {
      if (!File(nonVoicepackModel).existsSync()) return;
      final res = VoicePackInspector.inspect(nonVoicepackModel);
      expect(res.isValid, isFalse);
      expect(res.errorMessage, contains('Architecture GGUF non reconnue'));
      expect(
        () async => await service.importVoicePack(nonVoicepackModel),
        throwsA(isA<VoicePackImportException>()),
      );
    });

    test('D-04: Rejet GGUF corrompu / fichier invalide', () {
      final corruptFile = File(p.join(tempTestDir.path, 'corrupt.gguf'));
      corruptFile.writeAsBytesSync([0x47, 0x47, 0x55, 0x46, 0x01]);
      final res = VoicePackInspector.inspect(corruptFile.path);
      expect(res.isValid, isFalse);
      expect(
        () async => await service.importVoicePack(corruptFile.path),
        throwsA(isA<VoicePackImportException>()),
      );
    });

    test('D-05: Nom Chatterbox lu depuis metadata (general.name)', () {
      if (!File(chatterboxSample).existsSync()) return;
      final res = VoicePackInspector.inspect(chatterboxSample);
      expect(res.isValid, isTrue);
      expect(res.voiceNames, contains('C2_Chatterbox_Test'));
    });

    test('D-06: voicepack.names Qwen3 lu', () {
      if (!File(qwen3Sample).existsSync()) return;
      final res = VoicePackInspector.inspect(qwen3Sample);
      expect(res.isValid, isTrue);
      expect(res.voiceNames, contains('C2_Qwen3_Test'));
    });

    test('D-07: Qwen3 multi-speaker lu et validé', () {
      if (!File(qwen3MultiSample).existsSync()) return;
      final res = VoicePackInspector.inspect(qwen3MultiSample);
      expect(res.isValid, isTrue);
      expect(res.voiceNames.length, equals(2));
      expect(res.voiceNames, contains('Alice'));
      expect(res.voiceNames, contains('Bob'));
    });

    test('D-08: Collision fichier existant sans écrasement silencieux', () async {
      if (!File(chatterboxSample).existsSync()) return;
      await service.importVoicePack(chatterboxSample);

      expect(
        () async => await service.importVoicePack(chatterboxSample, overwrite: false),
        throwsA(isA<VoicePackAlreadyExistsException>()),
      );

      final overwritten = await service.importVoicePack(chatterboxSample, overwrite: true);
      expect(overwritten.fileName, equals('C2_Chatterbox_Test.gguf'));
    });

    test('D-09: Source externe supprimée après import -> copie locale intacte', () async {
      if (!File(chatterboxSample).existsSync()) return;
      final tempSource = File(p.join(tempTestDir.path, 'temp_voice.gguf'));
      File(chatterboxSample).copySync(tempSource.path);

      final imported = await service.importVoicePack(tempSource.path);
      expect(File(imported.localPath).existsSync(), isTrue);

      tempSource.deleteSync();
      expect(tempSource.existsSync(), isFalse);

      expect(File(imported.localPath).existsSync(), isTrue);
      expect(imported.fileExists, isTrue);
    });

    test('D-10: Restart persistance (lecture depuis imported_voices.json)', () async {
      if (!File(chatterboxSample).existsSync()) return;
      await service.importVoicePack(chatterboxSample);

      final indexFile = AppPaths.importedVoicesIndexFile;
      expect(indexFile.existsSync(), isTrue);
      final jsonRaw = jsonDecode(indexFile.readAsStringSync()) as List<dynamic>;
      expect(jsonRaw.length, equals(1));
      expect(jsonRaw.first['fileName'], equals('C2_Chatterbox_Test.gguf'));

      final newService = ImportedVoiceService();
      final loaded = await newService.loadAll();
      expect(loaded.length, equals(1));
      expect(loaded.first.fileName, equals('C2_Chatterbox_Test.gguf'));
      expect(loaded.first.family, equals(VoicePackFamily.chatterbox));
    });

    test('D-11: Portabilité A -> B (pas de chemin absolu codé en dur)', () async {
      if (!File(chatterboxSample).existsSync()) return;
      final imported = await service.importVoicePack(chatterboxSample);

      final jsonMap = imported.toJson();
      expect(jsonMap.containsKey('fileName'), isTrue);
      expect(jsonMap.containsKey('localPath'), isFalse);
      expect(jsonMap['fileName'], equals('C2_Chatterbox_Test.gguf'));
      expect((jsonMap['fileName'] as String).contains(r':\'), isFalse);
      expect((jsonMap['fileName'] as String).contains('/'), isFalse);

      final movedDir = Directory.systemTemp.createTempSync('jarvisol_moved_dir_');
      try {
        AppPaths.setTestOverride(movedDir);
        expect(imported.localPath, equals(p.join(movedDir.path, 'data', 'models', 'tts', 'voices', 'C2_Chatterbox_Test.gguf')));
      } finally {
        AppPaths.setTestOverride(tempTestDir);
        if (movedDir.existsSync()) movedDir.deleteSync(recursive: true);
      }
    });

    test('D-12: Chatterbox non proposé sous Qwen3', () async {
      if (!File(chatterboxSample).existsSync()) return;
      await service.importVoicePack(chatterboxSample);

      final qwenPacks = service.getPacksForBackend('qwen3-tts');
      expect(qwenPacks.isEmpty, isTrue);
    });

    test('D-13: Qwen3 non proposé sous Chatterbox', () async {
      if (!File(qwen3Sample).existsSync()) return;
      await service.importVoicePack(qwen3Sample);

      final chatterboxPacks = service.getPacksForBackend('chatterbox');
      expect(chatterboxPacks.isEmpty, isTrue);
    });
  });
}
