// lib/services/image_model_catalog_service.dart
//
// Service de gestion du catalogue et de detection de l'etat des modeles d'image
// pour Jarvisol (EXT-V1-02 Phase 1).

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../models/image_model_catalog.dart';
import '../utils/app_paths.dart';

class ImageModelCatalogService {
  ImageModelCatalog? _catalog;
  Directory? _modelsDirOverride;

  /// Cache d'integrite memoire et disque pour eviter de rehasher 37 Go
  /// Format: filename -> {'size': int, 'mtime': int, 'sha256': String}
  final Map<String, Map<String, dynamic>> _integrityCache = {};
  bool _cacheLoaded = false;

  ImageModelCatalogService({Directory? modelsDir}) {
    _modelsDirOverride = modelsDir;
  }

  /// Repertoire physique cible des modeles
  Directory get modelsDir => _modelsDirOverride ?? AppPaths.imageModelsDir;

  /// Catalogue charge en memoire
  ImageModelCatalog get catalog {
    if (_catalog == null) {
      throw StateError('Le catalogue des modeles d\'image n\'est pas charge. Appeler loadCatalog() d\'abord.');
    }
    return _catalog!;
  }

  bool get isLoaded => _catalog != null;

  /// Fichier de cache d'integrite sur disque : `<dataDir>/image_models_integrity_cache.json`
  File get _integrityCacheFile => File(p.join(AppPaths.dataDir.path, 'image_models_integrity_cache.json'));

  /// Chargement canonique du catalogue
  /// Priorite :
  /// 1. `data/config/image_model_catalog.json` (si present a la racine runtime)
  /// 2. `assets/models/image_model_catalog.json` (fichier direct ou asset bundle)
  Future<ImageModelCatalog> loadCatalog({String? jsonContent}) async {
    if (jsonContent != null && jsonContent.trim().isNotEmpty) {
      _catalog = parseCatalogJson(jsonContent);
      await _loadIntegrityCache();
      return _catalog!;
    }

    // 1. Verifier sur disque externe/portable data/config/
    final configFile = File(p.join(AppPaths.appDir.path, 'data', 'config', 'image_model_catalog.json'));
    if (await configFile.exists()) {
      final content = await configFile.readAsString();
      _catalog = parseCatalogJson(content);
      await _loadIntegrityCache();
      return _catalog!;
    }

    // 2. Verifier dans assets/models/image_model_catalog.json (fichier relatif local pour tests)
    final localAssetFile = File(p.join(Directory.current.path, 'assets', 'models', 'image_model_catalog.json'));
    if (await localAssetFile.exists()) {
      final content = await localAssetFile.readAsString();
      _catalog = parseCatalogJson(content);
      await _loadIntegrityCache();
      return _catalog!;
    }

    // 3. Verifier via assets Flutter rootBundle
    try {
      final content = await rootBundle.loadString('assets/models/image_model_catalog.json');
      _catalog = parseCatalogJson(content);
      await _loadIntegrityCache();
      return _catalog!;
    } catch (_) {
      // Fallback si pas en contexte Flutter UI
    }

    throw InvalidCatalogException(
      'INVALID_CATALOG_ENTRY',
      'Impossible de trouver le fichier catalogue image_model_catalog.json',
    );
  }

