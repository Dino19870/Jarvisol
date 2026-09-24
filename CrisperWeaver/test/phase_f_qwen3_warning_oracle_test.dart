import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/voice_pack_inspector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final badPackPath = r"C:\Users\lansa\.gemini\antigravity\brain\31f213dd-5da9-404a-adeb-04503ae36594\scratch\er9_fixtures\controlled_bad_double_paste.gguf";
  final cleanPackPath = r"C:\Users\lansa\.gemini\antigravity\brain\31f213dd-5da9-404a-adeb-04503ae36594\scratch\er8_fixtures\B_normale.gguf";
  final chatterboxPath = r"D:\Antigravity\AgentFolder\VoiceBake\output\C2_Chatterbox_Test.gguf";

  group('Oracle Explicite : Import pack Qwen3 suspect', () {
    test('1. VoicePackInspector détecte la répétition massive sur bad pack Qwen3', () {
      if (!File(badPackPath).existsSync()) {
        fail('Fichier badPackPath introuvable: $badPackPath');
      }
      final res = VoicePackInspector.inspect(badPackPath);
      expect(res.isValid, isTrue);
      expect(res.family, equals(VoicePackFamily.qwen3));
      expect(res.warningMessage, isNotNull);
      expect(res.warningMessage, contains('Répétition massive suspecte'));
      print('Avertissement détecté: ${res.warningMessage}');
    });

    test('2. VoicePackInspector ne produit aucun avertissement sur pack Qwen3 sain', () {
      if (!File(cleanPackPath).existsSync()) {
        fail('Fichier cleanPackPath introuvable: $cleanPackPath');
      }
      final res = VoicePackInspector.inspect(cleanPackPath);
      expect(res.isValid, isTrue);
      expect(res.family, equals(VoicePackFamily.qwen3));
      expect(res.warningMessage, isNull);
    });

    test('3. VoicePackInspector ne produit aucun avertissement sur pack Chatterbox', () {
      if (File(chatterboxPath).existsSync()) {
        final res = VoicePackInspector.inspect(chatterboxPath);
        expect(res.isValid, isTrue);
        expect(res.family, equals(VoicePackFamily.chatterbox));
        expect(res.warningMessage, isNull);
      }
    });

    testWidgets('4. Dialogue d\'import : Choix A -> Annuler => pack non importé', (tester) async {
      bool? importExecuted;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final res = VoicePackInspector.inspect(badPackPath);
                    if (res.warningMessage != null) {
                      final proceed = await showDialog<bool>(
                        context: context,
                        barrierDismissible: false,
                        builder: (ctx) => AlertDialog(
                          icon: const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 36),
                          title: const Text('Avertissement : Transcription potentiellement anormale'),
                          content: Text(res.warningMessage!),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Annuler'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Importer quand même'),
                            ),
                          ],
                        ),
                      );
                      if (proceed != true) {
                        importExecuted = false;
                        return;
                      }
                    }
                    importExecuted = true;
                  },
                  child: const Text('Simuler Import'),
                ),
              ),
            ),
          ),
        ),
      );

      // Ouvrir le dialogue
      await tester.tap(find.text('Simuler Import'));
      await tester.pumpAndSettle();

      // Vérifier la présence du dialogue d'alerte
      expect(find.text('Avertissement : Transcription potentiellement anormale'), findsOneWidget);
      expect(find.textContaining('Répétition massive suspecte'), findsOneWidget);
      expect(find.text('Annuler'), findsOneWidget);
      expect(find.text('Importer quand même'), findsOneWidget);

      // Clic sur Annuler
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      // Vérifier le rejet de l'import
      expect(importExecuted, isFalse);
      expect(find.text('Avertissement : Transcription potentiellement anormale'), findsNothing);
    });

    testWidgets('5. Dialogue d\'import : Choix B -> Importer quand même => import autorisé', (tester) async {
      bool? importExecuted;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final res = VoicePackInspector.inspect(badPackPath);
                    if (res.warningMessage != null) {
                      final proceed = await showDialog<bool>(
                        context: context,
                        barrierDismissible: false,
                        builder: (ctx) => AlertDialog(
                          icon: const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 36),
                          title: const Text('Avertissement : Transcription potentiellement anormale'),
                          content: Text(res.warningMessage!),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Annuler'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Importer quand même'),
                            ),
                          ],
                        ),
                      );
                      if (proceed != true) {
                        importExecuted = false;
                        return;
                      }
                    }
                    importExecuted = true;
                  },
                  child: const Text('Simuler Import'),
                ),
              ),
            ),
          ),
        ),
      );

      // Ouvrir le dialogue
      await tester.tap(find.text('Simuler Import'));
      await tester.pumpAndSettle();

      // Clic sur Importer quand même
      await tester.tap(find.text('Importer quand même'));
      await tester.pumpAndSettle();

      // Vérifier l'autorisation de l'import
      expect(importExecuted, isTrue);
      expect(find.text('Avertissement : Transcription potentiellement anormale'), findsNothing);
    });
  });
}
