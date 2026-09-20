import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/platform_utils.dart' as plat;
import 'package:shared_preferences/shared_preferences.dart';
import '../engines/engine_factory.dart';
import '../services/hotkey_service.dart' show HotkeyAction;
import '../services/log_service.dart';
import 'document_rag_service.dart' show RagSearchMode;
import 'llm_service.dart' show LlmProvider, LlmProviderExtension;

/// Central service for managing application settings and persistence.
class SettingsService {
  final SharedPreferences _prefs;

  SettingsService(this._prefs);

  // --- Transcription Settings ---

  EngineType get preferredEngine {
    final id = _prefs.getString('preferred_engine');
    return EngineType.values.firstWhere(
      (e) => e.id == id,
      orElse: () => EngineFactory.getRecommendedEngine(),
    );
  }

  set preferredEngine(EngineType type) {
    Log.instance.d('settings', 'Saving preferredEngine: ${type.id}');
    _prefs.setString('preferred_engine', type.id);

  }

  String get defaultModel => _prefs.getString('default_model') ?? 'base';
  set defaultModel(String model) {
    Log.instance.d('settings', 'Saving defaultModel: $model');
    _prefs.setString('default_model', model);

  }

  String get defaultBackend => _prefs.getString('default_backend') ?? 'whisper';
  set defaultBackend(String backend) {
    Log.instance.d('settings', 'Saving defaultBackend: $backend');
    _prefs.setString('default_backend', backend);

  }

  String get defaultLanguage => _prefs.getString('default_language') ?? 'auto';
  set defaultLanguage(String lang) {
    Log.instance.d('settings', 'Saving defaultLanguage: $lang');
    _prefs.setString('default_language', lang);

  }

  bool get autoDetectLanguage => _prefs.getBool('auto_detect_language') ?? true;
  set autoDetectLanguage(bool value) {
    Log.instance.d('settings', 'Saving autoDetectLanguage: $value');
    _prefs.setBool('auto_detect_language', value);

  }

  bool get enableWordTimestamps =>
      _prefs.getBool('enable_word_timestamps') ?? false;
  set enableWordTimestamps(bool value) {
    Log.instance.d('settings', 'Saving enableWordTimestamps: $value');
    _prefs.setBool('enable_word_timestamps', value);

  }

  // --- Audio Settings ---

  double get audioQuality => _prefs.getDouble('audio_quality') ?? 0.8;
  set audioQuality(double value) {
    Log.instance.d('settings', 'Saving audioQuality: $value');
    _prefs.setDouble('audio_quality', value);

  }

  bool get keepAudioFiles => _prefs.getBool('keep_audio_files') ?? false;
  set keepAudioFiles(bool value) {
    Log.instance.d('settings', 'Saving keepAudioFiles: $value');
    _prefs.setBool('keep_audio_files', value);

  }

  // --- Diarization Settings ---

  bool get enableDiarizationByDefault =>
      _prefs.getBool('enable_diarization_by_default') ?? false;
  set enableDiarizationByDefault(bool value) {
    Log.instance.d('settings', 'Saving enableDiarizationByDefault: $value');
    _prefs.setBool('enable_diarization_by_default', value);

  }

  // --- App Locale (i18n) ---

  String? get appLocale => _prefs.getString('app_locale');
  set appLocale(String? locale) {
    Log.instance.d('settings', 'Saving appLocale: $locale');
    if (locale == null || locale.isEmpty) {
      _prefs.remove('app_locale');
    } else {
      _prefs.setString('app_locale', locale);
    }

  }

  // --- Developer / Debug Settings ---

  LogLevel get logLevel {
    final levelName = _prefs.getString('log_level');
    return LogLevel.values.firstWhere(
      (l) => l.name == levelName,
      orElse: () => LogLevel.info,
    );
  }

  set logLevel(LogLevel level) {
    Log.instance.d('settings', 'Saving logLevel: ${level.name}');
    _prefs.setString('log_level', level.name);

  }

  bool get logToFile => _prefs.getBool('log_to_file') ?? false;
  set logToFile(bool value) {
    Log.instance.d('settings', 'Saving logToFile: $value');
    _prefs.setBool('log_to_file', value);

  }

  bool get skipChecksum => _prefs.getBool('skip_checksum') ?? false;
  set skipChecksum(bool value) {
    Log.instance.d('settings', 'Saving skipChecksum: $value');
    _prefs.setBool('skip_checksum', value);

  }

  String get hfToken => _prefs.getString('hf_token') ?? '';
  set hfToken(String token) {
    Log.instance
        .d('settings', 'Saving hfToken: ${token.isNotEmpty ? "SET" : "EMPTY"}');
    _prefs.setString('hf_token', token);

  }

  /// User-added HuggingFace repos for the "Add from HuggingFace repo"
  /// direct-download flow. Persisted as a JSON list of
  /// `{repoId, backend, displayPrefix?}` maps so they survive a restart;
  /// ModelService replays each through `probeHfRepoForBackend` on
  /// initialize. Entries are keyed by the (repoId, backend) pair.
  List<Map<String, String>> get hfUserRepos {
    final raw = _prefs.getString('hf_user_repos');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((m) =>
              m.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
          .where((m) =>
              (m['repoId'] ?? '').isNotEmpty && (m['backend'] ?? '').isNotEmpty)
          .toList();
    } catch (e) {
      Log.instance.w('settings', 'hfUserRepos decode failed — ignoring',
          error: e);
      return const [];
    }
  }

  set hfUserRepos(List<Map<String, String>> repos) {
    _prefs.setString('hf_user_repos', jsonEncode(repos));

  }

