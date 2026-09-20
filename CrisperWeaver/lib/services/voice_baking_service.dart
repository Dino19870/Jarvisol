import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../main.dart' show modelServiceProvider;
import '../utils/app_paths.dart';
import 'log_service.dart';
import 'model_service.dart';
import '../utils/platform_utils.dart' as plat;

/// Wraps `tools/voice_bake/bake-chatterbox-voice-from-wav.py` which is
/// packaged under `Release/tools/voice_bake/` in production builds.
///
/// Spawns the bundled Python (`Release/python_bake/python.exe`) as a child
/// process, fully isolated from the LiteRT runtime Python.  Streams stdout +
/// stderr into the in-app log buffer and drops the resulting GGUF next to the
/// user's other voicepacks under `Release/data/models/whisper_cpp/`.
///
/// Production portability contract:
///   • `python_bake/python.exe`         — bundled Python 3.11 (CPU-only torch)
///   • `tools/voice_bake/bake-*.py`     — bake script
///   • `tools/voice_bake/chatterbox_weights/` — PyTorch snapshot offline
///   • `python_bake/voice_bake_manifest.json` — bundle integrity proof
///
/// Mobile (iOS / Android) has no Python runtime; this service throws a clear
/// "desktop-only" error there and the screen disables the Bake button
/// accordingly.
class VoiceBakingService {
  final ModelService modelService;
  VoiceBakingService(this.modelService);

  // ─────────────────────────────────────────────────────────────────────────
  // Bundle sentinel — manifest written by bundle_voice_bake.ps1
  // ─────────────────────────────────────────────────────────────────────────

  /// Absolute path to the manifest produced by the bundle script.
  static String get _manifestPath => p.join(
        AppPaths.appDir.path,
        'python_bake',
        'voice_bake_manifest.json',
      );

  /// True when the voice-bake bundle is present and its critical components
  /// (Python, script, weights) are accounted for by the manifest.
  ///
  /// In Debug builds we skip the manifest check so developers can exercise the
  /// screen without a full bundle (the fallback sibling checkout takes over).
  /// In Release builds the manifest must be present — its absence means the
  /// CMake bundle step was skipped or failed.
  static bool get isBundlePresent {
    if (kDebugMode) return true; // dev shortcut — no bundle required
    final manifest = File(_manifestPath);
    if (!manifest.existsSync()) return false;
    try {
      final raw = manifest.readAsStringSync();
      final m = Map<String, dynamic>.from(
          (raw.isNotEmpty ? (jsonDecode(raw) as Map?) ?? {} : {}));
      final cc = m['critical_components'] as Map? ?? {};
      // Every critical component listed in the manifest must be 'ok'.
      return cc.values.every((v) => v == 'ok');
    } catch (_) {
      return false;
    }
  }

