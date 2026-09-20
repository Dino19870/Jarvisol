import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';

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
  final bool isMultimodal;
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
        // Windows / Desktop portable model directory discovery
        final userProfile = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
        final appDir = p.dirname(Platform.resolvedExecutable);
        final winDirs = [
          Directory(p.join(userProfile, 'Downloads', 'litert_models')),
          Directory(p.join(appDir, 'models')),
          Directory(p.join(appDir, 'data', 'models')),
          Directory(p.join(userProfile, '.litert-lm', 'models')),
          Directory(p.join(userProfile, 'Documents', 'CrisperWeaver', 'models')),
          Directory(p.join(userProfile, 'Documents', 'models', 'whisper_cpp')),
          Directory(p.join(userProfile, 'Downloads')),
          Directory(p.join(userProfile, '.local', 'share', 'litert_models')),
        ];
        final validExts = {'.litertlm', '.task', '.gguf', '.bin'};
        for (final dir in winDirs) {
          if (dir.existsSync()) {
            try {
              for (final f in dir.listSync(recursive: false)) {
                if (f is File && validExts.contains(p.extension(f.path).toLowerCase())) {
                  final length = f.lengthSync();
                  final fName = p.basename(f.path).toLowerCase();
                  if (length > 10 * 1024 * 1024) {
                    localFiles[fName] = f.path;
                  }
                }
              }
            } catch (_) {}
          }
        }
      }

      // Match models against local files
      for (final entry in _models) {
        final target = entry.filename.toLowerCase();
        if (localFiles.containsKey(target)) {
          entry.isDownloaded = true;
          entry.localPath = localFiles[target];
        } else {
          // Check for prefix match (e.g. gemma-4-e2b vs gemma-4-E2B-it.litertlm)
          bool found = false;
          for (final e in localFiles.entries) {
            if (e.key.contains(entry.id.replaceAll('-', '')) || 
                (entry.filename.isNotEmpty && e.key.contains(entry.filename.split('.').first.toLowerCase()))) {
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

      // Add discovered uncatalogued models as custom entries
      for (final e in localFiles.entries) {
        final existing = _models.any((m) => m.localPath == e.value || m.filename.toLowerCase() == e.key);
        if (!existing) {
          final isGemma = e.key.contains('gemma');
          final isQwen = e.key.contains('qwen') || e.key.contains('deepseek');
          final isMicro = e.key.contains('garden') || e.key.contains('action');
          _models.add(LiteRtModelEntry(
            id: p.basenameWithoutExtension(e.key),
            name: p.basename(e.value),
            author: 'Local Storage',
            description: 'Modèle détecté sur votre smartphone (${e.value})',
            repoId: '',
            filename: p.basename(e.value),
            downloadUrl: '',
            sizeBytes: 0,
            sizeDisplay: 'Local',
            format: p.extension(e.value).replaceAll('.', ''),
            preferredBackend: isMicro ? 'CPU' : 'GPU',
            isMultimodal: isGemma,
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
      final userProfile = Platform.environment['USERPROFILE'] ?? '.';
      targetDir = Directory(p.join(userProfile, 'Downloads', 'litert_models'));
    }
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }
    final savePath = p.join(targetDir.path, model.filename);
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
      if (tempFile.existsSync()) {
        final targetFile = File(savePath);
        if (targetFile.existsSync()) {
          targetFile.deleteSync();
        }
        tempFile.renameSync(savePath);
      }

      if (Platform.isWindows && (model.format == 'litertlm' || savePath.endsWith('.litertlm'))) {
        try {
          await Process.run('litert-lm', ['import', savePath, model.id], runInShell: true);
        } catch (_) {}
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
    if (model.localPath == null) return false;
    try {
      if (Platform.isAndroid) {
        final res = await _channel.invokeMethod<bool>('deleteLocalModel', {'modelPath': model.localPath});
        if (res == true) {
          model.isDownloaded = false;
          model.localPath = null;
          _notify();
          await refreshLocalStatus();
          return true;
        }
      } else {
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
    } catch (_) {}
    return false;
  }

  Future<void> updateModelConfig(String modelId, {double? temperature, int? topK, int? maxTokens}) async {
    final model = _models.firstWhere((m) => m.id == modelId, orElse: () => _models.first);
    if (temperature != null) model.temperature = temperature;
    if (topK != null) model.topK = topK;
    if (maxTokens != null) model.maxTokens = maxTokens;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('litert_temp_$modelId', model.temperature);
    await prefs.setInt('litert_topk_$modelId', model.topK);
    await prefs.setInt('litert_maxtok_$modelId', model.maxTokens);
    _notify();
  }

  Future<void> _loadSavedConfigs() async {
    final prefs = await SharedPreferences.getInstance();
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