  /// Add or replace a user HF repo entry (idempotent on the
  /// repoId+backend key).
  void addHfUserRepo(String repoId, String backend, {String? displayPrefix}) {
    final list = List<Map<String, String>>.from(hfUserRepos)
      ..removeWhere((m) => m['repoId'] == repoId && m['backend'] == backend);
    final entry = <String, String>{'repoId': repoId, 'backend': backend};
    if (displayPrefix != null && displayPrefix.isNotEmpty) {
      entry['displayPrefix'] = displayPrefix;
    }
    list.add(entry);
    hfUserRepos = list;
  }

  /// Forget a previously-added user HF repo.
  void removeHfUserRepo(String repoId, String backend) {
    final list = List<Map<String, String>>.from(hfUserRepos)
      ..removeWhere((m) => m['repoId'] == repoId && m['backend'] == backend);
    hfUserRepos = list;
  }

  /// Override directory for model GGUFs / .bin files. Empty / null
  /// means "use the platform-default `<app-docs>/models/whisper_cpp`".
  /// Useful for users who keep a shared library on an external disk
  /// (e.g. `/Volumes/backups/ai/crispasr-models`) and don't want
  /// CrisperWeaver to re-download every quant into its sandbox.
  ///
  /// ModelService.getModelsDirOverride reads this on every call so the
  /// effect is live — change the setting and the next download lands
  /// at the new path without an app restart.
  String get customModelsDir => _prefs.getString('custom_models_dir') ?? '';
  set customModelsDir(String dir) {
    Log.instance.d('settings',
        'Saving customModelsDir: ${dir.isEmpty ? "DEFAULT" : dir}');
    _prefs.setString('custom_models_dir', dir);

  }

  /// Reorder a batch queue so jobs with the same
  /// (backend, modelId, language) run consecutively, sparing the
  /// expensive session swap between them. Stable — preserves the
  /// enqueue order within each bundle. Default off so the user's
  /// drag-and-drop order is honoured verbatim by the drain loop.
  /// §5.23 Q1 grouping sub-bullet.
  bool get groupBatchByBackend =>
      _prefs.getBool('group_batch_by_backend') ?? false;
  set groupBatchByBackend(bool value) {
    Log.instance.d('settings', 'Saving groupBatchByBackend: $value');
    _prefs.setBool('group_batch_by_backend', value);

  }

  /// How many transcription jobs the drain loop runs in pipeline-
  /// parallel mode (§5.23 Q2). Stored as 1..[maxConcurrentLimit].
  ///
  /// v1 (shipped): "pipeline parallelism" — slider > 1 enables
  /// async audio prefetch of the next queued file in a worker
  /// isolate, overlapping its decode + Mel computation with the
  /// current file's GPU transcription. One session, one model
  /// copy in RAM, real-world speedup of 5–15% on batches of
  /// compressed audio (mp3 / m4a / opus) where decode is a non-
  /// trivial slice of total wall time.
  ///
  /// v2 (deferred — see PLAN §5.23): true N-way session pool with
  /// per-isolate `CrispasrSession` instances. Memory cost is
  /// N × model size; gated behind a future "I have RAM to burn"
  /// affordance.
  int get maxConcurrentTranscriptions {
    final raw = _prefs.getInt('max_concurrent_transcriptions') ?? 1;
    if (raw < 1) return 1;
    final cap = maxConcurrentTranscriptionsLimit;
    return raw > cap ? cap : raw;
  }

  set maxConcurrentTranscriptions(int value) {
    final cap = maxConcurrentTranscriptionsLimit;
    final clamped = value < 1 ? 1 : (value > cap ? cap : value);
    Log.instance.d('settings',
        'Saving maxConcurrentTranscriptions: $clamped (requested $value, cap $cap)');
    _prefs.setInt('max_concurrent_transcriptions', clamped);

  }

  /// Per-platform upper bound for the concurrent-transcriptions
  /// slider. iOS caps at 2 because of the tight memory budget on
  /// even the largest iPhone (8 GB); desktop/Android caps at 4
  /// because beyond that Metal queue contention dominates and the
  /// marginal speedup tapers.
  int get maxConcurrentTranscriptionsLimit => plat.isIOS ? 2 : 4;

  /// How many *true* parallel session workers the drain loop spawns
  /// (§5.23 Q2 v2). 1 = no pool (the v1 prefetch is what the other
  /// slider controls). 2+ spins up N persistent worker isolates,
  /// each holding its own CrispasrSession against the same model.
  /// Real GPU + decoder concurrency; cost is N × model size in RAM.
  ///
  /// At batch start the drain loop runs `MemoryEstimator.estimate`
  /// against the active model + this slider value, and clamps the
  /// actual worker count down to what fits in
  /// `physicalMemory × 50% − 400 MB`. The user-set value is what's
  /// requested; the actual spawn count is what's affordable.
  int get maxConcurrentSessions {
    final raw = _prefs.getInt('max_concurrent_sessions') ?? 1;
    if (raw < 1) return 1;
    final cap = maxConcurrentSessionsLimit;
    return raw > cap ? cap : raw;
  }

  set maxConcurrentSessions(int value) {
    final cap = maxConcurrentSessionsLimit;
    final clamped = value < 1 ? 1 : (value > cap ? cap : value);
    Log.instance.d('settings',
        'Saving maxConcurrentSessions: $clamped (requested $value, cap $cap)');
    _prefs.setInt('max_concurrent_sessions', clamped);

  }

  /// Same per-platform shape as the prefetch slider — iOS caps at 2
  /// (very tight memory), everything else at 4 (beyond which Metal
  /// queue contention dominates). The pre-flight check may clamp
  /// lower at runtime when the chosen model is too big.
  int get maxConcurrentSessionsLimit => plat.isIOS ? 2 : 4;

  // --- §5.1.6 v2 Cloud-LLM cleanup (BYOK) ---

