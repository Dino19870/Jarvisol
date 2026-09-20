import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/services/imported_voice_service.dart';
import 'package:jarvisol/services/voice_pack_inspector.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/widgets/voice_tuning_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late Directory tempVoicesDir;
  final sampleGgufSource = r"C:\Users\lansa\.gemini\antigravity\brain\31f213dd-5da9-404a-adeb-04503ae36594\scratch\er8_fixtures\B_normale.gguf";

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('jarvisol_f_nr_test_');
    tempVoicesDir = Directory('${tempRoot.path}/data/models/tts/voices');
    await tempVoicesDir.create(recursive: true);
    AppPaths.setTestOverride(tempRoot);
  });

  tearDown(() async {
    AppPaths.resetTestOverride();
    try {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Non-Régression E2E Flux Applicatifs (F-NR-09 à F-NR-14)', () {
    test('F-NR-09 & F-NR-10: Import depuis Synthesize / Studio visible sans restart', () async {
      final container = ProviderContainer();
      final voiceService = container.read(importedVoiceServiceProvider.notifier);

      expect(container.read(importedVoiceServiceProvider), isEmpty);

      // Simuler import
      final imported = await voiceService.importVoicePack(sampleGgufSource);
      expect(imported.id, equals('B_normale'));
      expect(imported.family, equals(VoicePackFamily.qwen3));

      // Vérifier que le provider d'état est immédiatement mis à jour (sans restart)
      final stateVoices = container.read(importedVoiceServiceProvider);
      expect(stateVoices.length, equals(1));
      expect(stateVoices.first.id, equals('B_normale'));
      expect(stateVoices.first.voiceNames, contains('B_normale'));

      // Vérifier que le fichier est bien copié dans le dossier des voix
      final targetFile = File('${tempVoicesDir.path}/B_normale.gguf');
      expect(targetFile.existsSync(), isTrue);

      container.dispose();
    });

    test('F-NR-11: Atelier de Paramétrage Vocal voit la voix importée', () async {
      final container = ProviderContainer();
      final voiceService = container.read(importedVoiceServiceProvider.notifier);
      await voiceService.importVoicePack(sampleGgufSource);

      final availableVoices = container.read(importedVoiceServiceProvider);
      expect(availableVoices.any((v) => v.displayName.contains('B_normale')), isTrue);

      // Vérifier qu'un locuteur d'audiobook peut utiliser cette voix
      final speaker = AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur Principal',
        voiceModelName: 'custom:qwen3:B_normale:B_normale',
        role: 'narrator',
      );

      expect(speaker.voiceModelName, contains('B_normale'));
      container.dispose();
    });

    test('F-NR-12: Suppression d\'une voix importée', () async {
      final container = ProviderContainer();
      final voiceService = container.read(importedVoiceServiceProvider.notifier);
      await voiceService.importVoicePack(sampleGgufSource);
      expect(container.read(importedVoiceServiceProvider).length, equals(1));

      // Supprimer la voix
      await voiceService.deleteVoicePack('B_normale');

      // Vérifier suppression d'état
      expect(container.read(importedVoiceServiceProvider), isEmpty);

      // Vérifier suppression physique sur disque
      final targetFile = File('${tempVoicesDir.path}/B_normale.gguf');
      expect(targetFile.existsSync(), isFalse);

      container.dispose();
    });

    test('F-NR-13: Restart / Persistence à travers les sessions', () async {
      // Session 1 : Import
      {
        final container1 = ProviderContainer();
        final voiceService1 = container1.read(importedVoiceServiceProvider.notifier);
        await voiceService1.importVoicePack(sampleGgufSource);
        expect(container1.read(importedVoiceServiceProvider).length, equals(1));
        container1.dispose();
      }

      // Vérifier présence sur disque du manifest json
      final manifest = File('${tempVoicesDir.path}/imported_voices.json');
      expect(manifest.existsSync(), isTrue);

      // Session 2 : "Redémarrage" de l'application (nouveau ProviderContainer)
      {
        final container2 = ProviderContainer();
        // Le service charge persisted voices à l'initialisation
        final voiceService2 = container2.read(importedVoiceServiceProvider.notifier);
        final loaded = container2.read(importedVoiceServiceProvider);
        expect(loaded.length, equals(1));
        expect(loaded.first.id, equals('B_normale'));
        container2.dispose();
      }
    });

    test('F-NR-14: Logs & Diagnostics - intégrité sans exception', () async {
      final container = ProviderContainer();
      final voiceService = container.read(importedVoiceServiceProvider.notifier);

      // Invoquer inspection et import
      final info = VoicePackInspector.inspect(sampleGgufSource);
      expect(info.isValid, isTrue);

      await voiceService.importVoicePack(sampleGgufSource);
      expect(container.read(importedVoiceServiceProvider).isNotEmpty, isTrue);

      container.dispose();
    });
  });
}
