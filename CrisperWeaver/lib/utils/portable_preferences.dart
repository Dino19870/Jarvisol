// lib/utils/portable_preferences.dart
//
// Remplacement portable de SharedPreferences pour CrisperWeaver.
// Stocke les préférences dans <appDir>/data/preferences.json au lieu de
// %APPDATA%\com.crispstrobe\crisper_weaver\shared_preferences.json.
//
// API identique à SharedPreferences pour faciliter la migration.
// Migration automatique depuis l'ancien emplacement au 1er lancement.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import '../services/log_service.dart';

/// Préférences portables stockées dans un fichier JSON local.
/// Thread-safe : les écritures sont séquentialisées et coalescées (TNR-039).
class PortablePreferences {
  PortablePreferences._(this._data, this._file);

  final File _file;
  final Map<String, dynamic> _data;
  bool _isSaving = false;
  Completer<bool>? _currentWriteCompleter;
  Completer<bool>? _nextWriteCompleter;

  // ──────────────────────────────────────────────────────────────────────────
  // Singleton / Initialisation
  // ──────────────────────────────────────────────────────────────────────────

  static PortablePreferences? _instance;

  // ──────────────────────────────────────────────────────────────────────────
  // Support isolation tests
  // ──────────────────────────────────────────────────────────────────────────

  /// Lorsque non-null, remplace AppPaths.preferencesFile pour les tests.
  /// Pointe vers un fichier temporaire unique créé par [resetForTesting].
  /// Jamais défini en production.
  // ignore: prefer_final_fields
  static File? _testOverrideFile;
  static bool _wasCorruptedAtLoad = false;

  /// Obtient l'instance singleton, en l'initialisant si nécessaire.
  /// Effectue la migration depuis SharedPreferences Windows au 1er lancement.
  static Future<PortablePreferences> getInstance() async {
    if (_instance != null) return _instance!;

    // En test : utiliser le fichier isolé ; en prod : chemin réel.
    final file = _testOverrideFile ?? AppPaths.preferencesFile;
    Map<String, dynamic> data = {};
    _wasCorruptedAtLoad = false;

    // 1. Charger les préférences existantes (nouveau format)
    if (file.existsSync()) {
      try {
        final raw = await file.readAsString();
        if (raw.trim().isEmpty) {
          _wasCorruptedAtLoad = true;
          Log.instance.w('prefs', 'preferences.json est vide (0 octet)');
        } else {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            data = decoded;
            Log.instance.i('prefs', 'Préférences portables chargées',
                fields: {'keys': data.length, 'path': file.path});
          } else {
            _wasCorruptedAtLoad = true;
            Log.instance.w('prefs', 'Format preferences.json invalide (non-Map)');
          }
        }
      } catch (e) {
        _wasCorruptedAtLoad = true;
        Log.instance.w('prefs', 'Erreur lecture preferences.json : $e');
      }
    }

    // 2. Migration depuis SharedPreferences Windows (uniquement hors test et si non-corrompu)
    if (data.isEmpty && _testOverrideFile == null && !_wasCorruptedAtLoad) {
      final sealedMarker = File(p.join(AppPaths.appDir.path, '.sealed'));
      if (!sealedMarker.existsSync()) {
        final migrated = await _migrateFromSharedPreferences();
        if (migrated != null && migrated.isNotEmpty) {
          data = migrated;
          Log.instance.i('prefs',
              '✅ Migration SharedPreferences → preferences.json réussie',
              fields: {'keys': data.length});
        }
      }
    }

