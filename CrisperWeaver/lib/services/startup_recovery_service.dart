// lib/services/startup_recovery_service.dart
//
// Service de détection d\'échec et récupération automatique après crash
// pendant la phase critique « Engine starting ».
// REQ-POST-002 (LITE-001 .. LITE-013).

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../utils/app_paths.dart';
import 'log_service.dart';

/// Statut retourné par [StartupRecoveryService.checkAndRecover].
enum StartupRecoveryStatus {
  /// Aucun marker présent : démarrage nominal ou crash survenu après Engine ready.
  noRecoveryNeeded,

  /// Marker stale détecté : preferences.json fautif sauvegardé et Lite restauré.
  recovered,

  /// Le crash précédent était déjà en mode Lite : arrêt pour éviter une boucle infinie.
  recoveryLoopAborted,

  /// Baseline Lite absente ou corrompue : preferences.json n\'a pas été écrasé.
  liteBaselineInvalid,
}

/// Résultat détaillé d\'une tentative de récupération.
class StartupRecoveryResult {
  final StartupRecoveryStatus status;
  final String message;
  final String? backupPath;
  final String? sourceLitePath;

  const StartupRecoveryResult({
    required this.status,
    required this.message,
    this.backupPath,
    this.sourceLitePath,
  });

  bool get wasRecovered => status == StartupRecoveryStatus.recovered;

  @override
  String toString() =>
      'StartupRecoveryResult($status, message: $message, backup: ${backupPath ?? "none"})';
}

/// Gère le cycle de vie du marker transactionnel .engine_starting.json
/// et la récupération automatique en configuration Lite.
class StartupRecoveryService {
  StartupRecoveryService._();

  static const String markerFileName = '.engine_starting.json';
  static const String litePreferencesFileName = 'preferences.lite.json';
  static const String liteRecoveryFileName = 'preferences.lite.recovery.json';
  static const String preferencesFileName = 'preferences.json';

  /// Indique si la session courante a été restaurée en mode Lite au démarrage.
  static bool wasRecoveredThisSession = false;

  /// Calcule le SHA-256 hexadécimal d\'un fichier.
  static String calculateSha256(File file) {
    if (!file.existsSync()) return '';
    final bytes = file.readAsBytesSync();
    return sha256.convert(bytes).toString().toUpperCase();
  }

  /// Résout le dossier de données cible (défaut : AppPaths.dataDir).
  static Directory _resolveDataDir(Directory? targetDataDir) {
    return targetDataDir ?? AppPaths.dataDir;
  }

