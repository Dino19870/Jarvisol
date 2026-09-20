// lib/services/image_model_install_planner.dart
//
// Planificateur d'installation pour les modeles d'image Jarvisol (EXT-V1-02 Phase 1).
// Calcule les dependances partagees, deduplique les composants et verifie
// les pre-requis de licence et d'espace disque portable.

import '../models/image_model_catalog.dart';
import 'disk_space.dart';
import 'image_model_catalog_service.dart';

class ImageModelInstallPlanner {
  final ImageModelCatalogService catalogService;
  final int Function(String path)? diskSpaceProbe;

  ImageModelInstallPlanner({
    required this.catalogService,
    this.diskSpaceProbe,
  });

  /// Construit un plan d'installation deduplique pour une liste de modeles logiques
  Future<InstallationPlan> buildPlan({
    required List<String> targetLogicalModelIds,
    bool checkDiskSpace = true,
    int? diskSpaceOverride,
  }) async {
    if (targetLogicalModelIds.isEmpty) {
      return const InstallationPlan(
        targetLogicalModelIds: [],
        componentsToDownload: [],
        alreadyInstalledComponents: [],
        totalRequiredBytes: 0,
        alreadyInstalledBytes: 0,
        downloadRequiredBytes: 0,
        temporaryOverheadBytes: 0,
        minimumFreeDiskBytes: 0,
        availableFreeDiskBytes: 0,
        isDiskSpaceSufficient: true,
        requiresLicenseAcceptance: false,
        unacceptedLicenseModelIds: [],
      );
    }

    final catalog = catalogService.catalog;
    final allNeededComponents = <String, PhysicalComponent>{};
    final unacceptedLicenseModels = <String>[];

    for (final modelId in targetLogicalModelIds) {
      final model = catalog.logicalModels[modelId];
      if (model == null) {
        throw InvalidCatalogException(
          'INVALID_CATALOG_ENTRY',
          'Modele logique introuvable dans le catalogue: $modelId',
        );
      }

      if (model.requiresUserAcceptance) {
        unacceptedLicenseModels.add(modelId);
      }

      for (final compId in model.requiredComponentIds) {
        final comp = catalog.components[compId];
        if (comp == null) {
          throw InvalidCatalogException(
            'INVALID_CATALOG_ENTRY',
            'Composant requis introuvable dans le catalogue: $compId (modele: $modelId)',
          );
        }
        allNeededComponents[compId] = comp;
      }
    }

    final componentsToDownload = <PhysicalComponent>[];
    final alreadyInstalled = <PhysicalComponent>[];
    var totalRequiredBytes = 0;
    var alreadyInstalledBytes = 0;
    var downloadRequiredBytes = 0;

    for (final comp in allNeededComponents.values) {
      totalRequiredBytes += comp.expectedSizeBytes;
      var status = await catalogService.detectComponentStatus(comp, verifySha: false);

      if (status.state == ComponentVerificationState.presentUnverified) {
        // Effectuer une verification SHA-256 de CE composant selectionne avant de decider
        status = await catalogService.detectComponentStatus(comp, verifySha: true);
      }

      if (status.state == ComponentVerificationState.installedVerified) {
        alreadyInstalled.add(comp);
        alreadyInstalledBytes += comp.expectedSizeBytes;
      } else {
        componentsToDownload.add(comp);
        downloadRequiredBytes += comp.expectedSizeBytes;
      }
    }

    // Calcul de l'overhead temporaire (.part sur le disque pendant le telechargement)
    // En telechargement sequentiel, chaque .part est ecrit puis renomme atomiquement.
    // L'espace temporaire maximum necessaire au cours du processus est la taille du plus gros composant
    // a telecharger, mais pour garantir la securite absolue de bout en bout meme si tous les .part
    // devaient etre crees, l'espace minimum requis prend en compte le total a telecharger + 100 Mo de tampon.
    final largestCompBytes = componentsToDownload.isEmpty
        ? 0
        : componentsToDownload.map((c) => c.expectedSizeBytes).reduce((a, b) => a > b ? a : b);
    final temporaryOverheadBytes = largestCompBytes;

    const safetyMarginBytes = 100 * 1024 * 1024; // 100 Mo de tampon
    final minimumFreeDiskBytes = downloadRequiredBytes + (downloadRequiredBytes > 0 ? safetyMarginBytes : 0);

    // Mesure de l'espace disque libre sur le volume reel portable
    var availableFreeDiskBytes = diskSpaceOverride ?? -1;
    if (availableFreeDiskBytes < 0 && checkDiskSpace) {
      if (diskSpaceProbe != null) {
        availableFreeDiskBytes = diskSpaceProbe!(catalogService.modelsDir.path);
      } else {
        availableFreeDiskBytes = getAvailableDiskSpace(catalogService.modelsDir.path);
      }
    }

    final isDiskSpaceSufficient = (availableFreeDiskBytes < 0) || (availableFreeDiskBytes >= minimumFreeDiskBytes);

    return InstallationPlan(
      targetLogicalModelIds: List.unmodifiable(targetLogicalModelIds),
      componentsToDownload: List.unmodifiable(componentsToDownload),
      alreadyInstalledComponents: List.unmodifiable(alreadyInstalled),
      totalRequiredBytes: totalRequiredBytes,
      alreadyInstalledBytes: alreadyInstalledBytes,
      downloadRequiredBytes: downloadRequiredBytes,
      temporaryOverheadBytes: temporaryOverheadBytes,
      minimumFreeDiskBytes: minimumFreeDiskBytes,
      availableFreeDiskBytes: availableFreeDiskBytes,
      isDiskSpaceSufficient: isDiskSpaceSufficient,
      requiresLicenseAcceptance: unacceptedLicenseModels.isNotEmpty,
      unacceptedLicenseModelIds: List.unmodifiable(unacceptedLicenseModels),
    );
  }
}
