// test/audiobook_voice_tuning_test.dart — Unit & Widget tests for voice tuning and preset management.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/widgets/voice_tuning_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AUDIT MODELES & PRESETS DE VOIX', () {
    test('1.1 AudiobookSpeaker serialization with speed, pitch, volume and preset', () {
      const speaker = AudiobookSpeaker(
        id: 'hero',
        name: 'Héros',
        voiceModelName: 'custom-clone',
        role: 'male',
        speed: 1.15,
        pitch: 0.92,
        volume: 1.20,
        presetName: 'preset_hero_deep',
        customVoiceWavPath: 'C:/Samples/hero_voice.wav',
      );

      final json = speaker.toJson();
      expect(json['id'], 'hero');
      expect(json['speed'], 1.15);
      expect(json['pitch'], 0.92);
      expect(json['volume'], 1.20);
      expect(json['presetName'], 'preset_hero_deep');
      expect(json['customVoiceWavPath'], 'C:/Samples/hero_voice.wav');

      final deserialized = AudiobookSpeaker.fromJson(json);
      expect(deserialized.id, 'hero');
      expect(deserialized.speed, 1.15);
      expect(deserialized.pitch, 0.92);
      expect(deserialized.volume, 1.20);
      expect(deserialized.presetName, 'preset_hero_deep');
      expect(deserialized.customVoiceWavPath, 'C:/Samples/hero_voice.wav');
    });

    test('1.2 VoicePreset default presets and copyWith', () {
      expect(VoicePreset.defaultPresets.length, greaterThanOrEqualTo(5));
      final p1 = VoicePreset.defaultPresets.first;
      expect(p1.name, contains('Narrateur'));

      final custom = p1.copyWith(name: 'Custom Narrateur', speed: 0.85);
      expect(custom.name, 'Custom Narrateur');
      expect(custom.speed, 0.85);
      expect(custom.pitch, 1.0);
    });
    test('1.3 ClonedVoiceProfile serialization and roundtrip', () {
      final profile = ClonedVoiceProfile(
        id: 'voice_123',
        name: 'Ma Voix (Lansana)',
        wavPath: 'C:/Audio/my_voice.wav',
        refText: 'Bonjour le monde',
        defaultSpeed: 1.1,
        defaultPitch: 0.95,
        defaultVolume: 1.0,
        createdAt: DateTime(2026, 8, 23, 10, 0),
      );

      final json = profile.toJson();
      expect(json['id'], 'voice_123');
      expect(json['name'], 'Ma Voix (Lansana)');
      expect(json['wavPath'], 'C:/Audio/my_voice.wav');
      expect(json['refText'], 'Bonjour le monde');

      final deserialized = ClonedVoiceProfile.fromJson(json);
      expect(deserialized.id, 'voice_123');
      expect(deserialized.name, 'Ma Voix (Lansana)');
      expect(deserialized.wavPath, 'C:/Audio/my_voice.wav');
      expect(deserialized.refText, 'Bonjour le monde');
      expect(deserialized.defaultSpeed, 1.1);
    });
  });

  group('AUDIT WIDGETS : VoiceTuningDialog', () {
    late SettingsService settingsService;

    setUp(() async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      settingsService = SettingsService(prefs);
    });

    testWidgets('2.1 VoiceTuningDialog renders sliders, voice dropdown, and presets', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const speaker = AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: 'kokoro-voice-ff_siwis',
        speed: 1.0,
        pitch: 1.0,
      );

      final availableVoices = {
        'kokoro-voice-ff_siwis': '👩 Siwis (Kokoro 82M — Voix Française Claire)',
        'qwen3-ethan': '👨 Ethan (Qwen3-TTS — Voix Masculine Naturelle)',
        'qwen3-vivian': '👩 Vivian (Qwen3-TTS — Voix Féminine Expressive)',
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
                  onPressed: () {
                    VoiceTuningDialog.show(
                      ctx,
                      speaker: speaker,
                      initialSampleText: 'Extrait de test interactif pour la voix.',
                      availableVoices: availableVoices,
                    );
                  },
                  child: const Text('Ouvrir Réglages Voix'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Ouvrir Réglages Voix'));
      await tester.pumpAndSettle();

      expect(find.text('Atelier de Paramétrage Vocal'), findsOneWidget);
      expect(find.textContaining('Narrateur'), findsWidgets);
      expect(find.text('Vitesse de diction'), findsOneWidget);
      expect(find.text('Tonalité / Pitch'), findsOneWidget);
      expect(find.text('Volume sonore :'), findsOneWidget);
      expect(find.text('Extrait de test en direct :'), findsOneWidget);
      expect(find.text('Appliquer au Personnage'), findsOneWidget);

      // Verify preset selection
      expect(find.text('Presets :'), findsOneWidget);

      // Verify dialog dismissal / cancel
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(find.text('Atelier de Paramétrage Vocal'), findsNothing);
    });

    testWidgets('2.2 VoiceTuningDialog renders custom clone mode, reference text field, and saves to library', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      AudiobookSpeaker? resultingSpeaker;

      const speaker = AudiobookSpeaker(
        id: 'hero',
        name: 'Héros',
        voiceModelName: 'custom-clone',
        customVoiceWavPath: 'C:/Audio/whatsapp_memo.wav',
        customVoiceRefText: 'Bonjour ceci est mon enregistrement de référence',
        speed: 1.05,
        pitch: 1.0,
      );

      final availableVoices = {
        'custom-clone': '🎙️ [Clonage Vocal] Échantillon Audio Personnalisé (.wav)',
        'kokoro-voice-ff_siwis': '👩 Siwis (Kokoro 82M)',
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
                  onPressed: () async {
                    resultingSpeaker = await VoiceTuningDialog.show(
                      ctx,
                      speaker: speaker,
                      availableVoices: availableVoices,
                    );
                  },
                  child: const Text('Ouvrir Dialogue Clonage'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Ouvrir Dialogue Clonage'));
      await tester.pumpAndSettle();

      expect(find.text('Clonage Vocal & Banque de Voix'), findsOneWidget);
      expect(find.text('whatsapp_memo.wav'), findsOneWidget);
      expect(find.text('Transcription de référence'), findsOneWidget);
      expect(find.text('Required for Qwen3-TTS Base and VibeVoice 1.5B when cloning from a WAV.'), findsOneWidget);
      expect(find.textContaining('facultatif'), findsNothing);
      expect(find.textContaining('optionnel'), findsNothing);
      expect(find.text('Nom de la voix (visible dans le sélecteur)'), findsOneWidget);

      await tester.tap(find.text('Appliquer au Personnage'));
      await tester.pumpAndSettle();

      expect(resultingSpeaker, isNotNull);
      expect(resultingSpeaker!.voiceModelName, startsWith('clone_'));
      expect(resultingSpeaker!.customVoiceWavPath, 'C:/Audio/whatsapp_memo.wav');
      expect(resultingSpeaker!.customVoiceRefText, 'Bonjour ceci est mon enregistrement de référence');
    });
  });
}