  /// OpenAI-compatible /v1/chat/completions endpoint. Empty
  /// means "feature off"; the Tidy dialog hides the LLM-pass
  /// toggle when this is empty. Defaults to OpenAI's public
  /// endpoint to nudge users into a known-good shape; can be
  /// pointed at any other compatible server (Anthropic via
  /// proxy, local llama-server, OpenRouter, Groq, etc.).
  String get cloudLlmApiUrl =>
      _prefs.getString('cloud_llm_api_url') ?? '';
  set cloudLlmApiUrl(String url) {
    Log.instance.d('settings',
        'Saving cloudLlmApiUrl: ${url.isEmpty ? "EMPTY" : url}');
    _prefs.setString('cloud_llm_api_url', url);

  }

  // --- HF Space / Cloud ASR ---
  static const _defaultHfSpaceUrl = 'https://cstr-crispasr.hf.space';
  String get hfSpaceUrl =>
      _prefs.getString('hf_space_url') ?? _defaultHfSpaceUrl;
  set hfSpaceUrl(String url) {
    _prefs.setString('hf_space_url', url);

  }

  /// API key — pasted by the user. Logged only as SET/EMPTY
  /// to avoid leaking into telemetry. Stored in
  /// SharedPreferences (platform-default; encrypted on iOS via
  /// the keychain integration, plain JSON in app-support on
  /// other platforms). For real secret storage we'd reach for
  /// flutter_secure_storage — out of scope for the v1
  /// opt-in cleanup feature.
  String get cloudLlmApiKey =>
      _prefs.getString('cloud_llm_api_key') ?? '';
  set cloudLlmApiKey(String key) {
    Log.instance.d('settings',
        'Saving cloudLlmApiKey: ${key.isEmpty ? "EMPTY" : "SET"}');
    _prefs.setString('cloud_llm_api_key', key);

  }

  /// Model id sent in the chat-completions request body.
  /// Default "gpt-4o-mini" — small, fast, cheap; users
  /// pointing at non-OpenAI endpoints override per their
  /// catalog (e.g. "claude-3-5-haiku-20241022" via proxy,
  /// "llama-3.1-8b-instruct" on local llama-server, …).
  String get cloudLlmModel =>
      _prefs.getString('cloud_llm_model') ?? 'gpt-4o-mini';
  set cloudLlmModel(String model) {
    Log.instance.d('settings', 'Saving cloudLlmModel: $model');
    _prefs.setString('cloud_llm_model', model);

  }

  // --- §5.1.6 v3 Local-LLM cleanup ---

  /// Which LLM path Tidy / Summarize routes through. Single
  /// source of truth — the three-mode UI selector writes here,
  /// and downstream code reads this to pick between the cloud
  /// service, the local service, or no LLM pass at all.
  /// Stored as the enum name so an order shuffle doesn't break
  /// existing installs.
  LlmCleanupMode get llmCleanupMode {
    final raw = _prefs.getString('llm_cleanup_mode');
    if (raw == null) return LlmCleanupMode.off;
    for (final v in LlmCleanupMode.values) {
      if (v.name == raw) return v;
    }
    return LlmCleanupMode.off;
  }

  set llmCleanupMode(LlmCleanupMode mode) {
    Log.instance.d('settings', 'Saving llmCleanupMode: ${mode.name}');
    _prefs.setString('llm_cleanup_mode', mode.name);

  }

  /// Absolute path to a GGUF chat model. Empty means "no model
  /// configured" — the Tidy dialog's "Local" affordance hides /
  /// disables until this is set. We don't curate a list of
  /// models here; the Settings screen surfaces a file picker
  /// and the user points at any GGUF on disk. A curated
  /// catalogue with downloads lands in §5.1.6 v3.1.
  String get localLlmModelPath =>
      _prefs.getString('local_llm_model_path') ?? '';
  set localLlmModelPath(String path) {
    Log.instance.d('settings',
        'Saving localLlmModelPath: ${path.isEmpty ? "EMPTY" : path}');
    _prefs.setString('local_llm_model_path', path);

  }

  /// `-1` = all layers on GPU (default — Metal on macOS, CUDA
  /// on Linux/Windows when present, CPU fallback otherwise).
  /// `0` = CPU only; positive int = partial offload. Stored as
  /// int so the user-facing slider in Settings can write it
  /// without per-platform branching here.
  int get localLlmNGpuLayers =>
      _prefs.getInt('local_llm_n_gpu_layers') ?? -1;
  set localLlmNGpuLayers(int n) {
    Log.instance.d('settings', 'Saving localLlmNGpuLayers: $n');
    _prefs.setInt('local_llm_n_gpu_layers', n);

  }

  /// Context window in tokens. 0 means "use the GGUF's baked-in
  /// default" — the binding interprets that as `null` upstream
  /// and lets the model pick. Bumping this is the lever a user
  /// pulls when summarising long transcripts.
  int get localLlmNCtx => _prefs.getInt('local_llm_n_ctx') ?? 0;
  set localLlmNCtx(int n) {
    Log.instance.d('settings', 'Saving localLlmNCtx: $n');
    _prefs.setInt('local_llm_n_ctx', n);

  }

  /// Generation threads. 0 = upstream's default (physical-cores cap).
  int get localLlmNThreads => _prefs.getInt('local_llm_n_threads') ?? 0;
  set localLlmNThreads(int n) {
    Log.instance.d('settings', 'Saving localLlmNThreads: $n');
    _prefs.setInt('local_llm_n_threads', n);

  }

  /// Per-call output cap. Smaller than the cloud default
  /// (1024) because per-segment cleanup typically produces
  /// output of similar length to the input — 512 is enough
  /// headroom while keeping a runaway generation from
  /// dominating the pass.
  int get localLlmMaxTokens =>
      _prefs.getInt('local_llm_max_tokens') ?? 512;
  set localLlmMaxTokens(int maxTokens) {
    Log.instance.d('settings', 'Saving localLlmMaxTokens: $maxTokens');
    _prefs.setInt('local_llm_max_tokens', maxTokens);
  }

