import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../constants/timeout_policy.dart';
import 'litert_model_registry.dart';
import 'log_service.dart';
import 'settings_service.dart';
import '../utils/app_paths.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LiteRT launch helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Thrown when the portable LiteRT runtime is absent in a Release build.
/// Never falls back silently to a system-wide installation.
class LitertRuntimeMissingException implements Exception {
  final String message;
  const LitertRuntimeMissingException(this.message);
  @override
  String toString() => 'LitertRuntimeMissingException: $message';
}

/// Thrown/returned when the LiteRT server does not become ready in time.
class LitertServerNotReadyException implements Exception {
  final String message;
  const LitertServerNotReadyException(this.message);
  @override
  String toString() => 'LitertServerNotReadyException: $message';
}

/// Describes how to invoke the litert-lm server executable.
///
/// In portable mode (Release) the embedded Python interpreter is used:
///   exe  = .../runtime/litert_lm/python/python.exe
///   args = ['-m', 'litert_lm_cli.main']
///
/// In dev/fallback mode:
///   exe  = .../Scripts/litert-lm.exe   (Hermes venv or similar)
///   args = []
class _LitertLaunchConfig {
  final String exe;
  final List<String> prefixArgs; // prepended before ['serve','--port','9379']
  final Map<String, String> extraEnv; // e.g. PYTHONPATH for portable mode
  final String source; // 'portable' | 'hermes' | 'pipx' | 'user' | 'path'

  const _LitertLaunchConfig({
    required this.exe,
    this.prefixArgs = const [],
    this.extraEnv = const {},
    required this.source,
  });

  List<String> get serveArgs => [...prefixArgs, 'serve', '--port', '9379'];
}


/// Supported local and remote LLM providers.
enum LlmProvider {
  liteRtWindows,
  lmStudio,
  ollama,
  liteRtAndroid,
  custom,
}

extension LlmProviderExtension on LlmProvider {
  String get id {
    switch (this) {
      case LlmProvider.liteRtWindows:
        return 'litert_windows';
      case LlmProvider.lmStudio:
        return 'lmstudio';
      case LlmProvider.ollama:
        return 'ollama';
      case LlmProvider.liteRtAndroid:
        return 'litert_android';
      case LlmProvider.custom:
        return 'custom';
    }
  }

  String get displayName {
    switch (this) {
      case LlmProvider.liteRtWindows:
        return 'Google LiteRT-LM (Serveur Windows)';
      case LlmProvider.lmStudio:
        return 'LM Studio';
      case LlmProvider.ollama:
        return 'Ollama';
      case LlmProvider.liteRtAndroid:
        return 'Google LiteRT-LM (Embarqué Android)';
      case LlmProvider.custom:
        return 'Personnalisé (OpenAI)';
    }
  }

  String get defaultEndpoint {
    switch (this) {
      case LlmProvider.liteRtWindows:
        return 'http://127.0.0.1:9379/v1';
      case LlmProvider.lmStudio:
        return 'http://localhost:1234/v1';
      case LlmProvider.ollama:
        return 'http://localhost:11434/v1';
      case LlmProvider.liteRtAndroid:
        return 'local_litert';
      case LlmProvider.custom:
        return 'http://localhost:1234/v1';
    }
  }
}

/// A chat message exchanged with the LLM.
class LlmChatMessage {
  final String role; // 'system', 'user', 'assistant'
  final String content;
  final DateTime timestamp;
  final String? actionPrompt;
  /// Base64 de l'image jointe (format vision OpenAI), null si message texte pur.
  final String? imageBase64;
  final String imageMimeType;

  LlmChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.actionPrompt,
    this.imageBase64,
    this.imageMimeType = 'image/png',
  }) : timestamp = timestamp ?? DateTime.now();

  /// Retourne true si ce message contient une image.
  bool get hasImage => imageBase64 != null && imageBase64!.isNotEmpty;

  Map<String, dynamic> toJson() {
    if (hasImage) {
      // Format multimodal OpenAI-compatible (vision)
      return {
        'role': role,
        'content': [
          if (content.isNotEmpty) {'type': 'text', 'text': content},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:$imageMimeType;base64,$imageBase64'},
          },
        ],
      };
    }
    // Format texte classique
    return {
      'role': role,
      'content': content,
      if (actionPrompt != null) 'actionPrompt': actionPrompt,
    };
  }

  factory LlmChatMessage.fromJson(Map<String, dynamic> json) {
    // Supporte les deux formats : content String OU content Array (vision)
    final rawContent = json['content'];
    String textContent = '';
    String? img;
    String mime = 'image/png';
    if (rawContent is String) {
      textContent = rawContent;
    } else if (rawContent is List) {
      for (final part in rawContent) {
        if (part is Map) {
          if (part['type'] == 'text') textContent = part['text'] as String? ?? '';
          if (part['type'] == 'image_url') {
            final url = (part['image_url'] as Map?)?['url'] as String? ?? '';
            if (url.startsWith('data:')) {
              final comma = url.indexOf(',');
              if (comma > 0) {
                final header = url.substring(5, comma);
                final parts = header.split(';');
                mime = parts.isNotEmpty ? parts[0] : 'image/png';
                img = url.substring(comma + 1);
              }
            }
          }
        }
      }
    }
    return LlmChatMessage(
      role: json['role'] as String? ?? 'user',
      content: textContent,
      actionPrompt: json['actionPrompt'] as String?,
      imageBase64: img,
      imageMimeType: mime,
    );
  }
}

/// Résultat de la découverte dynamique des modèles sur un serveur LM Studio.
class LmStudioDiscoveryResult {
  final bool isOnline;
  final List<String> chatModels;
  final List<String> embeddingModels;
  final List<String> vlmModels;
  final Map<String, String> modelTypes;
  final String? errorMessage;

  const LmStudioDiscoveryResult({
    required this.isOnline,
    this.chatModels = const [],
    this.embeddingModels = const [],
    this.vlmModels = const [],
    this.modelTypes = const {},
    this.errorMessage,
  });

  /// Vrai si le serveur est en ligne et annonce au moins un modèle LLM/VLM de chat.
  bool get hasChatModels => isOnline && chatModels.isNotEmpty;

  /// Vrai si le serveur est en ligne et annonce au moins un modèle d'embedding.
  bool get hasEmbeddingModels => isOnline && embeddingModels.isNotEmpty;

