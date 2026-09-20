// test/audiobook_rules_test.dart — Unit and widget tests for customizable cleaning & diarization rules.

import 'package:crisper_weaver/models/audiobook_models.dart';
import 'package:crisper_weaver/models/audiobook_rules.dart';
import 'package:crisper_weaver/services/audiobook_service.dart';
import 'package:crisper_weaver/services/tts_service.dart';
import 'package:crisper_weaver/widgets/audiobook_import_dialog.dart';
import 'package:crisper_weaver/widgets/audiobook_rules_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AUDIT REGLES LIVRE AUDIO : Nettoyage et Profils', () {
    test('Standard profile cleans hyphen line breaks', () {
      final profile = AudiobookRuleProfile.standard;
      const raw = 'C\'était un inves-\n tigateur très habile.';
      final cleaned = profile.applyCleaning(raw);
      expect(cleaned, contains('investigateur'));
    });

    test('OCR Scans profile removes noise and cleans hyphen dialogues', () {
      final profile = AudiobookRuleProfile.ocrScans;
      const raw = '''*Oraiett Bris, encore sous le coup. Vf1a-w~upae ~, .___ .C
- Merci, docteur. Le témoin est à vous.
- Je suis prête.''';

      final cleaned = profile.applyCleaning(raw);
      expect(cleaned.contains('~, .___ .C'), isFalse);
    });

    test('Diarization with OCR profile identifies hyphen dialogues', () {
      final profile = AudiobookRuleProfile.ocrScans;
      final svc = AudiobookService(FakeTtsService());

      final chap = AudiobookChapter(
        id: 'chap_1',
        index: 1,
        title: 'Chapitre 1',
        rawText: '''- Merci, docteur. Le témoin est à vous. Jake rassemble ses affaires.
- Je suis prête, déclara Lucy en souriant.
Il regarda la salle avec calme.''',
      );

      final speakers = <String, AudiobookSpeaker>{
        'narrator': const AudiobookSpeaker(id: 'narrator', name: 'Narrateur', voiceModelName: 'kokoro-voice-ff_siwis'),
        'male_main': const AudiobookSpeaker(id: 'male_main', name: 'Personnage H', voiceModelName: 'qwen3-ethan'),
        'female_main': const AudiobookSpeaker(id: 'female_main', name: 'Personnage F', voiceModelName: 'kokoro-voice-ff_siwis'),
      };

      final lines = svc.castChapterLinesSync(chapter: chap, speakers: speakers, profile: profile);
      expect(lines.isNotEmpty, isTrue);
      // Lucy should be identified as female
      final lucyLine = lines.firstWhere((l) => l.text.contains('prête'));
      expect(lucyLine.speakerId, 'female_main');
    });
  });

  group('AUDIT REGLES LIVRE AUDIO : Widgets & Boîtes de Dialogue', () {
    testWidgets('AudiobookRulesDialog renders live preview and profiles', (tester) async {
      AudiobookRuleProfile selected = AudiobookRuleProfile.standard;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: AudiobookRulesDialog(
                currentProfile: AudiobookRuleProfile.standard,
                onProfileSelected: (p) => selected = p,
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Règles de Découpage & Nettoyage des Livres'), findsOneWidget);
      expect(find.text('Test & Prévisualisation en direct'), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
    });

    testWidgets('AudiobookImportDialog prompts for RAG indexing and profile selection', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: AudiobookImportDialog(
                filePath: 'C:/Livres/roman_test.epub',
                initialProfile: AudiobookRuleProfile.standard,
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Importation de Livre'), findsOneWidget);
      expect(find.text('roman_test.epub'), findsOneWidget);
      expect(find.text('Indexation dans la Bibliothèque RAG'), findsOneWidget);
      expect(find.text('Studio Direct (Sans RAG)'), findsOneWidget);
      expect(find.text('Indexer RAG & Ouvrir'), findsOneWidget);
    });
  });
}

class FakeTtsService implements TtsService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