  double get llmTemperature => _prefs.getDouble('llm_temperature') ?? 0.7;
  set llmTemperature(double temp) {
    Log.instance.d('settings', 'Saving llmTemperature: $temp');
    _prefs.setDouble('llm_temperature', temp);
  }

  int get llmMaxTokens => _prefs.getInt('llm_max_tokens') ?? 4096;
  set llmMaxTokens(int tok) {
    Log.instance.d('settings', 'Saving llmMaxTokens: $tok');
    _prefs.setInt('llm_max_tokens', tok);
  }

  /// Whether Hybrid RAG (Semantic Chunking & Targeted Search) is enabled by default in Document Chat.
  bool get ragModeEnabled => _prefs.getBool('rag_mode_enabled') ?? true;
  set ragModeEnabled(bool enabled) {
    Log.instance.d('settings', 'Saving ragModeEnabled: $enabled');
    _prefs.setBool('rag_mode_enabled', enabled);
  }

  /// Active embedding model name (e.g. Qwen/Qwen3-Embedding-4B-GGUF, text-embedding-nomic, etc.)
  String get llmEmbeddingModel => _prefs.getString('llm_embedding_model') ?? '';
  set llmEmbeddingModel(String model) {
    Log.instance.d('settings', 'Saving llmEmbeddingModel: $model');
    _prefs.setString('llm_embedding_model', model);
  }

  /// Number of top RAG chunks retrieved per query (Top-K, default 5)
  int get ragTopK => _prefs.getInt('rag_top_k') ?? 5;
  set ragTopK(int val) {
    Log.instance.d('settings', 'Saving ragTopK: $val');
    _prefs.setInt('rag_top_k', val);
  }

  /// Minimum similarity threshold score to keep a chunk (default 0.15)
  double get ragMinRelevance => _prefs.getDouble('rag_min_relevance') ?? 0.15;
  set ragMinRelevance(double val) {
    Log.instance.d('settings', 'Saving ragMinRelevance: $val');
    _prefs.setDouble('rag_min_relevance', val);
  }

  /// Target chunk size in words for RAG slicing (default 350 words)
  int get ragChunkSize => _prefs.getInt('rag_chunk_size') ?? 350;
  set ragChunkSize(int val) {
    Log.instance.d('settings', 'Saving ragChunkSize: $val');
    _prefs.setInt('rag_chunk_size', val);
  }

  /// Custom disk path for RAG vectors cache (empty string means default path)
  String get ragCacheDirectory => _prefs.getString('rag_cache_directory') ?? '';
  set ragCacheDirectory(String path) {
    Log.instance.d('settings', 'Saving ragCacheDirectory: $path');
    _prefs.setString('rag_cache_directory', path.trim());
  }

  /// Custom disk path for AI Knowledge Base records (empty string means default path)
  String get aiKnowledgeDirectory => _prefs.getString('ai_knowledge_directory') ?? '';
  set aiKnowledgeDirectory(String path) {
    Log.instance.d('settings', 'Saving aiKnowledgeDirectory: $path');
    _prefs.setString('ai_knowledge_directory', path.trim());
  }

  /// Per-model persistent settings (Temperature & Max Context Tokens)
  Map<String, dynamic> _getModelConfigMap() {
    final raw = _prefs.getString('llm_per_model_configs');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  void _saveModelConfigMap(Map<String, dynamic> map) {
    _prefs.setString('llm_per_model_configs', jsonEncode(map));
  }

  double getModelTemperature(String modelName, {double defaultTemp = 0.7}) {
    if (modelName.isEmpty) return llmTemperature;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    if (map.containsKey(clean) && map[clean] is Map) {
      final sub = map[clean] as Map;
      if (sub['temperature'] is num) {
        return (sub['temperature'] as num).toDouble();
      }
    }
    return llmTemperature;
  }

  void setModelTemperature(String modelName, double temp) {
    llmTemperature = temp;
    if (modelName.isEmpty) return;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    final sub = Map<String, dynamic>.from(map[clean] as Map? ?? {});
    sub['temperature'] = temp;
    map[clean] = sub;
    _saveModelConfigMap(map);
  }

  int getModelMaxTokens(String modelName, {int? defaultTokens}) {
    final recommended = getRecommendedModelCapacity(modelName, llmProvider);
    final clean = modelName.trim().toLowerCase();
    if (clean.isNotEmpty) {
      final map = _getModelConfigMap();
      if (map.containsKey(clean) && map[clean] is Map) {
        final sub = map[clean] as Map;
        if (sub['maxTokens'] is num) {
          final val = (sub['maxTokens'] as num).toInt();
          if (val > 0) {
            if (llmProvider == LlmProvider.liteRtWindows || llmProvider == LlmProvider.liteRtAndroid) {
              return val.clamp(512, recommended);
            }
            return val;
          }
        }
      }
    }
    return defaultTokens ?? recommended;
  }

  void setModelMaxTokens(String modelName, int maxTokens) {
    llmMaxTokens = maxTokens;
    if (modelName.isEmpty) return;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    final sub = Map<String, dynamic>.from(map[clean] as Map? ?? {});
    sub['maxTokens'] = maxTokens;
    map[clean] = sub;
    _saveModelConfigMap(map);
  }

  int getModelRagTopK(String modelName, {int defaultTopK = 5}) {
    if (modelName.isEmpty) return ragTopK;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    if (map.containsKey(clean) && map[clean] is Map) {
      final sub = map[clean] as Map;
      if (sub['ragTopK'] is num) {
        return (sub['ragTopK'] as num).toInt();
      }
    }
    return ragTopK;
  }

  void setModelRagTopK(String modelName, int topK) {
    ragTopK = topK;
    if (modelName.isEmpty) return;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    final sub = Map<String, dynamic>.from(map[clean] as Map? ?? {});
    sub['ragTopK'] = topK;
    map[clean] = sub;
    _saveModelConfigMap(map);
  }

  int getModelRagChunkSize(String modelName, {int defaultSize = 350}) {
    if (modelName.isEmpty) return ragChunkSize;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    if (map.containsKey(clean) && map[clean] is Map) {
      final sub = map[clean] as Map;
      if (sub['ragChunkSize'] is num) {
        return (sub['ragChunkSize'] as num).toInt();
      }
    }
    return ragChunkSize;
  }

  void setModelRagChunkSize(String modelName, int size) {
    ragChunkSize = size;
    if (modelName.isEmpty) return;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    final sub = Map<String, dynamic>.from(map[clean] as Map? ?? {});
    sub['ragChunkSize'] = size;
    map[clean] = sub;
    _saveModelConfigMap(map);
  }

  double getModelRagMinRelevance(String modelName, {double defaultRelevance = 0.15}) {
    if (modelName.isEmpty) return ragMinRelevance;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    if (map.containsKey(clean) && map[clean] is Map) {
      final sub = map[clean] as Map;
      if (sub['ragMinRelevance'] is num) {
        return (sub['ragMinRelevance'] as num).toDouble();
      }
    }
    return ragMinRelevance;
  }

  void setModelRagMinRelevance(String modelName, double relevance) {
    ragMinRelevance = relevance;
    if (modelName.isEmpty) return;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    final sub = Map<String, dynamic>.from(map[clean] as Map? ?? {});
    sub['ragMinRelevance'] = relevance;
    map[clean] = sub;
    _saveModelConfigMap(map);
  }

  /// Active RAG search mode (Hybrid, Semantic, or Keyword)
  RagSearchMode get ragSearchMode {
    final raw = _prefs.getString('rag_search_mode');
    return RagSearchMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => RagSearchMode.hybrid,
    );
  }

