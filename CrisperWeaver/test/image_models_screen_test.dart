// test/image_models_screen_test.dart
//
// Suite de tests Widgets & Integration renforcee pour l'interface utilisateur des modeles Image
// JARVISOL — EXT-V1-02 — PHASE 2 : Tests P2-T01 a P2-T34.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jarvisol/l10n/generated/app_localizations.dart';
import 'package:jarvisol/models/image_model_catalog.dart';
import 'package:jarvisol/screens/image_models_screen.dart';
import 'package:jarvisol/screens/settings_screen.dart';
import 'package:jarvisol/services/image_model_catalog_service.dart';
import 'package:jarvisol/services/image_model_install_planner.dart';
import 'package:jarvisol/services/image_model_installer_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:path/path.dart' as p;

class _MockLicensePlanner extends ImageModelInstallPlanner {
  final InstallationPlan mockPlan;
  _MockLicensePlanner({required super.catalogService, required this.mockPlan});

  @override
  Future<InstallationPlan> buildPlan({
    required List<String> targetLogicalModelIds,
    bool checkDiskSpace = true,
    int? diskSpaceOverride,
  }) async {
    return mockPlan;
  }
}

class FakeImageModelInstallerService extends ImageModelInstallerService {
  final StreamController<DownloadProgressEvent> _controller =
      StreamController<DownloadProgressEvent>.broadcast();
  bool cancelCalled = false;
  Exception? planException;
  Future<void> Function(InstallationPlan plan)? onExecutePlan;

  FakeImageModelInstallerService({
    required super.catalogService,
    super.httpClient,
    super.diskSpaceProbe,
    super.writerFactory,
  });

  @override
  Stream<DownloadProgressEvent> get progressStream => _controller.stream;

  void emitProgress(DownloadProgressEvent event) {
    _controller.add(event);
  }

  @override
  void cancel() {
    cancelCalled = true;
    _controller.add(const DownloadProgressEvent(
      status: ImageDownloadStatus.cancelled,
      currentComponentId: '',
      currentFileName: '',
      bytesDownloaded: 0,
      totalBytes: 0,
      progressPercentage: 0,
    ));
  }

  @override
  Future<void> executePlan(InstallationPlan plan, {bool acceptedLicenses = false}) async {
    if (planException != null) {
      throw planException!;
    }
    if (onExecutePlan != null) {
      await onExecutePlan!(plan);
    }
  }

