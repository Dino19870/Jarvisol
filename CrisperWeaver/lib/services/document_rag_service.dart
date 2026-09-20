import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../constants/timeout_policy.dart';
import 'package:path/path.dart' as p;
import '../utils/app_paths.dart';
import 'document_source_service.dart';
import 'embedding_provider.dart';
import 'log_service.dart';
import 'settings_service.dart';
import '../native/crispembed_import.dart' show CrispEmbed;

/// Search mode strategy for RAG retrieval.
enum RagSearchMode {
  hybrid(
    '⚡ Hybride (Recommandé)',
    'Combine le sens profond (vecteurs) et les mots-clés avec fusion RRF pour une pertinence optimale.',
  ),
  semantic(
    '🧠 Sémantique Pure',
    'Analyse uniquement le sens des idées et des synonymes via le modèle d\'embeddings.',
  ),
  keyword(
    '🔤 Mots-clés Purs',
    'Recherche textuelle stricte par mots exacts (idéal pour noms propres rares, codes et références).',
  );

  final String label;
  final String description;
  const RagSearchMode(this.label, this.description);
}

/// A single cleaned and indexed document chunk for RAG search.
class DocumentChunk {
  final String id;
  final String sourceName;
  final String sourceType;
  final String? chapterTitle;
  final String text;
  final int wordCount;
  List<double>? embedding;

  DocumentChunk({
    required this.id,
    required this.sourceName,
    required this.sourceType,
    this.chapterTitle,
    required this.text,
    required this.wordCount,
    this.embedding,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceName': sourceName,
        'sourceType': sourceType,
        'chapterTitle': chapterTitle,
        'text': text,
        'wordCount': wordCount,
        if (embedding != null) 'embedding': embedding,
      };

  factory DocumentChunk.fromJson(Map<String, dynamic> json) => DocumentChunk(
        id: json['id'] as String,
        sourceName: json['sourceName'] as String,
        sourceType: json['sourceType'] as String,
        chapterTitle: json['chapterTitle'] as String?,
        text: json['text'] as String,
        wordCount: json['wordCount'] as int,
        embedding: (json['embedding'] as List?)?.map((v) => (v as num).toDouble()).toList(),
      );
}

/// Metadata and content entry for a document persisted in the RAG disk cache.
class CachedDocumentEntry {
  final String fileName;
  final String sourceName;
  final String category;
  final String hash;
  final String model;
  final DateTime createdAt;
  final int chunkCount;
  final int fileSizeBytes;
  final List<DocumentChunk> chunks;
  final String reconstructedText;
  /// Provider d'embedding tel que stocké dans les métadonnées v2.
  /// Null pour les caches legacy (format ancien sans champ embeddingProvider).
  final String? embeddingProvider;
  /// Dimension des vecteurs stockés (0 = inconnu/legacy).
  final int embeddingDimension;

  CachedDocumentEntry({
    required this.fileName,
    required this.sourceName,
    this.category = 'Général',
    required this.hash,
    required this.model,
    required this.createdAt,
    required this.chunkCount,
    required this.fileSizeBytes,
    required this.chunks,
    required this.reconstructedText,
    this.embeddingProvider,
    this.embeddingDimension = 0,
  });

  /// Libellé lisible pour la bibliothèque RAG :
  ///   LM Studio · Qwen3 Embedding 4B · 2560d
  ///   CrispEmbed · MiniLM-L6-v2 · 384d
  ///   Index historique · modèle inconnu
  String get indexLabel {
    if (embeddingProvider == null) {
      // Cache legacy sans métadonnées provider
      return model.isNotEmpty ? 'Index historique · $model' : 'Index historique · modèle inconnu';
    }
    final provLabel = switch (embeddingProvider) {
      'lmStudio'   => 'LM Studio',
      'crispEmbed' => 'CrispEmbed',
      'bm25Only'   => 'Mots-clés',
      _            => embeddingProvider!,
    };
    final modelShort = model.isNotEmpty ? _shortenModelName(model) : 'modèle inconnu';
    final dimStr = embeddingDimension > 0 ? ' · ${embeddingDimension}d' : '';
    return '$provLabel · $modelShort$dimStr';
  }

  static String _shortenModelName(String m) {
    // all-MiniLM-L6-v2-iq4_xs.gguf → MiniLM-L6-v2
    // text-embedding-qwen3-embedding-4b → Qwen3 Embedding 4B
    if (m.contains('MiniLM')) return 'MiniLM-L6-v2';
    if (m.contains('qwen3') || m.contains('Qwen3')) return 'Qwen3 Embedding 4B';
    if (m.contains('nomic')) return 'Nomic Embed';
    if (m.contains('bge')) return 'BGE';
    if (m.endsWith('.gguf')) return m.replaceAll('.gguf', '').replaceAll('-', ' ');
    if (m.length > 28) return '${m.substring(0, 25)}…';
    return m;
  }
}

/// Result of a RAG similarity search with relevance score.
class RagSearchResult {
  final DocumentChunk chunk;
  final double score;

  const RagSearchResult({
    required this.chunk,
    required this.score,
  });
}

/// Service handling Text Sanitization, Chunking, Embeddings generation and Semantic Retrieval.
class DocumentRagService {
  final http.Client _client;

  /// The retrieval mode that was actually used in the last [retrieveTopChunks] call.
  /// Null before any retrieval has occurred.
  RagRetrievalMode? lastRetrievalMode;