  /// Whether voice baking is available on this device and correctly bundled.
  ///
  /// Returns false on mobile (no Python sandbox) and in Release builds when
  /// the bundle is absent or corrupt.  The screen reads this once on build to
  /// decide whether to show the bake UI at all.
  static bool get isSupported {
    if (!plat.isMacOS && !plat.isLinux && !plat.isWindows) return false;
    return isBundlePresent;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Default executable / script resolution
  // ─────────────────────────────────────────────────────────────────────────

  /// Path to the bundled Python interpreter.
  ///
  /// In Release: only the `python_bake/` candidate is used (portable, CPU-only
  /// torch, fully isolated from the LiteRT runtime Python).
  ///
  /// In Debug:   the developer's system `python` is also accepted as a
  ///             fallback so the screen can be exercised without a full bundle.
  static String get defaultPythonExecutable {
    if (Platform.isWindows) {
      // python_bake\ is a full venv copy — python.exe is in Scripts\ subfolder.
      final prod = p.join(AppPaths.appDir.path, 'python_bake', 'Scripts', 'python.exe');
      if (!kDebugMode) return prod; // Release: one canonical path, no fallback
      // Debug: prefer bundle if present, then fall back to system Python.
      if (File(prod).existsSync()) return prod;
      return 'python';
    } else {
      // macOS / Linux — bin/python3 standard venv layout
      final prod = p.join(AppPaths.appDir.path, 'python_bake', 'bin', 'python3');
      if (!kDebugMode) return prod;
      if (File(prod).existsSync()) return prod;
      return 'python3';
    }
  }

  /// Path to the bake script.
  ///
  /// In Release: `Release/tools/voice_bake/bake-chatterbox-voice-from-wav.py`
  /// is the only production path — it is installed by CMake from
  /// `scripts/bundle_voice_bake.ps1`.
  ///
  /// In Debug:   the sibling CrispASR checkout is accepted as a fallback.
  ///             This fallback is guarded by `kDebugMode` so it is inert in
  ///             any Release binary.
  static String get defaultScriptPath {
    final candidates = <String>[
      // Production path — installed by CMake bundle step.
      p.join(AppPaths.appDir.path, 'tools', 'voice_bake',
          'bake-chatterbox-voice-from-wav.py'),
      p.join(AppPaths.appDir.path, 'bake-chatterbox-voice-from-wav.py'),
      // ──────────────────────────────────────────────────────────────────
      // DEBUG-ONLY fallback: sibling CrispASR checkout.
      // This path is ONLY included when kDebugMode is true so it can NEVER
      // be resolved in a Release binary.  Production portability must never
      // depend on this entry.
      // ──────────────────────────────────────────────────────────────────
      if (kDebugMode)
        p.normalize(p.join(AppPaths.appDir.path, '..', 'CrispASR', 'models',
            'bake-chatterbox-voice-from-wav.py')),
    ];
    return candidates.firstWhere((path) => File(path).existsSync(),
        orElse: () => candidates.first);
  }

  /// Absolute path to the bundled Chatterbox PyTorch weights directory.
  /// Passed as `--model-dir` so the script never calls `from_pretrained()`
  /// and never contacts HuggingFace.
  ///
  /// In Debug without a bundle the path may not exist; the script will then
  /// fall back to `from_pretrained()` (requires Internet — acceptable in dev).
  static String get defaultModelDir =>
      p.join(AppPaths.appDir.path, 'tools', 'voice_bake', 'chatterbox_weights');

  // ─────────────────────────────────────────────────────────────────────────
  // Core bake method
  // ─────────────────────────────────────────────────────────────────────────

  /// Spawn the bake script, await completion, and return the produced GGUF.
  ///
  /// [voiceRightsAttested] MUST be true — it maps 1-to-1 to `--i-have-rights`
  /// on the script CLI, which is the legal consent gate for voice cloning.
  /// The method throws immediately if false, before spawning any process.
  ///
  /// [modelDir] overrides the default bundled weights path.  When null the
  /// default `tools/voice_bake/chatterbox_weights/` is used.
  ///
  /// Throws [VoiceBakingException] on every failure mode. The message is
  /// user-readable so the screen can drop it straight into a SnackBar.
  Future<File> bake({
    required String wavPath,
    required String outputName,
    required bool voiceRightsAttested,
    String? pythonExecutable,
    String? scriptPath,
    String? modelDir,
    double exaggeration = 0.5,
    void Function(String line)? onStdout,
  }) async {
    // ── Consent gate (biometric operation — must not be bypassed) ─────────
    if (!voiceRightsAttested) {
      throw const VoiceBakingException(
          'Voice cloning requires attestation of speaker consent. '
          'Check the consent checkbox before baking.');
    }

    if (!isSupported) {
      throw const VoiceBakingException(
          'Voice baking needs a desktop Python interpreter; '
          'mobile platforms have no Python runtime.');
    }

    final wav = File(wavPath);
    if (!await wav.exists()) {
      throw VoiceBakingException('Reference WAV not found: $wavPath');
    }

    final resolvedPython = (pythonExecutable?.trim().isNotEmpty == true)
        ? pythonExecutable!.trim()
        : defaultPythonExecutable;
    final resolvedScript = (scriptPath?.trim().isNotEmpty == true)
        ? scriptPath!.trim()
        : defaultScriptPath;
    final resolvedModelDir = (modelDir?.trim().isNotEmpty == true)
        ? modelDir!.trim()
        : defaultModelDir;

    final script = File(resolvedScript);
    if (!await script.exists()) {
      throw VoiceBakingException(
          'Bake script not found: $resolvedScript\n'
          'In Release builds the script must be packaged under '
          'Release/tools/voice_bake/ by the CMake bundle step.');
    }

    await modelService.initialize();
    final modelsDir = modelService.whisperCppDir();
    await Directory(modelsDir).create(recursive: true);

    final fileName =
        outputName.endsWith('.gguf') ? outputName : '$outputName.gguf';
    final outputPath = p.join(modelsDir, fileName);

    // ── Build argv ─────────────────────────────────────────────────────────
    final args = <String>[
      script.absolute.path,
      '--input', wav.absolute.path,
      '--output', outputPath,
      '--exaggeration', exaggeration.toStringAsFixed(2),
      // Always pass --model-dir so the script uses from_local() and never
      // calls from_pretrained() (which would contact HuggingFace at runtime).
      '--model-dir', resolvedModelDir,
      // Consent gate: only reached when voiceRightsAttested == true (checked
      // above). Never hardcoded — always conditional on the attestation param.
      '--i-have-rights',
    ];

    // ── Isolated environment — no HuggingFace network, no external Python ──
    final env = Map<String, String>.from(Platform.environment)
      ..['HF_HUB_OFFLINE'] = '1'
      ..['HF_DATASETS_OFFLINE'] = '1'
      ..['TRANSFORMERS_OFFLINE'] = '1'
      // Redirect any residual HF cache away from the user profile.
      ..['HF_HOME'] = p.join(AppPaths.appDir.path, 'python_bake', 'hf_cache')
      // Confine Python to the bundled site-packages (belt-and-suspenders).
      ..remove('PYTHONPATH')
      ..remove('PYTHONHOME');

    Log.instance.i('voice-bake', 'spawn', fields: {
      'python': resolvedPython,
      'script': script.absolute.path,
      'wav': wav.absolute.path,
      'out': outputPath,
      'model_dir': resolvedModelDir,
      'exag': exaggeration,
      'HF_HUB_OFFLINE': '1',
    });

    final Process proc;
    try {
      proc = await Process.start(
        resolvedPython,
        args,
        workingDirectory: p.dirname(resolvedPython),
        environment: env,
        runInShell: false,
      );
    } catch (e) {
      throw VoiceBakingException(
          '$resolvedPython failed to launch: $e\n'
          'A portable Python runtime must be packaged under '
          'Release/python_bake/.');
    }

    // ── Stream stdout + stderr live ────────────────────────────────────────
    final stdoutLines = <String>[];
    final stderrLines = <String>[];
    final stdoutDone = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      Log.instance.d('voice-bake', line);
      stdoutLines.add(line);
      onStdout?.call(line);
    }).asFuture<void>();
    final stderrDone = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      Log.instance.i('voice-bake', line);
      stderrLines.add(line);
      onStdout?.call(line);
    }).asFuture<void>();

    final exitCode = await proc.exitCode;
    await stdoutDone;
    await stderrDone;

    if (exitCode != 0) {
      final tail = stderrLines.length <= 6
          ? stderrLines
          : stderrLines.sublist(stderrLines.length - 6);
      throw VoiceBakingException(
          'bake-chatterbox-voice-from-wav.py exited $exitCode: '
          '${tail.join("; ")}');
    }

    final out = File(outputPath);
    if (!await out.exists()) {
      throw const VoiceBakingException(
          'Bake script reported success but no GGUF was produced. '
          'Check the Logs screen for details.');
    }
    Log.instance.i('voice-bake', 'baked',
        fields: {'path': outputPath, 'bytes': await out.length()});
    return out;
  }
}

/// Thrown by [VoiceBakingService.bake] for every failure mode.
/// The message is user-readable so the screen can drop it straight into a
/// SnackBar.
class VoiceBakingException implements Exception {
  final String message;
  const VoiceBakingException(this.message);
  @override
  String toString() => 'VoiceBakingException: $message';
}

final voiceBakingServiceProvider = Provider<VoiceBakingService>(
    (ref) => VoiceBakingService(ref.watch(modelServiceProvider)));
