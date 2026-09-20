// lib/services/memory_server_manager.dart
//
// Gestion du cycle de vie de memory_server.exe — démarrage automatique portable.
//
// Règles d'Ownership strictes (CORR-LOT-002) :
//   1. Si /health répond 200 OK : serveur pré-existant sain
//      → _owned = false, adopté/external = true, JAMAIS tué à l'arrêt.
//   2. Si port 7862 occupé mais /health invalide/non-répondant :
//      → Conflit détecté : aucun second serveur lancé, occupant étranger JAMAIS tué.
//      → Retourne false avec message d'erreur explicite.
//   3. Si port 7862 libre :
//      → Lancer memory_server.exe local (mode portable).
//      → Mémoriser PID, _owned = true, _startTime.
//      → Liaison automatique à un Windows Job Object avec JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
//        (garantit l'éradication kernel de l'arbre à l'arrêt de Jarvisol).
//      → Readiness loop (10 × 500 ms).
//      → Si échec/timeout : arrêt contrôlé de l'arbre owned (_pid) uniquement.
//   4. Arrêt (stop / stopSync) :
//      → Si _owned = true : arrêt de l'arbre de processus owned via taskkill /PID <pid> /T /F.
//      → Interdiction absolue de taskkill /IM global.
//      → Si _owned = false : détachement sans aucun kill.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../constants/timeout_policy.dart';
import 'log_service.dart';

// ── Déclarations Win32 FFI pour Job Object ────────────────────────────────────

final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;
  @Uint32()
  external int limitFlags;
  @IntPtr()
  external int minimumWorkingSetSize;
  @IntPtr()
  external int maximumWorkingSetSize;
  @Uint32()
  external int activeProcessLimit;
  @IntPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation basicLimitInformation;
  external _IoCounters ioInfo;
  @IntPtr()
  external int processMemoryLimit;
  @IntPtr()
  external int jobMemoryLimit;
  @IntPtr()
  external int peakProcessMemoryLimit;
  @IntPtr()
  external int peakJobMemoryLimit;
}

typedef _CreateJobObjectWNative = IntPtr Function(Pointer<Void>, Pointer<Void>);
typedef _CreateJobObjectWDart = int Function(Pointer<Void>, Pointer<Void>);

typedef _SetInformationJobObjectNative = Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32);
typedef _SetInformationJobObjectDart = int Function(int, int, Pointer<Void>, int);

typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);

typedef _AssignProcessToJobObjectNative = Int32 Function(IntPtr, IntPtr);
typedef _AssignProcessToJobObjectDart = int Function(int, int);

typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

// ── Gestionnaire de cycle de vie Memory ────────────────────────────────────────

class MemoryServerManager {
  static const int    _kPort       = 7862;
  static const String _kBase       = 'http://127.0.0.1:$_kPort';
  static const String _kHealthFast = '$_kBase/health';
  static const String _kHealthOld  = '$_kBase/memory/stats';

  bool      _owned     = false;
  Process?  _process;
  bool      _available = false;
  int?      _pid;
  DateTime? _startTime;
  int?      _hJob;

  /// true si le serveur mémoire est joignable (pré-existant ou lancé par nous).
  bool get isAvailable => _available;

  /// true si le serveur a été démarré et est possédé par cette instance.
  bool get isOwned => _owned;

  /// PID du processus détenu si démarré par nous.
  int? get pid => _pid;

  /// Heure de démarrage du serveur détenu.
  DateTime? get startTime => _startTime;