  DocumentRagService({http.Client? client}) : _client = client ?? http.Client();

  /// Dernier motif de repli vers la recherche lexicale (null si sémantique normale).
  String? lastFallbackReason;

  /// 1. DATA CLEANING & SANITIZATION PIPELINE
  /// Strips technical artifacts, fixes hyphenation breaks, removes header/footer noise.
  String cleanDocumentText(String text, {String sourceType = 'text'}) {
    if (text.isEmpty) return '';

    var cleaned = text;

    // Normalise Unicode spaces and control characters
    cleaned = cleaned.replaceAll(RegExp(r'[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]'), '');

    // Reconnect hyphenated words split across lines (e.g. "inves-\n tigateur" -> "investigateur")
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'(\b[a-zA-ZÀ-ÿ]+)-\s*\r?\n\s*([a-zA-ZÀ-ÿ]+\b)'),
      (match) => '${match.group(1)}${match.group(2)}',
    );

    // Remove standalone page numbers or headers/footers (e.g., "Page 12", "12 / 340", "- 45 -")
    cleaned = cleaned.replaceAll(RegExp(r'^\s*(?:page\s+)?\d+(?:\s*/\s*\d+)?\s*$', multiLine: true, caseSensitive: false), '');
    cleaned = cleaned.replaceAll(RegExp(r'^\s*-\s*\d+\s*-\s*$', multiLine: true), '');

    // Normalize multiple consecutive blank lines to at most 2 newlines
    cleaned = cleaned.replaceAll(RegExp(r'\r\n|\r'), '\n');
    cleaned = cleaned.replaceAll(RegExp(r'[ \t]+'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return cleaned.trim();
  }

  /// 2. SMART CHUNKING PIPELINE
  /// Slices text into coherent paragraph-aligned chunks of targetWords (default 350-400 words)
  /// with a 10% overlap to preserve narrative flow.
  List<DocumentChunk> createChunks({
    required String sourceName,
    required String sourceType,
    required String text,
    int targetWords = 350,
    int overlapWords = 35,
  }) {
    final cleaned = cleanDocumentText(text, sourceType: sourceType);
    if (cleaned.isEmpty) return [];

    final chunks = <DocumentChunk>[];

    // Split by major sections / chapters first if markdown headers exist
    final sectionSplits = cleaned.split(RegExp(r'(?=\n#{1,3}\s+)'));

    int chunkCounter = 0;

    for (final section in sectionSplits) {
      var trimmedSection = section.trim();
      if (trimmedSection.isEmpty) continue;

      // Detect and extract chapter title if present at start
      String? chapterTitle;
      final headerMatch = RegExp(r'^#{1,3}\s+(.+)$', multiLine: true).firstMatch(trimmedSection);
      if (headerMatch != null) {
        chapterTitle = headerMatch.group(1)?.trim();
        // Remove the header line from body text so it doesn't duplicate
        trimmedSection = trimmedSection.replaceFirst(headerMatch.group(0)!, '').trim();
      }

      if (trimmedSection.isEmpty) continue;

      // Split into sentences
      final sentences = _splitSentences(trimmedSection);
      if (sentences.isEmpty) continue;

      List<String> currentChunkSentences = [];
      int currentWordCount = 0;

      for (int i = 0; i < sentences.length; i++) {
        final sentence = sentences[i];
        final wordCount = sentence.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

        currentChunkSentences.add(sentence);
        currentWordCount += wordCount;

        if (currentWordCount >= targetWords || i == sentences.length - 1) {
          final chunkText = currentChunkSentences.join(' ').trim();
          if (chunkText.isNotEmpty) {
            chunks.add(DocumentChunk(
              id: '${sourceName}_chunk_${chunkCounter++}',
              sourceName: sourceName,
              sourceType: sourceType,
              chapterTitle: chapterTitle,
              text: chunkText,
              wordCount: currentWordCount,
            ));
          }

          // Prepare next chunk with overlap
          if (i < sentences.length - 1) {
            final overlapSentences = <String>[];
            int overlapCount = 0;
            for (int j = currentChunkSentences.length - 1; j >= 0; j--) {
              final s = currentChunkSentences[j];
              final count = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
              overlapSentences.insert(0, s);
              overlapCount += count;
              if (overlapCount >= overlapWords) break;
            }
            currentChunkSentences = overlapSentences;
            currentWordCount = overlapCount;
          } else {
            currentChunkSentences = [];
            currentWordCount = 0;
          }
        }
      }
    }

    return chunks;
  }

  List<String> _splitSentences(String text) {
    final parts = text.split(RegExp(r'''(?<=[.!?…])\s+(?=[A-ZÀ-ÖØ-ß0-9«"'\u2014])'''));
    return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  }

  /// 3. BATCH EMBEDDINGS GENERATOR WITH PROGRESS CALLBACK
  ///
  /// Deux chemins possibles selon [crispEmbedder] :
  ///   • crispEmbedder != null → FFI local (aucune requête HTTP, dim 384)
  ///   • crispEmbedder == null → HTTP LM Studio (endpoint requis)
  ///
  /// **Pas de basculement silencieux** : si [crispEmbedder] est null alors que
  /// l'appelant attend CrispEmbed, les vecteurs seront vides → mode mots-clés.
  Future<List<List<double>>> fetchEmbeddings({
    required List<String> texts,
    required String endpoint,
    String? model,
    int batchSize = 16,
    void Function(int current, int total)? onProgress,
    CrispEmbed? crispEmbedder,
  }) async {
    if (texts.isEmpty) return [];

    // ── Chemin A : CrispEmbed FFI (portable, sans LM Studio) ──────
    if (crispEmbedder != null) {
      Log.instance.i('rag',
          'fetchEmbeddings: CrispEmbed FFI, ${texts.length} texte(s)');
      final allEmbeddings = <List<double>>[];
      try {
        // encodeBatch pour l'indexation par lots (plus efficace que boucle encode)
        final batchVecs = crispEmbedder.encodeBatch(texts);
        for (final vec in batchVecs) {
          allEmbeddings.add(_normalizeL2(vec.toList()));
        }
      } catch (e) {
        Log.instance.e('rag', 'CrispEmbed encodeBatch failed, essai encode() individuel: $e');
        // Fallback individuel en cas d'erreur de batch
        for (int i = 0; i < texts.length; i++) {
          try {
            final vec = crispEmbedder.encode(texts[i]);
            allEmbeddings.add(_normalizeL2(vec.toList()));
          } catch (e2) {
            Log.instance.w('rag', 'CrispEmbed encode failed pour texte $i: $e2');
            allEmbeddings.add([]);
          }
          if (onProgress != null) onProgress(i + 1, texts.length);
        }
        return allEmbeddings;
      }
      if (onProgress != null) onProgress(texts.length, texts.length);
      return allEmbeddings;
    }

    // ── Chemin B : LM Studio HTTP ──────────────────────────────────
    // Guard Fix-B : si l'endpoint est vide (configuration crispEmbed sans serveur HTTP)
    // et que crispEmbedder est null (GGUF absent), ne jamais tenter un appel HTTP
    // avec une URI invalide. Retourner des vecteurs vides → mode mots-clés propre.
    if (endpoint.isEmpty) {
      Log.instance.w('rag',
          'fetchEmbeddings: endpoint vide et CrispEmbed non disponible. '
          'Aucun HTTP tenté — ${texts.length} embedding(s) vide(s).');
      return List.filled(texts.length, <double>[]);
    }
    final normalizedEndpoint = endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint;
    final url = Uri.parse('$normalizedEndpoint/embeddings');

    final allEmbeddings = <List<double>>[];

    for (int i = 0; i < texts.length; i += batchSize) {
      final end = math.min(i + batchSize, texts.length);
      final batch = texts.sublist(i, end);

      try {
        final body = jsonEncode({
          'input': batch,
          if (model != null && model.isNotEmpty) 'model': model,
        });

        final timeoutDuration = texts.length == 1
            ? TimeoutPolicy.ragEmbeddingSingle
            : TimeoutPolicy.ragEmbeddingBatch;
        final res = await _client.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: body,
        ).timeout(timeoutDuration);

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map<String, dynamic> && data['data'] is List) {
            final list = data['data'] as List;
            for (final item in list) {
              if (item is Map && item['embedding'] is List) {
                final rawVec = (item['embedding'] as List).map((v) => (v as num).toDouble()).toList();
                allEmbeddings.add(_normalizeL2(rawVec));
              }
            }
          }
        } else {
          Log.instance.w('rag', 'Embeddings HTTP ${res.statusCode}: ${res.body}');
          for (int k = 0; k < batch.length; k++) {
            allEmbeddings.add([]);
          }
        }
      } catch (e) {
        Log.instance.e('rag', 'Failed to fetch batch embeddings', error: e);
        for (int k = 0; k < batch.length; k++) {
          allEmbeddings.add([]);
        }
      }

