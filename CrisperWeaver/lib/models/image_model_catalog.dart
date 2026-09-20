// lib/models/image_model_catalog.dart
//
// Types et structures de donnees pour le catalogue et l'installateur
// de modeles d'image Jarvisol (EXT-V1-02 Phase 1).

/// Categorie de modele d'image
enum ImageModelCategory {
  generation,
  inpaint;

  static ImageModelCategory fromString(String value) {
    switch (value.trim().toUpperCase()) {
      case 'GENERATION':
      case 'TEXT2IMAGE':
        return ImageModelCategory.generation;
      case 'INPAINT':
      case 'INPAINTING':
        return ImageModelCategory.inpaint;
      default:
        throw InvalidCatalogException(
          'INVALID_CATALOG_ENTRY',
          'Categorie de modele inconnue: $value',
        );
    }
  }

  String toJsonString() {
    switch (this) {
      case ImageModelCategory.generation:
        return 'GENERATION';
      case ImageModelCategory.inpaint:
        return 'INPAINT';
    }
  }
}

/// Etat de verification physique d'un composant
enum ComponentVerificationState {
  absent,
  presentUnverified,
  installedVerified,
  corruptOrMismatch,
}

/// Etat global d'installation d'un modele logique
enum LogicalModelInstallState {
  notInstalled,
  partiallyInstalled,
  installed,
  corrupt,
  unknown,
}

/// Statut d'avancement du cycle de vie du telechargement
enum ImageDownloadStatus {
  queued,
  checking,
  downloading,
  pausedOrResumable,
  verifying,
  installing,
  completed,
  failed,
  cancelled,
}

/// Exception levee en cas d'entree invalide dans le catalogue
class InvalidCatalogException implements Exception {
  final String code;
  final String message;
  final String? details;

  InvalidCatalogException(this.code, this.message, [this.details]);

  @override
  String toString() => 'InvalidCatalogException($code): $message${details != null ? " ($details)" : ""}';
}

/// Exception specifique pour les erreurs d'installation / telechargement
class ImageInstallerException implements Exception {
  final String code;
  final String message;
  final dynamic cause;

  ImageInstallerException(this.code, this.message, [this.cause]);

  @override
  String toString() => 'ImageInstallerException($code): $message${cause != null ? " [$cause]" : ""}';
}

/// Composant physique representant un fichier de modele ou dependance
class PhysicalComponent {
  final String componentId;
  final String fileName;
  final String relativeInstallPath;
  final String downloadUrl;
  final String expectedSha256;
  final int expectedSizeBytes;
  final bool isSharedDependency;
  final bool supportsResume;
  final bool authRequired;
  final String licenseId;

  const PhysicalComponent({
    required this.componentId,
    required this.fileName,
    required this.relativeInstallPath,
    required this.downloadUrl,
    required this.expectedSha256,
    required this.expectedSizeBytes,
    required this.isSharedDependency,
    this.supportsResume = true,
    this.authRequired = false,
    required this.licenseId,
  });

