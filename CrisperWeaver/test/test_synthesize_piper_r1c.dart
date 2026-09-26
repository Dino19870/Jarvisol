import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/main.dart' show modelServiceProvider;
import 'package:jarvisol/services/baked_catalog_loader.dart';
import 'package:jarvisol/services/model_catalog.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/tts_service.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testDllDir = r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST';
  final piperGgufScratch = r'D:\Antigravity\AgentFolder\CrisperWeaver\scratch\piper_r1c\piper-fr_FR-gilles-low.gguf';

  setUpAll(() async {
    await BakedCatalogLoader.load();
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

  test('TEST SYNTHESIZE SERVICE AVEC PIPER GILLES GGUF (VALIDATION SECTION 8)', () async {
    print('\n======================================================');
    print('  VOICE I/O R1c : TEST ÉCRAN SYNTHESIZE / TTS SERVICE');
    print('======================================================\n');

    final testInstanceDir = Directory(testDllDir);
    AppPaths.setTestOverride(testInstanceDir);
    addTearDown(AppPaths.resetTestOverride);

    // 1. Copier piper-fr_FR-gilles-low.gguf dans data/models/whisper_cpp
    final targetGguf = File(p.join(testInstanceDir.path, 'data', 'models', 'whisper_cpp', 'piper-fr_FR-gilles-low.gguf'));
    if (!targetGguf.existsSync()) {
      File(piperGgufScratch).copySync(targetGguf.path);
      print('GGUF copié temporairement dans : ${targetGguf.path}');
    }
    addTearDown(() {
      if (targetGguf.existsSync()) {
        targetGguf.deleteSync();
        print('GGUF temporaire supprimé de : ${targetGguf.path}');
      }
    });

    // 2. Ajouter l'entrée temporaire de test au catalogue
    const testModelKey = 'piper-fr-gilles-low-test';
    final testModelDef = ModelDefinition(
      name: testModelKey,
      displayName: 'Piper fr_FR Gilles — TEST R1c',
      fileName: 'piper-fr_FR-gilles-low.gguf',
      backend: 'piper',
      kind: ModelKind.tts,
      sizeBytes: targetGguf.lengthSync(),
      checksum: '',
      description: 'Piper VITS TTS - Français (Gilles GGUF Test R1c)',
      quantization: 'f16',
      languages: const ['fr'],
      url: 'https://local.test/piper-fr_FR-gilles-low.gguf',
    );

    BakedCatalogLoader.cached[testModelKey] = testModelDef;
    addTearDown(() => BakedCatalogLoader.cached.remove(testModelKey));

    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    final settingsService = SettingsService(prefs);

    final container = ProviderContainer(
      overrides: [
        settingsServiceProvider.overrideWithValue(settingsService),
      ],
    );
    addTearDown(container.dispose);

    final modelService = container.read(modelServiceProvider);
    final ttsService = container.read(ttsServiceProvider);

    // 3. Vérifier que ModelService résout le modèle
    final resolvedPath = await modelService.getWhisperCppModelPath(testModelKey);
    print('Chemin résolu par ModelService: $resolvedPath');
    expect(resolvedPath, isNotNull);
    expect(File(resolvedPath!).existsSync(), isTrue);

    // 4. Tester prepare() - Doit être ready sans "Missing required companion file"
    print('\n--- Appel de TtsService.prepare() ---');
    final status = await ttsService.prepare(
      modelName: testModelKey,
    );

    print('Status ready: ${status.ready}');
    print('Status backend: ${status.backend}');
    print('Status missingModelName: ${status.missingModelName}');
    print('Status missingVoiceName: ${status.missingVoiceName}');
    print('Status missingCodecName: ${status.missingCodecName}');
    print('Status errorMessage: ${status.errorMessage}');

    expect(status.ready, isTrue, reason: 'Le modèle doit être prêt sans erreur');
    expect(status.missingModelName, isNull);
    expect(status.missingVoiceName, isNull);
    expect(status.missingCodecName, isNull);
    expect(status.errorMessage, isNull);
    expect(status.backend, equals('piper'));

    // 5. Vérifier les métadonnées de session
    final nSpeakers = ttsService.session?.nSpeakers ?? 0;
    print('Nombre de locuteurs FFI: $nSpeakers');
    expect(nSpeakers, equals(1));

    // 6. Tester la synthèse vocale complète via TtsService
    print('\n--- Synthèse via TtsService.synthesize() ---');
    final sw = Stopwatch()..start();
    final result = await ttsService.synthesize(
      'Bonjour Olivier. Le test dans le moteur de synthèse de Jarvisol avec Piper Gilles est validé.',
      speed: 1.0,
    );
    sw.stop();

    expect(result, isNotNull);
    expect(result!.samples.isNotEmpty, isTrue);
    print('Synthèse réussie en ${sw.elapsedMilliseconds} ms ! Échantillons générés: ${result.samples.length}, durée: ${result.durationSeconds.toStringAsFixed(2)} s');
    print('======================================================\n');
  });
}
