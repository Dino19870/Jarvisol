// test/audiobook_editing_export_test.dart — Tests for lossless project persistence, multi-format export, and inline editing.

import 'dart:io';
import 'package:crisper_weaver/models/audiobook_models.dart';
import 'package:crisper_weaver/services/audiobook_service.dart';
import 'package:crisper_weaver/services/tts_service.dart';
import 'package:crisper_weaver/widgets/audiobook_export_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testProject = AudiobookProject(
    id: 'proj_test_1',
    title: 'Non Coupable',
    author: 'John Grisham',
    sourcePath: 'C:/Livres/non_coupable.epub',
    createdAt: DateTime(2026, 8, 22),
    speakers: {
      'narrator': const AudiobookSpeaker(id: 'narrator', name: 'Narrateur', voiceModelName: 'kokoro-voice-ff_siwis'),
      'male_main': const AudiobookSpeaker(id: 'male_main', name: 'Jake Brigance', voiceModelName: 'qwen3-ethan'),
      'female_main': const AudiobookSpeaker(id: 'female_main', name: 'Lucy', voiceModelName: 'kokoro-voice-ff_siwis'),
    },
    chapters: [
      AudiobookChapter(
        id: 'chap_1',
        index: 1,
        title: 'Chapitre 1',
        rawText: 'Introduction narrative.',
        lines: [
          const AudiobookLine(
            id: 'line_1_1',
            speakerId: 'narrator',
            speakerName: 'Narrateur',
            text: 'Jake alluma une cigarette en regardant par la fenêtre.',
          ),
          const AudiobookLine(
            id: 'line_1_2',
            speakerId: 'male_main',
            speakerName: 'Jake Brigance',
            text: 'Nous allons gagner ce procès.',
            colorHex: '0xFF38BDF8',
            highlightHex: '0x33FBBF24',
          ),
          const AudiobookLine(
            id: 'line_1_3',
            speakerId: 'female_main',
            speakerName: 'Lucy',
            text: 'J\'en suis certaine, Jake.',
          ),
        ],
      ),
    ],
  );

  group('AUDIT PERSISTANCE & EXPORTS PROJET AUDIOBOOK', () {
    test('Projet JSON Lossless Serialization and Deserialization', () {
      final jsonMap = testProject.toJson();
      final reloaded = AudiobookProject.fromJson(jsonMap);

      expect(reloaded.id, testProject.id);
      expect(reloaded.title, testProject.title);
      expect(reloaded.chapters.length, 1);
      expect(reloaded.chapters.first.lines.length, 3);

      final styledLine = reloaded.chapters.first.lines[1];
      expect(styledLine.speakerName, 'Jake Brigance');
      expect(styledLine.colorHex, '0xFF38BDF8');
      expect(styledLine.highlightHex, '0x33FBBF24');
    });

    test('Export PlainText Scenario', () {
      final svc = AudiobookService(FakeTtsService());
      final txt = svc.exportProjectToPlainText(testProject);

      expect(txt, contains('TITRE : Non Coupable'));
      expect(txt, contains('[JAKE BRIGANCE] Nous allons gagner ce procès.'));
      expect(txt, contains('[LUCY] J\'en suis certaine, Jake.'));
    });

    test('Export Markdown Script', () {
      final svc = AudiobookService(FakeTtsService());
      final md = svc.exportProjectToMarkdown(testProject);

      expect(md, contains('# Non Coupable'));
      expect(md, contains('🗣️ **Jake Brigance** : Nous allons gagner ce procès.'));
    });

    test('Export HTML Web Document', () {
      final svc = AudiobookService(FakeTtsService());
      final html = svc.exportProjectToHtml(testProject);

      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('<title>Non Coupable - Script Multi-Voix</title>'));
      expect(html, contains('class="badge">Jake Brigance</div>'));
    });

    test('Export Word DOCX and PDF Files', () async {
      final svc = AudiobookService(FakeTtsService());
      final tempDir = Directory.systemTemp.createTempSync('audiobook_export_test');

      final docxPath = '${tempDir.path}/test_export.docx';
      final pdfPath = '${tempDir.path}/test_export.pdf';

      await svc.exportProjectToDocx(testProject, docxPath);
      await svc.exportProjectToPdf(testProject, pdfPath);

      expect(File(docxPath).existsSync(), isTrue);
      expect(File(docxPath).lengthSync(), greaterThan(100));

      expect(File(pdfPath).existsSync(), isTrue);
      expect(File(pdfPath).lengthSync(), greaterThan(100));

      tempDir.deleteSync(recursive: true);
    });
  });

  group('AUDIT WIDGETS : Boîte de Dialogue Exportation', () {
    testWidgets('AudiobookExportDialog renders all format choices', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () => AudiobookExportDialog.show(ctx, testProject),
                  child: const Text('Open Dialog'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('Exporter le Document Découpé'), findsOneWidget);
      expect(find.text('Document Word (.docx)'), findsOneWidget);
      expect(find.text('Document PDF (.pdf)'), findsOneWidget);
      expect(find.text('Page Web Interactive (.html)'), findsOneWidget);
      expect(find.text('Script Markdown (.md)'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Scénario Texte (.txt)'), 100);
      expect(find.text('Scénario Texte (.txt)'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Projet Complet Studio (.cwproject)'), 100);
      expect(find.text('Projet Complet Studio (.cwproject)'), findsOneWidget);
    });

    test('AudiobookService stripStyleTags removes rich text tags cleanly for TTS', () {
      const tagged = '<color=0xFF38BDF8>**Bonjour**</color> à <mark=0x33FBBF24>*tous*</mark> !';
      final clean = AudiobookService.stripStyleTags(tagged);
      expect(clean, equals('Bonjour à tous !'));
    });

    test('AudiobookService exportProjectToHtml converts styling tags to clean HTML spans', () {
      final svc = AudiobookService(FakeTtsService());
      final formattedProject = testProject.copyWith(
        chapters: [
          testProject.chapters.first.copyWith(
            lines: [
              const AudiobookLine(
                id: 'l1',
                speakerId: 'narrator',
                speakerName: 'Narrateur',
                text: 'Une <color=0xFF38BDF8>voiture rouge</color> avec <mark=0x33FBBF24>**attention**</mark>.',
              ),
            ],
          ),
        ],
      );

      final html = svc.exportProjectToHtml(formattedProject);
      expect(html, contains('<span style="color:#38bdf8;">voiture rouge</span>'));
      expect(html, contains('<mark style="background-color:#fbbf24; color:#000000;"><b>attention</b></mark>'));
    });
  });
}

class FakeTtsService implements TtsService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