  /// Validation stricte de securite et de conformite du composant
  static void validateComponentData({
    required String componentId,
    required String fileName,
    required String relativeInstallPath,
    required String downloadUrl,
    required String expectedSha256,
    required int expectedSizeBytes,
  }) {
    if (componentId.trim().isEmpty) {
      throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'componentId ne peut pas etre vide');
    }
    if (fileName.trim().isEmpty) {
      throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'fileName ne peut pas etre vide');
    }

    // Protection anti-path-traversal
    _validateNoPathTraversal(fileName, 'fileName');
    _validateNoPathTraversal(relativeInstallPath, 'relativeInstallPath');

    // Validation URL
    if (downloadUrl.trim().isEmpty) {
      throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'downloadUrl ne peut pas etre vide ($componentId)');
    }
    final uri = Uri.tryParse(downloadUrl.trim());
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw InvalidCatalogException(
        'INVALID_CATALOG_ENTRY',
        'downloadUrl doit etre HTTP ou HTTPS: $downloadUrl ($componentId)',
      );
    }

    // Validation SHA-256 (exactement 64 caracteres hexadecimaux)
    final trimmedSha = expectedSha256.trim().toLowerCase();
    if (trimmedSha.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(trimmedSha)) {
      throw InvalidCatalogException(
        'INVALID_CATALOG_ENTRY',
        'expectedSha256 invalide (doit etre 64 hex lowercase): "$expectedSha256" ($componentId)',
      );
    }

    // Validation taille > 0
    if (expectedSizeBytes <= 0) {
      throw InvalidCatalogException(
        'INVALID_CATALOG_ENTRY',
        'expectedSizeBytes doit etre strictement positif: $expectedSizeBytes ($componentId)',
      );
    }
  }

  static void _validateNoPathTraversal(String pathStr, String fieldName) {
    final normalized = pathStr.replaceAll(r'\', '/');
    if (normalized.contains('../') ||
        normalized.contains(r'..\') ||
        normalized.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(pathStr) ||
        pathStr.startsWith(r'\\')) {
      throw InvalidCatalogException(
        'INVALID_CATALOG_ENTRY',
        'Tentative de path traversal detectee dans $fieldName: "$pathStr"',
      );
    }
  }

  factory PhysicalComponent.fromJson(Map<String, dynamic> json) {
    final compId = (json['component_id'] ?? json['componentId'] ?? '') as String;
    final fName = (json['file_name'] ?? json['fileName'] ?? '') as String;
    final relPath = (json['relative_install_path'] ?? json['relativeInstallPath'] ?? fName) as String;
    final url = (json['download_url'] ?? json['downloadUrl'] ?? '') as String;
    final sha = (json['expected_sha256'] ?? json['expectedSha256'] ?? '') as String;
    final size = (json['expected_size_bytes'] ?? json['expectedSizeBytes'] ?? 0) as int;
    final isShared = (json['is_shared_dependency'] ?? json['isSharedDependency'] ?? false) as bool;
    final resume = (json['supports_resume'] ?? json['supportsResume'] ?? true) as bool;
    final auth = (json['auth_required'] ?? json['authRequired'] ?? false) as bool;
    final lic = (json['license_id'] ?? json['licenseId'] ?? '') as String;

    validateComponentData(
      componentId: compId,
      fileName: fName,
      relativeInstallPath: relPath,
      downloadUrl: url,
      expectedSha256: sha,
      expectedSizeBytes: size,
    );

    return PhysicalComponent(
      componentId: compId.trim(),
      fileName: fName.trim(),
      relativeInstallPath: relPath.trim(),
      downloadUrl: url.trim(),
      expectedSha256: sha.trim().toLowerCase(),
      expectedSizeBytes: size,
      isSharedDependency: isShared,
      supportsResume: resume,
      authRequired: auth,
      licenseId: lic.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        'component_id': componentId,
        'file_name': fileName,
        'relative_install_path': relativeInstallPath,
        'download_url': downloadUrl,
        'expected_sha256': expectedSha256,
        'expected_size_bytes': expectedSizeBytes,
        'is_shared_dependency': isSharedDependency,
        'supports_resume': supportsResume,
        'auth_required': authRequired,
        'license_id': licenseId,
      };
}

/// Modele logique (ex: Chroma Flash, FLUX.1 Schnell) compose d'un ou plusieurs composants physiques
class LogicalImageModel {
  final String logicalModelId;
  final String displayName;
  final ImageModelCategory category;
  final String backend;
  final String primaryComponentId;
  final List<String> requiredComponentIds;
  final List<String> optionalComponentIds;
  final List<String> sharedDependencyIds;
  final String licenseId;
  final String licenseStatus;
  final String distributionStrategy;
  final bool requiresUserAcceptance;
  final String installerReadiness;
  final String? licenseUrl;
  final String? sourcePageUrl;

  const LogicalImageModel({
    required this.logicalModelId,
    required this.displayName,
    required this.category,
    required this.backend,
    required this.primaryComponentId,
    required this.requiredComponentIds,
    this.optionalComponentIds = const [],
    this.sharedDependencyIds = const [],
    required this.licenseId,
    required this.licenseStatus,
    required this.distributionStrategy,
    required this.requiresUserAcceptance,
    required this.installerReadiness,
    this.licenseUrl,
    this.sourcePageUrl,
  });

  factory LogicalImageModel.fromJson(Map<String, dynamic> json) {
    final id = (json['logical_model_id'] ?? json['logicalModelId'] ?? '') as String;
    if (id.trim().isEmpty) {
      throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'logicalModelId ne peut pas etre vide');
    }

    final name = (json['display_name'] ?? json['displayName'] ?? id) as String;
    final catStr = (json['category'] ?? '') as String;
    final cat = ImageModelCategory.fromString(catStr);
    final backend = (json['backend'] ?? 'stable_diffusion_cpp') as String;
    final primary = (json['primary_component_id'] ?? json['primaryComponentId'] ?? '') as String;
    if (primary.trim().isEmpty) {
      throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'primaryComponentId requis pour $id');
    }

    final req = ((json['required_component_ids'] ?? json['requiredComponentIds'] ?? <dynamic>[]) as List)
        .map((e) => e.toString().trim())
        .toList();
    if (!req.contains(primary.trim())) {
      req.insert(0, primary.trim());
    }

    final opt = ((json['optional_component_ids'] ?? json['optionalComponentIds'] ?? <dynamic>[]) as List)
        .map((e) => e.toString().trim())
        .toList();

    final shared = ((json['shared_dependency_ids'] ?? json['sharedDependencyIds'] ?? <dynamic>[]) as List)
        .map((e) => e.toString().trim())
        .toList();

    final licId = (json['license_id'] ?? json['licenseId'] ?? '') as String;
    final licStatus = (json['license_status'] ?? json['licenseStatus'] ?? '') as String;
    final distStrat = (json['distribution_strategy'] ?? json['distributionStrategy'] ?? '') as String;
    final reqAccept = (json['requires_user_acceptance'] ?? json['requiresUserAcceptance'] ?? false) as bool;
    final readiness = (json['installer_readiness'] ?? json['installerReadiness'] ?? '') as String;
    final licUrl = (json['license_url'] ?? json['licenseUrl']) as String?;
    final srcUrl = (json['source_page_url'] ?? json['sourcePageUrl']) as String?;

    return LogicalImageModel(
      logicalModelId: id.trim(),
      displayName: name.trim(),
      category: cat,
      backend: backend.trim(),
      primaryComponentId: primary.trim(),
      requiredComponentIds: List.unmodifiable(req),
      optionalComponentIds: List.unmodifiable(opt),
      sharedDependencyIds: List.unmodifiable(shared),
      licenseId: licId.trim(),
      licenseStatus: licStatus.trim(),
      distributionStrategy: distStrat.trim(),
      requiresUserAcceptance: reqAccept,
      installerReadiness: readiness.trim(),
      licenseUrl: licUrl?.trim(),
      sourcePageUrl: srcUrl?.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        'logical_model_id': logicalModelId,
        'display_name': displayName,
        'category': category.toJsonString(),
        'backend': backend,
        'primary_component_id': primaryComponentId,
        'required_component_ids': requiredComponentIds,
        'optional_component_ids': optionalComponentIds,
        'shared_dependency_ids': sharedDependencyIds,
        'license_id': licenseId,
        'license_status': licenseStatus,
        'distribution_strategy': distributionStrategy,
        'requires_user_acceptance': requiresUserAcceptance,
        'installer_readiness': installerReadiness,
        if (licenseUrl != null) 'license_url': licenseUrl,
        if (sourcePageUrl != null) 'source_page_url': sourcePageUrl,
      };
}

/// Catalogue complet contenant la table des composants physiques et celle des modeles logiques
class ImageModelCatalog {
  final String schemaVersion;
  final Map<String, PhysicalComponent> components;
  final Map<String, LogicalImageModel> logicalModels;

  const ImageModelCatalog({
    required this.schemaVersion,
    required this.components,
    required this.logicalModels,
  });

  factory ImageModelCatalog.fromJson(Map<String, dynamic> json) {
    final version = (json['schema_version'] ?? json['schemaVersion'] ?? '1.0.0') as String;
    final rawComps = json['components'] as List<dynamic>? ?? <dynamic>[];
    final rawModels = (json['logical_models'] ?? json['logicalModels']) as List<dynamic>? ?? <dynamic>[];

    final compsMap = <String, PhysicalComponent>{};
    final fNames = <String>{};

    for (final c in rawComps) {
      if (c is! Map<String, dynamic>) {
        throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'Entree de composant non-objet');
      }
      final comp = PhysicalComponent.fromJson(c);
      if (compsMap.containsKey(comp.componentId)) {
        throw InvalidCatalogException(
          'INVALID_CATALOG_ENTRY',
          'componentId duplique: ${comp.componentId}',
        );
      }
      if (fNames.contains(comp.fileName.toLowerCase())) {
        throw InvalidCatalogException(
          'INVALID_CATALOG_ENTRY',
          'fileName duplique dans les composants: ${comp.fileName}',
        );
      }
      compsMap[comp.componentId] = comp;
      fNames.add(comp.fileName.toLowerCase());
    }

    final modelsMap = <String, LogicalImageModel>{};
    for (final m in rawModels) {
      if (m is! Map<String, dynamic>) {
        throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'Entree de modele non-objet');
      }
      final model = LogicalImageModel.fromJson(m);
      if (modelsMap.containsKey(model.logicalModelId)) {
        throw InvalidCatalogException(
          'INVALID_CATALOG_ENTRY',
          'logicalModelId duplique: ${model.logicalModelId}',
        );
      }

      // Verifier que tous les composants requis existent
      if (!compsMap.containsKey(model.primaryComponentId)) {
        throw InvalidCatalogException(
          'INVALID_CATALOG_ENTRY',
          'primaryComponentId "${model.primaryComponentId}" introuvable pour ${model.logicalModelId}',
        );
      }
      for (final reqId in model.requiredComponentIds) {
        if (!compsMap.containsKey(reqId)) {
          throw InvalidCatalogException(
            'INVALID_CATALOG_ENTRY',
            'Composant requis "$reqId" introuvable pour ${model.logicalModelId}',
          );
        }
      }
      for (final sharedId in model.sharedDependencyIds) {
        if (!compsMap.containsKey(sharedId)) {
          throw InvalidCatalogException(
            'INVALID_CATALOG_ENTRY',
            'Dependance partagée "$sharedId" introuvable pour ${model.logicalModelId}',
          );
        }
      }

      modelsMap[model.logicalModelId] = model;
    }

    return ImageModelCatalog(
      schemaVersion: version,
      components: Map.unmodifiable(compsMap),
      logicalModels: Map.unmodifiable(modelsMap),
    );
  }

  PhysicalComponent? findComponentByFileName(String fileName) {
    final lower = fileName.trim().toLowerCase();
    for (final c in components.values) {
      if (c.fileName.toLowerCase() == lower) return c;
    }
    return null;
  }
}

