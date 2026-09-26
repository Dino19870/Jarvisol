import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/audiobook_service.dart';
import 'package:jarvisol/services/baked_catalog_loader.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await BakedCatalogLoader.load();
    const testDllDir = r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST';
    for (final dll in ['whisper.dll', 'crispasr.dll']) {
      final pth = p.join(testDllDir, dll);
      if (File(pth).existsSync()) {
        try {
          DynamicLibrary.open(pth);
          print('Opened DLL: $pth');
        } catch (e) {
          print('Failed opening $pth: $e');
        }
      }
    }
  });

  tearDownAll(() => BakedCatalogLoader.reset());

  test('DIAGNOSTIC TTS MANUEL AVEC APPPATHS DE TEST ET NATIVE DLL', () async {
    print('\n=== DIAGNOSTIC TTS MANUEL AVEC APPPATHS DU TEST RUNNER ===');
    
    final testInstanceDir = Directory(r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST');
    AppPaths.setTestOverride(testInstanceDir);
    addTearDown(AppPaths.resetTestOverride);

    print('AppPaths.appDir: ${AppPaths.appDir.path}');
    print('AppPaths.importedVoicesDir: ${AppPaths.importedVoicesDir.path}');
    final vh1 = File(p.join(AppPaths.importedVoicesDir.path, 'Voix_H_1.gguf'));
    print('Voix_H_1 exists at AppPaths: ${vh1.existsSync()} (taille: ${vh1.existsSync() ? vh1.lengthSync() : 0} octets)');

    final testPrefsFile = File(p.join(testInstanceDir.path, 'data', 'preferences.json'));
    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    
    final jsonMap = jsonDecode(testPrefsFile.readAsStringSync()) as Map<String, dynamic>;
    for (final entry in jsonMap.entries) {
      if (entry.value is String) {
        await prefs.setString(entry.key, entry.value as String);
      } else if (entry.value is bool) {
        await prefs.setBool(entry.key, entry.value as bool);
      } else if (entry.value is int) {
        await prefs.setInt(entry.key, entry.value as int);
      } else if (entry.value is double) {
        await prefs.setDouble(entry.key, entry.value as double);
      }
    }

    final settings = SettingsService(prefs);
    final savedConfig = settings.getSpeakerVoiceConfig('narrator');
    AudiobookSpeaker narratorSpeaker;
    if (savedConfig.isNotEmpty) {
      narratorSpeaker = AudiobookSpeaker.fromJson(savedConfig);
      if (settings.defaultNarratorVoice.isNotEmpty &&
          narratorSpeaker.voiceModelName != settings.defaultNarratorVoice) {
        narratorSpeaker =
            narratorSpeaker.copyWith(voiceModelName: settings.defaultNarratorVoice);
      }
    } else {
      narratorSpeaker = AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: settings.defaultNarratorVoice,
      );
    }
    print('Resolved narratorSpeaker: id=${narratorSpeaker.id}, name=${narratorSpeaker.name}, voiceModelName=${narratorSpeaker.voiceModelName}');

    final container = ProviderContainer(
      overrides: [
        settingsServiceProvider.overrideWithValue(settings),
      ],
    );
    addTearDown(container.dispose);

    final audiobookSvc = container.read(audiobookServiceProvider);

    const testText = 'Bonjour Olivier, ceci est un test de synthèse vocale manuelle dans Jarvisol.';
    final dummyLine = AudiobookLine(
      id: 'diag_test_${DateTime.now().millisecondsSinceEpoch}',
      speakerId: 'narrator',
      speakerName: 'Narrateur',
      text: testText,
    );

    try {
      print('Appel de synthesizeLinesToMemory avec la voix réelle...');
      final stopwatch = Stopwatch()..start();
      final wavBytes = await audiobookSvc.synthesizeLinesToMemory(
        lines: [dummyLine],
        speakers: {'narrator': narratorSpeaker},
      );
      stopwatch.stop();

      print('SUCCESS SYNTHÈSE !');
      print('Durée: ${stopwatch.elapsedMilliseconds} ms');
      print('WAV Bytes générés: ${wavBytes.length} octets');

      final previewFile = File(p.join(testInstanceDir.path, 'data', 'tmp', 'assistant_read_aloud_diag.wav'));
      await previewFile.writeAsBytes(wavBytes);
      print('Fichier écrit: ${previewFile.path} (taille: ${previewFile.lengthSync()} octets)');

      print('\n>>> CLASSIFICATION : CAS A (TTS_MANUEL_OK) <<<');
    } catch (e, st) {
      print('\n>>> ERREUR SYNTHÈSE : $e <<<');
      print('Stacktrace:\n$st');
    }
  });
}
