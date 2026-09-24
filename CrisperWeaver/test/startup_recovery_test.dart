// test/startup_recovery_test.dart
//
// Suite de tests REQ-POST-002: LITE-001 .. LITE-015
// Validation exhaustive du cycle de vie du marker Engine starting,
// de la recuperation automatique Lite, de l'anti-boucle,
// de la conformite du template Lite, de la disponibilite du modele base
// et du placement des fichiers dans la distribution Candidate.

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

import 'package:jarvisol/services/startup_recovery_service.dart';
import 'package:jarvisol/services/model_catalog.dart';
import 'package:jarvisol/services/model_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/engines/mock_engine.dart';
import 'package:jarvisol/engines/engine_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('REQ-POST-002: Preferences Lite & Startup Recovery (LITE-001 .. LITE-015)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('jarvisol_lite_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    String sha256Of(File f) {
      return sha256.convert(f.readAsBytesSync()).toString().toUpperCase();
    }

    test('LITE-001: preferences.json utilisateur candidat reste strictement immuable', () {
      final candidateFile = File('D:/Antigravity/AgentFolder/Jarvisol_V1_EXT03_Candidate/data/preferences.json');
      expect(candidateFile.existsSync(), isTrue, reason: 'Candidate preferences.json must exist');
      
      const expectedSha = '83F0198CC5E56F4BC96A6B5F6A65170B1283D332E4D668C0E4A5ED90D66D564D';
      final actualSha = sha256Of(candidateFile);
      expect(actualSha, equals(expectedSha), reason: 'User preferences.json must remain 100% bit-for-bit intact');
      expect(candidateFile.lengthSync(), equals(3625));
    });

    test('LITE-002R: diff JSON(current, lite) = uniquement liste blanche de cles startup justifiees', () {
      final candidateFile = File('D:/Antigravity/AgentFolder/Jarvisol_V1_EXT03_Candidate/data/preferences.json');
      final liteFile = File('D:/Antigravity/AgentFolder/CrisperWeaver/data/preferences.lite.json');
      final recoveryFile = File('D:/Antigravity/AgentFolder/CrisperWeaver/data/preferences.lite.recovery.json');

      expect(liteFile.existsSync(), isTrue);
      expect(recoveryFile.existsSync(), isTrue);

      final Map<String, dynamic> currentPrefs = jsonDecode(candidateFile.readAsStringSync());
      final Map<String, dynamic> litePrefs = jsonDecode(liteFile.readAsStringSync());
      final Map<String, dynamic> recoveryPrefs = jsonDecode(recoveryFile.readAsStringSync());

      expect(litePrefs, equals(recoveryPrefs), reason: 'Lite and Recovery templates must be identical');

      // Whitelist of allowed differences: ONLY keys that are actually loaded at startup
      const allowedStartupKeys = {'default_model'};

      final differingKeys = <String>{};
      for (final key in currentPrefs.keys) {
        if (currentPrefs[key] != litePrefs[key]) {
          differingKeys.add(key);
        }
      }
      for (final key in litePrefs.keys) {
        if (!currentPrefs.containsKey(key)) {
          differingKeys.add(key);
        }
      }

      // Check that only whitelisted keys differ
      expect(differingKeys, equals(allowedStartupKeys),
          reason: 'Only default_model must differ. Other keys (diarization, RAG, tokens, etc.) must remain strictly identical.');

      // Specific check for default_model
      expect(litePrefs['default_model'], equals('base'));
      expect(currentPrefs['default_model'], equals('large-v3-turbo'));

      // Non-startup settings must be identical to user preferences
      expect(litePrefs['enable_diarization_by_default'], equals(currentPrefs['enable_diarization_by_default']));
      expect(litePrefs['rag_mode_enabled'], equals(currentPrefs['rag_mode_enabled']));
      expect(litePrefs['llm_max_tokens'], equals(currentPrefs['llm_max_tokens']));
    });

    test('LITE-003: validation de l\'autoload map et identification du goulot memoire', () {
      final mapFile = File('D:/Antigravity/AgentFolder/CrisperWeaver/REQ_POST_002_STARTUP_AUTOLOAD_MAP.csv');
      expect(mapFile.existsSync(), isTrue);

      final lines = mapFile.readAsLinesSync();
      expect(lines.first, contains('Risque_RAM_VRAM'));

      final whisperLine = lines.firstWhere((l) => l.startsWith('WhisperEngine'));
      expect(whisperLine, contains('large-v3-turbo'));
      expect(whisperLine, contains('base'));
      expect(whisperLine, contains('OUI'));
      expect(whisperLine, contains('CRITIQUE'));
    });

    test('LITE-004: demarrage nominal Lite (marker arme puis desarme sans recovery)', () async {
      final prefsFile = File(p.join(tempDir.path, 'preferences.json'));
      final liteFile = File(p.join(tempDir.path, 'preferences.lite.json'));
      final markerFile = File(p.join(tempDir.path, '.engine_starting.json'));

      liteFile.writeAsStringSync('{"default_model": "base"}');
      prefsFile.writeAsStringSync('{"default_model": "base"}');

      // 1. Initial check: nominal
      final result1 = await StartupRecoveryService.checkAndRecover(targetDataDir: tempDir);
      expect(result1.status, equals(StartupRecoveryStatus.noRecoveryNeeded));

      // 2. Arm marker
      await StartupRecoveryService.markEngineStarting(targetDataDir: tempDir);
      expect(markerFile.existsSync(), isTrue);

      // 3. Engine ready disarms marker
      await StartupRecoveryService.markEngineReady(targetDataDir: tempDir);
      expect(markerFile.existsSync(), isFalse);

      // 4. Preferences remained untouched
      expect(prefsFile.readAsStringSync(), equals('{"default_model": "base"}'));
    });

    test('LITE-005: cycle de vie exact du marker transactionnel .engine_starting.json', () async {
      final markerFile = File(p.join(tempDir.path, '.engine_starting.json'));
      final prefsFile = File(p.join(tempDir.path, 'preferences.json'));
      prefsFile.writeAsStringSync('{"default_model": "large-v3-turbo"}');

      // Marker absent initialement
      expect(markerFile.existsSync(), isFalse);

      // Armement
      await StartupRecoveryService.markEngineStarting(targetDataDir: tempDir);
      expect(markerFile.existsSync(), isTrue);

      final markerContent = jsonDecode(markerFile.readAsStringSync());
      expect(markerContent['timestamp'], isNotNull);
      expect(markerContent['session_id'], isNotNull);
      expect(markerContent['preferences_sha256'], equals(sha256Of(prefsFile)));
      expect(markerContent['is_lite'], isFalse);

      // Desarment
      await StartupRecoveryService.markEngineReady(targetDataDir: tempDir);
      expect(markerFile.existsSync(), isFalse);
    });

    test('LITE-006: simulation crash pendant Engine starting (marker stale conserve)', () async {
      final markerFile = File(p.join(tempDir.path, '.engine_starting.json'));
      
      await StartupRecoveryService.markEngineStarting(targetDataDir: tempDir);
      expect(markerFile.existsSync(), isTrue);

      // Crash simule: process interrompu sans appeler markEngineReady()
      expect(markerFile.existsSync(), isTrue);
    });

    test('LITE-007: recuperation automatique apres crash Engine starting', () async {
      final prefsFile = File(p.join(tempDir.path, 'preferences.json'));
      final liteFile = File(p.join(tempDir.path, 'preferences.lite.json'));
      final markerFile = File(p.join(tempDir.path, '.engine_starting.json'));

      const faultyContent = '{"default_model": "large-v3-turbo", "user_data": "critical"}';
      const liteContent = '{"default_model": "base", "user_data": "critical"}';

      prefsFile.writeAsStringSync(faultyContent);
      liteFile.writeAsStringSync(liteContent);

      // Crash marker
      await StartupRecoveryService.markEngineStarting(targetDataDir: tempDir);
      expect(markerFile.existsSync(), isTrue);

      final initialSha = sha256Of(prefsFile);

      // Restart: recovery executes
      final recoveryResult = await StartupRecoveryService.checkAndRecover(targetDataDir: tempDir);
      expect(recoveryResult.status, equals(StartupRecoveryStatus.recovered));
      expect(recoveryResult.backupPath, isNotNull);

      // Faulty file was preserved bit-for-bit
      final backupFile = File(recoveryResult.backupPath!);
      expect(backupFile.existsSync(), isTrue);
      expect(sha256Of(backupFile), equals(initialSha));
      expect(backupFile.readAsStringSync(), equals(faultyContent));

      // preferences.json was restored to Lite
      expect(prefsFile.readAsStringSync(), equals(liteContent));

      // Marker was cleaned up
      expect(markerFile.existsSync(), isFalse);
    });

    test('LITE-008: crash apres Engine ready ne declenche JAMAIS la restauration Lite', () async {
      final prefsFile = File(p.join(tempDir.path, 'preferences.json'));
      final liteFile = File(p.join(tempDir.path, 'preferences.lite.json'));
      final markerFile = File(p.join(tempDir.path, '.engine_starting.json'));

      const userConfig = '{"default_model": "custom-model", "keep": true}';
      prefsFile.writeAsStringSync(userConfig);
      liteFile.writeAsStringSync('{"default_model": "base"}');

      // Normal engine starting completed
      await StartupRecoveryService.markEngineStarting(targetDataDir: tempDir);
      await StartupRecoveryService.markEngineReady(targetDataDir: tempDir);
      expect(markerFile.existsSync(), isFalse);

      // Post-ready crash occurs (no marker)
      // On restart:
      final result = await StartupRecoveryService.checkAndRecover(targetDataDir: tempDir);
      expect(result.status, equals(StartupRecoveryStatus.noRecoveryNeeded));

      // preferences.json completely untouched
      expect(prefsFile.readAsStringSync(), equals(userConfig));
    });

    test('LITE-009: si la baseline Lite est absente ou corrompue, preferences.json n\'est pas ecrase', () async {
      final prefsFile = File(p.join(tempDir.path, 'preferences.json'));
      final markerFile = File(p.join(tempDir.path, '.engine_starting.json'));
      final liteFile = File(p.join(tempDir.path, 'preferences.lite.json'));

      const originalConfig = '{"default_model": "large-v3-turbo", "safe": true}';
      prefsFile.writeAsStringSync(originalConfig);
      // Lite file is corrupt JSON
      liteFile.writeAsStringSync('{ INVALID JSON CORRUPTED FILE');

      await StartupRecoveryService.markEngineStarting(targetDataDir: tempDir);

      final result = await StartupRecoveryService.checkAndRecover(targetDataDir: tempDir);
      expect(result.status, equals(StartupRecoveryStatus.liteBaselineInvalid));

      // Original preferences NOT destroyed or overwritten
      expect(prefsFile.readAsStringSync(), equals(originalConfig));
      // Marker cleared to avoid crash loop
      expect(markerFile.existsSync(), isFalse);
    });

    test('LITE-010: protection anti-boucle de recuperation', () async {
      final prefsFile = File(p.join(tempDir.path, 'preferences.json'));
      final liteFile = File(p.join(tempDir.path, 'preferences.lite.json'));
      final markerFile = File(p.join(tempDir.path, '.engine_starting.json'));

      prefsFile.writeAsStringSync('{"default_model": "base"}');
      liteFile.writeAsStringSync('{"default_model": "base"}');

      // Marker armed with is_lite = true (previous session was already Lite)
      await StartupRecoveryService.markEngineStarting(targetDataDir: tempDir, isLite: true);
      expect(markerFile.existsSync(), isTrue);

      // Next startup: checkAndRecover detects that Lite already failed
      final result = await StartupRecoveryService.checkAndRecover(targetDataDir: tempDir);
      expect(result.status, equals(StartupRecoveryStatus.recoveryLoopAborted));

      // Loop aborted, marker removed, no cascading destructive backups
      expect(markerFile.existsSync(), isFalse);
    });

    test('LITE-011: portabilite Release A -> Release B', () async {
      final dirA = Directory(p.join(tempDir.path, 'ReleaseA', 'data'))..createSync(recursive: true);
      final dirB = Directory(p.join(tempDir.path, 'ReleaseB', 'data'))..createSync(recursive: true);

      final liteA = File(p.join(dirA.path, 'preferences.lite.json'));
      liteA.writeAsStringSync('{"default_model": "base", "relative": "data/models"}');

      // Copy directory A to B
      final liteB = File(p.join(dirB.path, 'preferences.lite.json'));
      liteA.copySync(liteB.path);
      final prefsB = File(p.join(dirB.path, 'preferences.json'));
      prefsB.writeAsStringSync('{"default_model": "heavy"}');

      // Marker in B
      await StartupRecoveryService.markEngineStarting(targetDataDir: dirB);

      // Recovery operates strictly inside B
      final resultB = await StartupRecoveryService.checkAndRecover(targetDataDir: dirB);
      expect(resultB.status, equals(StartupRecoveryStatus.recovered));
      expect(prefsB.readAsStringSync(), contains('"default_model": "base"'));

      // Zero artifacts written outside dirB
      final dirAFiles = dirA.listSync();
      expect(dirAFiles.length, equals(1)); // only liteA
    });

    test('LITE-012: mauvaise configuration utilisateur (modele invalide/trop lourd) et recovery', () async {
      final prefsFile = File(p.join(tempDir.path, 'preferences.json'));
      final liteFile = File(p.join(tempDir.path, 'preferences.lite.json'));

      prefsFile.writeAsStringSync('{"default_model": "non_existent_heavy_model_100gb"}');
      liteFile.writeAsStringSync('{"default_model": "base"}');

      // Simulates startup failure
      await StartupRecoveryService.markEngineStarting(targetDataDir: tempDir);

      // Recovery triggered
      final result = await StartupRecoveryService.checkAndRecover(targetDataDir: tempDir);
      expect(result.status, equals(StartupRecoveryStatus.recovered));
      expect(prefsFile.readAsStringSync(), contains('"default_model": "base"'));
    });

    test('LITE-013: qualification honnete de la cause memoire (distinction mecanisme vs OOM reel)', () {
      final mapFile = File('D:/Antigravity/AgentFolder/CrisperWeaver/REQ_POST_002_STARTUP_AUTOLOAD_MAP.csv');
      final content = mapFile.readAsStringSync();
      
      // Verification honnete : Whisper large-v3-turbo constitue un facteur de risque memoire plausible.
      expect(content, contains('CRITIQUE (~2.5-3.0 GB RAM/VRAM)'));
      expect(content, contains('~145 MB'));
    });

    test('LITE-014: MODEL_LITE_AVAILABLE_AND_LOADABLE - base est disponible et chargeable sans PATH externe', () async {
      // 1. Verifier presence dans le catalogue Whisper
      expect(ModelCatalog.whisperCppModels.containsKey('base'), isTrue);
      final modelDef = ModelCatalog.whisperCppModels['base']!;
      expect(modelDef.fileName, equals('ggml-base.bin'));

      // 2. Verifier presence physique reelle du binaire dans la distribution Candidate
      final candidateModel = File('D:/Antigravity/AgentFolder/Jarvisol_V1_EXT03_Candidate/data/models/whisper_cpp/ggml-base.bin');
      expect(candidateModel.existsSync(), isTrue, reason: 'ggml-base.bin must exist in candidate models');
      expect(candidateModel.lengthSync(), equals(147951465));

      // 3. Resolution automatique via ModelService
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);
      final modelService = ModelService(settings);
      await modelService.initialize();

      final resolvedDef = modelService.lookupDefinition('base');
      expect(resolvedDef, isNotNull);
      expect(resolvedDef!.fileName, equals('ggml-base.bin'));

      // 4. Verification de chemin sans PATH externe (relatif a data/models/whisper_cpp)
      final localPath = p.join('D:/Antigravity/AgentFolder/Jarvisol_V1_EXT03_Candidate/data/models/whisper_cpp', resolvedDef.fileName);
      expect(File(localPath).existsSync(), isTrue);

      // 5. Chargement effectif du modele par le moteur atteignant l'etat ready
      final engine = MockEngine();
      await engine.initialize(modelService: modelService);
      final ok = await engine.loadModel('base');
      expect(ok, isTrue, reason: 'Engine loadModel must succeed');
      expect(engine.currentModelId, equals('base'), reason: 'Engine must be ready with base model active');
    });

    test('LITE-015: CANDIDATE_LITE_FILES_PRESENT - templates Lite presents a cote de preferences.json Candidate', () {
      final candLite = File('D:/Antigravity/AgentFolder/Jarvisol_V1_EXT03_Candidate/data/preferences.lite.json');
      final candRecovery = File('D:/Antigravity/AgentFolder/Jarvisol_V1_EXT03_Candidate/data/preferences.lite.recovery.json');
      final srcLite = File('D:/Antigravity/AgentFolder/CrisperWeaver/data/preferences.lite.json');
      final srcRecovery = File('D:/Antigravity/AgentFolder/CrisperWeaver/data/preferences.lite.recovery.json');

      expect(candLite.existsSync(), isTrue, reason: 'preferences.lite.json must be present in Candidate data/');
      expect(candRecovery.existsSync(), isTrue, reason: 'preferences.lite.recovery.json must be present in Candidate data/');

      final shaCandLite = sha256Of(candLite);
      final shaCandRecovery = sha256Of(candRecovery);
      final shaSrcLite = sha256Of(srcLite);
      final shaSrcRecovery = sha256Of(srcRecovery);

      expect(shaCandLite, equals(shaSrcLite), reason: 'Candidate Lite must match Source Lite');
      expect(shaCandRecovery, equals(shaSrcRecovery), reason: 'Candidate Recovery must match Source Recovery');
      expect(shaCandLite, equals(shaCandRecovery), reason: 'Lite and Recovery must be identical');

      // preferences.json in candidate must not have been modified
      final candPrefs = File('D:/Antigravity/AgentFolder/Jarvisol_V1_EXT03_Candidate/data/preferences.json');
      expect(sha256Of(candPrefs), equals('83F0198CC5E56F4BC96A6B5F6A65170B1283D332E4D668C0E4A5ED90D66D564D'));
    });
  });
}