/// Statut de verification physique d'un composant sur disque
class ComponentStatus {
  final PhysicalComponent component;
  final ComponentVerificationState state;
  final int actualSizeBytes;
  final String? actualSha256;
  final String? errorMessage;

  const ComponentStatus({
    required this.component,
    required this.state,
    this.actualSizeBytes = 0,
    this.actualSha256,
    this.errorMessage,
  });

  bool get isVerified => state == ComponentVerificationState.installedVerified;
}

/// Statut global d'un modele logique
class LogicalModelStatus {
  final LogicalImageModel model;
  final LogicalModelInstallState state;
  final Map<String, ComponentStatus> componentStatuses;
  final List<String> missingComponentIds;
  final int totalRequiredSizeBytes;
  final int installedSizeBytes;

  const LogicalModelStatus({
    required this.model,
    required this.state,
    required this.componentStatuses,
    required this.missingComponentIds,
    required this.totalRequiredSizeBytes,
    required this.installedSizeBytes,
  });

  bool get isFullyInstalled => state == LogicalModelInstallState.installed;
}

/// Plan d'installation calcule avant tout telechargement
class InstallationPlan {
  final List<String> targetLogicalModelIds;
  final List<PhysicalComponent> componentsToDownload;
  final List<PhysicalComponent> alreadyInstalledComponents;
  final int totalRequiredBytes;
  final int alreadyInstalledBytes;
  final int downloadRequiredBytes;
  final int temporaryOverheadBytes;
  final int minimumFreeDiskBytes;
  final int availableFreeDiskBytes;
  final bool isDiskSpaceSufficient;
  final bool requiresLicenseAcceptance;
  final List<String> unacceptedLicenseModelIds;