      if (onProgress != null) {
        onProgress(end, texts.length);
      }
    }

    return allEmbeddings;
  }

  // --- 💾 PERSISTENT DISK CACHE MANAGEMENT ---

  /// Computes a deterministic MD5 hash of text content
  String computeFileHash(String content) {
    return md5.convert(utf8.encode(content)).toString();
  }

  /// Resolves the effective RAG cache directory (user-configured or default)
  Future<Directory> getEffectiveCacheDir(SettingsService settings) async {
    final customPath = settings.ragCacheDirectory;
    if (customPath.isNotEmpty) {
      final dir = Directory(customPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    // Chemin portable par défaut : Release\data\rag_cache\
    return AppPaths.ragCacheDir;
  }


  /// Attempts to load pre-calculated chunks and embeddings from disk cache.
  ///
  /// **Cache lookup order (v2-first policy):**
  ///
  /// 1. Look for the v2 file keyed by `EmbeddingProviderConfig.cacheFileName`.
  ///    On hit: verify embedded metadata (provider, model, dimension) and the
  ///    actual vector dimension of stored chunks.  Any divergence → skip + log.
  ///
  /// 2. Legacy files (`<md5>_<model>.json` without `cacheVersion`):
  ///    - Loaded as text/structure only if their internal metadata proves
  ///      exact compatibility with the current config (provider + model + dim).
  ///    - If metadata is absent or mismatched → NOT used for vectors; rebuilt
  ///      as v2 on the next indexing pass.  File is never deleted.
  ///
  /// On [FileSystemException] (binary data, OS error): quarantine as `.corrupt`.
  /// On [FormatException] / UTF-8 decode failure: quarantine as `.corrupt`.
  Future<List<DocumentChunk>?> loadFromCache({
    required String sourceName,
    required String content,
    required EmbeddingProviderConfig embConfig,
    required SettingsService settings,
  }) async {
    try {
      final dir = await getEffectiveCacheDir(settings);
      final hash = computeFileHash(content);

      // ── 1. Exact v2 lookup (canonical key with _dNNN) ──────────
      final fileNameV2 = embConfig.cacheFileName(hash);
      final fileV2 = File(p.join(dir.path, fileNameV2));
      if (await fileV2.exists()) {
        final result = await _loadAndVerifyCache(
          file: fileV2,
          embConfig: embConfig,
          sourceName: sourceName,
          isV2: true,
        );
        if (result != null) return result;
      }

      // ── 1b. Dimension-agnostic v2 fallback ────────────────────
      // Handles the transition window: a v2 file created when dimension=0
      // (no _dNNN in its name) but now embConfig.dimension=2560.
      // Pattern: <hash>_<provider>_<modelSlug>_v2.json  (no _dNNN segment)
      if (embConfig.dimension > 0) {
        final slug = embConfig.modelId
            .replaceAll(RegExp(r'[^\w\.-]'), '_')
            .toLowerCase();
        final dimlessName = '${hash}_${embConfig.provider.name}_${slug}_v2.json';
        final dimlessFile = File(p.join(dir.path, dimlessName));
        if (await dimlessFile.exists() && dimlessFile.path != fileV2.path) {
          final result = await _loadAndVerifyCache(
            file: dimlessFile,
            embConfig: embConfig,
            sourceName: sourceName,
            isV2: true,
          );
          if (result != null) {
            // Rename to canonical key so future lookups hit exactly (step 1).
            try {
              await dimlessFile.rename(fileV2.path);
              Log.instance.i('rag',
                  'Cache v2 renommé vers clé canonique : '
                  '$dimlessName → $fileNameV2');
            } catch (renameErr) {
              Log.instance.d('rag',
                  'Rename vers clé canonique échoué (ignoré) : $renameErr');
            }
            return result;
          }
        }
      }

      // ── 2. Legacy cache scan ───────────────────────────────────
      // Only consider legacy files if they carry provable metadata matching
      // the current config. Never use a legacy file blindly as valid vectors.
      final files = await dir.list().toList();
      for (final f in files) {
        if (f is! File) continue;
        final name = p.basename(f.path);
        if (!name.endsWith('.json') || name.endsWith('_v2.json') ||
            name.endsWith('.corrupt')) continue;
        final result = await _loadAndVerifyCache(
          file: f,
          embConfig: embConfig,
          sourceName: sourceName,
          isV2: false,
        );
        if (result != null) return result;
      }
    } catch (e) {
      Log.instance.w('rag', 'Failed to load cache for $sourceName: $e');
    }
    return null;
  }

  /// Internal: read one cache file, verify its metadata, return chunks or null.
  /// Quarantines the file as `.corrupt` on read/parse failure.
  Future<List<DocumentChunk>?> _loadAndVerifyCache({
    required File file,
    required EmbeddingProviderConfig embConfig,
    required String sourceName,
    required bool isV2,
  }) async {
    String jsonStr;
    try {
      jsonStr = await file.readAsString();
    } on FileSystemException catch (e) {
      await _quarantine(file, 'FileSystemException: $e');
      return null;
    }

    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) return null;
      data = decoded;
    } on FormatException catch (e) {
      await _quarantine(file, 'FormatException: $e');
      return null;
    } catch (e) {
      await _quarantine(file, 'JSON parse error: $e');
      return null;
    }

    if (data['chunks'] is! List) return null;

    // ── Metadata verification ──────────────────────────────────
    final cachedProvider = data['embeddingProvider'] as String?;
    final cachedModel    = data['embeddingModel']    as String?;
    final cachedDim      = data['embeddingDimension'] as int?;
    final cacheVersion   = data['cacheVersion']      as String?;
    final cachedSource   = data['sourceName']        as String?;

    if (!isV2) {
      // Legacy file: only proceed if ALL metadata fields are present and
      // exactly match current config.  Without proof, skip (never delete).
      final hasFullMeta = cachedProvider != null &&
          cachedModel != null &&
          cachedDim != null &&
          cacheVersion != null;
      if (!hasFullMeta ||
          cachedProvider != embConfig.provider.name ||
          cachedModel != embConfig.modelId ||
          cachedDim != embConfig.dimension ||
          cachedSource != sourceName) {
        // Cannot prove compatibility — skip silently, will rebuild as v2.
        return null;
      }
    } else {
      // V2 file: verify provider + model.  Dimension verified below via chunks.
      if (cachedProvider != embConfig.provider.name ||
          cachedModel != embConfig.modelId) {
        Log.instance.w(
            'rag',
            'Cache v2 incompatible pour $sourceName : '
            'provider=$cachedProvider≠${embConfig.provider.name} ou '
            'model=$cachedModel≠${embConfig.modelId}');
        return null;
      }
    }

    // ── Deserialize chunks ────────────────────────────────────
    final chunksJson = data['chunks'] as List;
    final chunks = <DocumentChunk>[];
    for (final c in chunksJson) {
      if (c is Map<String, dynamic>) chunks.add(DocumentChunk.fromJson(c));
    }
    if (chunks.isEmpty) return null;

    final hasEmbeddings = chunks.every(
        (c) => c.embedding != null && c.embedding!.isNotEmpty);
    if (!hasEmbeddings) return null;

    // ── Dimension cross-check ────────────────────────────────
    // Two independent sources of truth:
    //   A) embConfig.dimension — from current settings (0 if never persisted)
    //   B) cachedDim          — from the JSON metadata of this cache file
    // Reject if EITHER source has a non-zero value that disagrees with actual.
    final actualDim = chunks.first.embedding!.length;

    // A: config-side check (active after first successful embedding pass)
    if (embConfig.dimension > 0 && actualDim != embConfig.dimension) {
      Log.instance.w(
          'rag',
          'Cache ignoré pour $sourceName : dimension réelle=$actualDim '
          '≠ config=${embConfig.dimension} — reconstruction v2 requise');
      return null;
    }

    // B: metadata-side check (active whenever the JSON was written with a dim)
    if (cachedDim != null && cachedDim > 0 && actualDim != cachedDim) {
      Log.instance.w(
          'rag',
          'Cache ignoré pour $sourceName : dimension réelle=$actualDim '
          '≠ metadata=$cachedDim — fichier corrompu ou modifié manuellement');
      return null;
    }

    final label = isV2 ? 'cache v2' : 'cache legacy (métadonnées prouvées)';
    Log.instance.i(
        'rag',
        'Loaded ${chunks.length} chunks from $label for $sourceName '
        '(provider=${embConfig.provider.name}, model=${embConfig.modelId}, '
        'dim=$actualDim)');
    return chunks;
  }

  /// Renames [file] to `<path>.corrupt` and logs a warning.
  Future<void> _quarantine(File file, String reason) async {
    final corruptPath = '${file.path}.corrupt';
    try {
      await file.rename(corruptPath);
      Log.instance.w(
          'rag',
          'Cache mis en quarantaine : ${p.basename(file.path)} → '
          '${p.basename(corruptPath)} ($reason)');
    } catch (renameErr) {
      Log.instance.w(
          'rag',
          'Cache illisible, quarantaine échouée pour '
          '${p.basename(file.path)}: $reason / rename: $renameErr');
    }
  }

  /// Saves generated embeddings and metadata to disk cache (v2 format).
  ///
  /// **Atomic write**: writes to a `.tmp` file, flushes, then renames to the
  /// final path.  A crash during write leaves only the `.tmp` file, never
  /// corrupting the previously valid cache file.
  Future<void> saveChunksToCache({
    required String sourceName,
    required String content,
    required EmbeddingProviderConfig embConfig,
    required List<DocumentChunk> chunks,
    required SettingsService settings,
    String category = 'Général',
  }) async {
    // Do not cache binary files — their raw bytes corrupt the JSON cache.
    const binaryExts = {
      '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.svg', '.ico',
      '.mp3', '.wav', '.ogg', '.flac', '.mp4', '.mov', '.avi',
    };
    if (binaryExts.contains(p.extension(sourceName).toLowerCase())) {
      Log.instance.d('rag', 'Skip cache pour fichier binaire : $sourceName');
      return;
    }
    try {
      final dir = await getEffectiveCacheDir(settings);
      final hash = computeFileHash(content);

      // Compute actual embedding dimension from first chunk's embedding.
      final actualDim = (chunks.isNotEmpty &&
              chunks.first.embedding != null &&
              chunks.first.embedding!.isNotEmpty)
          ? chunks.first.embedding!.length
          : (embConfig.dimension > 0 ? embConfig.dimension : 0);

      final fileNameV2 = embConfig.cacheFileName(hash);
      final finalFile = File(p.join(dir.path, fileNameV2));
      final tmpFile   = File('${finalFile.path}.tmp');

      final payload = {
        // ── v2 metadata fields ──────────────────────────────
        'cacheVersion'      : 'v2',
        'embeddingProvider' : embConfig.provider.name,
        'embeddingModel'    : embConfig.modelId,
        'embeddingDimension': actualDim,
        // ── Document metadata ───────────────────────────────
        'sourceName'  : sourceName,
        'category'    : category.trim().isNotEmpty ? category.trim() : 'Général',
        'hash'        : hash,
        'createdAt'   : DateTime.now().toIso8601String(),
        'chunkCount'  : chunks.length,
        'rawText'     : content,
        'chunks'      : chunks.map((c) => c.toJson()).toList(),
      };

      // Atomic write: tmp → flush → rename
      await tmpFile.writeAsString(jsonEncode(payload), flush: true);
      await tmpFile.rename(finalFile.path);

      Log.instance.i('rag',
          'Saved ${chunks.length} chunks to cache v2 ($fileNameV2) '
          'provider=${embConfig.provider.name} model=${embConfig.modelId} '
          'dim=$actualDim');
    } catch (e) {
      Log.instance.w('rag', 'Failed to save cache for $sourceName: $e');
    }
  }

  /// Backward-compatible alias for [saveChunksToCache].
  /// Builds a minimal [EmbeddingProviderConfig] from the legacy [model] string.
  Future<void> saveToCache({
    required String sourceName,
    required String content,
    required String model,
    required List<DocumentChunk> chunks,
    required SettingsService settings,
    String category = 'Général',
    String endpoint = 'http://127.0.0.1:1234/v1',
    int dimension = 0,
  }) {
    final embConfig = EmbeddingProviderConfig(
      provider: EmbeddingProvider.lmStudio,
      modelId: model,
      dimension: dimension,
      endpoint: endpoint,
    );
    return saveChunksToCache(
      sourceName: sourceName,
      content: content,
      embConfig: embConfig,
      chunks: chunks,
      settings: settings,
      category: category,
    );
  }

  /// Returns total cached files count and disk size in bytes.
  Future<(int fileCount, int totalBytes)> getCacheStats(SettingsService settings) async {
    try {
      final dir = await getEffectiveCacheDir(settings);
      if (!await dir.exists()) return (0, 0);
      int count = 0;
      int bytes = 0;
      final files = await dir.list().toList();
      for (final f in files) {
        if (f is File && f.path.endsWith('.json')) {
          count++;
          bytes += await f.length();
        }
      }
      return (count, bytes);
    } catch (_) {
      return (0, 0);
    }
  }

  /// Clears all vector cache files on disk.
  Future<int> clearCache(SettingsService settings) async {
    try {
      final dir = await getEffectiveCacheDir(settings);
      if (!await dir.exists()) return 0;
      int deleted = 0;
      final files = await dir.list().toList();
      for (final f in files) {
        if (f is File && f.path.endsWith('.json')) {
          await f.delete();
          deleted++;
        }
      }
      Log.instance.i('rag', 'Cleared $deleted RAG cache files from ${dir.path}');
      return deleted;
    } catch (e) {
      Log.instance.e('rag', 'Failed to clear RAG cache: $e');
      return 0;
    }
  }

  /// Lists all cached documents stored in the RAG cache directory.
  Future<List<CachedDocumentEntry>> listCachedDocuments(SettingsService settings) async {
    try {
      final dir = await getEffectiveCacheDir(settings);
      if (!await dir.exists()) return [];
      final entries = <CachedDocumentEntry>[];
      final files = await dir.list().toList();
      for (final f in files) {
        if (f is! File) continue;
        final name = p.basename(f.path);
        // Skip quarantine and temp files
        if (name.endsWith('.corrupt') || name.endsWith('.tmp')) continue;
        if (!name.endsWith('.json')) continue;
        try {
          String jsonStr;
          try {
            jsonStr = await f.readAsString();
          } on FileSystemException catch (e) {
            await _quarantine(f, 'listCachedDocuments FileSystemException: $e');
            continue;
          }
          Map<String, dynamic> data;
          try {
            final decoded = jsonDecode(jsonStr);
            if (decoded is! Map<String, dynamic>) continue;
            data = decoded;
          } on FormatException catch (e) {
            await _quarantine(f, 'listCachedDocuments FormatException: $e');
            continue;
          }
          if (data['chunks'] is! List) continue;
          final chunksJson = data['chunks'] as List;
          final chunks = <DocumentChunk>[];
          for (final c in chunksJson) {
            if (c is Map<String, dynamic>) chunks.add(DocumentChunk.fromJson(c));
          }
          final sourceName = data['sourceName'] as String? ?? name;
          final category   = data['category']   as String? ?? 'Général';
          final hash       = data['hash']        as String? ?? '';
          // Support both legacy 'model' and v2 'embeddingModel' fields
          final model = (data['embeddingModel'] ?? data['model']) as String? ?? '';
          final createdAt  = DateTime.tryParse(data['createdAt'] as String? ?? '') ?? DateTime.now();
          final size = await f.length();
          final text = chunks.map((c) => c.text).join('\n\n');
          // Métadonnées v2 : provider et dimension. Null = cache legacy.
          // Ne JAMAIS déduire le provider depuis la dimension seule.
          final embProvider  = data['embeddingProvider']  as String?;
          final embDimension = (data['embeddingDimension'] as num?)?.toInt() ?? 0;

          entries.add(CachedDocumentEntry(
            fileName: name,
            sourceName: sourceName,
            category: category,
            hash: hash,
            model: model,
            createdAt: createdAt,
            chunkCount: chunks.length,
            fileSizeBytes: size,
            chunks: chunks,
            reconstructedText: text,
            embeddingProvider: embProvider,
            embeddingDimension: embDimension,
          ));
        } catch (e) {
          Log.instance.w('rag', 'Failed to parse cache file ${f.path}: $e');
        }
      }
      entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return entries;
    } catch (e) {
      Log.instance.e('rag', 'Error listing cached documents: $e');
      return [];
    }
  }

  /// Updates the category for a specific cached document JSON file.
  Future<bool> updateCachedDocumentCategory(String fileName, String newCategory, SettingsService settings) async {
    try {
      final dir = await getEffectiveCacheDir(settings);
      final file = File(p.join(dir.path, fileName));
      if (!await file.exists()) return false;
      final jsonStr = await file.readAsString();
      final data = jsonDecode(jsonStr);
      if (data is Map<String, dynamic>) {
        data['category'] = newCategory.trim().isNotEmpty ? newCategory.trim() : 'Général';
        // Atomic write: tmp → flush → rename
        final tmpFile = File('${file.path}.tmp');
        await tmpFile.writeAsString(jsonEncode(data), flush: true);
        await tmpFile.rename(file.path);
        return true;
      }
    } catch (e) {
      Log.instance.e('rag', 'Failed to update category for $fileName: $e');
    }
    return false;
  }

  /// Batch updates the category for multiple cached files.
  Future<int> batchUpdateCategory(List<String> fileNames, String newCategory, SettingsService settings) async {
    int count = 0;
    for (final f in fileNames) {
      final ok = await updateCachedDocumentCategory(f, newCategory, settings);
      if (ok) count++;
    }
    return count;
  }

  /// Renames all occurrences of oldCategory in cached documents to newCategory.
  Future<int> renameCategoryInCachedDocuments(String oldCategory, String newCategory, SettingsService settings) async {
    final list = await listCachedDocuments(settings);
    int updatedCount = 0;
    for (final doc in list) {
      if (doc.category.toLowerCase() == oldCategory.toLowerCase()) {
        await updateCachedDocumentCategory(doc.fileName, newCategory, settings);
        updatedCount++;
      }
    }
    return updatedCount;
  }

  /// Reassigns cached documents in oldCategory to fallbackCategory (e.g. 'Général' when deleting a category).
  Future<int> reassignCategoryInCachedDocuments(String oldCategory, String fallbackCategory, SettingsService settings) async {
    return renameCategoryInCachedDocuments(oldCategory, fallbackCategory, settings);
  }

  /// Deletes a specific cache file.
  Future<bool> deleteCachedFile(String fileName, SettingsService settings) async {
    try {
      final dir = await getEffectiveCacheDir(settings);
      final file = File(p.join(dir.path, fileName));
      if (await file.exists()) {
        await file.delete();
        return true;
      }
    } catch (e) {
      Log.instance.e('rag', 'Failed to delete cache file $fileName: $e');
    }
    return false;
  }

  /// 4. MULTI-STRATEGY RETRIEVAL PIPELINE (Hybrid RRF / Semantic / Keyword)
  ///
  /// [crispEmbedder] : instance CrispEmbed optionnelle. Si non-null et que le
  /// provider résolu est crispEmbed, l'encodage de la requête se fait via FFI
  /// (aucune requête HTTP). Si null pour un provider crispEmbed, le service
  /// journalise l'indisponibilité et dégrade vers mots-clés.
  Future<List<RagSearchResult>> retrieveTopChunks({
    required String query,
    required List<DocumentChunk> chunks,
    required String endpoint,
    String? model,
    int topK = 5,
    double minRelevance = 0.15,
    RagSearchMode mode = RagSearchMode.hybrid,
    CrispEmbed? crispEmbedder,
  }) async {
    if (query.trim().isEmpty || chunks.isEmpty) return [];

    // 1. Semantic Vector Search
    final semanticResults = <RagSearchResult>[];
    if (mode == RagSearchMode.hybrid || mode == RagSearchMode.semantic) {
      try {
        final queryEmbeddings = await fetchEmbeddings(
          texts: [query],
          endpoint: endpoint,
          model: model,
          crispEmbedder: crispEmbedder,
        );

        if (queryEmbeddings.isNotEmpty && queryEmbeddings.first.isNotEmpty) {
          final qVec = queryEmbeddings.first;
          for (final chunk in chunks) {
            if (chunk.embedding != null && chunk.embedding!.isNotEmpty) {
              final sim = _cosineSimilarity(qVec, chunk.embedding!);
              if (sim >= minRelevance) {
                semanticResults.add(RagSearchResult(chunk: chunk, score: sim));
              }
            }
          }
          lastFallbackReason = null;
          semanticResults.sort((a, b) => b.score.compareTo(a.score));
        } else {
          lastFallbackReason = 'Embedding vide ou timeout';
        }
      } catch (e) {
        lastFallbackReason = 'Erreur/Timeout vecteur: $e';
        Log.instance.w('rag', 'Vector search unavailable, falling back to lexical: $e');
      }
    }

    // 2. Keyword Lexical Search (overlap normalisé : matches / sqrt(chunkLen))
    List<RagSearchResult> keywordResults = [];
    if (mode == RagSearchMode.hybrid || mode == RagSearchMode.keyword || semanticResults.isEmpty) {
      keywordResults = _keywordFallbackSearch(query, chunks, topK: chunks.length);
    }

    // 3. Dispatch based on requested mode — tracking actual mode used
    if (mode == RagSearchMode.semantic && semanticResults.isNotEmpty) {
      lastRetrievalMode = RagRetrievalMode.semantic;
      Log.instance.i('rag',
          'Retrieval: mode=semantic chunks=${semanticResults.take(topK).length} '
          'semantic=${semanticResults.length} keyword=0');
      return semanticResults.take(topK).toList();
    }

    if (mode == RagSearchMode.keyword) {
      final result = keywordResults.take(topK).toList();
      lastRetrievalMode = result.isEmpty
          ? RagRetrievalMode.positionalFallback
          : RagRetrievalMode.bm25Fallback;
      Log.instance.i('rag',
          'Retrieval: mode=keyword(${lastRetrievalMode!.label}) chunks=${result.length} '
          'semantic=0 keyword=${keywordResults.length}');
      return result;
    }

    // 4. Hybrid Mode: Reciprocal Rank Fusion (RRF)
    if (semanticResults.isEmpty) {
      // Aucun vecteur disponible — dégradation vers mots-clés
      final result = keywordResults.take(topK).toList();
      if (result.isEmpty) {
        lastRetrievalMode = RagRetrievalMode.positionalFallback;
        Log.instance.w('rag',
            'Retrieval: mode=positionalFallback — aucun résultat sémantique ni lexical '
            '(chunks=${chunks.length})');
      } else {
        lastRetrievalMode = RagRetrievalMode.bm25Fallback;
        Log.instance.w('rag',
            'Retrieval: mode=bm25Fallback chunks=${result.length} '
            'semantic=0 keyword=${keywordResults.length}');
      }
      return result;
    }

    const int kRrf = 60;
    final rrfScores = <String, double>{};
    final chunkMap = <String, DocumentChunk>{};

    for (int rank = 0; rank < semanticResults.length; rank++) {
      final r = semanticResults[rank];
      chunkMap[r.chunk.id] = r.chunk;
      rrfScores[r.chunk.id] = (rrfScores[r.chunk.id] ?? 0.0) + (1.0 / (kRrf + rank + 1));
    }

    for (int rank = 0; rank < keywordResults.length; rank++) {
      final r = keywordResults[rank];
      chunkMap[r.chunk.id] = r.chunk;
      rrfScores[r.chunk.id] = (rrfScores[r.chunk.id] ?? 0.0) + (1.0 / (kRrf + rank + 1));
    }

    final fusedResults = rrfScores.entries.map((e) {
      final chunk = chunkMap[e.key]!;
      return RagSearchResult(chunk: chunk, score: e.value);
    }).toList();

    fusedResults.sort((a, b) => b.score.compareTo(a.score));

    // Multi-Source Round-Robin Interleaving: ensure representation from all open documents
    final distinctSources = chunks.map((c) => c.sourceName).toSet();
    List<RagSearchResult> finalResult;
    if (distinctSources.length <= 1) {
      finalResult = fusedResults.take(topK).toList();
    } else {
      final sourceMap = <String, List<RagSearchResult>>{};
      for (final s in distinctSources) {
        sourceMap[s] = fusedResults.where((r) => r.chunk.sourceName == s).toList();
      }

      final balanced = <RagSearchResult>[];
      int idx = 0;
      while (balanced.length < topK) {
        bool addedAny = false;
        for (final s in distinctSources) {
          final list = sourceMap[s];
          if (list != null && idx < list.length) {
            balanced.add(list[idx]);
            addedAny = true;
            if (balanced.length >= topK) break;
          }
        }
        if (!addedAny) break;
        idx++;
      }
      finalResult = balanced;
    }

    lastRetrievalMode = RagRetrievalMode.hybrid;
    Log.instance.i('rag',
        'Retrieval: mode=hybrid chunks=${finalResult.length} '
        'semantic=${semanticResults.length} keyword=${keywordResults.length}');
    return finalResult;
  }

  List<RagSearchResult> _keywordFallbackSearch(String query, List<DocumentChunk> chunks, {int topK = 4}) {
    final queryTokens = query
        .toLowerCase()
        .split(RegExp(r'[^\w\u00C0-\u017F]+'))
        .where((t) => t.length > 2)
        .toSet();

    if (queryTokens.isEmpty) {
      return chunks.take(topK).map((c) => RagSearchResult(chunk: c, score: 0.5)).toList();
    }

    final results = <RagSearchResult>[];

    for (final chunk in chunks) {
      final chunkTokens = chunk.text
          .toLowerCase()
          .split(RegExp(r'[^\w\u00C0-\u017F]+'))
          .where((t) => t.isNotEmpty)
          .toList();

      if (chunkTokens.isEmpty) continue;

      int matches = 0;
      for (final t in chunkTokens) {
        if (queryTokens.contains(t)) matches++;
      }

      if (matches > 0) {
        final score = matches / math.sqrt(chunkTokens.length);
        results.add(RagSearchResult(chunk: chunk, score: score));
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(topK).toList();
  }

  /// L2 Normalization helper
  List<double> _normalizeL2(List<double> vec) {
    double sumSq = 0.0;
    for (final v in vec) {
      sumSq += v * v;
    }
    final norm = math.sqrt(sumSq);
    if (norm == 0.0) return vec;
    return vec.map((v) => v / norm).toList();
  }

  /// Cosine Similarity calculation between two L2-normalized vectors
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot.clamp(-1.0, 1.0);
  }

  /// Indexes an external file (EPUB, PDF, TXT, DOCX) into the RAG cache.
  Future<CachedDocumentEntry> indexFile(
    String filePath, {
    required SettingsService settings,
    String? embeddingModel,
  }) async {
    final docSource = DocumentSourceService();
    final docItem = await docSource.parseFile(filePath);
    final text = cleanDocumentText(docItem.textContent, sourceType: docItem.type);
    final chunks = createChunks(
      sourceName: docItem.name,
      sourceType: docItem.type,
      text: text,
      targetWords: settings.ragChunkSize,
    );

    final model = embeddingModel ?? 'text-embedding-qwen3-embedding-4b';
    final embConfig = EmbeddingProviderConfig(
      provider: EmbeddingProvider.lmStudio,
      modelId: model,
      dimension: 0, // unknown at this stage
      endpoint: 'http://127.0.0.1:1234/v1',
    );
    await saveChunksToCache(
      sourceName: docItem.name,
      content: text,
      embConfig: embConfig,
      chunks: chunks,
      settings: settings,
    );

    final file = File(filePath);
    final sizeBytes = file.existsSync() ? file.lengthSync() : text.length;

    return CachedDocumentEntry(
      fileName: p.basename(filePath),
      sourceName: docItem.name,
      hash: computeFileHash(text),
      model: model,
      createdAt: DateTime.now(),
      chunkCount: chunks.length,
      fileSizeBytes: sizeBytes,
      chunks: chunks,
      reconstructedText: text,
    );
  }
}

/// Riverpod provider for DocumentRagService
final documentRagServiceProvider = Provider<DocumentRagService>((ref) {
  return DocumentRagService();
});
