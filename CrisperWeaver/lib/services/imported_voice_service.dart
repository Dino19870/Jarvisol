import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../utils/app_paths.dart';
import 'log_service.dart';
import 'voice_pack_inspector.dart';

class ImportedVoicePack {
  final String id;
  final String fileName; // Nom de fichier relatif, ex: "MaVoix.gguf"
  final VoicePackFamily family;
  final String compatibleBackend;
  final List<String> voiceNames;
  final int fileSizeBytes;
  final DateTime importedAt;

  const ImportedVoicePack({
    required this.id,
    required this.fileName,
    required this.family,
    required this.compatibleBackend,
    required this.voiceNames,
    required this.fileSizeBytes,
    required this.importedAt,
  });

  /// Résout dynamiquement le chemin absolu sur la machine actuelle.
  /// Reste toujours valide même si l'application est déplacée (A -> B).
  String get localPath => p.join(AppPaths.importedVoicesDir.path, fileName);

  bool get fileExists => File(localPath).existsSync();

  String get displayName => voiceNames.length == 1
      ? voiceNames.first
      : '$id (${voiceNames.length} voix)';

  /// Seules les voix de la famille Qwen3 supportent la sélection de locuteurs internes (multi-speaker).
  /// Les Voice Packs Chatterbox représentent directement le conditionnement vocal et n'ont pas de preset speakers.
  List<String> get presetSpeakers =>
      family == VoicePackFamily.qwen3 ? voiceNames : const [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'family': family.name,
        'compatibleBackend': compatibleBackend,
        'voiceNames': voiceNames,
        'fileSizeBytes': fileSizeBytes,
        'importedAt': importedAt.toIso8601String(),
      };

  factory ImportedVoicePack.fromJson(Map<String, dynamic> json) =>
      ImportedVoicePack(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        family: VoicePackFamily.values.firstWhere(
          (f) => f.name == json['family'],
          orElse: () => VoicePackFamily.chatterbox,
        ),
        compatibleBackend: json['compatibleBackend'] as String,
        voiceNames: (json['voiceNames'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [json['id'] as String],
        fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt() ?? 0,
        importedAt: DateTime.tryParse(json['importedAt']?.toString() ?? '') ??
            DateTime.now(),
      );
}

class VoicePackAlreadyExistsException implements Exception {
  final String fileName;
  const VoicePackAlreadyExistsException(this.fileName);
  @override
  String toString() => 'Un Voice Pack nommé "$fileName" existe déjà dans Jarvisol.';
}

class VoicePackImportException implements Exception {
  final String message;
  const VoicePackImportException(this.message);
  @override
  String toString() => message;
}

class ImportedVoiceService extends Notifier<List<ImportedVoicePack>> {
  ImportedVoiceService();

  List<ImportedVoicePack> _cachedPacks = [];

  List<ImportedVoicePack> get allPacks {
    try {
      return state;
    } catch (_) {
      return List.unmodifiable(_cachedPacks);
    }
  }

  void _updateState(List<ImportedVoicePack> packs) {
    _cachedPacks = packs;
    try {
      state = List.unmodifiable(_cachedPacks);
    } catch (_) {
      // Standalone mode without Riverpod container
    }
  }

  List<ImportedVoicePack> _loadInitialSync() {
    final indexFile = AppPaths.importedVoicesIndexFile;
    final list = <ImportedVoicePack>[];
    if (indexFile.existsSync()) {
      try {
        final content = indexFile.readAsStringSync();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content) as List<dynamic>;
          for (final item in decoded) {
            final vp = ImportedVoicePack.fromJson(item as Map<String, dynamic>);
            if (vp.fileExists) {
              list.add(vp);
            }
          }
        }
      } catch (e) {
        Log.instance.w('voicepack', 'Erreur lecture synchrone index: $e');
      }
    }
    _cachedPacks = list;
    return list;
  }

  @override
  List<ImportedVoicePack> build() {
    return _loadInitialSync();
  }

  void setImportedPacksForTesting(List<ImportedVoicePack> packs) {
    _updateState(packs);
  }

