import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../utils/portable_preferences.dart';
import 'package:dio/dio.dart';
import '../utils/app_paths.dart';
import 'llm_service.dart';
import 'log_service.dart';

class LiteRtModelEntry {
  final String id;
  final String name;
  final String author;
  final String description;
  final String repoId;
  final String filename;
  final String downloadUrl;
  final int sizeBytes;
  final String sizeDisplay;
  final String format;
  final String preferredBackend;
  /// Indique si le build LiteRT téléchargé inclut un encodeur vision.
  /// Mis à jour dynamiquement par refreshLocalStatus() via détection
  /// du fichier vision_adapter.xnnpack_cache dans le dossier portable.
  bool isMultimodal;
  final bool isRecommended;
  final Map<String, dynamic> defaultConfig;

  String? localPath;
  bool isDownloaded;
  bool isDownloading;
  double downloadProgress; // 0.0 to 1.0
  int downloadedBytes;
  String downloadSpeed;
  CancelToken? cancelToken;

  double temperature;
  int topK;
  int maxTokens;

  LiteRtModelEntry({
    required this.id,
    required this.name,
    required this.author,
    required this.description,
    required this.repoId,
    required this.filename,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.sizeDisplay,
    required this.format,
    required this.preferredBackend,
    required this.isMultimodal,
    required this.isRecommended,
    required this.defaultConfig,
    this.localPath,
    this.isDownloaded = false,
    this.isDownloading = false,
    this.downloadProgress = 0.0,
    this.downloadedBytes = 0,
    this.downloadSpeed = '',
    this.cancelToken,
    double? temperature,
    int? topK,
    int? maxTokens,
  })  : temperature = temperature ?? (defaultConfig['temperature'] as num?)?.toDouble() ?? 0.7,
        topK = topK ?? (defaultConfig['topK'] as num?)?.toInt() ?? 40,
        maxTokens = maxTokens ?? (defaultConfig['maxTokens'] as num?)?.toInt() ?? 4096;

  factory LiteRtModelEntry.fromJson(Map<String, dynamic> json) {
    return LiteRtModelEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Modèle sans nom',
      author: json['author'] as String? ?? 'Inconnu',
      description: json['description'] as String? ?? '',
      repoId: json['repoId'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      downloadUrl: json['downloadUrl'] as String? ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      sizeDisplay: json['sizeDisplay'] as String? ?? '',
      format: json['format'] as String? ?? 'litertlm',
      preferredBackend: json['preferredBackend'] as String? ?? 'GPU',
      isMultimodal: json['isMultimodal'] as bool? ?? false,
      isRecommended: json['isRecommended'] as bool? ?? false,
      defaultConfig: (json['defaultConfig'] as Map<String, dynamic>?) ?? {},
    );
  }

  /// Vérifie dynamiquement si le build LiteRT installé inclut un encodeur vision.
  /// Gère les deux formats que peut stocker settings.llmModel :
  ///   - ID simple  : "gemma-3n-e2b-it"
  ///   - Chemin complet : "D:\...\gemma-3n-e2b-it\model.litertlm"
  static bool hasVisionEncoder(String modelIdOrPath) {
    if (!Platform.isWindows) return false;
    try {
      Directory modelDir;
      if (modelIdOrPath.contains(Platform.pathSeparator) ||
          modelIdOrPath.contains('/')) {
        // Chemin complet → le dossier du modèle est le parent du fichier
        modelDir = Directory(p.dirname(modelIdOrPath));
      } else {
        // ID simple → construire le chemin portable
        modelDir = Directory(
            p.join(AppPaths.litertModelsDir.path, modelIdOrPath));
      }
      if (!modelDir.existsSync()) return false;
      return modelDir.listSync().any(
          (f) => f is File && f.path.contains('vision_adapter'));
    } catch (_) {
      return false;
    }
  }
}

class LiteRtModelRegistry {
  static final LiteRtModelRegistry _instance = LiteRtModelRegistry._internal();
  factory LiteRtModelRegistry() => _instance;
  LiteRtModelRegistry._internal();