  set ragSearchMode(RagSearchMode mode) {
    Log.instance.d('settings', 'Saving ragSearchMode: ${mode.name}');
    _prefs.setString('rag_search_mode', mode.name);
  }

  RagSearchMode getModelRagSearchMode(String modelName) {
    if (modelName.isEmpty) return ragSearchMode;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    if (map.containsKey(clean) && map[clean] is Map) {
      final sub = map[clean] as Map;
      if (sub['ragSearchMode'] is String) {
        final raw = sub['ragSearchMode'] as String;
        return RagSearchMode.values.firstWhere(
          (m) => m.name == raw,
          orElse: () => ragSearchMode,
        );
      }
    }
    return ragSearchMode;
  }

  void setModelRagSearchMode(String modelName, RagSearchMode mode) {
    ragSearchMode = mode;
    if (modelName.isEmpty) return;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    final sub = Map<String, dynamic>.from(map[clean] as Map? ?? {});
    sub['ragSearchMode'] = mode.name;
    map[clean] = sub;
    _saveModelConfigMap(map);
  }

  /// Global Thinking Mode setting (default true)
  bool get thinkingModeEnabled => _prefs.getBool('llm_thinking_mode_enabled') ?? true;
  set thinkingModeEnabled(bool v) {
    Log.instance.d('settings', 'Saving thinkingModeEnabled: $v');
    _prefs.setBool('llm_thinking_mode_enabled', v);
  }

  bool getModelThinkingEnabled(String modelName) {
    if (modelName.isEmpty) return thinkingModeEnabled;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    if (map.containsKey(clean) && map[clean] is Map) {
      final sub = map[clean] as Map;
      if (sub['thinkingEnabled'] is bool) {
        return sub['thinkingEnabled'] as bool;
      }
    }
    return thinkingModeEnabled;
  }

  void setModelThinkingEnabled(String modelName, bool enabled) {
    thinkingModeEnabled = enabled;
    if (modelName.isEmpty) return;
    final map = _getModelConfigMap();
    final clean = modelName.trim().toLowerCase();
    final sub = Map<String, dynamic>.from(map[clean] as Map? ?? {});
    sub['thinkingEnabled'] = enabled;
    map[clean] = sub;
    _saveModelConfigMap(map);
  }

  /// Sampling temperature. 0.0 = greedy, matches the cloud
  /// path's default and keeps Tidy output reproducible.
  double get localLlmTemperature =>
      _prefs.getDouble('local_llm_temperature') ?? 0.0;
  set localLlmTemperature(double t) {
    Log.instance.d('settings', 'Saving localLlmTemperature: $t');
    _prefs.setDouble('local_llm_temperature', t);

  }

  // --- §5.1.11 Global hotkey ---

  /// Whether the global hotkey is registered at all. Off by
  /// default so a fresh install doesn't grab a system shortcut
  /// the user didn't ask for. Desktop-only — the setting is
  /// still readable on mobile but the service treats those
  /// platforms as no-ops.
  bool get hotkeyEnabled => _prefs.getBool('hotkey_enabled') ?? false;
  set hotkeyEnabled(bool value) {
    Log.instance.d('settings', 'Saving hotkeyEnabled: $value');
    _prefs.setBool('hotkey_enabled', value);

  }

  /// Normalised combo string ("meta+shift+space",
  /// "control+alt+r") — see HotkeyService.serialize for the
  /// canonical form. Empty until the user picks one in
  /// Settings.
  String get hotkeyCombo => _prefs.getString('hotkey_combo') ?? '';
  set hotkeyCombo(String combo) {
    Log.instance.d('settings', 'Saving hotkeyCombo: $combo');
    _prefs.setString('hotkey_combo', combo);

  }

  /// 'pushToTalk' (default) or 'toggle'. Stored as the enum
  /// name so it survives an enum-order shuffle.
  String get hotkeyActionName =>
      _prefs.getString('hotkey_action') ?? 'pushToTalk';
  set hotkeyActionName(String name) {
    Log.instance.d('settings', 'Saving hotkeyActionName: $name');
    _prefs.setString('hotkey_action', name);

  }

