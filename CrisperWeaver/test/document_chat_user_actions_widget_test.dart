import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/widgets/document_chat_widget.dart';
import 'package:jarvisol/widgets/prompt_library_dialog.dart';
import 'package:jarvisol/widgets/ai_knowledge_dialog.dart';
import 'package:jarvisol/widgets/rag_library_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PortablePreferences prefs;
  late SettingsService settings;

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
  });

  Widget createTestWidget() {
    return ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(settings),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: DocumentChatWidget(isFullscreen: false),
        ),
      ),
    );
  }

  group(
      'AUDIT COMPLET MULTI-FENÊTRES & ACTIONS UTILISATEUR (Assistant Documents)',
      () {
    testWidgets(
        'ACTION 1 : Fenêtre Saisie Directe de Note (Ajout & Annulation)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      // 1.1 Ouverture et Annulation
      await tester.tap(find.text('Écrire une note'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Saisie / Note Directe'), findsOneWidget);
      await tester.tap(find.text('Annuler'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Saisie / Note Directe'), findsNothing);

      // 1.2 Ouverture, Saisie et Validation
      await tester.tap(find.text('Écrire une note'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final dialogTextFields = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      await tester.enterText(dialogTextFields.at(0), 'Note Enquête 2026');
      await tester.enterText(dialogTextFields.at(1),
          'Le témoin a confirmé la présence du suspect à 21h45.');
      await tester.tap(find.text('Ajouter au contexte'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Note Enquête 2026'), findsOneWidget);
    });

    testWidgets('ACTION 2 : Collage Presse-papier et gestion des sources',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform,
              (MethodCall methodCall) async {
        if (methodCall.method == 'Clipboard.getData') {
          return {'text': 'Contenu presse-papier pour test RAG.'};
        }
        return null;
      });

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      await tester.tap(find.text('Coller le presse-papier'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Presse-papier'), findsOneWidget);

      // Suppression de la source via Chip delete icon
      final chip = tester.widget<Chip>(find.byType(Chip));
      chip.onDeleted!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Presse-papier'), findsNothing);
      expect(
          find.text('Assistant IA Multi-Sources & Documents'), findsOneWidget);
    });

    testWidgets(
        'ACTION 3 : Bascule dynamique des Puces MCP (Date, Web Search, Gmail)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      // ── Ouvrir McpLibraryDialog via le chip ⚡ MCP ──────────────────────
      // L'ActionChip est identifié par son tooltip (stable même si le
      // compteur N/M change selon l'état des settings).
      final mcpChip = find.byTooltip('Gérer les outils MCP actifs');
      expect(mcpChip, findsOneWidget,
          reason: 'Le chip ⚡ MCP doit être présent dans la barre de saisie');

      await tester.tap(mcpChip);
      // pumpAndSettle attend que _load() (HTTP vers localhost:7862 absent)
      // échoue et setState(_serverOffline = true) — les built-ins restent
      // visibles, seul l'onglet custom affiche _OfflineTile.
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // Le dialog s'est ouvert.
      expect(find.text('⚡ Bibliothèque MCP'), findsOneWidget,
          reason: 'McpLibraryDialog doit être affiché');

      // Helper : trouve le Switch dans le ListTile qui contient [name].
      Switch findSwitch(String name) {
        final listTile = find.ancestor(
          of: find.text(name),
          matching: find.byType(ListTile),
        );
        final sw = find.descendant(
          of: listTile,
          matching: find.byType(Switch),
        );
        return tester.widget<Switch>(sw.first);
      }

      // ── Date & Heure ─────────────────────────────────────────────────────
      final initDate = settings.enableCurrentDateTool;
      // Taper directement le Switch (GestureDetector interne).
      final dateSw = find.descendant(
        of: find.ancestor(
            of: find.text('Date & Heure'), matching: find.byType(ListTile)),
        matching: find.byType(Switch),
      );
      await tester.tap(dateSw.first);
      await tester.pump();
      expect(settings.enableCurrentDateTool, equals(!initDate),
          reason: 'Date & Heure doit être basculé');

      // ── Recherche Web ─────────────────────────────────────────────────────
      final initWeb = settings.enableWebSearchTool;
      final webSw = find.descendant(
        of: find.ancestor(
            of: find.text('Recherche Web'), matching: find.byType(ListTile)),
        matching: find.byType(Switch),
      );
      await tester.tap(webSw.first);
      await tester.pump();
      expect(settings.enableWebSearchTool, equals(!initWeb),
          reason: 'Recherche Web doit être basculé');

      // ── Gmail MCP ─────────────────────────────────────────────────────────
      final initGmail = settings.enableGmailTool;
      final gmailSw = find.descendant(
        of: find.ancestor(
            of: find.text('Gmail MCP'), matching: find.byType(ListTile)),
        matching: find.byType(Switch),
      );
      await tester.tap(gmailSw.first);
      await tester.pump();
      expect(settings.enableGmailTool, equals(!initGmail),
          reason: 'Gmail MCP doit être basculé');

      // ── Génération d'image ────────────────────────────────────────────────
      final initImg = settings.enableImageGenTool;
      final imgSw = find.descendant(
        of: find.ancestor(
            of: find.text("Génération d'image"),
            matching: find.byType(ListTile)),
        matching: find.byType(Switch),
      );
      await tester.tap(imgSw.first);
      await tester.pump();
      expect(settings.enableImageGenTool, equals(!initImg),
          reason: "Génération d'image doit être basculé");

      // ── Fermer le dialog ──────────────────────────────────────────────────
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('⚡ Bibliothèque MCP'), findsNothing,
          reason: 'Le dialog doit être fermé');
    });

    testWidgets('ACTION 4 : Clic sur les boutons de synthèse rapide RAG',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      await tester.tap(find.text('Écrire une note'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final dialogTextFields = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      await tester.enterText(dialogTextFields.at(0), 'Rapport Annuel');
      await tester.enterText(
          dialogTextFields.at(1), 'Chiffre d affaires en hausse de 15%.');
      await tester.tap(find.text('Ajouter au contexte'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('📝 Résumer les sources'), findsOneWidget);
      await tester.tap(find.text('📝 Résumer les sources'));
      await tester.pump();

      expect(
          find.text(
              'Fais une synthèse claire et structurée des documents fournis.'),
          findsOneWidget);
    });

    testWidgets(
        'ACTION 5 : Fenêtre Modale Bibliothèque de Prompts (Filtres, Sélection & Création)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      final promptBtn = find.byIcon(Icons.bookmark_added_rounded).last;
      await tester.tap(promptBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(PromptLibraryDialog), findsOneWidget);

      // 5.1 Filtrage par type Système / Discussion
      final systemTypeFilter = find.textContaining('Système (');
      if (systemTypeFilter.evaluate().isNotEmpty) {
        await tester.tap(systemTypeFilter.first);
        await tester.pump();
      }

      // 5.2 Recherche par mot-clé
      final searchInput = find
          .descendant(
              of: find.byType(PromptLibraryDialog),
              matching: find.byType(TextField))
          .first;
      await tester.enterText(searchInput, 'RAG');
      await tester.pump();

      // 5.3 Clic sur bouton Nouveau Prompt pour tester la sous-fenêtre d édition
      final newPromptBtn = find.text('Nouveau Prompt');
      expect(newPromptBtn, findsOneWidget);
      await tester.tap(newPromptBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Nouveau prompt'), findsOneWidget);
      // Annuler la création
      await tester.tap(find.text('Annuler'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 5.4 Fermeture de la modale de prompts
      final closeBtn = find
          .descendant(
              of: find.byType(PromptLibraryDialog),
              matching: find.byIcon(Icons.close))
          .first;
      await tester.tap(closeBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(PromptLibraryDialog), findsNothing);
    });

    testWidgets(
        'ACTION 6 : Fenêtre Modale Bibliothèque RAG (Cache & Documents)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      final ragLibBtn = find.widgetWithText(OutlinedButton, 'Bibliothèque');
      expect(ragLibBtn, findsOneWidget);
      await tester.tap(ragLibBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(RagLibraryDialog), findsOneWidget);

      // Fermeture
      final closeBtn = find
          .descendant(
              of: find.byType(RagLibraryDialog),
              matching: find.byIcon(Icons.close))
          .first;
      await tester.tap(closeBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(RagLibraryDialog), findsNothing);
    });

    testWidgets(
        'ACTION 7 : Fenêtre Modale Fiches & Connaissances IA (AiKnowledgeDialog)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      final aiKnowledgeBtn =
          find.byTooltip('Bibliothèque & Base de Connaissances IA');
      expect(aiKnowledgeBtn, findsOneWidget);
      await tester.tap(aiKnowledgeBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AiKnowledgeDialog), findsOneWidget);

      // Fermeture
      final closeBtn = find
          .descendant(
              of: find.byType(AiKnowledgeDialog),
              matching: find.byIcon(Icons.close))
          .first;
      await tester.tap(closeBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AiKnowledgeDialog), findsNothing);
    });

    testWidgets(
        'ACTION 8 : Fenêtre Modale d Exportation Multi-Formats (PDF, Word DOCX, Markdown, HTML, TXT, JSON)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      // Envoi d un message pour créer un contenu de discussion
      await tester.enterText(
          find.byType(TextField), 'Analyse financière du dossier 2026');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // Clic sur l icone d export dans l en-tête
      final exportBtn = find.byIcon(Icons.file_download_outlined);
      expect(exportBtn, findsOneWidget);
      await tester.tap(exportBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verification des 6 formats proposes dans la modale
      expect(find.text('Exporter la Discussion'), findsOneWidget);
      expect(find.text('Document PDF Natif (.pdf)'), findsOneWidget);
      expect(find.text('Document Microsoft Word (.docx)'), findsOneWidget);
      expect(find.text('Format Markdown (.md)'), findsOneWidget);
      expect(find.text('Page Web Imprimable (.html)'), findsOneWidget);
      expect(find.text('Texte Brut Universel (.txt)'), findsOneWidget);
      expect(find.text('Données Structurées (.json)'), findsOneWidget);

      // Fermeture
      await tester.tap(find.text('Fermer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Exporter la Discussion'), findsNothing);
    });

    testWidgets('ACTION 9 : Envoi, Interruption du Streaming et Vidage Complet',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      // Saisie et Envoi
      final inputField = find.byType(TextField);
      await tester.enterText(inputField, 'Question sur le rapport');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(find.text('Question sur le rapport'), findsOneWidget);

      // Clic sur Tout Vider
      final deleteSweepBtn = find.byIcon(Icons.delete_sweep);
      await tester.ensureVisible(deleteSweepBtn);
      await tester.tap(deleteSweepBtn);
      // Drainer les frames sans pumpAndSettle (évite timeout causé par timers HTTP ouverts)
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('Question sur le rapport'), findsNothing);
      expect(
          find.text('Assistant IA Multi-Sources & Documents'), findsOneWidget);
    });
  });
}
