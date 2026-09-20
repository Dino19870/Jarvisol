// test/audiobook_studio_test.dart — tests for Audiobook models, service, and studio widget.

import 'package:crisper_weaver/models/audiobook_models.dart';
import 'package:crisper_weaver/services/audiobook_service.dart';
import 'package:crisper_weaver/services/model_catalog.dart';
import 'package:crisper_weaver/services/settings_service.dart';
import 'package:crisper_weaver/widgets/audiobook_studio_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crisper_weaver/utils/portable_preferences.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AUDIT STUDIO LIVRE AUDIO : Modèles & Structure', () {
    test('AudiobookSpeaker serialization & copyWith', () {
      const spk = AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: 'piper-fr-siwis-medium',
        role: 'narrator',
      );
      expect(spk.id, 'narrator');
      expect(spk.voiceModelName, 'piper-fr-siwis-medium');

      final copy = spk.copyWith(name: 'Narrateur Principal');
      expect(copy.name, 'Narrateur Principal');
      expect(copy.id, 'narrator');

      final json = spk.toJson();
      final revived = AudiobookSpeaker.fromJson(json);
      expect(revived.name, 'Narrateur');
      expect(revived.voiceModelName, 'piper-fr-siwis-medium');
    });

    test('AudiobookChapter duration & word count calculation', () {
      const sampleText = 'Ceci est un test de livre audio avec plusieurs mots.';
      final chap = AudiobookChapter(
        id: 'chap_1',
        index: 1,
        title: 'Chapitre 1',
        rawText: sampleText,
      );
      expect(chap.wordCount, 10);
      expect(chap.estimatedDurationMinutes, 1);
    });

    test('AudiobookProject holds chapters and speakers', () {
      final project = AudiobookProject(
        id: 'proj_1',
        title: 'Mon Roman',
        author: 'Auteur',
        sourcePath: 'roman.epub',
        chapters: [
          AudiobookChapter(
            id: 'chap_1',
            index: 1,
            title: 'Chapitre 1',
            rawText: 'Texte court du chapitre 1.',
          ),
        ],
        speakers: {
          'narrator': const AudiobookSpeaker(
            id: 'narrator',
            name: 'Narrateur',
            voiceModelName: 'piper-fr-siwis-medium',
          ),
        },
        createdAt: DateTime.now(),
      );

      expect(project.title, 'Mon Roman');
      expect(project.chapters.length, 1);
      expect(project.speakers.containsKey('narrator'), isTrue);
    });
  });

  group('AUDIT STUDIO LIVRE AUDIO : Catalogue des Voix Françaises', () {
    test('Piper French voices are correctly registered in ModelCatalog', () {
      final siwis = ModelCatalog.crispasrBackendModels['piper-fr-siwis-medium'];
      final upmc = ModelCatalog.crispasrBackendModels['piper-fr-upmc-medium'];
      final tom = ModelCatalog.crispasrBackendModels['piper-fr-tom-medium'];
      final gilles = ModelCatalog.crispasrBackendModels['piper-fr-gilles-low'];

      expect(siwis, isNotNull);
      expect(upmc, isNotNull);
      expect(tom, isNotNull);
      expect(gilles, isNotNull);

      expect(siwis!.languages, contains('fr'));
      expect(upmc!.languages, contains('fr'));
      expect(tom!.languages, contains('fr'));
      expect(gilles!.languages, contains('fr'));
    });
  });

  group('AUDIT STUDIO LIVRE AUDIO : Widget test interactif', () {
    testWidgets(
      'AudiobookStudioWidget renders Toolbar, Table of Contents and Voice Casting',
      // just_audio positionStream/playerStateStream provoque setState() infini sans plugin natif audio
      skip: true,
      (tester) async {

      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settingsSvc = SettingsService(prefs);

      await tester.binding.setSurfaceSize(const Size(1280, 800));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(settingsSvc),
          ],
          child: const MaterialApp(
            home: AudiobookStudioWidget(),
          ),
        ),
      );
      // Drainer les frames initiales sans pumpAndSettle (le widget a des timers continus)
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }


      expect(find.text('Studio Livre Audio Multi-Voix'), findsOneWidget);
      expect(find.text('Bibliothèque RAG'), findsOneWidget);
      expect(find.text('Importer EPUB / TXT'), findsOneWidget);
      expect(find.text('TABLE DES MATIÈRES'), findsOneWidget);
      expect(find.text('DISTRIBUTION DES VOIX'), findsOneWidget);
      expect(find.text('Générer Tout le Chapitre'), findsOneWidget);
    });
  });
}