  /// Vérifie la présence d\'un marker stale avant l\'initialisation des préférences.
  static Future<StartupRecoveryResult> checkAndRecover({
    Directory? targetDataDir,
  }) async {
    final dataDir = _resolveDataDir(targetDataDir);
    final markerFile = File(p.join(dataDir.path, markerFileName));
    final prefsFile = File(p.join(dataDir.path, preferencesFileName));
    final liteFile = File(p.join(dataDir.path, litePreferencesFileName));
    final recoveryFile = File(p.join(dataDir.path, liteRecoveryFileName));

    if (!markerFile.existsSync()) {
      return const StartupRecoveryResult(
        status: StartupRecoveryStatus.noRecoveryNeeded,
        message: 'No stale engine starting marker found. Startup nominal.',
      );
    }

    Log.instance.w('recovery',
        'Stale marker detected: previous engine starting phase did not complete',
        fields: {'marker': markerFile.path});

    // 1. Lire le contenu du marker transactionnel
    Map<String, dynamic> markerData = {};
    try {
      final markerContent = markerFile.readAsStringSync().trim();
      if (markerContent.isNotEmpty) {
        final decoded = jsonDecode(markerContent);
        if (decoded is Map<String, dynamic>) {
          markerData = decoded;
        }
      }
    } catch (e) {
      Log.instance.w('recovery', 'Could not parse marker JSON: ');
    }

    final bool wasLiteSession = markerData['is_lite'] == true;

    // 2. Protection contre boucle de recovery (LITE-010)
    if (wasLiteSession) {
      Log.instance.e('recovery',
          'RECOVERY LOOP DETECTED: Previous session was ALREADY Lite and failed during Engine starting. Aborting recovery loop to protect user data.',
          fields: {'markerData': markerData});
      try {
        markerFile.deleteSync();
      } catch (_) {}
      return const StartupRecoveryResult(
        status: StartupRecoveryStatus.recoveryLoopAborted,
        message:
            'Recovery loop prevented: crashed session was already running under Lite profile.',
      );
    }

    // 3. Validation de la baseline Lite (LITE-009)
    File? validLiteSource;
    for (final candidate in [liteFile, recoveryFile]) {
      if (candidate.existsSync()) {
        try {
          final text = candidate.readAsStringSync().trim();
          if (text.isNotEmpty) {
            final decoded = jsonDecode(text);
            if (decoded is Map<String, dynamic> && decoded.isNotEmpty) {
              validLiteSource = candidate;
              break;
            }
          }
        } catch (e) {
          Log.instance.w('recovery',
              'Lite candidate ${candidate.path} is corrupt: $e');
        }
      }
    }

    if (validLiteSource == null) {
      Log.instance.e('recovery',
          'Cannot perform recovery: neither preferences.lite.json nor preferences.lite.recovery.json is valid. preferences.json NOT modified.',
          fields: {
            'liteExists': liteFile.existsSync(),
            'recoveryExists': recoveryFile.existsSync(),
          });
      try {
        markerFile.deleteSync();
      } catch (_) {}
      return const StartupRecoveryResult(
        status: StartupRecoveryStatus.liteBaselineInvalid,
        message:
            'Lite baseline missing or corrupt. Preserved existing preferences.',
      );
    }

    // 4. Sauvegarde bit-for-bit du preferences.json fautif (LITE-007)
    String? backupPath;
    if (prefsFile.existsSync()) {
      final now = DateTime.now();
      final y = now.year.toString();
      final m = now.month.toString().padLeft(2, '0');
      final d = now.day.toString().padLeft(2, '0');
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      final ss = now.second.toString().padLeft(2, '0');
      final ts = '$y$m${d}_$hh$mm$ss';
      final backupFile =
          File(p.join(dataDir.path, 'preferences.failed_$ts.json'));

      try {
        prefsFile.copySync(backupFile.path);
        backupPath = backupFile.path;
        Log.instance.i('recovery', 'Faulty preferences preserved bit-for-bit',
            fields: {
              'source': prefsFile.path,
              'backup': backupPath,
              'sha256': calculateSha256(backupFile),
            });
      } catch (e) {
        Log.instance.e('recovery', 'Failed to backup faulty preferences: ');
      }
    }

    // 5. Restauration atomique de la configuration Lite
    try {
      final tmpFile = File(p.join(dataDir.path, 'preferences.json.tmp'));
      tmpFile.writeAsBytesSync(validLiteSource.readAsBytesSync(), flush: true);

      if (prefsFile.existsSync()) {
        try {
          prefsFile.deleteSync();
        } catch (_) {}
      }
      tmpFile.renameSync(prefsFile.path);

      wasRecoveredThisSession = true;
      Log.instance.i('recovery', 'Successfully restored Lite configuration',
          fields: {
            'from': validLiteSource.path,
            'to': prefsFile.path,
            'sha256': calculateSha256(prefsFile),
          });
    } catch (e) {
      Log.instance.e('recovery', 'Atomic replace failed: ');
      return StartupRecoveryResult(
        status: StartupRecoveryStatus.liteBaselineInvalid,
        message: 'Failed to restore Lite preferences: ',
        backupPath: backupPath,
      );
    }

    // 6. Nettoyage du marker stale
    try {
      if (markerFile.existsSync()) {
        markerFile.deleteSync();
      }
    } catch (e) {
      Log.instance.w('recovery', 'Could not delete stale marker: ');
    }

    return StartupRecoveryResult(
      status: StartupRecoveryStatus.recovered,
      message: 'Restored Lite preferences after engine starting failure.',
      backupPath: backupPath,
      sourceLitePath: validLiteSource.path,
    );
  }

  /// Écrit le marker transactionnel immédiatement avant la phase lourde Engine starting.
  static Future<void> markEngineStarting({
    Directory? targetDataDir,
    bool? isLite,
  }) async {
    final dataDir = _resolveDataDir(targetDataDir);
    final markerFile = File(p.join(dataDir.path, markerFileName));
    final prefsFile = File(p.join(dataDir.path, preferencesFileName));

    bool determinedIsLite = isLite ?? false;
    String currentSha = '';

    if (prefsFile.existsSync()) {
      currentSha = calculateSha256(prefsFile);
      if (isLite == null) {
        try {
          final content = prefsFile.readAsStringSync();
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            final model = decoded['default_model'] as String?;
            if (model == 'base' || model == 'tiny') {
              determinedIsLite = true;
            }
          }
        } catch (_) {}
      }
    }

    final markerPayload = {
      'timestamp': DateTime.now().toIso8601String(),
      'session_id': '${DateTime.now().millisecondsSinceEpoch}_$pid',
      'preferences_sha256': currentSha,
      'is_lite': determinedIsLite,
    };

    try {
      final tmp = File(p.join(dataDir.path, '$markerFileName.tmp'));
      tmp.writeAsStringSync(jsonEncode(markerPayload), flush: true);
      if (markerFile.existsSync()) {
        try {
          markerFile.deleteSync();
        } catch (_) {}
      }
      tmp.renameSync(markerFile.path);

      Log.instance.d('recovery', 'Engine starting marker armed',
          fields: {'marker': markerFile.path, 'is_lite': determinedIsLite});
    } catch (e) {
      // Fallback écriture directe si rename échoue
      try {
        markerFile.writeAsStringSync(jsonEncode(markerPayload), flush: true);
      } catch (err) {
        Log.instance.w('recovery', 'Could not write engine starting marker: ');
      }
    }
  }

  /// Supprime le marker transactionnel une fois l\'Engine ready confirmé.
  static Future<void> markEngineReady({Directory? targetDataDir}) async {
    final dataDir = _resolveDataDir(targetDataDir);
    final markerFile = File(p.join(dataDir.path, markerFileName));

    try {
      if (markerFile.existsSync()) {
        markerFile.deleteSync();
        Log.instance.d('recovery', 'Engine ready: starting marker disarmed');
      }
    } catch (e) {
      Log.instance.w('recovery', 'Could not remove engine starting marker: ');
    }
  }
}
