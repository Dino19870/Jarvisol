// test/voice_clone_reftext_ux_fix_test.dart
// Targeted verification tests for PHASE JARVISOL-VOICE-CLONE-REFTEXT-UX-FIX1.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:jarvisol/l10n/generated/app_localizations.dart';
import 'package:jarvisol/l10n/generated/app_localizations_en.dart';
import 'package:jarvisol/l10n/generated/app_localizations_de.dart';
import 'package:jarvisol/l10n/generated/app_localizations_zh.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/screens/synthesize_screen.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/widgets/voice_tuning_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A. Wizard & ARB texts — no false claims of audio-alone for Qwen3 Base', () {
    test('EN: voiceCloneRefTextHelp does not claim Qwen3 Base clones from audio alone', () {
      final l = AppLocalizationsEn();
      final help = l.voiceCloneRefTextHelp;
      expect(help.contains('qwen3-tts Base) clone from audio alone'), isFalse,
          reason: 'Must not claim Qwen3 Base clones from audio alone');
      expect(help.toLowerCase(), contains('qwen3-tts base'));
      expect(help.toLowerCase(), contains('vibevoice 1.5b'));
      expect(help.toLowerCase(), contains('required'));
    });

    test('EN: voiceCloneHandoffModelHint does not claim Qwen3 Base clones from audio alone', () {
      final l = AppLocalizationsEn();
      final hint = l.voiceCloneHandoffModelHint;
      expect(hint.contains('qwen3-tts Base clone from audio alone'), isFalse,
          reason: 'Must not claim Qwen3 Base clones from audio alone');
      expect(hint.toLowerCase(), contains('qwen3-tts base and vibevoice'));
    });

    test('DE: voiceCloneRefTextHelp does not claim Qwen3 Base clones from audio alone', () {
      final l = AppLocalizationsDe();
      final help = l.voiceCloneRefTextHelp;
      expect(help.contains('qwen3-tts Base) klonen nur aus Audio'), isFalse);
      expect(help, contains('Qwen3-TTS Base'));
      expect(help, contains('VibeVoice 1.5B'));
    });

    test('ZH: voiceCloneRefTextHelp does not claim Qwen3 Base clones from audio alone', () {
      final l = AppLocalizationsZh();
      final help = l.voiceCloneRefTextHelp;
      expect(help.contains('qwen3-tts Base）仅从音频克隆'), isFalse);
      expect(help, contains('Qwen3-TTS Base'));
      expect(help, contains('VibeVoice 1.5B'));
    });

    test('synthRefTextRequired exists and is translated across all locales', () {
      final en = AppLocalizationsEn();
      final de = AppLocalizationsDe();
      final zh = AppLocalizationsZh();
      expect(en.synthRefTextRequired, isNotEmpty);
      expect(de.synthRefTextRequired, isNotEmpty);
      expect(zh.synthRefTextRequired, isNotEmpty);
    });
  });

  group('B. Studio Audio — VoiceTuningDialog label and helper', () {
    late SettingsService settingsService;

    setUp(() async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      settingsService = SettingsService(prefs);
    });

    testWidgets('VoiceTuningDialog does not show (optionnel) and displays corrected label & helper', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const speaker = AudiobookSpeaker(
        id: 'hero',
        name: 'Héros',
        voiceModelName: 'custom-clone',
        customVoiceWavPath: 'C:/Audio/whatsapp_memo.wav',
        customVoiceRefText: 'Bonjour ceci est mon enregistrement de référence',
        speed: 1.0,
        pitch: 1.0,
      );

      final availableVoices = {
        'custom-clone': '🎙️ [Clonage Vocal] Échantillon Audio Personnalisé (.wav)',
      };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(settingsService),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () => VoiceTuningDialog.show(
                    ctx,
                    speaker: speaker,
                    availableVoices: availableVoices,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Ensure "optionnel" / "facultatif" is not displayed anywhere for reference text
      expect(find.textContaining('facultatif'), findsNothing);
      expect(find.textContaining('optionnel'), findsNothing);

      // Verify exact label and helper text
      expect(find.text('Transcription de référence'), findsOneWidget);
      expect(find.text('Required for Qwen3-TTS Base and VibeVoice 1.5B when cloning from a WAV.'), findsOneWidget);
    });
  });

  group('C, D, E, F, G. SynthesizeScreen Pre-Flight Guard Contract', () {
    test('C. Qwen3 Base + custom WAV + empty refText -> BLOCKED', () {
      const qwenModels = [
        'qwen3-tts-12hz-0.6b-base-q8_0',
        'qwen3-tts-12hz-0.6b-base',
        'qwen3-tts-12hz-0.6b-base-q4_k',
        'qwen3-tts-base',
      ];
      for (final model in qwenModels) {
        expect(
          SynthesizeScreen.shouldBlockSynthesisForMissingRefText(
            hasCustomWav: true,
            modelName: model,
            refText: '',
          ),
          isTrue,
          reason: '$model with custom WAV and empty refText must be blocked',
        );
        expect(
          SynthesizeScreen.shouldBlockSynthesisForMissingRefText(
            hasCustomWav: true,
            modelName: model,
            refText: '   ',
          ),
          isTrue,
          reason: '$model with custom WAV and whitespace refText must be blocked',
        );
      }
    });

    test('D. Qwen3 Base + custom WAV + present refText -> ALLOWED', () {
      expect(
        SynthesizeScreen.shouldBlockSynthesisForMissingRefText(
          hasCustomWav: true,
          modelName: 'qwen3-tts-12hz-0.6b-base-q8_0',
          refText: 'Bonjour Olivier. Ceci est un essai de clonage vocal.',
        ),
        isFalse,
        reason: 'Qwen3 Base with custom WAV and valid refText must NOT be blocked',
      );
    });

    test('E. VibeVoice 1.5B + custom WAV + empty refText -> BLOCKED', () {
      const vibeModels = [
        'vibevoice-1.5b-tts-q4_k',
        'vibevoice-1.5b',
      ];
      for (final model in vibeModels) {
        expect(
          SynthesizeScreen.shouldBlockSynthesisForMissingRefText(
            hasCustomWav: true,
            modelName: model,
            refText: '',
          ),
          isTrue,
          reason: '$model with custom WAV and empty refText must be blocked',
        );
        expect(
          SynthesizeScreen.shouldBlockSynthesisForMissingRefText(
            hasCustomWav: true,
            modelName: model,
            refText: '   \t  ',
          ),
          isTrue,
          reason: '$model with custom WAV and whitespace refText must be blocked',
        );
      }
    });

    test('F. VibeVoice 1.5B + custom WAV + present refText -> ALLOWED', () {
      expect(
        SynthesizeScreen.shouldBlockSynthesisForMissingRefText(
          hasCustomWav: true,
          modelName: 'vibevoice-1.5b-tts-q4_k',
          refText: 'Valid reference transcript',
        ),
        isFalse,
        reason: 'VibeVoice 1.5B with valid refText must NOT be blocked',
      );
    });

    test('G. Backends not requiring refText are NOT blocked', () {
      final nonBlockedModels = [
        'chatterbox',
        'chatterbox-turbo',
        'kokoro-v1_0',
        'orpheus-3.0b',
        'qwen3-tts-0.6b-customvoice',
        'melotts-french',
        'piper-fr',
      ];
      for (final model in nonBlockedModels) {
        expect(
          SynthesizeScreen.shouldBlockSynthesisForMissingRefText(
            hasCustomWav: true,
            modelName: model,
            refText: '',
          ),
          isFalse,
          reason: '$model should NOT be blocked even if refText is empty',
        );
      }
    });

    test('G2. Models with no custom WAV (preset voices) are NEVER blocked on refText', () {
      final models = [
        'qwen3-tts-12hz-0.6b-base-q8_0',
        'vibevoice-1.5b-tts-q4_k',
        'chatterbox',
        'kokoro-v1_0',
      ];
      for (final model in models) {
        expect(
          SynthesizeScreen.shouldBlockSynthesisForMissingRefText(
            hasCustomWav: false,
            modelName: model,
            refText: '',
          ),
          isFalse,
          reason: '$model without custom WAV must never be blocked by refText guard',
        );
      }
    });
  });
}