  /// Convenience: parse / write the enum directly. Defaults to
  /// pushToTalk on unknown strings so a stale prefs row doesn't
  /// crash startup.
  HotkeyAction get hotkeyAction {
    final n = hotkeyActionName;
    for (final v in HotkeyAction.values) {
      if (v.name == n) return v;
    }
    return HotkeyAction.pushToTalk;
  }

  set hotkeyAction(HotkeyAction v) {
    hotkeyActionName = v.name;

  }

  /// §5.1.5 Phase C — whether the EditAudioScreen's transcript
  /// pane is expanded by default. Persists so users who treat
  /// the editor as audio-only collapse once and never see the
  /// pane again; users who treat it as a Descript-style joint
  /// editor leave it open. Default false to favour the pure-
  /// audio-editing flow on first launch.
  bool get editAudioShowTranscript =>
      _prefs.getBool('edit_audio_show_transcript') ?? false;
  set editAudioShowTranscript(bool value) {
    Log.instance
        .d('settings', 'Saving editAudioShowTranscript: $value');
    _prefs.setBool('edit_audio_show_transcript', value);

  }

  /// Helper to clear all settings (for reset)
  Future<void> clearAll() async {
    await _prefs.clear();
  }

  // --- Watch Folder (§5.25.8) ---

  bool get watchFolderEnabled => _prefs.getBool('watch_folder_enabled') ?? false;
  set watchFolderEnabled(bool v) {
    _prefs.setBool('watch_folder_enabled', v);

  }

  String? get watchFolderPath => _prefs.getString('watch_folder_path');
  set watchFolderPath(String? v) {
    if (v == null) {
      _prefs.remove('watch_folder_path');
    } else {
      _prefs.setString('watch_folder_path', v);
    }

  }

  /// macOS security-scoped bookmark for [watchFolderPath], base64-encoded.
  ///
  /// The path alone is not enough under the App Store sandbox: the grant that
  /// comes from the user picking a folder expires with the session, so on
  /// relaunch the raw path is unreadable and — because a sandbox denial makes
  /// `stat` fail rather than throw — the watcher silently found "no such
  /// directory" and gave up with the setting still showing as enabled.
  ///
  /// Null on every other platform and on macOS builds where bookmark creation
  /// failed; callers fall back to [watchFolderPath], which is correct
  /// everywhere the sandbox is not in play.
  String? get watchFolderBookmark => _prefs.getString('watch_folder_bookmark');
  set watchFolderBookmark(String? v) {
    if (v == null) {
      _prefs.remove('watch_folder_bookmark');
    } else {
      _prefs.setString('watch_folder_bookmark', v);
    }
  }

  /// Set when a configured watch folder could not be opened at launch, so
  /// Settings can say so instead of displaying the path as though a watch
  /// were running.
  ///
  /// Recorded as an explicit flag rather than re-probed in `build`: outside
  /// the launch path the app holds no security scope on the folder, so a
  /// `Directory.existsSync()` check in the widget would report every
  /// perfectly good sandboxed folder as missing. Cleared when the user picks
  /// a folder again, which is what restores the grant.
  bool get watchFolderAccessLost =>
      _prefs.getBool('watch_folder_access_lost') ?? false;
  set watchFolderAccessLost(bool v) =>
      _prefs.setBool('watch_folder_access_lost', v);

  // EU AI Act Art. 52 — first-use AI transparency notice.
  bool get aiTransparencyNoticeSeen =>
      _prefs.getBool('ai_transparency_notice_seen') ?? false;
  set aiTransparencyNoticeSeen(bool value) =>
      _prefs.setBool('ai_transparency_notice_seen', value);

  /// Reveal the power-user surface: transcript A/B compare, subtitle overlay,
  /// voice baking, audio editing, the local HTTP server, and the log and
  /// storage inspectors.
  ///
  /// **Off by default, and that is a beta decision rather than a judgement
  /// about the features.** The app has 18 routes and 111 advanced options; a
  /// TestFlight tester who opens it for the first time needs to find "record
  /// or pick a file, get a transcript" and nothing else. Everything gated
  /// here is either a developer tool, a workflow that presumes a finished
  /// transcript, or — in the server's case — something that makes iOS ask for
  /// local-network permission on first use, which is a support conversation
  /// nobody wants to have with a beta tester.
  ///
  /// Nothing is deleted or compiled out: this flips one flag and the whole
  /// surface returns, so feedback on it stays one tap away for the testers
  /// who want it.
  bool get experimentalFeatures =>
      _prefs.getBool('experimental_features') ?? false;
  set experimentalFeatures(bool value) =>
      _prefs.setBool('experimental_features', value);

  // --- LLM Assistant Settings (LM Studio / Ollama / Custom / LiteRT) ---
  LlmProvider get llmProvider {
    final defaultProvider = plat.isAndroid ? 'litert_android' : 'litert_windows';
    final raw = _prefs.getString('llm_provider') ?? defaultProvider;
    if (plat.isAndroid && raw == 'litert_windows') return LlmProvider.liteRtAndroid;
    if (!plat.isAndroid && raw == 'litert_android') return LlmProvider.liteRtWindows;
    switch (raw) {
      case 'litert_windows':
        return LlmProvider.liteRtWindows;
      case 'ollama':
        return LlmProvider.ollama;
      case 'litert_android':
        return LlmProvider.liteRtAndroid;
      case 'custom':
        return LlmProvider.custom;
      default:
        return LlmProvider.lmStudio;
    }
  }
  set llmProvider(LlmProvider p) {
    _prefs.setString('llm_provider', p.id);
  }

  String get llmApiUrl => _prefs.getString('llm_api_url') ?? '';
  set llmApiUrl(String v) => _prefs.setString('llm_api_url', v.trim());

