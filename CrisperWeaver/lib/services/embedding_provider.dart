import '../services/settings_service.dart';
import '../services/llm_service.dart';

// ─────────────────────────────────────────────────────────────────
// EmbeddingProvider
// ─────────────────────────────────────────────────────────────────

/// Which engine produces the dense embedding vectors for RAG retrieval.
///
/// The chat LLM provider ([LlmProvider]) and the embedding provider are
/// deliberately independent:
///
///   Chat = LiteRT  →  Embeddings = LM Studio   (baseline P0, always available)
///   Chat = LiteRT  →  Embeddings = CrispEmbed  (portable, no LM Studio needed)
///   Any            →  bm25Only                 (dégradé, aucun modèle disponible)
///
/// **Routing**: [fromSettings] reads [SettingsService.embeddingProviderName] to
/// select the active provider. Default is [lmStudio] for backward compatibility.
enum EmbeddingProvider {
  /// LM Studio REST endpoint – POST /v1/embeddings.
  lmStudio,

  /// CrispEmbed FFI – encode() / encodeBatch() via crispembed.dll.
  /// Requires a ModelKind.embed GGUF present in data/models/whisper_cpp/.
  /// Dimension 384 for all-MiniLM-L6-v2-iq4_xs.gguf.
  crispEmbed,

  /// Aucun moteur vectoriel disponible – recherche par mots-clés uniquement.
  /// NOTE: identifiant interne conservé (sérialisé dans les caches JSON et SharedPreferences).
  bm25Only,
}

// ─────────────────────────────────────────────────────────────────
// RagRetrievalMode
// ─────────────────────────────────────────────────────────────────

/// The retrieval strategy that was **actually used** for the last query.
/// Reflects reality, not the mode requested in settings.
enum RagRetrievalMode {
  /// Reciprocal Rank Fusion of semantic vectors + keyword scores (overlap normalisé).
  hybrid,

  /// Dense vector cosine similarity only.
  semantic,

  /// Keyword overlap only – triggered when embeddings unavailable/failed.
  /// NOTE: identifiant interne conservé (sérialisé dans les caches JSON et SharedPreferences).
  bm25Fallback,

  /// First-N positional chunks – triggered when lexical also returns nothing.
  positionalFallback,
}

extension RagRetrievalModeDisplay on RagRetrievalMode {
  String get label {
    switch (this) {
      case RagRetrievalMode.hybrid:
        return 'Hybride';
      case RagRetrievalMode.semantic:
        return 'Sémantique';
      case RagRetrievalMode.bm25Fallback:
        return 'Mots-clés'; // INC-RAG-LEXICAL-LABEL résolu
      case RagRetrievalMode.positionalFallback:
        return 'Positionnel';
    }
  }

  bool get isDegraded =>
      this == RagRetrievalMode.bm25Fallback ||
      this == RagRetrievalMode.positionalFallback;

  String get tooltip {
    switch (this) {
      case RagRetrievalMode.hybrid:
        return 'Sémantique + Mots-clés, fusion RRF';
      case RagRetrievalMode.semantic:
        return 'Recherche sémantique : similarité cosinus uniquement';
      case RagRetrievalMode.bm25Fallback:
        return 'Recherche par mots-clés — le modèle d\'embeddings est indisponible';
      case RagRetrievalMode.positionalFallback:
        return 'Fragments positionnels — aucun résultat sémantique ni lexical trouvé';
    }
  }
}

// ─────────────────────────────────────────────────────────────────
// EmbeddingProviderConfig
// ─────────────────────────────────────────────────────────────────

/// Immutable snapshot of the embedding configuration for one request cycle.
///
/// Resolved once per indexing/retrieval call via [fromSettings], then
/// passed down through [DocumentRagService] so every layer uses the
/// same consistent config.
class EmbeddingProviderConfig {
  final EmbeddingProvider provider;

  /// Model identifier sent in the 'model' field of the HTTP payload,
  /// or the GGUF file name for CrispEmbed.
  final String modelId;

  /// Dimension of the embedding vectors (0 = unknown / not yet probed).
  final int dimension;

