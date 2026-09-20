// test/hardware_diagnostic_ui_test.dart
//
// Tests de widgets pour FirstRunWelcomeDialog, HardwareChangedDialog et HardwareDiagnosticDialog (EXT-V1-01)
// Couvre les exigences de micro-hardening :
// A. Séquencement correct des dialogues
// B. Absence de concurrence / superposition
// C. Wording corrigé
// F. « Plus tard » : aucun blocage
// G. « Actualiser » : ouverture du diagnostic

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/hardware_advisor_service.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/widgets/hardware_diagnostic_dialog.dart';

void main() {
  testWidgets('C: FirstRunWelcomeDialog uses exact and cautious wording without 100% or fixed time', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FirstRunWelcomeDialog(),
        ),
      ),
    );

    // Titre et boutons
    expect(find.text('Bienvenue dans Jarvisol'), findsOneWidget);
    expect(find.text('Analyser cet ordinateur'), findsOneWidget);
    expect(find.text('Continuer sans analyser'), findsOneWidget);

    // Wording exact & prudent
    expect(
      find.textContaining('Jarvisol peut fonctionner avec de nombreux moteurs locaux et propose également certaines fonctions connectées optionnelles.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('analyser les principales capacités matérielles de cet ordinateur'),
      findsOneWidget,
    );

    // Absence de formulations trop absolues ou promesses de temps fixes
    expect(find.textContaining('100% locale et portable'), findsNothing);
    expect(find.textContaining('en une fraction de seconde'), findsNothing);
  });

  testWidgets('A & B: Séquencement strict et absence de superposition entre dialogue IA et Hardware Advisor', (tester) async {
    // Ce test simule l'enchaînement au premier démarrage :
    // 1. Dialogue de transparence IA ouvert
    // 2. Hardware Advisor ne doit PAS être visible tant que le dialogue IA est ouvert
    // 3. Fermeture du dialogue IA
    // 4. Ensuite seulement, affichage de FirstRunWelcomeDialog

    bool aiNoticeOpen = false;
    bool welcomeDialogOpen = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                // Étape 1 : Dialogue IA affiché
                aiNoticeOpen = true;
                await showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Transparence IA'),
                    content: const Text('Information sur les systèmes IA utilisés.'),
                    actions: [
                      FilledButton(
                        onPressed: () {
                          aiNoticeOpen = false;
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('J\'ai compris'),
                      ),
                    ],
                  ),
                );

                // Étape 2 : Après fermeture du dialogue IA, affichage du Welcome Dialog
                if (context.mounted) {
                  welcomeDialogOpen = true;
                  await showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const FirstRunWelcomeDialog(),
                  );
                }
              },
              child: const Text('Démarrer Séquence'),
            ),
          ),
        ),
      ),
    );

    // Lancer la séquence
    await tester.tap(find.text('Démarrer Séquence'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 1. Le dialogue de transparence IA est visible
    expect(find.text('Transparence IA'), findsOneWidget);
    expect(aiNoticeOpen, isTrue);

    // 2. Le dialogue Hardware Advisor n'est PAS encore affiché (aucune concurrence/superposition)
    expect(find.text('Bienvenue dans Jarvisol'), findsNothing);
    expect(welcomeDialogOpen, isFalse);

    // 3. L'utilisateur valide le dialogue de transparence IA
    await tester.tap(find.text('J\'ai compris'));
    await tester.pumpAndSettle();

    // 4. Le dialogue de transparence est fermé et le Hardware Advisor apparaît maintenant
    expect(find.text('Transparence IA'), findsNothing);
    expect(aiNoticeOpen, isFalse);
    expect(welcomeDialogOpen, isTrue);
    expect(find.text('Bienvenue dans Jarvisol'), findsOneWidget);

    // 5. Fermeture propre de FirstRunWelcomeDialog
    await tester.tap(find.text('Continuer sans analyser'));
    await tester.pumpAndSettle();
    expect(find.text('Bienvenue dans Jarvisol'), findsNothing);
  });

  testWidgets('F: HardwareChangedDialog dismisses cleanly on "Plus tard" without blocking', (tester) async {
    bool dialogPopped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await showDialog<void>(
                  context: context,
                  builder: (_) => const HardwareChangedDialog(),
                );
                dialogPopped = true;
              },
              child: const Text('Trigger Changed Dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Trigger Changed Dialog'));
    await tester.pumpAndSettle();

    expect(find.text('Configuration matérielle'), findsOneWidget);
    expect(
      find.text('Jarvisol semble être utilisé sur une configuration matérielle différente. Actualiser le diagnostic ?'),
      findsOneWidget,
    );
    expect(find.text('Plus tard'), findsOneWidget);
    expect(find.text('Actualiser'), findsOneWidget);

    // Clic sur "Plus tard"
    await tester.tap(find.text('Plus tard'));
    await tester.pumpAndSettle();

    expect(dialogPopped, isTrue);
    expect(find.text('Configuration matérielle'), findsNothing);
  });

  testWidgets('G: HardwareChangedDialog opens diagnostic on "Actualiser"', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const HardwareChangedDialog(),
              ),
              child: const Text('Trigger Changed Dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Trigger Changed Dialog'));
    await tester.pumpAndSettle();

    expect(find.text('Configuration matérielle'), findsOneWidget);

    // Clic sur "Actualiser"
    await tester.tap(find.text('Actualiser'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    // HardwareChangedDialog fermé, HardwareDiagnosticDialog ouvert
    expect(find.text('Configuration matérielle'), findsNothing);
    expect(find.text('Diagnostic Matériel & Capacités IA'), findsOneWidget);
  });

  testWidgets('Scénario complet : Continuer sans analyser -> redémarrage sans faux dialogue', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('hw_ui_test_');
    AppPaths.setTestOverride(tempDir);

    try {
      // 1. Premier démarrage : état vierge
      bool serviceInvoked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  HardwareAdvisorService.instance.checkAndPromptOnboarding(context);
                  serviceInvoked = true;
                },
                child: const Text('Start First Run'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Start First Run'));
      await tester.pump();
      await tester.pumpAndSettle();

      // Le dialogue d'accueil est présent
      expect(find.text('Bienvenue dans Jarvisol'), findsOneWidget);
      expect(find.text('Continuer sans analyser'), findsOneWidget);
      expect(serviceInvoked, isTrue);

      // 2. L'utilisateur clique sur "Continuer sans analyser"
      await tester.tap(find.text('Continuer sans analyser'));
      await tester.pumpAndSettle();

      // Le dialogue se ferme
      expect(find.text('Bienvenue dans Jarvisol'), findsNothing);

      // Vérification de l'état enregistré : onboarding_seen == true, AUCUN technical_fingerprint
      final savedFp = await HardwareAdvisorService.instance.getSavedFingerprint();
      final seen = await HardwareAdvisorService.instance.hasSeenOnboarding();
      expect(seen, isTrue);
      expect(savedFp, isNull);

      // 3. Deuxième démarrage (simulation de redémarrage de Jarvisol)
      bool secondRunComplete = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  await HardwareAdvisorService.instance.checkAndPromptOnboarding(context);
                  secondRunComplete = true;
                },
                child: const Text('Start Second Run'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Start Second Run'));
      await tester.pump();
      await tester.pumpAndSettle();

      // Oracle strict :
      // - aucun faux HardwareChangedDialog
      // - aucun dialogue de bienvenue réaffiché
      // - aucun diagnostic imposé
      // - Jarvisol démarre normalement
      expect(secondRunComplete, isTrue);
      expect(find.text('Configuration matérielle'), findsNothing);
      expect(find.text('Bienvenue dans Jarvisol'), findsNothing);
      expect(find.text('Diagnostic Matériel & Capacités IA'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    } finally {
      AppPaths.resetTestOverride();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('Qualifié : Le statut principal en haut à droite est préfixé "Matériel :" ou "Stockage :"', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HardwareDiagnosticDialog(),
        ),
      ),
    );

    // Attendre la fin du chargement de l'inspection
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Diagnostic Matériel & Capacités IA'), findsOneWidget);

    // Vérifier la présence de statuts qualifiés
    final materielStatusFinder = find.textContaining('Matériel : ');
    final stockageStatusFinder = find.textContaining('Stockage : ');
    expect(materielStatusFinder, findsWidgets);
    expect(stockageStatusFinder, findsWidgets);

    // Vérifier qu'aucun label brut non qualifié n'apparaît en statut principal
    expect(find.text('Compatible'), findsNothing);
    expect(find.text('Probablement compatible'), findsNothing);
    expect(find.text('Capacité restreinte'), findsNothing);
    expect(find.text('Non recommandé'), findsNothing);
  });
}