  /// Démarre ou adopte le serveur mémoire selon les règles d'ownership strictes.
  /// Retourne true si prêt, false si indisponible ou en conflit.
  Future<bool> start() async {
    // 1. Health-check initial : serveur pré-existant déjà sain ?
    if (await _isHealthy()) {
      _owned     = false;
      _available = true;
      Log.instance.i('memory-mgr',
          'memory_server pré-existant sain sur :$_kPort — adopté, non détenu');
      return true;
    }

    // 2. Vérifier si le port est occupé par un processus étranger ou non sain
    if (await _isPortOccupied()) {
      _owned     = false;
      _available = false;
      Log.instance.e('memory-mgr',
          'port $_kPort occupé par un service non compatible ou Memory non sain — refus de démarrage doublon, occupant étranger préservé');
      return false;
    }

    // 3. Trouver memory_server.exe dans le dossier portable (à côté de jarvisol.exe)
    final exeDir  = p.dirname(Platform.resolvedExecutable);
    final exePath = p.join(exeDir, 'memory_server.exe');

    if (!File(exePath).existsSync()) {
      Log.instance.w('memory-mgr',
          'memory_server.exe absent de $exeDir — mémoire persistante indisponible');
      _available = false;
      return false;
    }

    // 4. Lancer le serveur
    try {
      _startTime = DateTime.now();
      _process = await Process.start(
        exePath,
        const [],
        workingDirectory: exeDir,
        mode: ProcessStartMode.normal,
      );
      _pid   = _process!.pid;
      _owned = true;
      Log.instance.i('memory-mgr', 'memory_server.exe lancé (PID=$_pid, owned=true)');

      // Liaison Job Object pour garantie kernel d'arrêt automatique
      if (Platform.isWindows && _pid != null) {
        _bindProcessToJob(_pid!);
      }
    } catch (e) {
      Log.instance.e('memory-mgr', 'memory_server.exe launch failed: $e');
      _available = false;
      _owned     = false;
      _pid       = null;
      return false;
    }

    // 5. Drainer stdout/stderr pour éviter le blocage du pipe
    _process!.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) => Log.instance.d('memsvr-out', l), onError: (_) {});
    _process!.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) => Log.instance.d('memsvr-err', l), onError: (_) {});

    // 6. Détecter les sorties prématurées
    _process!.exitCode.then((code) {
      if (_owned && _process != null) {
        _process   = null;
        _available = false;
        _closeJob();
        Log.instance.w('memory-mgr',
            'memory_server.exe terminé prématurément (code=$code) — mémoire indisponible');
      }
    }).ignore();

    // 7. Readiness loop — polling adaptatif avec tolérance matériel lent (CORR-FIX1)
    final maxAttempts = TimeoutPolicy.memoryServerStartupMaxAttempts;
    final pollInterval = TimeoutPolicy.memoryServerPollInterval;
    for (int i = 0; i < maxAttempts; i++) {
      await Future<void>.delayed(pollInterval);
      if (_process == null) {
        Log.instance.e('memory-mgr', 'memory_server.exe crashé avant readiness');
        _available = false;
        _owned     = false;
        _pid       = null;
        _closeJob();
        return false;
      }
      if (await _isHealthy()) {
        _available = true;
        Log.instance.i('memory-mgr',
            'memory_server READY après ${(i + 1) * pollInterval.inMilliseconds} ms (PID=$_pid)');
        return true;
      }
    }

    // 8. Timeout readiness : nettoyer UNIQUEMENT son propre arbre
    Log.instance.e('memory-mgr',
        'memory_server readiness timeout (${TimeoutPolicy.memoryServerStartupTimeout.inSeconds} s) — nettoyage de son propre arbre PID=$_pid');
    await _killOwnedTree();
    _available = false;
    _owned     = false;
    _pid       = null;
    _process   = null;
    _closeJob();
    return false;
  }

  /// Arrête le serveur seulement s'il a été démarré par nous (_owned = true).
  /// Un serveur pré-existant / externe n'est JAMAIS touché.
  Future<void> stop() async {
    if (!_owned || _pid == null) {
      Log.instance.i('memory-mgr',
          'stop() appelé : serveur non détenu ou inactif — détachement sans arrêt');
      _process   = null;
      _pid       = null;
      _owned     = false;
      _available = false;
      _closeJob();
      return;
    }

    Log.instance.i('memory-mgr',
        'stop() : arrêt contrôlé de l\'arbre memory_server.exe owned (PID=$_pid)');
    await _killOwnedTree();
    _closeJob();
    _process   = null;
    _pid       = null;
    _owned     = false;
    _available = false;
  }

  /// Arrêt synchrone pour les hooks de sortie critique (dispose / shutdown).
  void stopSync() {
    if (!_owned || _pid == null) return;
    final targetPid = _pid!;
    Log.instance.i('memory-mgr', 'stopSync() : arrêt immédiat de l\'arbre PID=$targetPid');
    _process = null;
    _pid = null;
    _owned = false;
    _available = false;
    if (Platform.isWindows) {
      try {
        Process.runSync('taskkill', ['/PID', '$targetPid', '/T', '/F']);
      } catch (_) {}
    }
    _closeJob();
  }

  // ── Méthodes Internes ───────────────────────────────────────────────────────

  void _bindProcessToJob(int targetPid) {
    if (!Platform.isWindows) return;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final createJobObject = kernel32.lookupFunction<_CreateJobObjectWNative, _CreateJobObjectWDart>('CreateJobObjectW');
      final setInfoJob = kernel32.lookupFunction<_SetInformationJobObjectNative, _SetInformationJobObjectDart>('SetInformationJobObject');
      final openProc = kernel32.lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
      final assignProc = kernel32.lookupFunction<_AssignProcessToJobObjectNative, _AssignProcessToJobObjectDart>('AssignProcessToJobObject');
      final closeHandle = kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

      final hJob = createJobObject(nullptr, nullptr);
      if (hJob == 0) return;

      final pInfo = calloc<_JobObjectExtendedLimitInformation>();
      pInfo.ref.basicLimitInformation.limitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      final ok = setInfoJob(hJob, 9, pInfo.cast(), sizeOf<_JobObjectExtendedLimitInformation>());
      calloc.free(pInfo);

      if (ok != 0) {
        final hProc = openProc(0x0100 | 0x0001, 0, targetPid);
        if (hProc != 0) {
          assignProc(hJob, hProc);
          closeHandle(hProc);
          _hJob = hJob;
          Log.instance.i('memory-mgr', 'memory_server PID=$targetPid lié au Job Object Windows (kill-on-close)');
        } else {
          closeHandle(hJob);
        }
      } else {
        closeHandle(hJob);
      }
    } catch (e) {
      Log.instance.w('memory-mgr', 'Échec liaison Job Object: $e');
    }
  }

  void _closeJob() {
    if (_hJob != null && Platform.isWindows) {
      try {
        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final closeHandle = kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
        closeHandle(_hJob!);
      } catch (_) {}
      _hJob = null;
    }
  }

  Future<void> _killOwnedTree() async {
    final targetPid = _pid;
    if (targetPid == null) return;

    if (Platform.isWindows) {
      try {
        await Process.run(
          'taskkill',
          ['/PID', '$targetPid', '/T', '/F'],
        ).timeout(const Duration(seconds: 4));
        Log.instance.i('memory-mgr', 'taskkill /PID $targetPid /T /F exécuté avec succès');
      } catch (e) {
        Log.instance.w('memory-mgr', 'taskkill /PID $targetPid /T /F error: $e');
        try {
          _process?.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    } else {
      _process?.kill(ProcessSignal.sigterm);
    }
  }

  Future<bool> _isPortOccupied() async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        _kPort,
        timeout: const Duration(milliseconds: 300),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isHealthy() async {
    // Tente d'abord /health
    if (await _checkUrl(_kHealthFast)) return true;
    // Repli sur /memory/stats
    return await _checkUrl(_kHealthOld);
  }

  Future<bool> _checkUrl(String url) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 700);
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(milliseconds: 700));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200) {
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            final service = decoded['service'] as String? ?? '';
            final status = decoded['status'] as String? ?? '';
            // Rejeter explicitement tout démon tiers ou service factice
            if (service.contains('rogue') || service.contains('arbitrary')) {
              return false;
            }
            // Exiger l'identité formelle du Memory Server
            if (service.contains('Memory Server') ||
                (status == 'ok' && decoded.containsKey('facts') && decoded.containsKey('sessions')) ||
                decoded.containsKey('total_facts')) {
              return true;
            }
          }
        } catch (_) {
          return false;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// Provider singleton — une seule instance pour toute l'application.
final memoryServerManagerProvider = Provider<MemoryServerManager>((ref) {
  return MemoryServerManager();
});