  static const MethodChannel _channel = MethodChannel('crisperweaver/litert_lm');
  final List<LiteRtModelEntry> _models = [];
  bool _isLoaded = false;

  final StreamController<List<LiteRtModelEntry>> _modelsStream = StreamController.broadcast();
  Stream<List<LiteRtModelEntry>> get modelsStream => _modelsStream.stream;
  List<LiteRtModelEntry> get models => List.unmodifiable(_models);

  Future<void> init() async {
    if (!_isLoaded) {
      await loadAllowlist();
    }
    await refreshLocalStatus();
  }

  Future<void> loadAllowlist() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/models/model_allowlist.json');
      final List<dynamic> list = json.decode(jsonStr) as List<dynamic>;
      _models.clear();
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          _models.add(LiteRtModelEntry.fromJson(item));
        }
      }
      await _loadSavedConfigs();
      _isLoaded = true;
      _notify();
    } catch (e) {
      // Fallback empty
    }
  }

  Future<void> refreshLocalStatus() async {
    try {
      final localFiles = <String, String>{}; // fileName -> absolutePath

      if (Platform.isAndroid) {
        final List<dynamic>? rawList = await _channel.invokeMethod<List<dynamic>>('listLocalModels');
        if (rawList != null) {
          for (final m in rawList) {
            if (m is Map) {
              final path = m['path'] as String?;
              final name = m['name'] as String?;
              if (path != null) {
                final fName = name ?? p.basename(path);
                localFiles[fName.toLowerCase()] = path;
              }
            }
          }
        }
      } else {
        // 🗂️ CHEMIN PORTABLE — litert-lm list avec USERPROFILE → Release/data/litert_home
        // Les modèles sont dans : litert_home/.litert-lm/models/<id>/model.litertlm
        if (Platform.isWindows) {
          final output = await LlmService.runLitertCli(['list']);
          if (output != null) {
            // Format de sortie : "ID   SIZE   MODIFIED" (3 colonnes, séparées par ≥2 espaces)
            // La ligne "Listing models in: ..." et l'en-tête sont sautées.
            for (final line in output.split('\n')) {
              final trimmed = line.trim();
              if (trimmed.isEmpty ||
                  trimmed.startsWith('Listing') ||
                  trimmed.startsWith('ID') ||
                  trimmed.startsWith('---')) continue;
              // Extraire l'ID (premier token avant ≥2 espaces)
              final cols = trimmed.split(RegExp(r'\s{2,}'));
              if (cols.isEmpty) continue;
              final modelId = cols[0].trim();
              if (modelId.isEmpty) continue;
              // Chemin portable complet du fichier modèle
              final modelPath = p.join(
                AppPaths.litertModelsDir.path,
                modelId,
                'model.litertlm',
              );
              localFiles[modelId.toLowerCase()] = modelPath;
            }
          }

          // Fallback : scan du dossier portable si CLI non disponible
          if (localFiles.isEmpty) {
            final portableModelsDir = AppPaths.litertModelsDir;
            if (portableModelsDir.existsSync()) {
              for (final sub in portableModelsDir.listSync()) {
                if (sub is Directory) {
                  final modelFile = File(p.join(sub.path, 'model.litertlm'));
                  if (modelFile.existsSync() && modelFile.lengthSync() > 10 * 1024 * 1024) {
                    final id = p.basename(sub.path).toLowerCase();
                    localFiles[id] = modelFile.path;
                  }
                }
              }
            }
          }
        } else {
          // Desktop non-Windows (macOS, Linux) : scan classique
          final userProfile = Platform.environment['HOME'] ?? '.';
          final appDir = p.dirname(Platform.resolvedExecutable);
          final winDirs = [
            Directory(AppPaths.litertModelsDir.path),
            Directory(p.join(userProfile, 'Downloads', 'litert_models')),
            Directory(p.join(appDir, 'models')),
            Directory(p.join(userProfile, '.litert-lm', 'models')),
          ];
          for (final dir in winDirs) {
            if (dir.existsSync()) {
              try {
                for (final sub in dir.listSync()) {
                  if (sub is Directory) {
                    final modelFile = File(p.join(sub.path, 'model.litertlm'));
                    if (modelFile.existsSync() && modelFile.lengthSync() > 10 * 1024 * 1024) {
                      final id = p.basename(sub.path).toLowerCase();
                      localFiles[id] = modelFile.path;
                    }
                  }
                }
              } catch (_) {}
            }
          }
        }
      }

      // Match models against local files (key = model ID ou filename, value = absolute path)
      for (final entry in _models) {
        // 1. Correspondance par ID exact (chemin portable litert-lm)
        final idKey = entry.id.toLowerCase();
        if (localFiles.containsKey(idKey)) {
          entry.isDownloaded = true;
          entry.localPath = localFiles[idKey];
        } else {
          // 2. Correspondance par filename (legacy, Android)
          final target = entry.filename.toLowerCase();
          if (localFiles.containsKey(target)) {
            entry.isDownloaded = true;
            entry.localPath = localFiles[target];
          } else {
            // 3. Correspondance partielle
            bool found = false;
            for (final e in localFiles.entries) {
              if (e.key.contains(entry.id.replaceAll('-', '').toLowerCase()) ||
                  (entry.filename.isNotEmpty &&
                      e.key.contains(entry.filename.split('.').first.toLowerCase()))) {
                entry.isDownloaded = true;
                entry.localPath = e.value;
                found = true;
                break;
              }
            }
            if (!found && !entry.isDownloading) {
              entry.isDownloaded = false;
              entry.localPath = null;
            }
          }
        }

        // 🔍 DÉTECTION DYNAMIQUE VISION — override la valeur statique de l'allowlist
        // Vérifie la présence du fichier vision_adapter.xnnpack_cache dans le
        // dossier portable. Un build LiteRT multimodal l'inclut TOUJOURS.
        // Ex : gemma-3n-e2b-it  → vision_adapter présent → isMultimodal = true
        //      gemma-4-e4b-it   → vision_adapter absent  → isMultimodal = false
        if (entry.isDownloaded) {
          final detected = LiteRtModelEntry.hasVisionEncoder(entry.id);
          // Mettre à jour seulement si la valeur change (évite des rebuilds inutiles)
          if (entry.isMultimodal != detected) {
            entry.isMultimodal = detected;
          }
        }
      }

      // Ajouter les modèles non-catalogués découverts localement
      for (final e in localFiles.entries) {
        final existing = _models.any((m) =>
            m.id.toLowerCase() == e.key ||
            m.localPath == e.value ||
            m.filename.toLowerCase() == e.key);
        if (!existing) {
          final isGemma = e.key.contains('gemma');
          final isQwen = e.key.contains('qwen') || e.key.contains('deepseek');
          final isMicro = e.key.contains('garden') || e.key.contains('action');
          _models.add(LiteRtModelEntry(
            id: e.key,
            name: e.key,
            author: 'Portable Storage',
            description: 'Modèle détecté dans le dossier portable (${e.value})',
            repoId: '',
            filename: 'model.litertlm',
            downloadUrl: '',
            sizeBytes: 0,
            sizeDisplay: 'Local',
            format: 'litertlm',
            preferredBackend: isMicro ? 'CPU' : 'GPU',
            isMultimodal: e.key.contains('gemma-3n') || e.key.contains('gemma-4-e2b'),
            isRecommended: false,
            defaultConfig: {
              'temperature': 0.7,
              'topK': 40,
              'maxTokens': 4096,
              'promptTemplate': isGemma ? 'gemma' : (isQwen ? 'qwen' : 'standard'),
            },
            localPath: e.value,
            isDownloaded: true,
          ));
        }
      }


      _notify();
    } catch (_) {}
  }

  Future<void> startDownload(LiteRtModelEntry model, {String? hfToken, void Function(double progress)? onProgress}) async {
    if (model.downloadUrl.isEmpty || model.isDownloading) return;

    model.isDownloading = true;
    model.downloadProgress = 0.0;
    model.downloadedBytes = 0;
    model.cancelToken = CancelToken();
    _notify();

    final dio = Dio();
    final Directory targetDir;
    if (Platform.isAndroid) {
      targetDir = Directory('/storage/emulated/0/Download');
    } else {
      // 🗂️ CHEMIN PORTABLE — Télécharger dans Release/data/litert_home/.litert-lm/models/<id>/
      targetDir = Directory(p.join(AppPaths.litertModelsDir.path, model.id));
    }
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }
    // Le fichier s'appellera toujours "model.litertlm" (convention litert-lm)
    final savePath = p.join(targetDir.path, 'model.litertlm');

    final tempPath = '$savePath.download';

    final headers = <String, dynamic>{};
    if (hfToken != null && hfToken.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${hfToken.trim()}';
    }

    var lastTime = DateTime.now();
    var lastBytes = 0;

    try {
      await dio.download(
        model.downloadUrl,
        tempPath,
        cancelToken: model.cancelToken,
        options: Options(headers: headers),
        onReceiveProgress: (received, total) {
          model.downloadedBytes = received;
          final now = DateTime.now();
          final elapsedSec = now.difference(lastTime).inMilliseconds / 1000.0;
          if (elapsedSec >= 0.5) {
            final speedBytesPerSec = (received - lastBytes) / elapsedSec;
            final speedMbPerSec = speedBytesPerSec / (1024 * 1024);
            model.downloadSpeed = '${speedMbPerSec.toStringAsFixed(1)} Mo/s';
            lastTime = now;
            lastBytes = received;
          }

          if (total > 0) {
            model.downloadProgress = received / total;
          } else if (model.sizeBytes > 0) {
            model.downloadProgress = received / model.sizeBytes;
          }
          onProgress?.call(model.downloadProgress);
          _notify();
        },
      );

      final tempFile = File(tempPath);
      if (!tempFile.existsSync() || tempFile.lengthSync() == 0) {
        throw Exception('Le fichier téléchargé est vide ou introuvable : $tempPath');
      }

      // Validation de taille minimale / intégrité avant promotion (AUD-LITERT-02 / TNR-071)
      if (model.sizeBytes > 0 && tempFile.lengthSync() < (model.sizeBytes * 0.95).toInt()) {
        throw Exception(
          'Fichier modèle incomplet : reçu ${tempFile.lengthSync()} octets, '
          'attendu au moins ${(model.sizeBytes * 0.95).toInt()} octets.',
        );
      }

      final targetFile = File(savePath);
      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }
      tempFile.renameSync(savePath);

      // Enregistrement via CLI portable mutualisé (AUD-LITERT-01 / TNR-070)
      if (Platform.isWindows && (model.format == 'litertlm' || savePath.endsWith('.litertlm'))) {
        final importOut = await LlmService.runLitertCli(['import', savePath, model.id]);
        if (importOut == null) {
          Log.instance.e('litert-reg', 'Échec litert-lm import portable pour ${model.id}');
          throw Exception('Échec de l\'enregistrement portable litert-lm import pour ${model.id}');
        }
      }

      model.isDownloading = false;
      model.isDownloaded = true;
      model.localPath = savePath;
      model.downloadProgress = 1.0;
      model.downloadSpeed = '';
      _notify();

      await refreshLocalStatus();
    } catch (e) {
      model.isDownloading = false;
      model.downloadSpeed = '';
      final tempFile = File(tempPath);
      if (tempFile.existsSync()) {
        try { tempFile.deleteSync(); } catch (_) {}
      }
      _notify();
      rethrow;
    }
  }

  void cancelDownload(String modelId) {
    final model = _models.firstWhere((m) => m.id == modelId, orElse: () => _models.first);
    if (model.isDownloading && model.cancelToken != null) {
      model.cancelToken!.cancel('Annulé par l\'utilisateur');
      model.isDownloading = false;
      model.downloadProgress = 0.0;
      _notify();
    }
  }

  Future<bool> deleteModel(LiteRtModelEntry model) async {
    if (model.localPath == null && model.id.isEmpty) return false;
    try {
      if (Platform.isAndroid) {
        if (model.localPath != null) {
          final res = await _channel.invokeMethod<bool>('deleteLocalModel', {'modelPath': model.localPath});
          if (res == true) {
            model.isDownloaded = false;
            model.localPath = null;
            _notify();
            await refreshLocalStatus();
            return true;
          }
        }
      } else if (Platform.isWindows) {
        // Exécution de la suppression officielle via litert-lm CLI
        String? out;
        try {
          out = await LlmService.runLitertCli(['delete', model.id]);
          Log.instance.i('litert-reg', 'litert-lm delete output: $out');
        } catch (e) {
          Log.instance.w('litert-reg', 'litert-lm delete error: $e');
          return false;
        }

        if (out == null || !out.toLowerCase().contains('deleted model')) {
          Log.instance.w('litert-reg', 'litert-lm delete non-success output: $out');
          return false;
        }

        // Vérifier dans litert-lm list que le modèle n'est plus enregistré
        final listOut = await LlmService.runLitertCli(['list']);
        if (listOut == null) {
          Log.instance.w('litert-reg', 'litert-lm list check failed');
          return false;
        }
        final isStillInList = listOut.split('\n').any((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('Listing') || trimmed.startsWith('ID') || trimmed.startsWith('---')) {
            return false;
          }
          final firstToken = trimmed.split(RegExp(r'\s+')).first;
          return firstToken == model.id;
        });
        if (isStillInList) {
          Log.instance.w('litert-reg', 'Model ${model.id} still registered in litert-lm list');
          return false;
        }

        // Nettoyage disque physique borné exclusivement à AppPaths.litertModelsDir
        try {
          final modelsDir = AppPaths.litertModelsDir;
          final targetDir = Directory(p.join(modelsDir.path, model.id));
          if (p.isWithin(modelsDir.path, targetDir.path) && targetDir.existsSync()) {
            targetDir.deleteSync(recursive: true);
          }
          if (model.localPath != null) {
            final f = File(model.localPath!);
            if (p.isWithin(modelsDir.path, f.path) && f.existsSync()) {
              f.deleteSync();
            }
          }
        } catch (e) {
          Log.instance.w('litert-reg', 'Physical cleanup error: $e');
        }

        // Vérifier l'absence effective sur le filesystem
        final targetDirAfter = Directory(p.join(AppPaths.litertModelsDir.path, model.id));
        if (targetDirAfter.existsSync()) {
          Log.instance.w('litert-reg', 'Directory still exists after cleanup: ${targetDirAfter.path}');
          return false;
        }

        // Retirer les modèles importés hors catalogue
        _models.removeWhere((m) => m.id == model.id && m.downloadUrl.isEmpty);
        model.isDownloaded = false;
        model.localPath = null;
        _notify();
        await refreshLocalStatus();
        return true;
      } else {
        if (model.localPath != null) {
          final f = File(model.localPath!);
          if (f.existsSync()) {
            f.deleteSync();
            model.isDownloaded = false;
            model.localPath = null;
            _notify();
            await refreshLocalStatus();
            return true;
          }
        }
      }
    } catch (e) {
      Log.instance.e('litert-reg', 'deleteModel failed', error: e);
    }
    return false;
  }

  /// Importe un modèle local (.litertlm, .bin, .task) dans le registre LiteRT.
  /// Sur Windows, utilise la commande officielle `litert-lm import`.
  Future<String?> importLocalModel(String sourcePath, {String? customId}) async {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw Exception('Fichier introuvable : $sourcePath');
    }
    final ext = p.extension(sourcePath).toLowerCase();
    if (!['.litertlm', '.bin', '.task'].contains(ext)) {
      throw Exception('Format non supporté : $ext (formats acceptés : .litertlm, .bin, .task)');
    }

    final baseName = p.basenameWithoutExtension(sourcePath);
    final modelId = (customId != null && customId.trim().isNotEmpty)
        ? customId.trim()
        : baseName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-_.]'), '-');

    if (Platform.isWindows) {
      final isAlreadyRegistered = _models.any((m) =>
          m.id.toLowerCase() == modelId.toLowerCase() && m.isDownloaded);
      if (isAlreadyRegistered) {
        throw Exception('Un modèle avec l\'identifiant "$modelId" est déjà enregistré.');
      }

      final out = await LlmService.runLitertCli(['import', sourcePath, modelId]);
      Log.instance.i('litert-reg', 'litert-lm import output: $out');

      await refreshLocalStatus();

      // Vérifier que le modèle est maintenant dans _models ou l'ajouter
      final imported = _models.firstWhere(
        (m) => m.id.toLowerCase() == modelId.toLowerCase() ||
               (m.localPath != null && p.basename(p.dirname(m.localPath!)).toLowerCase() == modelId.toLowerCase()),
        orElse: () {
          final targetPath = p.join(AppPaths.litertModelsDir.path, modelId, 'model.litertlm');
          final isGemma = modelId.contains('gemma');
          final isQwen = modelId.contains('qwen');
          final newEntry = LiteRtModelEntry(
            id: modelId,
            name: modelId,
            author: 'Import Local',
            description: 'Modèle importé depuis $sourcePath',
            repoId: '',
            filename: 'model.litertlm',
            downloadUrl: '',
            sizeBytes: file.lengthSync(),
            sizeDisplay: '${(file.lengthSync() / (1024 * 1024)).toStringAsFixed(1)} Mo',
            format: ext.replaceFirst('.', ''),
            preferredBackend: 'GPU',
            isMultimodal: LiteRtModelEntry.hasVisionEncoder(modelId),
            isRecommended: false,
            defaultConfig: {
              'temperature': 0.7,
              'topK': 40,
              'maxTokens': 4096,
              'promptTemplate': isGemma ? 'gemma' : (isQwen ? 'qwen' : 'standard'),
            },
            localPath: File(targetPath).existsSync() ? targetPath : sourcePath,
            isDownloaded: true,
          );
          _models.add(newEntry);
          return newEntry;
        },
      );

      imported.isDownloaded = true;
      if (imported.localPath == null || !File(imported.localPath!).existsSync()) {
        final expectedTarget = p.join(AppPaths.litertModelsDir.path, modelId, 'model.litertlm');
        imported.localPath = File(expectedTarget).existsSync() ? expectedTarget : sourcePath;
      }
      _notify();
      return imported.id;
    } else if (Platform.isAndroid) {
      final res = await _channel.invokeMethod<String>('importLocalModel', {'sourcePath': sourcePath});
      await refreshLocalStatus();
      return res ?? modelId;
    }
    return null;
  }

  Future<void> updateModelConfig(String modelId, {double? temperature, int? topK, int? maxTokens}) async {
    final model = _models.firstWhere((m) => m.id == modelId, orElse: () => _models.first);
    if (temperature != null) model.temperature = temperature;
    if (topK != null) model.topK = topK;
    if (maxTokens != null) model.maxTokens = maxTokens;

    final prefs = await PortablePreferences.getInstance();
    await prefs.setDouble('litert_temp_$modelId', model.temperature);
    await prefs.setInt('litert_topk_$modelId', model.topK);
    await prefs.setInt('litert_maxtok_$modelId', model.maxTokens);
    _notify();
  }

  Future<void> _loadSavedConfigs() async {
    final prefs = await PortablePreferences.getInstance();
    for (final m in _models) {
      final t = prefs.getDouble('litert_temp_${m.id}');
      if (t != null) m.temperature = t;
      final k = prefs.getInt('litert_topk_${m.id}');
      if (k != null) m.topK = k;
      final tok = prefs.getInt('litert_maxtok_${m.id}');
      if (tok != null) m.maxTokens = tok;
    }
  }

  void _notify() {
    if (!_modelsStream.isClosed) {
      _modelsStream.add(List.unmodifiable(_models));
    }
  }
}