  /// REST endpoint base URL (e.g. 'http://127.0.0.1:1234/v1').
  /// Empty for [EmbeddingProvider.crispEmbed] and [EmbeddingProvider.bm25Only].
  final String endpoint;

  const EmbeddingProviderConfig({
    required this.provider,
    required this.modelId,
    required this.dimension,
    required this.endpoint,
  });

  // ── Factory ────────────────────────────────────────────────────

  /// Resolves the embedding configuration from the current [settings].
  ///
  /// **Routing table :**
  ///
  /// | embeddingProviderName  | Chat provider     | Résultat                     |
  /// |------------------------|-------------------|------------------------------|
  /// | 'crispEmbed'           | any               | CrispEmbed FFI (dim 384)     |
  /// | 'lmStudio' (défaut)    | liteRtWindows     | http://127.0.0.1:1234/v1     |
  /// | 'lmStudio' (défaut)    | liteRtAndroid     | http://127.0.0.1:1234/v1     |
  /// | 'lmStudio' (défaut)    | lmStudio / other  | settings.llmApiUrl           |
  ///
  /// Jamais de basculement silencieux : si le provider demandé est crispEmbed
  /// mais que l'instance est null au moment de l'encodage, le service journalise
  /// l'indisponibilité et retourne le mode dégradé mots-clés.
  static EmbeddingProviderConfig fromSettings(
    SettingsService settings,
    LlmService llm,
  ) {
    // ── CrispEmbed (portable, sans LM Studio) ─────────────────────
    if (settings.embeddingProviderName == 'crispEmbed') {
      // Le modelId provient de settings.llmEmbeddingModel si renseigné,
      // sinon on utilise le nom de fichier du modèle embed actif.
      // La dimension est stockée dans settings.embeddingDimension après le
      // premier encodage réussi (384 pour all-MiniLM-L6-v2).
      final modelId = settings.llmEmbeddingModel.isNotEmpty
          ? settings.llmEmbeddingModel
          : 'all-MiniLM-L6-v2-iq4_xs.gguf';
      final dimension = settings.embeddingDimension > 0
          ? settings.embeddingDimension
          : 384; // Dimension connue du modèle MiniLM embarqué
      return EmbeddingProviderConfig(
        provider: EmbeddingProvider.crispEmbed,
        modelId: modelId,
        dimension: dimension,
        endpoint: '', // FFI local — aucune requête HTTP
      );
    }

    // ── LM Studio (défaut, P0 non-regression garantie) ─────────────
    final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows ||
        settings.llmProvider == LlmProvider.liteRtAndroid;

    final embEndpoint = isLiteRt
        ? 'http://127.0.0.1:1234/v1'
        : (settings.llmApiUrl.isNotEmpty ? settings.llmApiUrl : llm.endpoint);

    return EmbeddingProviderConfig(
      provider: EmbeddingProvider.lmStudio,
      modelId: settings.llmEmbeddingModel,
      dimension: settings.embeddingDimension,
      endpoint: embEndpoint,
    );
  }

  // ── Cache key v2 ───────────────────────────────────────────────

  /// Generates a deterministic, unambiguous v2 cache filename.
  ///
  /// Format: `<contentHash>_<provider>_<modelSlug>_d<dim>_v2.json`
  ///
  /// Examples:
  ///   `abc123_lmStudio_text-embedding-qwen3-embedding-4b_d2560_v2.json`
  ///   `abc123_crispEmbed_all-minilm-l6-v2-iq4_xs_d384_v2.json`
  ///
  /// The provider name and dimension prevent silent cross-engine reuse.
  String cacheFileName(String contentHash) {
    final slug = modelId
        .replaceAll(RegExp(r'[^\w\.-]'), '_')
        .toLowerCase();
    final dimPart = dimension > 0 ? '_d$dimension' : '';
    return '${contentHash}_${provider.name}_${slug}${dimPart}_v2.json';
  }

  /// Whether this config can produce dense vectors.
  bool get supportsVectors => provider != EmbeddingProvider.bm25Only;

  @override
  String toString() =>
      'EmbeddingProviderConfig(${provider.name}, model=$modelId, dim=$dimension, '
      'endpoint=${endpoint.isEmpty ? "FFI" : endpoint})';
}