  String get llmModel => _prefs.getString('llm_model') ?? '';
  set llmModel(String v) => _prefs.setString('llm_model', v.trim());

  String get llmApiKey => _prefs.getString('llm_api_key') ?? '';
  set llmApiKey(String v) => _prefs.setString('llm_api_key', v.trim());

  // --- Logging State Toggle ---
  bool get loggingEnabled => _prefs.getBool('logging_enabled') ?? true;
  set loggingEnabled(bool v) {
    _prefs.setBool('logging_enabled', v);
    Log.instance.setEnabled(v);
  }

  // --- System Prompt Presets & Management ---

  String get activeSystemPromptId => _prefs.getString('active_system_prompt_id') ?? 'default';
  set activeSystemPromptId(String id) {
    _prefs.setString('active_system_prompt_id', id);
  }

  String get activeSystemPromptText {
    final stored = _prefs.getString('active_system_prompt_text');
    if (stored != null && stored.trim().isNotEmpty) return stored;
    return defaultSystemPromptText;
  }

  set activeSystemPromptText(String text) {
    _prefs.setString('active_system_prompt_text', text);
  }

  List<SystemPromptPreset> get systemPromptPresets {
    final raw = _prefs.getString('custom_system_prompt_presets');
    final customList = <SystemPromptPreset>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded) {
          customList.add(SystemPromptPreset.fromJson(item as Map<String, dynamic>));
        }
      } catch (e) {
        Log.instance.w('settings', 'Failed to parse custom system prompt presets: $e');
      }
    }
    return [...defaultSystemPromptPresets, ...customList];
  }

  Future<void> saveCustomSystemPromptPreset(String name, String prompt) async {
    final raw = _prefs.getString('custom_system_prompt_presets');
    final customList = <SystemPromptPreset>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded) {
          customList.add(SystemPromptPreset.fromJson(item as Map<String, dynamic>));
        }
      } catch (_) {}
    }
    final newId = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    final newPreset = SystemPromptPreset(id: newId, name: name, prompt: prompt);
    customList.add(newPreset);
    await _prefs.setString('custom_system_prompt_presets', jsonEncode(customList.map((e) => e.toJson()).toList()));
    activeSystemPromptId = newId;
    activeSystemPromptText = prompt;
  }

  Future<void> deleteSystemPromptPreset(String id) async {
    final raw = _prefs.getString('custom_system_prompt_presets');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final customList = decoded
          .map((e) => SystemPromptPreset.fromJson(e as Map<String, dynamic>))
          .where((p) => p.id != id)
          .toList();
      await _prefs.setString('custom_system_prompt_presets', jsonEncode(customList.map((e) => e.toJson()).toList()));
      if (activeSystemPromptId == id) {
        activeSystemPromptId = 'default';
        activeSystemPromptText = defaultSystemPromptText;
      }
    } catch (_) {}
  }

  void resetActiveSystemPromptToDefault() {
    activeSystemPromptId = 'default';
    activeSystemPromptText = defaultSystemPromptText;
  }

  // --- Knowledge & RAG Categories Settings ---

  List<String> get knowledgeCategories {
    final list = _prefs.getStringList('knowledge_categories');
    if (list != null && list.isNotEmpty) return list;
    return ['Général', 'Finances & Factures', 'Cloud & Technique', 'Médical & Santé', 'Personnel'];
  }

  set knowledgeCategories(List<String> categories) {
    _prefs.setStringList('knowledge_categories', categories);
  }

  void addKnowledgeCategory(String category) {
    final clean = category.trim();
    if (clean.isEmpty) return;
    final list = List<String>.from(knowledgeCategories);
    if (!list.contains(clean)) {
      list.add(clean);
      knowledgeCategories = list;
    }
  }

  void renameKnowledgeCategory(String oldName, String newName) {
    final cleanNew = newName.trim();
    if (cleanNew.isEmpty || oldName == cleanNew) return;
    final list = List<String>.from(knowledgeCategories);
    final idx = list.indexOf(oldName);
    if (idx != -1) {
      list[idx] = cleanNew;
      knowledgeCategories = list;
    }
  }

  void deleteKnowledgeCategory(String category) {
    if (category == 'Général') return;
    final list = List<String>.from(knowledgeCategories);
    list.remove(category);
    knowledgeCategories = list;
  }

  // --- Prompt Categories Settings ---

  List<String> get promptCategories {
    final list = _prefs.getStringList('prompt_categories');
    if (list != null && list.isNotEmpty) return list;
    return ['Général', 'Synthèses', 'Juridique & Audit', 'Finances & Factures'];
  }

  set promptCategories(List<String> categories) {
    _prefs.setStringList('prompt_categories', categories);
  }

  void addPromptCategory(String category) {
    final clean = category.trim();
    if (clean.isEmpty) return;
    final list = List<String>.from(promptCategories);
    if (!list.contains(clean)) {
      list.add(clean);
      promptCategories = list;
    }
  }

  void renamePromptCategory(String oldName, String newName) {
    final cleanNew = newName.trim();
    if (cleanNew.isEmpty || oldName == cleanNew) return;
    final list = List<String>.from(promptCategories);
    final idx = list.indexOf(oldName);
    if (idx != -1) {
      list[idx] = cleanNew;
      promptCategories = list;
    }
  }

  void deletePromptCategory(String category) {
    if (category == 'Général') return;
    final list = List<String>.from(promptCategories);
    list.remove(category);
    promptCategories = list;
  }

  // --- MCP Tools Toggles ---

  bool get enableCurrentDateTool => _prefs.getBool('enable_current_date_tool') ?? true;
  set enableCurrentDateTool(bool value) => _prefs.setBool('enable_current_date_tool', value);

  bool get enableWebSearchTool => _prefs.getBool('enable_web_search_tool') ?? false;
  set enableWebSearchTool(bool value) => _prefs.setBool('enable_web_search_tool', value);

  bool get enableGmailTool => _prefs.getBool('enable_gmail_tool') ?? false;
  set enableGmailTool(bool value) => _prefs.setBool('enable_gmail_tool', value);
}