  /// Indique si un modèle spécifique supporte Vision (type 'vlm').
  bool isVlm(String modelId) {
    if (vlmModels.contains(modelId)) return true;
    final t = modelTypes[modelId]?.toLowerCase();
    if (t == 'vlm' || t == 'vision') return true;
    // Heuristique de repli si le type n'a pas été retourné (ex: /v1/models au lieu de /api/v0/models)
    final lower = modelId.toLowerCase();
    return lower.contains('-vl') ||
        lower.contains('vision') ||
        lower.contains('pixtral') ||
        lower.contains('gemma-3n') ||
        lower.contains('gemma-4') ||
        lower.contains('qwen3.6') ||
        lower.contains('omni');
  }
}

/// Service that communicates with local/remote LLM backends (LM Studio, Ollama, etc.).
class LlmService {
  final SettingsService _settings;
  final http.Client _client;

  /// Cache en mémoire du dernier résultat de découverte LM Studio.
  static LmStudioDiscoveryResult? lastLmStudioDiscovery;

  LlmService(this._settings, {http.Client? client})
      : _client = client ?? http.Client();

  /// Normalized base endpoint without trailing slashes.
  String get endpoint {
    final custom = _settings.llmApiUrl;
    if (custom.isNotEmpty) {
      if (provider == LlmProvider.liteRtWindows) {
        if (custom.contains(':1234')) return LlmProvider.liteRtWindows.defaultEndpoint;
        return custom.replaceAll('localhost:9379', '127.0.0.1:9379').replaceAll(RegExp(r'/+$'), '');
      }
      if (provider == LlmProvider.lmStudio && custom.contains(':9379')) {
        return LlmProvider.lmStudio.defaultEndpoint;
      }
      return custom.replaceAll(RegExp(r'/+$'), '');
    }
    return provider.defaultEndpoint;
  }

  LlmProvider get provider => _settings.llmProvider;

