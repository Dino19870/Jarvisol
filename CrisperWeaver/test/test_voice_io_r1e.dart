import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/assistant_voice_service.dart';
import 'package:jarvisol/widgets/voice_dictation_button.dart';
import 'package:jarvisol/widgets/assistant_voice_settings_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PortablePreferences prefs;
  late SettingsService settings;

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
  });

  group('VOICE I/O R1e : SettingsService Configuration', () {
    test('1. Default settings for Voice I/O are correctly initialized', () {
      expect(settings.voiceIoMode, equals('auto'));
      expect(settings.voiceIoOnlineVoice, equals('fr-FR-HenriNeural'));
      expect(settings.voiceIoOfflineVoice, equals('Microsoft Paul'));
      expect(settings.voiceIoOnlineConsent, isNull);
      expect(settings.voiceIoEngine, equals('microsoft'));
    });

    test('2. Setting and persisting voice modes and choices', () async {
      await settings.setVoiceIoMode('offline_only');
      expect(settings.voiceIoMode, equals('offline_only'));

      await settings.setVoiceIoOnlineVoice('fr-FR-DeniseNeural');
      expect(settings.voiceIoOnlineVoice, equals('fr-FR-DeniseNeural'));

      await settings.setVoiceIoOfflineVoice('Microsoft Hortense');
      expect(settings.voiceIoOfflineVoice, equals('Microsoft Hortense'));

      await settings.setVoiceIoOnlineConsent(true);
      expect(settings.voiceIoOnlineConsent, isTrue);

      await settings.setVoiceIoOnlineConsent(false);
      expect(settings.voiceIoOnlineConsent, isFalse);

      await settings.setVoiceIoEngine('legacy_narrator');
      expect(settings.voiceIoEngine, equals('legacy_narrator'));
    });
  });

  group('VOICE I/O R1e : AssistantVoiceService Logic', () {
    test('3. Online and offline voices catalogue definitions', () {
      final onlineVoices = AssistantVoiceService.onlineVoices;
      expect(onlineVoices.isNotEmpty, isTrue);
      expect(onlineVoices.any((v) => v.id == 'fr-FR-HenriNeural'), isTrue);
      expect(onlineVoices.any((v) => v.id == 'fr-FR-DeniseNeural'), isTrue);

      final defaultOffline = AssistantVoiceService.defaultOfflineVoices;
      expect(defaultOffline.isNotEmpty, isTrue);
      expect(defaultOffline.any((v) => v.id.contains('Paul')), isTrue);
    });

    test('4. Text cleaning for speech synthesis', () {
      const markdown = '# Titre Principal\n'
          'Voici du code: `print("hello")` et un [lien](https://example.com).\n'
          'Du texte en **gras** et *italique*.\n'
          '```dart\nvoid main() {}\n```';

      final cleaned = AssistantVoiceService.cleanTextForSpeech(markdown);
      expect(cleaned.contains('#'), isFalse);
      expect(cleaned.contains('`'), isFalse);
      expect(cleaned.contains('['), isFalse);
      expect(cleaned.contains(']'), isFalse);
      expect(cleaned.contains('https://example.com'), isFalse);
      expect(cleaned.contains('**'), isFalse);
      expect(cleaned.contains('Titre Principal'), isTrue);
      expect(cleaned.contains('Voici du code'), isTrue);
      expect(cleaned.contains('gras'), isTrue);
    });

    test('5. Mode online_only without consent returns error result', () async {
      await settings.setVoiceIoMode('online_only');
      await settings.setVoiceIoOnlineConsent(false);

      final service = AssistantVoiceService(settings);
      final res = await service.synthesize(text: 'Bonjour tout le monde');

      expect(res.isSuccess, isFalse);
      expect(res.errorMessage, isNotNull);
      expect(res.errorMessage!.contains('consentement'), isTrue);
    });

    test('6. Mode offline_only executes Windows OneCore without network calls', () async {
      await settings.setVoiceIoMode('offline_only');
      final service = AssistantVoiceService(settings);

      if (Platform.isWindows) {
        final res = await service.synthesize(text: 'Test rapide hors ligne');
        expect(res.isOnline, isFalse);
        expect(res.isSuccess, isTrue);
        expect(res.filePath, isNotNull);
        expect(File(res.filePath!).existsSync(), isTrue);
        // Nettoyage après test
        try {
          File(res.filePath!).deleteSync();
        } catch (_) {}
      }
    });
  });

  group('VOICE I/O R1e : UI Components Integration', () {
    testWidgets('7. AutoTtsToggleButton displays Auto pill and tune settings button',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(settings),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: AutoTtsToggleButton(),
            ),
          ),
        ),
      );
      await tester.pump();

      // Vérifie la présence de la commande Auto
      expect(find.text('Auto'), findsOneWidget);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

      // Vérifie la présence du bouton Réglages Voix
      final tuneIcon = find.byIcon(Icons.tune_rounded);
      expect(tuneIcon, findsOneWidget);
    });

    testWidgets('8. AssistantVoiceSettingsDialog opens and renders options',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(settings),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => AssistantVoiceSettingsDialog.show(context),
                  child: const Text('Ouvrir Réglages'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Clic pour ouvrir le dialogue
      await tester.tap(find.text('Ouvrir Réglages'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Vérifie les éléments clés du dialogue
      expect(find.text('Voix de l’Assistant'), findsOneWidget);
      expect(find.text('Automatique (Recommandé)'), findsOneWidget);
      expect(find.text('En ligne uniquement'), findsOneWidget);
      expect(find.text('Hors ligne uniquement'), findsOneWidget);
      expect(find.text('Confidentialité des voix en ligne'), findsOneWidget);
      expect(find.text('Enregistrer les réglages'), findsOneWidget);
    });
  });
}