    _instance = PortablePreferences._(data, file);
    // Sauvegarder immédiatement si données migrées
    if (data.isNotEmpty && !file.existsSync()) {
      await _instance!._save();
    }
    return _instance!;
  }

  /// Réinitialise le singleton ET redirige vers un fichier temporaire isolé.
  ///
  /// Appelé au début de chaque test qui utilise [PortablePreferences].
  /// Crée un nouveau fichier JSON vide dans [Directory.systemTemp] pour
  /// garantir une isolation totale entre tests, sans toucher au chemin
  /// de production (`Release\data\preferences.json`).
  static void resetForTesting() {
    _instance = null;
    _wasCorruptedAtLoad = false;
    // Créer un fichier temporaire unique pour ce cycle de test
    final tmpDir = Directory.systemTemp.createTempSync('jarvisol_prefs_test_');
    _testOverrideFile = File('${tmpDir.path}/preferences.json');
    // Écrire un JSON vide pour éviter toute lecture de données de prod
    _testOverrideFile!.writeAsStringSync('{}');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Lecture
  // ──────────────────────────────────────────────────────────────────────────

  String? getString(String key) {
    final v = _data[key];
    if (v is String) return v;
    return null;
  }

  bool? getBool(String key) {
    final v = _data[key];
    if (v is bool) return v;
    return null;
  }

  int? getInt(String key) {
    final v = _data[key];
    if (v is num) return v.toInt();
    return null;
  }

  double? getDouble(String key) {
    final v = _data[key];
    if (v is num) return v.toDouble();
    return null;
  }

  List<String>? getStringList(String key) {
    final v = _data[key];
    if (v is List) return v.map((e) => e?.toString() ?? '').toList();
    return null;
  }

  List<dynamic>? getList(String key) {
    final v = _data[key];
    if (v is List) return v;
    return null;
  }

  Map<String, dynamic>? getMap(String key) {
    final v = _data[key];
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  bool containsKey(String key) => _data.containsKey(key);

  Set<String> getKeys() => _data.keys.toSet();

  Object? get(String key) => _data[key];

  // ──────────────────────────────────────────────────────────────────────────
  // Écriture
  // ──────────────────────────────────────────────────────────────────────────

  Future<bool> setString(String key, String value) async {
    _data[key] = value;
    return _save();
  }

  Future<bool> setBool(String key, bool value) async {
    _data[key] = value;
    return _save();
  }

  Future<bool> setInt(String key, int value) async {
    _data[key] = value;
    return _save();
  }

  Future<bool> setDouble(String key, double value) async {
    _data[key] = value;
    return _save();
  }

  Future<bool> setStringList(String key, List<String> value) async {
    _data[key] = value;
    return _save();
  }

  Future<bool> setRaw(String key, Object? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    return _save();
  }

  Future<bool> remove(String key) async {
    _data.remove(key);
    return _save();
  }

  Future<bool> clear() async {
    _data.clear();
    return _save();
  }

  // Alias pour compatibilité avec SharedPreferences (méthodes commit/apply)
  Future<bool> commit() => _save();
  Future<void> apply() => _save();

  // ──────────────────────────────────────────────────────────────────────────
  // Persistance interne
  // ──────────────────────────────────────────────────────────────────────────

  Future<bool> _save() {
    if (!_isSaving) {
      _isSaving = true;
      _currentWriteCompleter = Completer<bool>();
      _runSaveLoop();
      return _currentWriteCompleter!.future;
    } else {
      // Une écriture est déjà active sur le disque.
      // Enregistrer cette mutation pour le cycle suivant afin qu'elle ne soit jamais perdue (TNR-039).
      _nextWriteCompleter ??= Completer<bool>();
      return _nextWriteCompleter!.future;
    }
  }

  Future<void> _runSaveLoop() async {
    while (_currentWriteCompleter != null) {
      final active = _currentWriteCompleter!;

      final success = await _commitToDisk();
      if (!active.isCompleted) {
        active.complete(success);
      }

      // Récupérer les mutations survenues pendant l'I/O du commit précédent
      _currentWriteCompleter = _nextWriteCompleter;
      _nextWriteCompleter = null;
    }
    _isSaving = false;
  }

  Future<bool> _commitToDisk() async {
    try {
      // Si le fichier initial était corrompu ou 0-octet sur disque, créer une quarantaine avant écrasement
      if (_wasCorruptedAtLoad && _file.existsSync()) {
        try {
          final ts = DateTime.now().millisecondsSinceEpoch;
          final corruptBak = File('${_file.path}.bak_corrupt_$ts');
          await _file.copy(corruptBak.path);
          Log.instance.w('prefs', 'Quarantaine de preferences.json corrompu créée : ${corruptBak.path}');
        } catch (e) {
          Log.instance.e('prefs', 'Erreur création quarantaine preferences.json : $e');
        }
        _wasCorruptedAtLoad = false;
      }

      // Écriture atomique via fichier temporaire
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_data),
        flush: true,
      );
      await tmp.rename(_file.path);
      return true;
    } catch (e) {
      Log.instance.e('prefs', 'Erreur écriture preferences.json : $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Migration depuis SharedPreferences Windows
  // ──────────────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> _migrateFromSharedPreferences() async {
    if (!Platform.isWindows) return null;

    // Emplacement Windows de shared_preferences_windows
    final legacy = AppPaths.legacyPreferencesFile;
    if (legacy == null) return null;

    try {
      final raw = await legacy.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      // shared_preferences_windows stocke les valeurs avec préfixe de type :
      // "flutter.key" → la valeur est directement la valeur Dart
      // On nettoie les préfixes "flutter." si présents
      final cleaned = <String, dynamic>{};
      for (final entry in decoded.entries) {
        final key = entry.key.startsWith('flutter.')
            ? entry.key.substring(8)
            : entry.key;
        cleaned[key] = entry.value;
      }

      Log.instance.i('prefs',
          '📦 Migration depuis SharedPreferences Windows',
          fields: {'source': legacy.path, 'keys': cleaned.length});
      return cleaned.isNotEmpty ? cleaned : null;
    } catch (e) {
      Log.instance.w('prefs', 'Migration SharedPreferences échouée : $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Migration des fichiers Documents\CrisperWeaver\ → data\
  // ──────────────────────────────────────────────────────────────────────────

  /// Migre les données de l'ancien emplacement Documents\CrisperWeaver\
  /// vers le nouveau dossier data\ relatif à l'exe.
  /// Idempotente et reprenable : ne copie que les fichiers manquants et ne détruit rien.
  static Future<List<String>> migrateDocumentsData() async {
    final migrated = <String>[];
    final legacyDir = AppPaths.legacyDocumentsDir;
    if (legacyDir == null) return migrated;

    // Protection distribution scellée : aucune réinjection de données legacy
    final sealedMarker = File(p.join(AppPaths.appDir.path, '.sealed'));
    if (sealedMarker.existsSync()) {
      Log.instance.i('prefs', 'Distribution scellée détectée : migration legacy ignorée');
      return migrated;
    }

    final mappings = {
      'ai_knowledge': AppPaths.aiKnowledgeDir.path,
      'GeneratedImages': AppPaths.imagesDir.path,
      'rag_cache': AppPaths.ragCacheDir.path,
      'history': AppPaths.historyDir.path,
      'audiobooks': AppPaths.audiobooksDir.path,
      'espeak-ng-data': AppPaths.espeakDataDir.path,
      'batch': AppPaths.batchDir.path,
    };

    for (final entry in mappings.entries) {
      final srcDir = Directory(p.join(legacyDir.path, entry.key));
      if (!srcDir.existsSync()) continue;

      final dstDir = Directory(entry.value);
      try {
        final count = await _copyDirectoryMissingOnly(srcDir, dstDir);
        if (count > 0) {
          migrated.add('${entry.key} → ${entry.value} ($count fichier(s))');
          Log.instance.i('prefs', 'Dossier migré : ${srcDir.path} → ${dstDir.path} ($count fichier(s))');
        }
      } catch (e) {
        Log.instance.w('prefs', 'Migration dossier ${entry.key} échouée : $e');
      }
    }

    // Migrer le fichier log principal
    final legacyLog = File(p.join(legacyDir.path, 'crisperweaver.log'));
    if (legacyLog.existsSync() && !AppPaths.logFile.existsSync()) {
      try {
        await legacyLog.copy(AppPaths.logFile.path);
        migrated.add('crisperweaver.log → ${AppPaths.logFile.path}');
      } catch (_) {}
    }

    return migrated;
  }

  static Future<int> _copyDirectoryMissingOnly(Directory src, Directory dst) async {
    if (!dst.existsSync()) dst.createSync(recursive: true);
    var copied = 0;
    await for (final entity in src.list(recursive: false)) {
      final destPath = p.join(dst.path, p.basename(entity.path));
      if (entity is File) {
        final destFile = File(destPath);
        if (!destFile.existsSync()) {
          await entity.copy(destPath);
          copied++;
        }
      } else if (entity is Directory) {
        copied += await _copyDirectoryMissingOnly(entity, Directory(destPath));
      }
    }
    return copied;
  }
}