  /// Check connection health and return true if reachable.
  Future<bool> checkConnection() async {
    try {
      final models = await getAvailableModels();
      return models.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// List available models from the local server.
  Future<List<String>> getAvailableModels() async {
    if (provider == LlmProvider.liteRtAndroid && Platform.isAndroid) {
      try {
        final res = await const MethodChannel('crisperweaver/litert_lm')
            .invokeListMethod<Map<dynamic, dynamic>>('listLocalModels');
        if (res != null) {
          return res.map((m) => m['path'].toString()).toList();
        }
      } catch (_) {}
      return [];
    }
    if (provider == LlmProvider.lmStudio) {
      final discovery = await discoverLmStudioModels(endpoint, client: _client);
      return discovery.chatModels;
    }
    return fetchModelsForEndpoint(endpoint);
  }

  /// Vérifie si le modèle actuellement sélectionné (ou passé en paramètre) prend en charge
  /// l'analyse d'images / Vision de manière adaptée à chaque fournisseur (LM Studio, LiteRT, etc.).
  Future<({bool isSupported, String activeModelId, String? reason})> checkVisionCapability({
    String? modelOverride,
  }) async {
    final activeModel = (modelOverride != null && modelOverride.isNotEmpty)
        ? modelOverride
        : _settings.llmModel;

    switch (provider) {
      case LlmProvider.lmStudio:
        if (activeModel.isEmpty) {
          return (
            isSupported: false,
            activeModelId: '',
            reason: '⚠️ Aucun modèle LM Studio n\'est actuellement sélectionné.',
          );
        }
        // Utiliser le cache de découverte ou sonder le serveur
        var discovery = lastLmStudioDiscovery;
        if (discovery == null || !discovery.isOnline || !discovery.chatModels.contains(activeModel)) {
          discovery = await discoverLmStudioModels(endpoint, client: _client);
        }

        if (!discovery.isOnline) {
          return (
            isSupported: false,
            activeModelId: activeModel,
            reason: '⚠️ Le serveur LM Studio ($endpoint) est indisponible ou ne répond pas.',
          );
        }

        // Vérifier si le modèle est un VLM reconnu
        final isVlmModel = discovery.isVlm(activeModel);
        if (isVlmModel) {
          return (
            isSupported: true,
            activeModelId: activeModel,
            reason: null,
          );
        } else {
          return (
            isSupported: false,
            activeModelId: activeModel,
            reason: '⚠️ Le modèle "$activeModel" ne supporte pas Vision.\n'
                'Sélectionnez un modèle multimodal VLM (ex : Gemma 4, Qwen 3.6 VLM) '
                'dans LM Studio ou les Paramètres → Modèle LLM.',
          );
        }

      case LlmProvider.liteRtWindows:
        final resolvedId = resolveWindowsModelId(activeModel);
        final visionOk = LiteRtModelEntry.hasVisionEncoder(resolvedId);
        if (visionOk) {
          return (
            isSupported: true,
            activeModelId: resolvedId,
            reason: null,
          );
        } else {
          return (
            isSupported: false,
            activeModelId: resolvedId,
            reason: '⚠️ Le modèle "$resolvedId" ne supporte pas Vision.\n'
                'Sélectionnez un modèle multimodal (ex : gemma-3n-e4b-it, gemma-3n-e2b-it) '
                'dans les Paramètres → Modèle LLM.',
          );
        }

      case LlmProvider.liteRtAndroid:
        final lower = activeModel.toLowerCase();
        final isMulti = lower.contains('3n') || lower.contains('vision') || lower.contains('vl');
        return (
          isSupported: isMulti,
          activeModelId: activeModel,
          reason: isMulti
              ? null
              : '⚠️ Le modèle "$activeModel" ne supporte pas Vision sur Android.',
        );

      case LlmProvider.ollama:
      case LlmProvider.custom:
        final lower = activeModel.toLowerCase();
        final isMulti = lower.contains('llava') ||
            lower.contains('vision') ||
            lower.contains('vl') ||
            lower.contains('pixtral') ||
            lower.contains('gpt-4') ||
            lower.contains('claude-3') ||
            lower.contains('gemini') ||
            lower.contains('gemma-3n') ||
            lower.contains('gemma-4') ||
            lower.contains('qwen3.6');
        return (
          isSupported: isMulti,
          activeModelId: activeModel,
          reason: isMulti
              ? null
              : '⚠️ Le modèle "$activeModel" ne semble pas supporter Vision.',
        );
    }
  }

  static Process? _litertProcess;

  /// Exit code of the last litert-lm process (null = running / never started).
  /// Set by the exitCode callback; used in the health-check loop to detect
  /// premature crashes without waiting for the full 30 s timeout.
  static int? _litertLastExitCode;

  // ───────────────────────────────────────────────────────────────────────────
  // Portable runtime resolution
  // ───────────────────────────────────────────────────────────────────────────

  /// Returns the launch configuration for the litert-lm server.
  ///
  /// Priority order:
  ///   1. Portable embedded runtime at  Release\runtime\litert_lm\  (always preferred)
  ///   2. In Release builds (kReleaseMode) → [LitertRuntimeMissingException] if absent
  /// Returns the launch configuration for the litert-lm server.
  ///
  /// Priority order:
  ///   1. Portable embedded runtime at Release\runtime\litert_lm\ or runtime\litert_lm\ (always preferred)
  ///   2. In Release builds → [LitertRuntimeMissingException] if absent
  ///   3. In Debug/dev builds → check hermes / pipx / local programs (AUD-LITERT-01: forbids host PATH fallback)
  static _LitertLaunchConfig _getLitertConfig() {
    final candidateDirs = <String>[];
    if (Platform.isWindows) {
      final appDir = p.dirname(Platform.resolvedExecutable);
      candidateDirs.add(p.join(appDir, 'runtime', 'litert_lm'));
      candidateDirs.add(p.join(appDir, 'runtime', 'litert'));
    }
    candidateDirs.add(p.join(Directory.current.path, 'runtime', 'litert_lm'));
    candidateDirs.add(p.join(Directory.current.path, 'runtime', 'litert'));
    candidateDirs.add(p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Release', 'runtime', 'litert_lm'));

    for (final baseDir in candidateDirs) {
      final portablePython = p.join(baseDir, 'python', 'python.exe');
      final portableSite = p.join(baseDir, 'site-packages');
      if (File(portablePython).existsSync()) {
        return _LitertLaunchConfig(
          exe: portablePython,
          prefixArgs: const ['-m', 'litert_lm_cli.main'],
          extraEnv: {'PYTHONPATH': portableSite},
          source: 'portable',
        );
      }
      final portableCli = p.join(baseDir, 'litert-lm.exe');
      if (File(portableCli).existsSync()) {
        return _LitertLaunchConfig(
          exe: portableCli,
          prefixArgs: const [],
          extraEnv: const {},
          source: 'portable',
        );
      }
    }

    // ── 2. Release build without portable runtime → hard fail ───────────────
    const isRelease = bool.fromEnvironment('dart.vm.product');
    if (isRelease) {
      throw LitertRuntimeMissingException(
        'LiteRT portable runtime absent de runtime/litert_lm/. '
        'Ce build Release requiert le runtime LiteRT portable embarqué.',
      );
    }

    // ── 3. Dev/debug fallback: hermes, pipx, local programs (excluding blind host PATH) ──
    final userProfile =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ??
        p.join(userProfile, r'AppData\Local');

    final devCandidates = <(String, String)>[
      (p.join(localAppData, r'hermes\hermes-agent\venv\Scripts\litert-lm.exe'), 'hermes'),
      (p.join(localAppData, r'pipx\venvs\litert-lm\Scripts\litert-lm.exe'),   'pipx'),
      (p.join(localAppData, r'Programs\litert-lm\litert-lm.exe'),              'programs'),
      (p.join(userProfile,  r'.local\bin\litert-lm.exe'),                      'user'),
    ];

    for (final (path, src) in devCandidates) {
      if (File(path).existsSync()) {
        return _LitertLaunchConfig(exe: path, source: src);
      }
    }

    // AUD-LITERT-01: Interdiction stricte de recourir silencieusement à litert-lm dans le PATH hôte
    throw LitertRuntimeMissingException(
      'Runtime LiteRT-LM introuvable : aucun runtime portable dans runtime/litert_lm/ '
      'ni environnement local hermes/pipx détecté (AUD-LITERT-01).',
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Server lifecycle
  // ───────────────────────────────────────────────────────────────────────────

  /// Kill the LiteRT background server — only if THIS app started it.
  ///
  /// Ownership indicator: `_litertProcess != null` means we started the server.
  ///   • If `_litertProcess == null` (pre-existing server or already exited): do nothing.
  ///   • If `_litertProcess != null`: kill with `taskkill /T /F` (entire process tree).
  ///     `/T` kills wrapper + all uvicorn worker descendants — no separate port-based
  ///     kill needed or wanted (a port-kill would be indiscriminate and could hit
  ///     servers not belonging to this process tree).
  ///
  /// A pre-existing server that was already listening on port 9379 before Jarvisol
  /// started is NEVER killed, even if Jarvisol used it for inference.
  static void stopWindowsServer() {
    if (!Platform.isWindows) return;
    final proc = _litertProcess;
    _litertProcess = null;
    _litertLastExitCode = null;

    if (proc == null) {
      // Either the server was pre-existing (we never set _litertProcess) or it
      // already exited and the exitCode callback nulled it.  Either way, nothing
      // to do — we do NOT own the process on port 9379.
      Log.instance.i(
        'llm',
        'stopWindowsServer: no owned LiteRT process — '
        'server was pre-existing or already exited, leaving port 9379 untouched',
      );
      return;
    }

    final pid = proc.pid;
    try {
      // /T → kill entire tree (wrapper + all uvicorn workers)
      Process.runSync('taskkill', ['/T', '/F', '/PID', '$pid'], runInShell: false);
      Log.instance.i('llm', 'LiteRT server stopped — process tree PID=$pid killed');
    } catch (e) {
      Log.instance.w('llm', 'taskkill /T /F failed for PID=$pid: $e — falling back to SIGKILL');
      try { proc.kill(); } catch (_) {}
    }
  }

  /// Ensure the local LiteRT-LM server is running on Windows.
  ///
  /// Returns `true` only when `GET /v1/models` responds HTTP 200.
  /// Returns `false` if:
  ///   • the runtime is missing (Release without bundle)
  ///   • the process exits before readiness
  ///   • the 30-second readiness window expires
  ///
  /// The caller MUST treat a `false` return as a hard failure and NOT
  /// proceed to POST /chat/completions.
  Future<bool> _ensureWindowsServerRunning() async {
    if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) {
      return true;
    }

    // ── Already up? (AUD-LLM-01 / TNR-068: probe HTTP /v1/models, not raw TCP) ──
    try {
      final res = await _client
          .get(Uri.parse('http://127.0.0.1:9379/v1/models'))
          .timeout(const Duration(milliseconds: 800));
      if (res.statusCode == 200) {
        if (_litertProcess != null) {
          Log.instance.d(
            'llm',
            'LiteRT already ready (PID=${_litertProcess!.pid}, owned by this app)',
          );
        } else {
          Log.instance.d(
            'llm',
            'LiteRT server already listening on port 9379 with HTTP 200 '
            '(pre-existing, NOT owned by Jarvisol — will NOT be stopped at exit)',
          );
        }
        return true;
      }
    } catch (_) {
      // Si la sonde HTTP échoue, vérifier si le port 9379 est occupé par un processus tiers
      try {
        final socket = await Socket.connect(
          '127.0.0.1', 9379,
          timeout: const Duration(milliseconds: 500),
        );
        socket.destroy();
        // Le port 9379 est ouvert en TCP mais ne répond pas au protocole HTTP /v1/models: occupant tiers!
        Log.instance.w(
          'llm',
          'Port 9379 occupé par un processus tiers ne répondant pas au protocole LiteRT /v1/models. '
          'Le processus tiers est préservé sans être tué (AUD-LLM-01 / TNR-068).',
        );
        return false;
      } catch (_) {
        // Le port 9379 est libre, on peut démarrer le serveur
      }
    }

    // ── Resolve runtime ──────────────────────────────────────────────────────
    final _LitertLaunchConfig config;
    try {
      config = _getLitertConfig();
    } on LitertRuntimeMissingException catch (e) {
      Log.instance.e('llm', e.message);
      return false;
    }

    // ── Build environment ────────────────────────────────────────────────────
    final portableHome = AppPaths.litertHomeDir.path;
    final env = Map<String, String>.from(Platform.environment)
      ..['USERPROFILE'] = portableHome
      ..['HOME'] = portableHome
      ..addAll(config.extraEnv); // e.g. PYTHONPATH for portable Python mode

    final fullArgs = config.serveArgs;

    // ── Log boot info (REQ-FINAL trace) ─────────────────────────────────────
    Log.instance.i('llm', 'Démarrage automatique du serveur LiteRT-LM Windows en arrière-plan...');
    Log.instance.i('llm', 'LiteRT runtime  source=${config.source}');
    Log.instance.i('llm', 'LiteRT exe      ${config.exe}');
    Log.instance.i('llm', 'LiteRT args     ${fullArgs.join(' ')}');
    Log.instance.i('llm', 'LiteRT HOME     $portableHome');

    // ── Start process ────────────────────────────────────────────────────────
    try {
      _litertLastExitCode = null;
      // ProcessStartMode.normal: conserve PID, stdout, stderr, exitCode et
      // ownership complet (taskkill /T /F). Pas de fenêtre console parasite :
      // Jarvisol est compilé en subsystème WINDOWS_GUI → CreateProcess sans
      // CREATE_NEW_CONSOLE.  detachedWithStdio levait "Bad state: Process is
      // detached" à l'accès de .exitCode et .pid sur Windows.
      _litertProcess = await Process.start(
        config.exe,
        fullArgs,
        environment: env,
        workingDirectory: p.dirname(Platform.resolvedExecutable),
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      Log.instance.e('llm', 'LiteRT Process.start failed: $e');
      return false;
    }

    final pid = _litertProcess!.pid;
    Log.instance.i('llm', 'LiteRT PID      $pid');

    // ── Drain stdout/stderr (prevent pipe deadlock, capture logs) ────────────
    _litertProcess!.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => Log.instance.d('litert-stdout', line),
          onError: (_) {},
          cancelOnError: false,
        );
    _litertProcess!.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => Log.instance.d('litert-stderr', line),
          onError: (_) {},
          cancelOnError: false,
        );

    // ── Monitor exit (fast-fail on premature crash) ──────────────────────────
    _litertProcess!.exitCode.then((code) {
      _litertLastExitCode = code;
      final wasRunning = _litertProcess != null;
      _litertProcess = null;
      if (wasRunning) {
        Log.instance.w(
          'llm',
          'LiteRT process PID=$pid exited prematurely with code=$code',
        );
      }
    }).ignore();

    // ── Readiness health-check loop (120 s / 240 × 500 ms while process is alive) ──
    const maxAttempts = TimeoutPolicy.litertStartupMaxAttempts; // 120 s total
    for (int i = 0; i < maxAttempts; i++) {
      // Fast-fail: process crashed before binding the port
      if (_litertProcess == null && _litertLastExitCode != null) {
        Log.instance.e(
          'llm',
          'LiteRT process exited before readiness '
          'PID=$pid exitCode=$_litertLastExitCode',
        );
        return false;
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));

      try {
        final res = await _client
            .get(Uri.parse('http://127.0.0.1:9379/v1/models'))
            .timeout(const Duration(milliseconds: 500));
        if (res.statusCode == 200) {
          Log.instance.i(
            'llm',
            'Serveur LiteRT-LM Windows prêt sur http://127.0.0.1:9379/v1 '
            '(tentative ${i + 1}/$maxAttempts)',
          );
          return true;
        }
        Log.instance.d(
          'llm',
          'LiteRT health-check attempt ${i + 1}: HTTP ${res.statusCode}',
        );
      } on SocketException catch (e) {
        Log.instance.d(
          'llm',
          'LiteRT health-check attempt ${i + 1}: port not yet open (${e.message})',
        );
      } on TimeoutException {
        Log.instance.d(
          'llm',
          'LiteRT health-check attempt ${i + 1}: connection timeout',
        );
      } catch (e) {
        Log.instance.w(
          'llm',
          'LiteRT health-check attempt ${i + 1}: unexpected error — $e',
        );
      }
    }

    Log.instance.e(
      'llm',
      'LiteRT server did not become ready within 120 s '
      '(PID=$pid exitCode=$_litertLastExitCode) — killing hung process tree and cleaning ownership (AUD-LLM-02 / TNR-069)',
    );
    stopWindowsServer();
    return false;
  }

  /// Run a CLI command via litert-lm with the portable USERPROFILE set.
  /// Returns stdout string or null on error.
  static Future<String?> runLitertCli(List<String> args) async {
    if (!Platform.isWindows) return null;
    try {
      final config = _getLitertConfig();
      final portableHome = AppPaths.litertHomeDir.path;
      final env = Map<String, String>.from(Platform.environment)
        ..['USERPROFILE'] = portableHome
        ..['HOME'] = portableHome
        ..addAll(config.extraEnv);
      final result = await Process.run(
        config.exe,
        [...config.prefixArgs, ...args],
        environment: env,
      );
      if (result.exitCode != 0) {
        Log.instance.w('llm', 'runLitertCli $args returned exitCode ${result.exitCode}: ${result.stderr}');
        return null;
      }
      return result.stdout as String;
    } catch (e) {
      Log.instance.d('llm', 'runLitertCli $args failed: $e');
      return null;
    }
  }

  /// Découvre dynamiquement les modèles disponibles sur un serveur LM Studio local ou distant.
  /// Interroge en priorité `/api/v0/models` pour exploiter les métadonnées de typage
  /// (ex: "type": "embeddings" vs "llm" / "vlm"), et bascule sur `/v1/models` si indisponible.
  /// Les modèles de chat et d'embeddings sont rigoureusement séparés.
  static Future<LmStudioDiscoveryResult> discoverLmStudioModels(
    String baseEndpoint, {
    Duration timeout = const Duration(seconds: 3),
    http.Client? client,
  }) async {
    final httpClient = client ?? http.Client();
    final shouldClose = client == null;

    try {
      // Normaliser l'URL de base pour obtenir l'origine http://host:port
      String rootOrigin = baseEndpoint.trim().replaceAll(RegExp(r'/+$'), '');
      try {
        final parsed = Uri.parse(rootOrigin);
        if (parsed.hasScheme && parsed.hasAuthority) {
          rootOrigin = '${parsed.scheme}://${parsed.authority}';
        }
      } catch (_) {}
      if (rootOrigin.endsWith('/v1')) {
        rootOrigin = rootOrigin.substring(0, rootOrigin.length - 3);
      }

      final List<String> chatModels = [];
      final List<String> embeddingModels = [];
      final List<String> vlmModels = [];
      final Map<String, String> modelTypes = {};

      // 1. Première tentative : /api/v0/models (spécifique LM Studio avec métadonnées de type)
      final v0Url = Uri.parse('$rootOrigin/api/v0/models');
      bool probedV0 = false;
      try {
        final res0 = await httpClient.get(
          v0Url,
          headers: {'Accept': 'application/json'},
        ).timeout(timeout);

        if (res0.statusCode == 200) {
          final decoded = jsonDecode(res0.body);
          List<dynamic> items = [];
          if (decoded is Map && decoded['data'] is List) {
            items = decoded['data'] as List;
          } else if (decoded is List) {
            items = decoded;
          }

          for (final item in items) {
            final id = item is Map ? (item['id']?.toString() ?? '') : item.toString();
            if (id.isEmpty) continue;
            final type = item is Map ? (item['type']?.toString().toLowerCase() ?? '') : '';
            if (type.isNotEmpty) {
              modelTypes[id] = type;
            }

            final isEmbedding = type == 'embeddings' ||
                type == 'embedding' ||
                id.toLowerCase().contains('embedding') ||
                id.toLowerCase().contains('embed-text') ||
                id.toLowerCase().startsWith('text-embedding-');

            if (isEmbedding) {
              if (!embeddingModels.contains(id)) embeddingModels.add(id);
            } else {
              if (!chatModels.contains(id)) chatModels.add(id);
              if (type == 'vlm' || type == 'vision') {
                if (!vlmModels.contains(id)) vlmModels.add(id);
              }
            }
          }
          probedV0 = true;
        }
      } catch (e) {
        // Si le serveur est hors-ligne (SocketException ou TimeoutException),
        // on retourne immédiatement le statut hors-ligne
        if (e is SocketException || e is TimeoutException) {
          final res = LmStudioDiscoveryResult(
            isOnline: false,
            chatModels: const [],
            embeddingModels: const [],
            vlmModels: const [],
            modelTypes: const {},
            errorMessage: e.toString(),
          );
          lastLmStudioDiscovery = res;
          return res;
        }
      }

      if (probedV0) {
        final res = LmStudioDiscoveryResult(
          isOnline: true,
          chatModels: chatModels,
          embeddingModels: embeddingModels,
          vlmModels: vlmModels,
          modelTypes: modelTypes,
        );
        lastLmStudioDiscovery = res;
        return res;
      }

      // 2. Repli / Fallback : /v1/models (compatible OpenAI standard)
      final v1Url = Uri.parse('$rootOrigin/v1/models');
      try {
        final res1 = await httpClient.get(
          v1Url,
          headers: {'Accept': 'application/json'},
        ).timeout(timeout);

        if (res1.statusCode == 200) {
          final decoded = jsonDecode(res1.body);
          List<dynamic> items = [];
          if (decoded is Map && decoded['data'] is List) {
            items = decoded['data'] as List;
          } else if (decoded is List) {
            items = decoded;
          }

          for (final item in items) {
            final id = item is Map ? (item['id']?.toString() ?? '') : item.toString();
            if (id.isEmpty) continue;

            final isEmbedding = id.toLowerCase().contains('embedding') ||
                id.toLowerCase().contains('embed-text') ||
                id.toLowerCase().startsWith('text-embedding-');

            if (isEmbedding) {
              if (!embeddingModels.contains(id)) embeddingModels.add(id);
            } else {
              if (!chatModels.contains(id)) chatModels.add(id);
              final lower = id.toLowerCase();
              if (lower.contains('-vl') ||
                  lower.contains('vision') ||
                  lower.contains('pixtral') ||
                  lower.contains('gemma-3n') ||
                  lower.contains('gemma-4') ||
                  lower.contains('qwen3.6') ||
                  lower.contains('omni')) {
                if (!vlmModels.contains(id)) vlmModels.add(id);
                modelTypes[id] = 'vlm';
              } else {
                modelTypes[id] = 'llm';
              }
            }
          }

          final res = LmStudioDiscoveryResult(
            isOnline: true,
            chatModels: chatModels,
            embeddingModels: embeddingModels,
            vlmModels: vlmModels,
            modelTypes: modelTypes,
          );
          lastLmStudioDiscovery = res;
          return res;
        }
      } catch (e) {
        final res = LmStudioDiscoveryResult(
          isOnline: false,
          chatModels: const [],
          embeddingModels: const [],
          vlmModels: const [],
          modelTypes: const {},
          errorMessage: e.toString(),
        );
        lastLmStudioDiscovery = res;
        return res;
      }

      const res = LmStudioDiscoveryResult(
        isOnline: false,
        chatModels: [],
        embeddingModels: [],
        vlmModels: [],
        modelTypes: {},
        errorMessage: 'Serveur injoignable ou code HTTP inattendu',
      );
      lastLmStudioDiscovery = res;
      return res;
    } finally {
      if (shouldClose) {
        httpClient.close();
      }
    }
  }

  /// List available models for any given base endpoint.
  Future<List<String>> fetchModelsForEndpoint(String baseEndpoint, {String? apiKey}) async {
    if (provider == LlmProvider.liteRtAndroid && Platform.isAndroid) {
      return getAvailableModels();
    }
    if (provider == LlmProvider.liteRtWindows) {
      await _ensureWindowsServerRunning();
    }
    if (provider == LlmProvider.lmStudio) {
      final discovery = await discoverLmStudioModels(baseEndpoint, client: _client);
      return discovery.chatModels;
    }
    final clean = baseEndpoint.trim().replaceAll(RegExp(r'/+$'), '');
    final url = '$clean/models';
    try {
      final res = await _client.get(
        Uri.parse(url),
        headers: _buildHeaders(overrideApiKey: apiKey),
      ).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['data'] is List) {
          final list = (data['data'] as List)
              .map((m) => m is Map ? (m['id']?.toString() ?? '') : '')
              .where((id) => id.isNotEmpty)
              .toList();
          return list;
        } else if (data is List) {
          final list = data
              .map((m) => m is Map ? (m['id']?.toString() ?? m['name']?.toString() ?? '') : m.toString())
              .where((id) => id.isNotEmpty)
              .toList();
          return list;
        }
      }
    } catch (e) {
      Log.instance.d('llm', 'fetchModelsForEndpoint failed for $url: $e');
    }
    return [];
  }