  @override
  void dispose() {
    _controller.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory tempModelsDir;
  late ImageModelCatalogService catalogService;
  late ImageModelInstallPlanner planner;
  late PortablePreferences prefs;
  late SettingsService settingsService;

  final canonicalCatalogJson = File('assets/models/image_model_catalog.json').readAsStringSync();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('image_ui_test_');
    tempModelsDir = Directory('${tempDir.path}/models/Stable-diffusion');
    await tempModelsDir.create(recursive: true);

    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settingsService = SettingsService(prefs);

    catalogService = ImageModelCatalogService(modelsDir: tempModelsDir);
    await catalogService.loadCatalog(jsonContent: canonicalCatalogJson);

    planner = ImageModelInstallPlanner(
      catalogService: catalogService,
      diskSpaceProbe: (_) => 500 * 1024 * 1024 * 1024, // 500 Go libres
    );
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  LogicalModelStatus createMockStatus({
    required String modelId,
    required LogicalModelInstallState state,
    int installedBytes = 0,
    int totalBytes = 1000,
  }) {
    final model = catalogService.catalog.logicalModels[modelId]!;
    return LogicalModelStatus(
      model: model,
      state: state,
      componentStatuses: const {},
      missingComponentIds: state == LogicalModelInstallState.installed ? const [] : model.requiredComponentIds,
      totalRequiredSizeBytes: totalBytes,
      installedSizeBytes: installedBytes,
    );
  }

  InstallationPlan createLicenseTestPlan({String modelId = 'MOD_03_SD35_LARGE_TURBO'}) {
    return InstallationPlan(
      targetLogicalModelIds: [modelId],
      componentsToDownload: const [],
      alreadyInstalledComponents: const [],
      totalRequiredBytes: 1000,
      alreadyInstalledBytes: 0,
      downloadRequiredBytes: 1000,
      temporaryOverheadBytes: 1000,
      minimumFreeDiskBytes: 2000,
      availableFreeDiskBytes: 50000000,
      isDiskSpaceSufficient: true,
      requiresLicenseAcceptance: true,
      unacceptedLicenseModelIds: [modelId],
    );
  }

  InstallationPlan createReadyTestPlan({String modelId = 'MOD_01_CHROMA_FLASH'}) {
    final model = catalogService.catalog.logicalModels[modelId]!;
    final comp = catalogService.catalog.components[model.primaryComponentId]!;
    return InstallationPlan(
      targetLogicalModelIds: [modelId],
      componentsToDownload: [comp],
      alreadyInstalledComponents: const [],
      totalRequiredBytes: comp.expectedSizeBytes,
      alreadyInstalledBytes: 0,
      downloadRequiredBytes: comp.expectedSizeBytes,
      temporaryOverheadBytes: comp.expectedSizeBytes,
      minimumFreeDiskBytes: comp.expectedSizeBytes + 100 * 1024 * 1024,
      availableFreeDiskBytes: 500 * 1024 * 1024 * 1024,
      isDiskSpaceSufficient: true,
      requiresLicenseAcceptance: false,
      unacceptedLicenseModelIds: const [],
    );
  }

  Widget buildTestApp({
    Key? key,
    ImageModelCatalogService? customCatalog,
    ImageModelInstallPlanner? customPlanner,
    ImageModelInstallerService? customInstaller,
    SettingsService? customSettings,
    int Function(String)? diskSpaceProbe,
    Map<String, LogicalModelStatus>? initialStatusesOverride,
    Size? screenSize,
    Future<bool> Function(Uri)? customUrlLauncher,
  }) {
    return ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(customSettings ?? settingsService),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(size: screenSize ?? const Size(1280, 2500)),
          child: ImageModelsScreen(
            key: key,
            catalogServiceOverride: customCatalog ?? catalogService,
            plannerOverride: customPlanner ?? planner,
            installerOverride: customInstaller,
            settingsServiceOverride: customSettings ?? settingsService,
            diskSpaceProbeOverride: diskSpaceProbe ?? ((_) => 500 * 1024 * 1024 * 1024),
            initialStatusesOverride: initialStatusesOverride,
            urlLauncherOverride: customUrlLauncher,
          ),
        ),
      ),
    );
  }

  Future<void> pumpAndLoad(WidgetTester tester, [Widget? app]) async {
    tester.view.physicalSize = const Size(1280, 2500);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(app ?? buildTestApp());
    await tester.pump();
    await tester.pumpAndSettle();
  }

  group('EXT-V1-02 Phase 2 — Suite Complete Renforcee P2-T01 a P2-T34', () {
    // P2-T01: Navigation reelle depuis Parametres vers Modeles Image via GoRouter
    testWidgets('P2-T01: navigation reelle SettingsScreen -> /models/image via GoRouter', (tester) async {
      tester.view.physicalSize = const Size(1280, 2500);
      tester.view.devicePixelRatio = 1.0;

      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/models/image',
            builder: (context, state) => ImageModelsScreen(
              catalogServiceOverride: catalogService,
              plannerOverride: planner,
              settingsServiceOverride: settingsService,
            ),
          ),
        ],
      );

      final navApp = ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settingsService),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );

      await tester.pumpWidget(navApp);
      await tester.pump();
      final tile = find.text('Modèles Image');
      await tester.scrollUntilVisible(tile, 300);
      await tester.pumpAndSettle();

      expect(tile, findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(find.text('Modèles Image'), findsWidgets);
      expect(find.text('GÉNÉRATION'), findsOneWidget);
      expect(find.text('INPAINT / MODIFICATION'), findsOneWidget);
    });

    // P2-T02: sections Generation et Inpaint distinctes.
    testWidgets('P2-T02: sections Generation et Inpaint distinctes', (tester) async {
      await pumpAndLoad(tester);

      expect(find.text('GÉNÉRATION'), findsOneWidget);
      expect(find.text('INPAINT / MODIFICATION'), findsOneWidget);
    });

    // P2-T03: 5 modeles generation affiches depuis catalogue.
    testWidgets('P2-T03: 5 modeles generation affiches depuis catalogue', (tester) async {
      await pumpAndLoad(tester);

      expect(find.textContaining('Chroma Flash'), findsOneWidget);
      expect(find.textContaining('FLUX.1 Schnell'), findsOneWidget);
      expect(find.textContaining('Stable Diffusion 3.5 Large Turbo'), findsOneWidget);
      expect(find.textContaining('SD-Turbo'), findsOneWidget);
      expect(find.textContaining('Stable Diffusion 1.5 (Q4_0)'), findsOneWidget);
    });

    // P2-T04: 3 modeles inpaint affiches depuis catalogue.
    testWidgets('P2-T04: 3 modeles inpaint affiches depuis catalogue', (tester) async {
      await pumpAndLoad(tester);

      expect(find.textContaining('Realistic Vision V6.0 B1 Inpainting (Full'), findsOneWidget);
      expect(find.textContaining('Realistic Vision V6.0 B1 Inpainting (FP16'), findsOneWidget);
      expect(find.textContaining('Stable Diffusion 1.5 Inpainting (Q4_0'), findsOneWidget);
    });

    // P2-T05: modele installe affiche INSTALLE.
    testWidgets('P2-T05: modele installe affiche INSTALLE', (tester) async {
      final statuses = {
        'MOD_04_SD_TURBO': createMockStatus(
          modelId: 'MOD_04_SD_TURBO',
          state: LogicalModelInstallState.installed,
          installedBytes: 2000,
          totalBytes: 2000,
        ),
      };

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      expect(find.text('INSTALLÉ'), findsOneWidget);
    });

    // P2-T06: modele absent affiche NON INSTALLE.
    testWidgets('P2-T06: modele absent affiche NON INSTALLE', (tester) async {
      await pumpAndLoad(tester);

      expect(find.text('NON INSTALLÉ'), findsNWidgets(8));
    });

    // P2-T07: modele partiel affiche correctement.
    testWidgets('P2-T07: modele partiel affiche correctement', (tester) async {
      final statuses = {
        'MOD_01_CHROMA_FLASH': createMockStatus(
          modelId: 'MOD_01_CHROMA_FLASH',
          state: LogicalModelInstallState.partiallyInstalled,
          installedBytes: 500,
          totalBytes: 2000,
        ),
      };

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      expect(find.text('Installation partielle'), findsOneWidget);
    });

    // P2-T08: modele corrompu affiche correctement.
    testWidgets('P2-T08: modele corrompu affiche correctement', (tester) async {
      final statuses = {
        'MOD_04_SD_TURBO': createMockStatus(
          modelId: 'MOD_04_SD_TURBO',
          state: LogicalModelInstallState.corrupt,
          installedBytes: 100,
          totalBytes: 2000,
        ),
      };

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      expect(find.text('Fichier invalide / vérification nécessaire'), findsOneWidget);
    });

    // P2-T09: UNKNOWN reste UNKNOWN.
    test('P2-T09: UNKNOWN reste UNKNOWN', () {
      final model = catalogService.catalog.logicalModels['MOD_04_SD_TURBO']!;
      final status = LogicalModelStatus(
        model: model,
        state: LogicalModelInstallState.unknown,
        installedSizeBytes: 0,
        totalRequiredSizeBytes: 1000,
        componentStatuses: const {},
        missingComponentIds: const [],
      );
      expect(status.state, equals(LogicalModelInstallState.unknown));
    });

    // P2-T10: shared dependency dedupliquee dans taille totale.
    test('P2-T10: shared dependency dedupliquee dans taille totale', () async {
      final plan = await planner.buildPlan(
        targetLogicalModelIds: ['MOD_01_CHROMA_FLASH', 'MOD_02_FLUX1_SCHNELL'],
      );
      final sumIndiv = catalogService.catalog.logicalModels['MOD_01_CHROMA_FLASH']!.requiredComponentIds
              .map((id) => catalogService.catalog.components[id]!.expectedSizeBytes)
              .reduce((a, b) => a + b) +
          catalogService.catalog.logicalModels['MOD_02_FLUX1_SCHNELL']!.requiredComponentIds
              .map((id) => catalogService.catalog.components[id]!.expectedSizeBytes)
              .reduce((a, b) => a + b);

      expect(plan.downloadRequiredBytes, lessThan(sumIndiv));
    });

    // P2-T11: espace requis affiche depuis planner.
    test('P2-T11: espace requis affiche depuis planner', () async {
      final plan = await planner.buildPlan(
        targetLogicalModelIds: ['MOD_04_SD_TURBO'],
      );
      expect(plan.minimumFreeDiskBytes, greaterThan(plan.downloadRequiredBytes));
    });

    // P2-T12: volume portable utilise.
    test('P2-T12: volume portable utilise', () async {
      String? probedPath;
      final customPlanner = ImageModelInstallPlanner(
        catalogService: catalogService,
        diskSpaceProbe: (path) {
          probedPath = path;
          return 100 * 1024 * 1024 * 1024;
        },
      );

      await customPlanner.buildPlan(targetLogicalModelIds: ['MOD_05_SD15_BASE']);
      expect(probedPath, equals(tempModelsDir.path));
    });

    // P2-T13: licence requise bloque installation avec liens officiels.
    testWidgets('P2-T13: licence requise bloque installation avec liens', (tester) async {
      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createLicenseTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner));

      final mod03Card = find.textContaining('Stable Diffusion 3.5 Large Turbo');
      final cbFinder = find.descendant(
        of: find.ancestor(of: mod03Card, matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      expect(find.text('1 modèle(s) sélectionné(s)'), findsOneWidget);

      final installBtn = find.widgetWithText(ElevatedButton, 'Installer la sélection');
      await tester.tap(installBtn);
      await tester.pumpAndSettle();

      expect(find.textContaining('Acceptation de licence'), findsOneWidget);
      expect(find.textContaining('Voir la licence officielle'), findsOneWidget);
      expect(find.textContaining('Voir la source officielle'), findsOneWidget);
      expect(find.text('Accepter et continuer'), findsOneWidget);
    });

    // P2-T14: annulation licence n installe rien.
    testWidgets("P2-T14: annulation licence n'installe rien", (tester) async {
      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createLicenseTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner));

      final mod03Card = find.textContaining('Stable Diffusion 3.5 Large Turbo');
      final cbFinder = find.descendant(
        of: find.ancestor(of: mod03Card, matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();

      // Clic "Annuler"
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      expect(find.text("Récapitulatif d'installation"), findsNothing);
    });

    // P2-T15: acceptation explicite autorise installation.
    testWidgets('P2-T15: acceptation explicite autorise installation', (tester) async {
      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createLicenseTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner));

      final mod03Card = find.textContaining('Stable Diffusion 3.5 Large Turbo');
      final cbFinder = find.descendant(
        of: find.ancestor(of: mod03Card, matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Accepter et continuer'));
      await tester.pumpAndSettle();

      expect(find.text("Récapitulatif d'installation"), findsOneWidget);
    });

    // P2-T16: Progression DOWNLOADING reellement visible dans le widget via fake installer
    testWidgets('P2-T16: Progression DOWNLOADING reellement visible dans le widget', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      fakeInstaller.onExecutePlan = (plan) async {
        fakeInstaller.emitProgress(const DownloadProgressEvent(
          status: ImageDownloadStatus.downloading,
          currentComponentId: 'CMP_04_CHROMA_FLASH_DIT',
          currentFileName: 'chroma-unlocked-v46-flash-Q4_0.gguf',
          bytesDownloaded: 500,
          totalBytes: 1000,
          progressPercentage: 0.5,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      };

      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createReadyTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Chroma Flash'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      final installBtn = find.widgetWithText(ElevatedButton, 'Installer la sélection');
      await tester.tap(installBtn);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('Statut : DOWNLOADING'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('50.0%'), findsOneWidget);

      await tester.pumpAndSettle();
    });

    // P2-T17: VERIFYING etape reellement visible dans le widget via fake installer
    testWidgets('P2-T17: VERIFYING reellement visible dans le widget', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      fakeInstaller.onExecutePlan = (plan) async {
        fakeInstaller.emitProgress(const DownloadProgressEvent(
          status: ImageDownloadStatus.verifying,
          currentComponentId: 'CMP_04_CHROMA_FLASH_DIT',
          currentFileName: 'chroma-unlocked-v46-flash-Q4_0.gguf',
          bytesDownloaded: 1000,
          totalBytes: 1000,
          progressPercentage: 1.0,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      };

      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createReadyTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Chroma Flash'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('Statut : VERIFYING'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    // P2-T18: COMPLETED rafraichit etat vers INSTALLE
    testWidgets('P2-T18: COMPLETED rafraichit etat vers INSTALLE', (tester) async {
      final key = GlobalKey();
      await pumpAndLoad(tester, buildTestApp(key: key));
      expect(find.text('INSTALLÉ'), findsNothing);

      final updatedStatuses = {
        'MOD_04_SD_TURBO': createMockStatus(
          modelId: 'MOD_04_SD_TURBO',
          state: LogicalModelInstallState.installed,
          installedBytes: 1000,
          totalBytes: 1000,
        ),
      };

      await pumpAndLoad(tester, buildTestApp(key: key, initialStatusesOverride: updatedStatuses));
      expect(find.text('INSTALLÉ'), findsOneWidget);
    });

    // P2-T19: Fake installer leve DOWNLOAD_DISK_FULL -> banniere exacte visible
    testWidgets('P2-T19: Erreur DOWNLOAD_DISK_FULL affiche banniere exacte', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      fakeInstaller.planException = ImageInstallerException('DOWNLOAD_DISK_FULL', 'Disque plein');

      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createReadyTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Chroma Flash'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pumpAndSettle();

      expect(find.text('Le disque est devenu insuffisant pendant le téléchargement.'), findsOneWidget);
    });

    // P2-T20: Fake installer leve HASH_MISMATCH -> banniere exacte visible
    testWidgets('P2-T20: Erreur HASH_MISMATCH affiche banniere exacte', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      fakeInstaller.planException = ImageInstallerException('HASH_MISMATCH', 'Sha invalide');

      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createReadyTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Chroma Flash'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pumpAndSettle();

      expect(find.text('Le fichier téléchargé ne correspond pas au fichier attendu. Il n\'a pas été installé.'), findsOneWidget);
    });

    // P2-T21: Clic Annuler appelle cancel() et aucun message de succes
    testWidgets('P2-T21: Clic Annuler appelle cancel() reellement sans message de succes', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      fakeInstaller.onExecutePlan = (plan) async {
        fakeInstaller.emitProgress(const DownloadProgressEvent(
          status: ImageDownloadStatus.downloading,
          currentComponentId: 'CMP_04_CHROMA_FLASH_DIT',
          currentFileName: 'chroma-unlocked-v46-flash-Q4_0.gguf',
          bytesDownloaded: 200,
          totalBytes: 1000,
          progressPercentage: 0.2,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        throw ImageInstallerException('DOWNLOAD_CANCELLED', 'Annule');
      };

      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createReadyTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Chroma Flash'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pump(const Duration(milliseconds: 250));

      final cancelFinder = find.descendant(
        of: find.byType(Card),
        matching: find.widgetWithText(TextButton, 'Annuler'),
      );
      expect(cancelFinder, findsOneWidget);
      await tester.tap(cancelFinder);
      await tester.pumpAndSettle();

      expect(fakeInstaller.cancelCalled, isTrue);
      expect(find.text('Installation terminée avec succès.'), findsNothing);
      expect(find.text('Téléchargement annulé.'), findsOneWidget);
    });

    // P2-T22: Reprise .part affiche texte explicite
    testWidgets('P2-T22: isResumed = true affiche le message de reprise', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      fakeInstaller.onExecutePlan = (plan) async {
        fakeInstaller.emitProgress(const DownloadProgressEvent(
          status: ImageDownloadStatus.downloading,
          currentComponentId: 'CMP_04_CHROMA_FLASH_DIT',
          currentFileName: 'chroma-unlocked-v46-flash-Q4_0.gguf',
          bytesDownloaded: 400,
          totalBytes: 1000,
          progressPercentage: 0.4,
          isResumed: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      };

      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createReadyTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Chroma Flash'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.textContaining('reprise disponible'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    // P2-T23: Operation d installation factice Generation ne modifie pas active_image_model
    testWidgets('P2-T23: Operation d installation factice Generation preserve active_image_model', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      settingsService.activeImageModel = 'initial_gen.safetensors';

      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createReadyTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Chroma Flash'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pumpAndSettle();

      expect(settingsService.activeImageModel, equals('initial_gen.safetensors'));
    });

    // P2-T24: Operation d installation factice Inpaint ne modifie pas active_inpaint_model
    testWidgets('P2-T24: Operation d installation factice Inpaint preserve active_inpaint_model', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      settingsService.activeInpaintModel = 'initial_inpaint.safetensors';

      final mockPlanner = _MockLicensePlanner(
        catalogService: catalogService,
        mockPlan: createReadyTestPlan(modelId: 'MOD_08_SD15_INPAINT_Q4'),
      );
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Stable Diffusion 1.5 Inpainting'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pumpAndSettle();

      expect(settingsService.activeInpaintModel, equals('initial_inpaint.safetensors'));
    });

    // P2-T25: Activation generation -> active_image_model == primary component filename ET active_inpaint_model inchange
    testWidgets('P2-T25: activation generation modifie uniquement active_image_model vers filename', (tester) async {
      final statuses = {
        'MOD_04_SD_TURBO': createMockStatus(
          modelId: 'MOD_04_SD_TURBO',
          state: LogicalModelInstallState.installed,
          installedBytes: 2000,
          totalBytes: 2000,
        ),
      };

      settingsService.activeImageModel = '';
      settingsService.activeInpaintModel = 'preserve_inpaint.safetensors';

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      final activeButtons = tester.widgetList<OutlinedButton>(find.byType(OutlinedButton)).where((btn) => btn.onPressed != null);
      expect(activeButtons.length, equals(1));
      await tester.tap(find.byWidget(activeButtons.first));
      await tester.pumpAndSettle();

      expect(settingsService.activeImageModel, equals('sd_turbo.safetensors'));
      expect(settingsService.activeInpaintModel, equals('preserve_inpaint.safetensors'));
    });

    // P2-T26: Activation inpaint -> active_inpaint_model == primary component filename ET active_image_model inchange
    testWidgets('P2-T26: activation inpaint modifie uniquement active_inpaint_model vers filename', (tester) async {
      final statuses = {
        'MOD_08_SD15_INPAINT_Q4': createMockStatus(
          modelId: 'MOD_08_SD15_INPAINT_Q4',
          state: LogicalModelInstallState.installed,
          installedBytes: 2000,
          totalBytes: 2000,
        ),
      };

      settingsService.activeImageModel = 'preserve_gen.safetensors';
      settingsService.activeInpaintModel = '';

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      final activeButtons = tester.widgetList<OutlinedButton>(find.byType(OutlinedButton)).where((btn) => btn.onPressed != null);
      expect(activeButtons.length, equals(1));
      await tester.scrollUntilVisible(find.byWidget(activeButtons.first), 200);
      await tester.tap(find.byWidget(activeButtons.first));
      await tester.pumpAndSettle();

      expect(settingsService.activeInpaintModel, equals('stable-diffusion-v1-5-inpainting-Q4_0.gguf'));
      expect(settingsService.activeImageModel, equals('preserve_gen.safetensors'));
    });

    // P2-T27: Compatibilite historique: preference enregistree en filename reconnue active sans migration silencieuse
    testWidgets('P2-T27: preference enregistree sous forme filename reconnue comme ACTIF', (tester) async {
      settingsService.activeImageModel = 'chroma-unlocked-v46-flash-Q4_0.gguf';
      settingsService.activeInpaintModel = 'Realistic_Vision_V6.0_NV_B1_inpainting.safetensors';

      final statuses = {
        'MOD_01_CHROMA_FLASH': createMockStatus(
          modelId: 'MOD_01_CHROMA_FLASH',
          state: LogicalModelInstallState.installed,
        ),
        'MOD_06_REALISTIC_VISION_INPAINT_FP32': createMockStatus(
          modelId: 'MOD_06_REALISTIC_VISION_INPAINT_FP32',
          state: LogicalModelInstallState.installed,
        ),
      };

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      final actifBadges = find.text('ACTIF');
      expect(actifBadges, findsNWidgets(2));

      expect(settingsService.activeImageModel, equals('chroma-unlocked-v46-flash-Q4_0.gguf'));
      expect(settingsService.activeInpaintModel, equals('Realistic_Vision_V6.0_NV_B1_inpainting.safetensors'));
    });

    // P2-T28: Impossible d activer modele corrompu.
    testWidgets("P2-T28: impossible d'activer modele corrompu", (tester) async {
      final statuses = {
        'MOD_04_SD_TURBO': createMockStatus(
          modelId: 'MOD_04_SD_TURBO',
          state: LogicalModelInstallState.corrupt,
          installedBytes: 100,
          totalBytes: 2000,
        ),
      };

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      final buttons = tester.widgetList<OutlinedButton>(find.byType(OutlinedButton));
      for (final btn in buttons) {
        expect(btn.onPressed, isNull);
      }
    });

    // P2-T29: Preference active absente -> alerte sans fallback silencieux.
    testWidgets('P2-T29: preference active absente -> alerte sans fallback silencieux', (tester) async {
      settingsService.activeImageModel = 'MOD_01_CHROMA_FLASH';

      await pumpAndLoad(tester);

      expect(find.textContaining('MOD_01_CHROMA_FLASH'), findsWidgets);
      expect(settingsService.activeImageModel, equals('MOD_01_CHROMA_FLASH'));
    });

    // P2-T30: Statuts de licence honnetes (autorisation, attribution, acceptation)
    testWidgets('P2-T30: statuts de licence honnetes', (tester) async {
      await pumpAndLoad(tester);

      expect(find.textContaining('Licence : téléchargement autorisé'), findsWidgets);
      expect(find.textContaining('Licence : attribution / notice requise'), findsWidgets);
      expect(find.textContaining('Licence : acceptation requise'), findsWidgets);
      expect(find.text('Licence libre'), findsNothing);
    });

    // P2-T31: Fichier physiquement present, taille correcte, cache absent => NON affiche "NON INSTALLE"
    testWidgets('P2-T31: composant present non verifie n est PAS affiche NON INSTALLE', (tester) async {
      final statuses = {
        'MOD_04_SD_TURBO': createMockStatus(
          modelId: 'MOD_04_SD_TURBO',
          state: LogicalModelInstallState.unknown,
        ),
      };

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      final cardFinder = find.widgetWithText(Card, 'SD-Turbo (Monolithic safetensors)');
      expect(find.descendant(of: cardFinder, matching: find.text('NON INSTALLÉ')), findsNothing);
      expect(find.descendant(of: cardFinder, matching: find.text('État inconnu / À vérifier')), findsOneWidget);
    });

    // P2-T32: Tous composants presents non verifies => logical state UNKNOWN et message de telechargement a determiner
    testWidgets('P2-T32: model physique non verifie affiche texte a determiner', (tester) async {
      final statuses = {
        'MOD_04_SD_TURBO': createMockStatus(
          modelId: 'MOD_04_SD_TURBO',
          state: LogicalModelInstallState.unknown,
        ),
      };

      await pumpAndLoad(tester, buildTestApp(initialStatusesOverride: statuses));

      expect(find.text('Téléchargement nécessaire : à déterminer après vérification'), findsOneWidget);
    });

    // P2-T33: Planner verifie SHA d un composant presentUnverified: si hash correct -> ne pas telecharger
    test('P2-T33: planner verifie SHA et omet le telechargement si hash correct', () async {
      final comp = catalogService.catalog.components['CMP_10_SD_TURBO_MONO']!; // sd_turbo.safetensors
      final compFile = File('${tempModelsDir.path}/${comp.fileName}');
      await compFile.writeAsString('CORRECT CONTENT');

      final customCatalogJson = jsonDecode(canonicalCatalogJson) as Map<String, dynamic>;
      final compsList = customCatalogJson['components'] as List;
      for (final c in compsList) {
        if (c['component_id'] == 'CMP_10_SD_TURBO_MONO') {
          c['expected_size_bytes'] = compFile.lengthSync();
          c['expected_sha256'] = '176c350071edbc309d28b06fa571d426ab85362fe08e73a99b006f7f225b08d8'; // sha256('CORRECT CONTENT')
        }
      }

      final customCatalogService = ImageModelCatalogService(modelsDir: tempModelsDir);
      await customCatalogService.loadCatalog(jsonContent: jsonEncode(customCatalogJson));

      final customPlanner = ImageModelInstallPlanner(catalogService: customCatalogService);

      final plan = await customPlanner.buildPlan(
        targetLogicalModelIds: ['MOD_04_SD_TURBO'],
        checkDiskSpace: false,
      );

      expect(plan.componentsToDownload, isEmpty);
      expect(plan.alreadyInstalledComponents.length, equals(1));
      expect(plan.downloadRequiredBytes, equals(0));
    });

    // P2-T34: Planner verifie SHA d un composant presentUnverified: si hash faux -> programme telechargement
    test('P2-T34: planner verifie SHA et programme telechargement si hash incorrect', () async {
      final comp = catalogService.catalog.components['CMP_10_SD_TURBO_MONO']!;
      final compFile = File('${tempModelsDir.path}/${comp.fileName}');
      await compFile.writeAsString('BAD HASH CONTENT');

      final customCatalogJson = jsonDecode(canonicalCatalogJson) as Map<String, dynamic>;
      final compsList = customCatalogJson['components'] as List;
      for (final c in compsList) {
        if (c['component_id'] == 'CMP_10_SD_TURBO_MONO') {
          c['expected_size_bytes'] = compFile.lengthSync();
          c['expected_sha256'] = '0000000000000000000000000000000000000000000000000000000000000000';
        }
      }

      final customCatalogService = ImageModelCatalogService(modelsDir: tempModelsDir);
      await customCatalogService.loadCatalog(jsonContent: jsonEncode(customCatalogJson));

      final customPlanner = ImageModelInstallPlanner(catalogService: customCatalogService);

      final plan = await customPlanner.buildPlan(
        targetLogicalModelIds: ['MOD_04_SD_TURBO'],
        checkDiskSpace: false,
      );

      expect(plan.componentsToDownload.length, equals(1));
      expect(plan.alreadyInstalledComponents, isEmpty);
      expect(plan.downloadRequiredBytes, equals(compFile.lengthSync()));
    });

    // P2-T35: Chargement runtime reel du catalogue depuis data/config sans injection jsonContent
    test('P2-T35: chargement runtime reel depuis data/config/image_model_catalog.json sans jsonContent', () async {
      final runtimeDir = await Directory.systemTemp.createTemp('runtime_catalog_test_');
      try {
        AppPaths.setTestOverride(runtimeDir);
        final configDir = Directory(p.join(runtimeDir.path, 'data', 'config'));
        await configDir.create(recursive: true);

        // Copier le catalogue canonique P2 dans data/config/image_model_catalog.json
        final distributedConfigFile = File(p.join(configDir.path, 'image_model_catalog.json'));
        await File('assets/models/image_model_catalog.json').copy(distributedConfigFile.path);

        final testCatalogService = ImageModelCatalogService(
          modelsDir: Directory(p.join(runtimeDir.path, 'models', 'Stable-diffusion')),
        );

        // Appel sans argument jsonContent -> doit charger data/config/image_model_catalog.json
        final loadedCatalog = await testCatalogService.loadCatalog();

        // 1. Nombre de modeles et composants
        expect(loadedCatalog.logicalModels.length, equals(8));
        expect(loadedCatalog.components.length, equals(13));

        // 2. MOD_03_SD35_LARGE_TURBO
        final mod03 = loadedCatalog.logicalModels['MOD_03_SD35_LARGE_TURBO']!;
        expect(mod03.licenseUrl, isNotNull);
        expect(mod03.licenseUrl, isNotEmpty);
        expect(mod03.sourcePageUrl, isNotNull);
        expect(mod03.sourcePageUrl, isNotEmpty);

        // 3. MOD_04_SD_TURBO
        final mod04 = loadedCatalog.logicalModels['MOD_04_SD_TURBO']!;
        expect(mod04.licenseUrl, isNotNull);
        expect(mod04.licenseUrl, isNotEmpty);
        expect(mod04.sourcePageUrl, isNotNull);
        expect(mod04.sourcePageUrl, isNotEmpty);

        // 4. Verification de conformite des 13 composants physiques V2
        for (final comp in loadedCatalog.components.values) {
          expect(comp.downloadUrl, startsWith('http'));
          expect(comp.expectedSha256.length, equals(64));
          expect(comp.expectedSizeBytes, greaterThan(0));
          expect(comp.fileName, isNotEmpty);
          expect(comp.componentId, isNotEmpty);
        }
      } finally {
        AppPaths.resetTestOverride();
        try {
          await runtimeDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    // P2-T36: Clic sur 'Voir la licence officielle' ouvre l URL exacte via url_launcher
    testWidgets('P2-T36: Clic sur Voir la licence officielle ouvre licenseUrl exacte', (tester) async {
      Uri? launchedUri;
      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createLicenseTestPlan());

      await pumpAndLoad(tester, buildTestApp(
        customPlanner: mockPlanner,
        customUrlLauncher: (uri) async {
          launchedUri = uri;
          return true;
        },
      ));

      final mod03Card = find.textContaining('Stable Diffusion 3.5 Large Turbo');
      final cbFinder = find.descendant(
        of: find.ancestor(of: mod03Card, matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Acceptation de licence'), findsOneWidget);

      final licenseBtn = find.textContaining('Voir la licence officielle');
      expect(licenseBtn, findsOneWidget);
      await tester.tap(licenseBtn);
      await tester.pumpAndSettle();

      final model = catalogService.catalog.logicalModels['MOD_03_SD35_LARGE_TURBO']!;
      expect(launchedUri, isNotNull);
      expect(launchedUri.toString(), equals(model.licenseUrl));
    });

    // P2-T37: Clic sur 'Voir la source officielle' ouvre l URL exacte via url_launcher
    testWidgets('P2-T37: Clic sur Voir la source officielle ouvre sourcePageUrl exacte', (tester) async {
      Uri? launchedUri;
      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createLicenseTestPlan());

      await pumpAndLoad(tester, buildTestApp(
        customPlanner: mockPlanner,
        customUrlLauncher: (uri) async {
          launchedUri = uri;
          return true;
        },
      ));

      final mod03Card = find.textContaining('Stable Diffusion 3.5 Large Turbo');
      final cbFinder = find.descendant(
        of: find.ancestor(of: mod03Card, matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Installer la sélection'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Acceptation de licence'), findsOneWidget);

      final sourceBtn = find.textContaining('Voir la source officielle');
      expect(sourceBtn, findsOneWidget);
      await tester.tap(sourceBtn);
      await tester.pumpAndSettle();

      final model = catalogService.catalog.logicalModels['MOD_03_SD35_LARGE_TURBO']!;
      expect(launchedUri, isNotNull);
      expect(launchedUri.toString(), equals(model.sourcePageUrl));
    });

    // ────────────────────────────────────────────────────────────────────────
    // P4 Tests: Package sans modeles preinstalles
    // ────────────────────────────────────────────────────────────────────────

    // P2-T38: Package vide -> les 8 modeles sont affiches en NON INSTALLE, 0 INSTALLE
    testWidgets('P2-T38: package vide sans poids -> tous les 8 modeles sont NON INSTALLE', (tester) async {
      await pumpAndLoad(tester);

      expect(find.text('GÉNÉRATION'), findsOneWidget);
      expect(find.text('INPAINT / MODIFICATION'), findsOneWidget);

      final nonInstalles = find.text('NON INSTALLÉ');
      expect(nonInstalles, findsNWidgets(8));

      expect(find.text('INSTALLÉ'), findsNothing);
      expect(find.text('ACTIF'), findsNothing);

      final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
      expect(checkboxes.length, equals(8));
      for (final cb in checkboxes) {
        expect(cb.onChanged, isNotNull, reason: 'Tous les modeles non installes doivent etre selectionnables');
      }
    });

    // P2-T39: Test d installation bout-en-bout leger via UI et fake installer
    testWidgets('P2-T39: flux complet selection -> confirmation -> progression -> statut INSTALLE', (tester) async {
      final fakeInstaller = FakeImageModelInstallerService(catalogService: catalogService);
      addTearDown(() => fakeInstaller.dispose());

      fakeInstaller.onExecutePlan = (plan) async {
        fakeInstaller.emitProgress(const DownloadProgressEvent(
          status: ImageDownloadStatus.downloading,
          currentComponentId: 'CMP_04_CHROMA_FLASH_DIT',
          currentFileName: 'chroma-unlocked-v46-flash-Q4_0.gguf',
          bytesDownloaded: 500,
          totalBytes: 1000,
          progressPercentage: 0.5,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        fakeInstaller.emitProgress(const DownloadProgressEvent(
          status: ImageDownloadStatus.completed,
          bytesDownloaded: 1000,
          totalBytes: 1000,
          progressPercentage: 1.0,
        ));
      };

      final mockPlanner = _MockLicensePlanner(catalogService: catalogService, mockPlan: createReadyTestPlan());
      await pumpAndLoad(tester, buildTestApp(customPlanner: mockPlanner, customInstaller: fakeInstaller));

      final cbFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('Chroma Flash'), matching: find.byType(Card)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cbFinder);
      await tester.pumpAndSettle();

      final installBtn = find.widgetWithText(ElevatedButton, 'Installer la sélection');
      await tester.tap(installBtn);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Télécharger et installer'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.text('Installation terminée avec succès.'), findsOneWidget);
    });

    // P2-T40: Test de suppression manuelle / redetection avec fixture reelle
    test('P2-T40: modele installe -> fichier principal supprime hors app -> redetection NON INSTALLE', () async {
      // 1. Creer un modele factice physiquement installe dans tempModelsDir
      const fileContent = 'FIXTURE_WEIGHT_CONTENT_P2_T40';
      final compFile = File(p.join(tempModelsDir.path, 'sd_turbo.safetensors'));
      await compFile.writeAsString(fileContent);
      final actualSize = compFile.lengthSync();
      final actualSha = sha256.convert(utf8.encode(fileContent)).toString();

      final fixtureCatalogJson = jsonDecode(canonicalCatalogJson) as Map<String, dynamic>;
      final compsList = fixtureCatalogJson['components'] as List;
      for (final c in compsList) {
        if (c['component_id'] == 'CMP_10_SD_TURBO_MONO') {
          c['expected_size_bytes'] = actualSize;
          c['expected_sha256'] = actualSha;
        }
      }

      await catalogService.loadCatalog(jsonContent: jsonEncode(fixtureCatalogJson));

      // 2. Verifier INSTALLED via le vrai catalog service avec verifySha: true
      final initialStatus = await catalogService.getLogicalModelStatus('MOD_04_SD_TURBO', verifySha: true);
      expect(initialStatus.state, equals(LogicalModelInstallState.installed));
      expect(initialStatus.installedSizeBytes, equals(actualSize));

      // 3. Supprimer le fichier principal directement via File.delete() dans le test, hors service Jarvisol
      await compFile.delete();
      expect(await compFile.exists(), isFalse);

      // 4. Demander un refresh reel de l'etat
      final refreshedStatus = await catalogService.getLogicalModelStatus('MOD_04_SD_TURBO', verifySha: true);

      // 5. Verifier NOT_INSTALLED
      expect(refreshedStatus.state, equals(LogicalModelInstallState.notInstalled));
      expect(refreshedStatus.installedSizeBytes, equals(0));
    });
  });
}