  /// Charge tous les Voice Packs importés depuis l'index JSON portable.
  /// Si des fichiers .gguf sont présents dans importedVoicesDir sans être indexés,
  /// ils sont inspectés et indexés automatiquement.
  Future<List<ImportedVoicePack>> loadAll() async {
    final dir = AppPaths.importedVoicesDir;
    final indexFile = AppPaths.importedVoicesIndexFile;

    final list = <ImportedVoicePack>[];
    final knownFiles = <String>{};

    if (indexFile.existsSync()) {
      try {
        final content = indexFile.readAsStringSync();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content) as List<dynamic>;
          for (final item in decoded) {
            final vp = ImportedVoicePack.fromJson(item as Map<String, dynamic>);
            if (vp.fileExists) {
              list.add(vp);
              knownFiles.add(vp.fileName);
            }
          }
        }
      } catch (e) {
        Log.instance.w('voicepack', 'Erreur lecture index: $e');
      }
    }

    // Découverte automatique de fichiers .gguf déposés directement
    if (dir.existsSync()) {
      final entries = dir.listSync();
      for (final entity in entries) {
        if (entity is File && entity.path.toLowerCase().endsWith('.gguf')) {
          final fn = p.basename(entity.path);
          if (!knownFiles.contains(fn)) {
            final res = VoicePackInspector.inspect(entity.path);
            if (res.isValid && res.family != null) {
              final vp = ImportedVoicePack(
                id: p.basenameWithoutExtension(fn),
                fileName: fn,
                family: res.family!,
                compatibleBackend: res.compatibleBackend!,
                voiceNames: res.voiceNames,
                fileSizeBytes: res.fileSizeBytes,
                importedAt: entity.lastModifiedSync(),
              );
              list.add(vp);
              knownFiles.add(fn);
            }
          }
        }
      }
    }

    _updateState(list);
    await _saveIndex();
    return allPacks;
  }

  /// Filtre les Voice Packs compatibles avec le backend TTS actif.
  List<ImportedVoicePack> getPacksForBackend(String? backend) {
    if (backend == null || backend.isEmpty) return const [];
    return allPacks.where((p) {
      if (!p.fileExists) return false;
      if (backend == 'chatterbox' && p.family == VoicePackFamily.chatterbox) {
        return true;
      }
      if (backend == 'qwen3-tts' && p.family == VoicePackFamily.qwen3) {
        return true;
      }
      return false;
    }).toList();
  }

  /// Analyse et copie un fichier Voice Pack GGUF externe vers le stockage portable.
  Future<ImportedVoicePack> importVoicePack(
    String sourcePath, {
    bool overwrite = false,
  }) async {
    final srcFile = File(sourcePath);
    if (!srcFile.existsSync()) {
      throw VoicePackImportException('Le fichier source est introuvable : $sourcePath');
    }

    final val = VoicePackInspector.inspect(sourcePath);
    if (!val.isValid || val.family == null) {
      throw VoicePackImportException(val.errorMessage ?? 'Fichier GGUF non reconnu comme Voice Pack');
    }

    final dir = AppPaths.importedVoicesDir;
    final fileName = p.basename(sourcePath);
    final targetPath = p.join(dir.path, fileName);
    final targetFile = File(targetPath);

    if (targetFile.existsSync() && !overwrite) {
      throw VoicePackAlreadyExistsException(fileName);
    }

    // Copie sécurisée via fichier temporaire atomique
    final tmpPath = '$targetPath.tmp';
    final tmpFile = File(tmpPath);
    try {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
      srcFile.copySync(tmpPath);
      if (targetFile.existsSync()) targetFile.deleteSync();
      tmpFile.renameSync(targetPath);
    } catch (e) {
      if (tmpFile.existsSync()) {
        try {
          tmpFile.deleteSync();
        } catch (_) {}
      }
      throw VoicePackImportException('Échec de la copie vers $targetPath : $e');
    }

    final id = p.basenameWithoutExtension(fileName);
    final vp = ImportedVoicePack(
      id: id,
      fileName: fileName,
      family: val.family!,
      compatibleBackend: val.compatibleBackend ?? (val.family == VoicePackFamily.chatterbox ? 'chatterbox' : 'qwen3-tts'),
      voiceNames: val.voiceNames,
      fileSizeBytes: val.fileSizeBytes,
      importedAt: DateTime.now(),
    );

    // Remplacement ou ajout dans le cache et propagation d'état réactive
    final updatedList = List<ImportedVoicePack>.from(_cachedPacks)
      ..removeWhere((item) => item.fileName == fileName)
      ..add(vp);
    _updateState(updatedList);
    await _saveIndex();

    Log.instance.i('voicepack', 'Voice Pack importé avec succès', fields: {
      'id': id,
      'fileName': fileName,
      'family': val.family!.name,
      'voices': val.voiceNames.join(', '),
      'bytes': val.fileSizeBytes,
      'target': targetPath,
    });

    return vp;
  }

  /// Supprime un Voice Pack du stockage portable et de l'index.
  Future<bool> deleteVoicePack(String idOrFileName) async {
    final idx = _cachedPacks.indexWhere(
      (p) => p.id == idOrFileName || p.fileName == idOrFileName,
    );
    if (idx == -1) return false;

    final vp = _cachedPacks[idx];
    final f = File(vp.localPath);
    try {
      if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (e) {
      Log.instance.w('voicepack', 'Impossible de supprimer le fichier: $e');
    }

    final updatedList = List<ImportedVoicePack>.from(_cachedPacks)..removeAt(idx);
    _updateState(updatedList);
    await _saveIndex();
    return true;
  }

  Future<void> _saveIndex() async {
    try {
      final indexFile = AppPaths.importedVoicesIndexFile;
      final data = _cachedPacks.map((p) => p.toJson()).toList();
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
      await indexFile.writeAsString(jsonStr);
    } catch (e) {
      Log.instance.w('voicepack', 'Erreur sauvegarde index: $e');
    }
  }
}

final importedVoiceServiceProvider =
    NotifierProvider<ImportedVoiceService, List<ImportedVoicePack>>(
  ImportedVoiceService.new,
);