  const InstallationPlan({
    required this.targetLogicalModelIds,
    required this.componentsToDownload,
    required this.alreadyInstalledComponents,
    required this.totalRequiredBytes,
    required this.alreadyInstalledBytes,
    required this.downloadRequiredBytes,
    required this.temporaryOverheadBytes,
    required this.minimumFreeDiskBytes,
    required this.availableFreeDiskBytes,
    required this.isDiskSpaceSufficient,
    required this.requiresLicenseAcceptance,
    required this.unacceptedLicenseModelIds,
  });
}

/// Notification d'evenement de progression
class DownloadProgressEvent {
  final ImageDownloadStatus status;
  final String? currentComponentId;
  final String? currentFileName;
  final int bytesDownloaded;
  final int totalBytes;
  final double progressPercentage;
  final String? errorMessage;
  final bool isResumed;

  const DownloadProgressEvent({
    required this.status,
    this.currentComponentId,
    this.currentFileName,
    this.bytesDownloaded = 0,
    this.totalBytes = 0,
    this.progressPercentage = 0.0,
    this.errorMessage,
    this.isResumed = false,
  });

  @override
  String toString() =>
      'DownloadProgressEvent($status, file: $currentFileName, $bytesDownloaded/$totalBytes, ${(progressPercentage * 100).toStringAsFixed(1)}%)';
}