  /// Send a streaming chat completion request.
  Stream<String> streamChat({
    required List<LlmChatMessage> messages,
    String? model,
    double temperature = 0.7,
    int? maxTokens,
  }) async* {
    String targetModel = model ?? _settings.llmModel;

    if (provider == LlmProvider.liteRtWindows) {
      // ── Readiness guard ────────────────────────────────────────────────────
      // Only proceed to /chat/completions when the server is confirmed ready.
      // IMPORTANT: throw (not yield) — a yielded string would be stored in the
      // chat history as assistant content. The exception goes to onError in the
      // widget's stream.listen, which shows a transient SnackBar instead.
      final serverReady = await _ensureWindowsServerRunning();
      if (!serverReady) {
        throw const LitertServerNotReadyException(
          'Le serveur LiteRT-LM n\'a pas démarré dans les 30 secondes.\n'
          'Consultez les onglets 📜 Logs avec les filtres '
          '[litert-stdout] et [litert-stderr] pour le diagnostic complet.',
        );
      }

      final rawTarget = (model != null && model.isNotEmpty) ? model : _settings.llmModel;
      targetModel = resolveWindowsModelId(rawTarget);
      Log.instance.i('llm', 'Routage LiteRT Windows: modèle demandé="$model" (settings: "${_settings.llmModel}"), résolu="$targetModel" sur $endpoint');
    }
    if (provider == LlmProvider.liteRtAndroid && Platform.isAndroid) {
      // Construction du format de dialogue multi-tours adapté à la famille du modèle
      final buffer = StringBuffer();
      String? systemContext;
      for (final m in messages) {
        if (m.role == 'system') {
          systemContext = m.content;
          break;
        }
      }

      final activeModelLower = targetModel.toLowerCase();
      final isQwenOrDeepSeek = activeModelLower.contains('qwen') || activeModelLower.contains('deepseek');
      final isTinyGarden = activeModelLower.contains('tiny_garden') || activeModelLower.contains('mobile_actions') || activeModelLower.contains('garden');

      // Protection mémoire & budget tokens adapté (3000 car. pour modèles 1024 tokens, 14000 car. pour modèles 4096 tokens)
      final maxContextChars = isTinyGarden ? 3000 : 12000;
      if (systemContext != null && systemContext.length > maxContextChars) {
        systemContext = '${systemContext.substring(0, maxContextChars)}\n\n[... Début du document fourni ci-dessus pour analyse ...]';
      }

      if (isQwenOrDeepSeek) {
        // Gabarit ChatML (<|im_start|>) pour Qwen 2.5 et DeepSeek
        if (systemContext != null && systemContext.isNotEmpty) {
          buffer.writeln('<|im_start|>system');
          buffer.writeln(systemContext);
          buffer.writeln('<|im_end|>');
        }
        for (final m in messages) {
          if (m.role == 'system') continue;
          final role = m.role == 'user' ? 'user' : 'assistant';
          buffer.writeln('<|im_start|>$role');
          buffer.writeln(m.content);
          buffer.writeln('<|im_end|>');
        }
        buffer.write('<|im_start|>assistant\n');
      } else if (isTinyGarden) {
        // Gabarit Direct épuré pour TinyGarden
        if (systemContext != null && systemContext.isNotEmpty) {
          buffer.writeln('Contexte documentaire :');
          buffer.writeln(systemContext);
          buffer.writeln();
        }
        for (final m in messages) {
          if (m.role == 'system') continue;
          final role = m.role == 'user' ? 'Utilisateur' : 'Assistant';
          buffer.writeln('$role : ${m.content}');
        }
        buffer.write('Assistant : ');
      } else {
        // Format naturel pour Gemma 4 / Gemma 3 / Gemma 2
        // LiteRT-LM applique déjà le templating de dialogue en interne.
        if (systemContext != null && systemContext.isNotEmpty) {
          buffer.writeln(systemContext);
          buffer.writeln();
        }
        for (final m in messages) {
          if (m.role == 'system') continue;
          buffer.writeln(m.content);
        }
      }
      final prompt = buffer.toString();

      Log.instance.i('llm-litert', 'Lancement de la génération LiteRT sur Android (prompt: ${prompt.length} car., ${messages.length} messages dans l\'historique)');
      try {
        String? res;
        try {
          res = await const MethodChannel('crisperweaver/litert_lm')
              .invokeMethod<String>('generateResponse', {
            'prompt': prompt,
            'temperature': _settings.llmTemperature,
            'maxTokens': maxTokens ?? _settings.llmMaxTokens,
          });
        } on PlatformException catch (pe) {
          if (pe.code == 'not_initialized') {
            Log.instance.i('llm-litert', 'Auto-initialisation du modèle LiteRT sur Android...');
            final modelToLoad = _settings.llmModel.isNotEmpty ? _settings.llmModel : 'gemma-2b-it-gpu-int4.bin';
            await const MethodChannel('crisperweaver/litert_lm')
                .invokeMethod('initModel', {
              'modelPath': modelToLoad,
              'temperature': _settings.llmTemperature,
              'maxTokens': _settings.llmMaxTokens,
            });
            res = await const MethodChannel('crisperweaver/litert_lm')
                .invokeMethod<String>('generateResponse', {
              'prompt': prompt,
              'temperature': _settings.llmTemperature,
              'maxTokens': maxTokens ?? _settings.llmMaxTokens,
            });
          } else {
            rethrow;
          }
        }
        Log.instance.i('llm-litert', 'Génération LiteRT réussie (${res?.length ?? 0} caractères)');
        yield res ?? '';
      } catch (e, st) {
        Log.instance.e('llm-litert', 'Erreur LiteRT-LM', error: e, stack: st);
        yield '\n\n❌ Erreur LiteRT-LM : $e\nConsultez l\'onglet 📜 Logs & Diagnostics pour voir les détails.';
      }
      return;
    }

    final url = Uri.parse('$endpoint/chat/completions');
    final thinkingEnabled = _settings.getModelThinkingEnabled(targetModel);
    final isThinkingDisabled = !thinkingEnabled;

    final effectiveMessages = List<LlmChatMessage>.from(messages);
    if (isThinkingDisabled) {
      // Direct response directive for thinking models (DeepSeek-R1, Qwen-Thinking, LFM, etc.)
      final sysIdx = effectiveMessages.indexWhere((m) => m.role == 'system');
      const directive = '\n[Consigne absolue : Ne produis aucun bloc <think>, <thought> ni aucun préambule d\'analyse interne en anglais ("The user is asking..."). Réponds immédiatement, directement et uniquement en français.]';
      if (sysIdx >= 0) {
        effectiveMessages[sysIdx] = LlmChatMessage(
          role: 'system',
          content: '${effectiveMessages[sysIdx].content}$directive',
          timestamp: effectiveMessages[sysIdx].timestamp,
        );
      }
    }

    final isLiteRt = provider == LlmProvider.liteRtWindows || provider == LlmProvider.liteRtAndroid;
    final modelCapacity = _settings.getModelMaxTokens(targetModel);

    final wireModelName = (provider == LlmProvider.liteRtWindows)
        ? '$targetModel,gpu,$modelCapacity'
        : (targetModel.isNotEmpty ? targetModel : 'default');

    final payloadMap = <String, dynamic>{
      'model': wireModelName,
      'messages': effectiveMessages.map((m) => m.toJson()).toList(),
      'temperature': _settings.llmTemperature,
      if (!isLiteRt) 'frequency_penalty': 0.3,
      if (!isLiteRt) 'presence_penalty': 0.2,
      if (!isLiteRt) 'repetition_penalty': 1.15,
      'stream': true,
      'max_tokens': maxTokens ?? _settings.llmMaxTokens,
      if (!isLiteRt && isThinkingDisabled) 'thinking': false,
      if (!isLiteRt && isThinkingDisabled) 'chat_template_kwargs': {'thinking': false},
      if (!isLiteRt && isThinkingDisabled) 'reasoning_effort': 'none',
    };

    final bodyBytes = utf8.encode(jsonEncode(payloadMap));

    final hasImageAttachment = effectiveMessages.any((m) => m.hasImage);
    Log.instance.i('llm', 'Requête Chat/Vision : provider=${provider.id}, endpoint=$url, model=$wireModelName, image_attached=$hasImageAttachment');

    final nativeClient = HttpClient();
    HttpClientResponse res;
    try {
      final req = await nativeClient.postUrl(url);
      _buildHeaders().forEach((k, v) {
        req.headers.set(k, v);
      });
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.headers.set('Accept', 'text/event-stream, */*');
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      res = await req.close();
    } catch (e) {
      nativeClient.close();
      Log.instance.e('llm-stream', 'Erreur ouverture HTTP vers $url', error: e);
      yield '❌ Impossible de se connecter au serveur LLM sur $endpoint ($e). Vérifiez que le serveur est démarré.';
      return;
    }

    if (res.statusCode != 200) {
      final body = await res.transform(utf8.decoder).join();
      Log.instance.w('llm-stream', 'Stream error ${res.statusCode}: $body');
      yield '❌ Erreur ${res.statusCode} du serveur LLM : $body';
      return;
    }

    String lastLine = '';
    int duplicateLineCount = 0;
    final accumulatedBuffer = StringBuffer();

    try {
      final lines = res
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed == 'data: [DONE]' || trimmed == 'data:[DONE]') break;
        if (trimmed.startsWith('data:') || trimmed.startsWith('data :')) {
          final jsonStr = trimmed.substring(trimmed.indexOf(':') + 1).trim();
          if (jsonStr == '[DONE]') break;
          try {
            final data = jsonDecode(jsonStr);
            if (data is Map && data['error'] != null) {
              final err = data['error'].toString();
              Log.instance.e('llm-stream', 'Erreur SSE du serveur LLM: $err');
              yield '\n\n❌ Erreur du serveur LLM : $err';
              break;
            }
            if (data is Map && data['choices'] is List && (data['choices'] as List).isNotEmpty) {
              final choice = data['choices'][0];
              final delta = choice['delta'];
              String? chunk;
              if (delta is Map) {
                chunk = isThinkingDisabled
                    ? (delta['content'] ?? delta['text'])?.toString()
                    : (delta['content'] ?? delta['reasoning_content'] ?? delta['text'])?.toString();
              } else if (choice['text'] != null) {
                chunk = choice['text'].toString();
              }
              if (chunk != null && chunk.isNotEmpty) {
                accumulatedBuffer.write(chunk);
                if (chunk.contains('\n')) {
                  final fullText = accumulatedBuffer.toString();
                  final allLines = fullText.split('\n');
                  if (allLines.length >= 2) {
                    final prevLine = allLines[allLines.length - 2].trim();
                    if (prevLine.length > 15 && prevLine == lastLine) {
                      duplicateLineCount++;
                      if (duplicateLineCount >= 3) {
                        Log.instance.w('llm-stream', 'Disjoncteur anti-boucle activé : ligne répétée 3 fois de suite, interruption.');
                        break;
                      }
                    } else {
                      duplicateLineCount = 0;
                      if (prevLine.isNotEmpty) lastLine = prevLine;
                    }
                  }
                }
                yield chunk;
              }
            }
          } catch (_) {
            // ignore non-json SSE frames
          }
        } else if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
          try {
            final data = jsonDecode(trimmed);
            if (data is Map && data['choices'] is List && (data['choices'] as List).isNotEmpty) {
              final choice = data['choices'][0];
              final text = choice['message']?['content'] ?? choice['text'];
              if (text != null && text.toString().isNotEmpty) {
                yield text.toString();
              }
            }
          } catch (_) {}
        }
      }
    } finally {
      nativeClient.close();
    }
  }

  /// Send a non-streaming completion.
  Future<String> completeChat({
    required List<LlmChatMessage> messages,
    String? model,
    double temperature = 0.7,
  }) async {
    String targetModel = model ?? _settings.llmModel;

    if (provider == LlmProvider.liteRtWindows) {
      final serverReady = await _ensureWindowsServerRunning();
      if (!serverReady) {
        throw const LitertServerNotReadyException(
          'Le serveur LiteRT-LM n\'a pas démarré dans les 30 secondes.',
        );
      }
      final rawTarget = (model != null && model.isNotEmpty) ? model : _settings.llmModel;
      targetModel = resolveWindowsModelId(rawTarget);
      Log.instance.i('llm', 'Routage LiteRT Windows (completeChat): modèle demandé="$model" (settings: "${_settings.llmModel}"), résolu="$targetModel" sur $endpoint');
    }

    final url = '$endpoint/chat/completions';

    final res = await _client.post(
      Uri.parse(url),
      headers: _buildHeaders(),
      body: jsonEncode({
        if (targetModel.isNotEmpty) 'model': targetModel,
        'messages': messages.map((m) => m.toJson()).toList(),
        'temperature': temperature,
        'stream': false,
      }),
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      if (data is Map && data['choices'] is List && (data['choices'] as List).isNotEmpty) {
        final msg = data['choices'][0]['message'];
        if (msg is Map && msg['content'] != null) {
          return msg['content'].toString();
        }
      }
    }
    throw Exception('LLM error ${res.statusCode}: ${res.body}');
  }

  Map<String, String> _buildHeaders({String? overrideApiKey}) {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final key = (overrideApiKey != null && overrideApiKey.isNotEmpty) ? overrideApiKey : _settings.llmApiKey;
    if (key.isNotEmpty) {
      headers['Authorization'] = 'Bearer $key';
    }
    return headers;
  }

  /// Resolves a raw model ID / path to the canonical LiteRT-LM model identifier
  /// expected by the server (e.g. the directory name under `.litert-lm/models/`).
  ///
  /// Rules are ordered most-specific-first so that gemma-3n-* variants are
  /// never shadowed by broader patterns such as `contains('e4b')`.
  ///
  /// The method is intentionally static and pure (no I/O, no state) so that it
  /// can be exercised by unit tests without spinning up a real LlmService.
  static String resolveWindowsModelId(String rawId) {
    // Normalise: strip path, lowercase, collapse spaces/underscores to hyphens.
    final cleanId = p
        .basenameWithoutExtension(rawId)
        .toLowerCase()
        .replaceAll(RegExp(r'[\s_]+'), '-');

    // ── Gemma 3n (multimodal) — must come BEFORE any generic 'e4b' / 'gemma' ──
    if (cleanId.contains('gemma-3n-e4b') || cleanId.contains('3n-e4b')) {
      return 'gemma-3n-E4B-IT';
    }
    if (cleanId.contains('gemma-3n-e2b') ||
        cleanId.contains('3n-e2b') ||
        cleanId.contains('3n')) {
      return 'gemma-3n-e2b-it';
    }

    // ── Gemma 4 / other ──────────────────────────────────────────────────────
    if (cleanId == 'gemma-4-12b-it-gpu' ||
        cleanId == 'gemma-4-12b' ||
        cleanId.contains('12b')) {
      return 'gemma-4-12B-it-gpu';
    }
    if (cleanId == 'gemma-4-e4b-it' ||
        cleanId == 'gemma-4-e4b' ||
        cleanId == '4-e4b-it' ||
        cleanId == '4-e4b' ||
        cleanId.contains('e4b')) {
      return 'gemma-4-e4b-it';
    }
    if (cleanId.contains('gemma-4-e2b') ||
        cleanId.contains('4-e2b') ||
        cleanId == 'gemma-4-gpu') {
      return 'gemma-4-gpu';
    }
    if (cleanId.contains('gemma-3-1b') || cleanId.contains('3-1b')) {
      return 'gemma-3-1b-it';
    }
    if (cleanId.contains('gemma-2b') || cleanId.contains('2b-it')) {
      return 'gemma-2b-it';
    }
    if (cleanId.contains('gemma')) return 'gemma-4-e4b-it';

    // ── Other model families ─────────────────────────────────────────────────
    if (cleanId.contains('deepseek') || cleanId.contains('r1')) {
      return 'deepseek-r1-distill-qwen-1.5b';
    }
    if (cleanId.contains('mobile') || cleanId.contains('action')) {
      return 'mobile-actions-270m';
    }
    if (cleanId.contains('tiny') || cleanId.contains('garden')) {
      return 'tiny-garden-270m';
    }
    if (cleanId.contains('qwen')) return 'qwen-2.5-1.5b-instruct';

    // ── Passthrough: return the raw value as-is if nothing matched ───────────
    return rawId.isNotEmpty ? rawId : 'gemma-4-e4b-it';
  }
}

/// Riverpod provider for LlmService.
final llmServiceProvider = Provider<LlmService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  return LlmService(settings);
});