  /// Analyse et validation du JSON de catalogue
  ImageModelCatalog parseCatalogJson(String jsonString) {
    try {
      final dynamic decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'Le JSON racine doit etre un objet');
      }
      return ImageModelCatalog.fromJson(decoded);
    } on FormatException catch (e) {
      throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'Erreur de syntaxe JSON dans le catalogue: ${e.message}');
    }
  }

  /// Chargement du cache d'integrite
  Future<void> _loadIntegrityCache() async {
    if (_cacheLoaded) return;
    try {
      if (await _integrityCacheFile.exists()) {
        final content = await _integrityCacheFile.readAsString();
        final dynamic data = jsonDecode(content);
        if (data is Map<String, dynamic>) {
          for (final entry in data.entries) {
            if (entry.value is Map) {
              _integrityCache[entry.key] = Map<String, dynamic>.from(entry.value as Map);
            }
          }
        }
      }
    } catch (_) {
      // Ignorer si cache illisible
    }
    _cacheLoaded = true;
  }

  /// Sauvegarde du cache d'integrite sur disque
  Future<void> _saveIntegrityCache() async {
    try {
      await _integrityCacheFile.parent.create(recursive: true);
      await _integrityCacheFile.writeAsString(jsonEncode(_integrityCache), flush: true);
    } catch (_) {
      // Ignorer si non inscriptible (ex: test read-only)
    }
  }

  /// Enregistre un hash verifie dans le cache d'integrite
  Future<void> recordVerifiedComponent(String fileName, int size, int mtime, String sha256) async {
    _integrityCache[fileName] = {
      'size': size,
      'mtime': mtime,
      'sha256': sha256.toLowerCase(),
    };
    await _saveIntegrityCache();
  }

  /// Detection de l'etat physique d'un composant
  Future<ComponentStatus> detectComponentStatus(
    PhysicalComponent component, {
    bool verifySha = false,
  }) async {
    final file = File(p.join(modelsDir.path, component.fileName));
    if (!await file.exists()) {
      return ComponentStatus(
        component: component,
        state: ComponentVerificationState.absent,
      );
    }

    final stat = await file.stat();
    final actualSize = stat.size;

    // Si la taille differe, c'est directement un mismatch / corruption
    if (actualSize != component.expectedSizeBytes) {
      return ComponentStatus(
        component: component,
        state: ComponentVerificationState.corruptOrMismatch,
        actualSizeBytes: actualSize,
        errorMessage: 'Taille incorrecte: $actualSize octets (attendu: ${component.expectedSizeBytes})',
      );
    }

    // Si verification SHA demandee
    if (verifySha) {
      final sha = await computeFileSha256(file);
      if (sha.toLowerCase() == component.expectedSha256.toLowerCase()) {
        await recordVerifiedComponent(component.fileName, actualSize, stat.modified.millisecondsSinceEpoch, sha);
        return ComponentStatus(
          component: component,
          state: ComponentVerificationState.installedVerified,
          actualSizeBytes: actualSize,
          actualSha256: sha,
        );
      } else {
        return ComponentStatus(
          component: component,
          state: ComponentVerificationState.corruptOrMismatch,
          actualSizeBytes: actualSize,
          actualSha256: sha,
          errorMessage: 'SHA-256 incorrect: $sha (attendu: ${component.expectedSha256})',
        );
      }
    }

    // Verification rapide via cache d'integrite
    final cached = _integrityCache[component.fileName];
    if (cached != null) {
      final cachedSize = cached['size'] as int?;
      final cachedMtime = cached['mtime'] as int?;
      final cachedSha = (cached['sha256'] as String?)?.toLowerCase();

      if (cachedSize == actualSize &&
          cachedMtime == stat.modified.millisecondsSinceEpoch &&
          cachedSha == component.expectedSha256.toLowerCase()) {
        return ComponentStatus(
          component: component,
          state: ComponentVerificationState.installedVerified,
          actualSizeBytes: actualSize,
          actualSha256: cachedSha,
        );
      }
    }

    // Fichier present mais non encore verifie par SHA-256
    return ComponentStatus(
      component: component,
      state: ComponentVerificationState.presentUnverified,
      actualSizeBytes: actualSize,
    );
  }

  /// Calcul deterministe et securise du SHA-256 d'un fichier binaire par streaming
  static Future<String> computeFileSha256(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString().toLowerCase();
  }

  /// Evaluation de l'etat d'un modele logique
  Future<LogicalModelStatus> getLogicalModelStatus(
    String logicalModelId, {
    bool verifySha = false,
  }) async {
    final model = catalog.logicalModels[logicalModelId];
    if (model == null) {
      throw InvalidCatalogException('INVALID_CATALOG_ENTRY', 'Modele logique introuvable: $logicalModelId');
    }

    final statuses = <String, ComponentStatus>{};
    final missingIds = <String>[];
    var totalRequired = 0;
    var installedBytes = 0;

    for (final compId in model.requiredComponentIds) {
      final comp = catalog.components[compId]!;
      totalRequired += comp.expectedSizeBytes;

      final status = await detectComponentStatus(comp, verifySha: verifySha);
      statuses[compId] = status;

      if (status.state == ComponentVerificationState.installedVerified) {
        installedBytes += comp.expectedSizeBytes;
      } else {
        missingIds.add(compId);
      }
    }

    final compStatuses = statuses.values.toList();
    final allAbsent = compStatuses.every((s) => s.state == ComponentVerificationState.absent);
    final allInstalledVerified = compStatuses.every((s) => s.state == ComponentVerificationState.installedVerified);
    final hasCorrupt = compStatuses.any((s) => s.state == ComponentVerificationState.corruptOrMismatch);
    final allPresent = compStatuses.every((s) =>
        s.state == ComponentVerificationState.installedVerified ||
        s.state == ComponentVerificationState.presentUnverified);
    final hasUnverified = compStatuses.any((s) => s.state == ComponentVerificationState.presentUnverified);
    final hasPresent = compStatuses.any((s) =>
        s.state == ComponentVerificationState.installedVerified ||
        s.state == ComponentVerificationState.presentUnverified);
    final hasAbsent = compStatuses.any((s) => s.state == ComponentVerificationState.absent);

    LogicalModelInstallState state;
    if (hasCorrupt) {
      // C. au moins un CORRUPT => CORRUPT
      state = LogicalModelInstallState.corrupt;
    } else if (allInstalledVerified) {
      // B. tous INSTALLED_VERIFIED => INSTALLED
      state = LogicalModelInstallState.installed;
    } else if (allAbsent) {
      // A. tous les composants obligatoires ABSENT => NOT_INSTALLED
      state = LogicalModelInstallState.notInstalled;
    } else if (allPresent && hasUnverified) {
      // D. tous les composants physiquement presents mais au moins un PRESENT_UNVERIFIED => UNKNOWN
      state = LogicalModelInstallState.unknown;
    } else if (hasPresent && hasAbsent) {
      // E. melange de composants presents et absents => PARTIALLY_INSTALLED
      state = LogicalModelInstallState.partiallyInstalled;
    } else {
      state = LogicalModelInstallState.unknown;
    }

    return LogicalModelStatus(
      model: model,
      state: state,
      componentStatuses: statuses,
      missingComponentIds: missingIds,
      totalRequiredSizeBytes: totalRequired,
      installedSizeBytes: installedBytes,
    );
  }

  /// Verification de tous les composants du catalogue
  Future<Map<String, ComponentStatus>> detectAllComponents({bool verifySha = false}) async {
    final results = <String, ComponentStatus>{};
    for (final comp in catalog.components.values) {
      results[comp.componentId] = await detectComponentStatus(comp, verifySha: verifySha);
    }
    return results;
  }
}