class SystemPromptPreset {
  final String id;
  final String name;
  final String prompt;

  const SystemPromptPreset({
    required this.id,
    required this.name,
    required this.prompt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'prompt': prompt,
      };

  factory SystemPromptPreset.fromJson(Map<String, dynamic> json) => SystemPromptPreset(
        id: json['id'] as String? ?? 'default',
        name: json['name'] as String? ?? 'Preset',
        prompt: json['prompt'] as String? ?? '',
      );
}

const String defaultSystemPromptText = '''Tu es un assistant IA documentaire expert et précis intégré dans CrisperWeaver.
DOCUMENTS ACTIFS DANS LA SESSION :
{DOCUMENTS_LIST}

Voici les EXTRAITS PERTINENTS issus de la recherche sémantique ciblée (Mode RAG) pour répondre à la question :
===
{RAG_EXTRACTS}
===
Consignes strictes de réponse :
1. Réponds UNIQUEMENT en français clair, soigné, direct et structuré.
2. Si la question demande une comparaison ou une analyse entre plusieurs documents, identifie bien les titres et auteurs distincts de la liste ci-dessus et compare leurs intrigues, thèmes et personnages respectifs.
3. Synthétise de façon complète, affirmative et précise toutes les informations présentes dans ces extraits.
4. Ne produis AUCUN préambule d'analyse interne en anglais ("The user is asking..."), réponds directement.''';

final List<SystemPromptPreset> defaultSystemPromptPresets = [
  const SystemPromptPreset(
    id: 'default',
    name: '✨ Standard RAG CrisperWeaver',
    prompt: defaultSystemPromptText,
  ),
  const SystemPromptPreset(
    id: 'summary',
    name: '📝 Synthèse & Résumé Structuré',
    prompt: '''Tu es un assistant éditorial expert en analyse et synthèse documentaire.
DOCUMENTS ACTIFS :
{DOCUMENTS_LIST}

EXTRAITS DU DOCUMENT :
===
{RAG_EXTRACTS}
===
Consignes :
1. Produis un résumé analytique structuré en grands points clés.
2. Dégage les idées principales, les thèmes majeurs et les conclusions.
3. Utilise des puces et des titres clairs en français.
4. Évite les bavardages et va à l'essentiel.''',
  ),
  const SystemPromptPreset(
    id: 'detective',
    name: '🔍 Analyse Critique & Détective',
    prompt: '''Tu es un enquêteur et analyste critique minutieux.
DOCUMENTS ACTIFS :
{DOCUMENTS_LIST}

EXTRAITS DU DOCUMENT :
===
{RAG_EXTRACTS}
===
Consignes :
1. Examine les preuves, indices, dates, lieux, personnages et contradictions dans ces extraits.
2. Présente tes constatations sous forme de rapport d'enquête rigoureux en français.
3. N'invente aucun fait non présent dans le texte.''',
  ),
  const SystemPromptPreset(
    id: 'concise',
    name: '⚡ Réponses Courtes en Puces',
    prompt: '''Tu es un assistant IA concis et direct.
DOCUMENTS ACTIFS :
{DOCUMENTS_LIST}

EXTRAITS DU DOCUMENT :
===
{RAG_EXTRACTS}
===
Consignes :
1. Réponds en 3 à 5 puces courtes maximum.
2. Pas de longues phrases, va immédiatement aux faits bruts.
3. Réponds exclusivement en français.''',
  ),
];

/// Helper to detect native physical capacity of an LLM model by name and provider.
int getRecommendedModelCapacity(String modelName, LlmProvider provider) {
  final clean = modelName.toLowerCase();

  // Pour LiteRT (Windows / Android) :
  if (provider == LlmProvider.liteRtWindows || provider == LlmProvider.liteRtAndroid) {
    if (clean.contains('gemma-4-e4b') || clean.contains('gemma-4-12b') || clean.contains('4-e4b') || clean.contains('4-12b')) {
      return 32768;
    }
    if (clean.contains('tiny') || clean.contains('garden') || clean.contains('270m')) {
      return 2048;
    }
    return 4096;
  }

  // 1. Modèles compacts 4K
  if (clean.contains('3n') || clean.contains('e2b') || clean.contains('1.5b') || clean.contains('tiny') || clean.contains('garden') || clean.contains('1b') || clean.contains('2b') || clean.contains('270m')) {
    return 4096;
  }
  // 2. Modèles intermédiaires 16K
  if (clean.contains('lfm2.5') || clean.contains('liquid') || clean.contains('lfm')) {
    return 16384;
  }
  // 3. Modèles standards 32K
  if (clean.contains('gemma-4') || clean.contains('e4b') || clean.contains('12b') || clean.contains('7b') || clean.contains('8b') || clean.contains('14b') || clean.contains('gemma') || clean.contains('mistral') || clean.contains('llama') || clean.contains('coder')) {
    return 32768;
  }
  // 4. Modèles grands formats 128K
  if (clean.contains('27b') || clean.contains('70b') || clean.contains('deepseek') || clean.contains('claude') || clean.contains('gpt-4')) {
    return 131072;
  }
  return 32768;
}

/// Provider for the SettingsService.
/// Note: Requires initialization in main() before use.
final settingsServiceProvider = Provider<SettingsService>((ref) {
  throw UnimplementedError('SettingsService not initialized');
});

/// §5.1.6 v3 — which LLM cleanup path Tidy / Summarize uses.
/// Single source of truth, persisted to prefs, read by both the
/// cleanup pass and the summarisation pass so a user only has
/// to pick once and both surfaces follow.
enum LlmCleanupMode { off, cloud, local }
