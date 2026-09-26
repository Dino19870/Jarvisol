import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/audiobook_service.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/services/baked_catalog_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Diagnose legacy narrator fallback synthesis in AudiobookService', () async {
    AppPaths.setTestOverride(Directory(r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2'));
    final catalogFile = File('assets/models/catalog.json');
    if (catalogFile.existsSync()) {
      BakedCatalogLoader.loadFromString(catalogFile.readAsStringSync());
    }
    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    final settings = SettingsService(prefs);

    final container = ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(settings),
      ],
      child: const SizedBox(),
    );

    // Initialiser container Riverpod
    final element = ProviderContainer(
      overrides: [
        settingsServiceProvider.overrideWithValue(settings),
      ],
    );

    final audiobookSvc = element.read(audiobookServiceProvider);

    // Tester la préparation avec le narrateur par défaut
    final savedConfig = settings.getSpeakerVoiceConfig('narrator');
    print('savedConfig: $savedConfig');
    print('defaultNarratorVoice: ${settings.defaultNarratorVoice}');

    final speaker = AudiobookSpeaker(
      id: 'narrator',
      name: 'Narrateur',
      voiceModelName: 'vibevoice-voice-fr-Spk0_man',
    );

    final line = AudiobookLine(
      id: 'test_line',
      speakerId: 'narrator',
      speakerName: 'Narrateur',
      text: 'Bonjour, ceci est un test de secours.',
    );

    try {
      final wavBytes = await audiobookSvc.synthesizeLinesToMemory(
        lines: [line],
        speakers: {'narrator': speaker},
      );
      print('Synthesized WAV bytes length: ${wavBytes.length}');
      expect(wavBytes.isNotEmpty, isTrue);
    } catch (e) {
      print('AudiobookService synthesis error: $e');
    }
  });
}
