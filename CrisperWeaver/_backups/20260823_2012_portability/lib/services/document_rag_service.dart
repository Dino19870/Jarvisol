import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'document_source_service.dart';
import 'log_service.dart';
import 'settings_service.dart';

/// Search mode strategy for RAG retrieval.
enum RagSearchMode {
  hybrid(
    '⚡ Hybride (Recommandé)',
    'Combine le sens profond (vecteurs) et les mots exacts (BM25) avec fusion RRF pour une pertinence optimale.',
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
  });
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

  DocumentRagService({http.Client? client}) : _client = client ?? http.Client();

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
  /// Calls standard OpenAI/LM Studio embeddings endpoint (`POST $endpoint/embeddings`)
  Future<List<List<double>>> fetchEmbeddings({
    required List<String> texts,
    required String endpoint,
    String? model,
    int batchSize = 16,
    void Function(int current, int total)? onProgress,
  }) async {
    if (texts.isEmpty) return [];

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

        final timeoutDuration = texts.length == 1 ? const Duration(seconds: 2) : const Duration(seconds: 45);
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
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'CrisperWeaver', 'rag_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Attempts to load pre-calculated chunks and embeddings from disk cache.
  Future<List<DocumentChunk>?> loadFromCache({
    required String sourceName,
    required String content,
    required String model,
    required SettingsService settings,
  }) async {
    try {
      final dir = await getEffectiveCacheDir(settings);
      final hash = computeFileHash(content);
      final cleanModel = model.replaceAll(RegExp(r'[^\w\.-]'), '_');
      final fileName = '${hash}_$cleanModel.json';
      final file = File(p.join(dir.path, fileName));
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final data = jsonDecode(jsonStr);
        if (data is Map<String, dynamic> && data['chunks'] is List) {
          final chunksJson = data['chunks'] as List;
          final chunks = chunksJson
              .map((c) => DocumentChunk.fromJson(c as Map<String, dynamic>))
              .toList();
          if (chunks.isNotEmpty && chunks.every((c) => c.embedding != null && c.embedding!.isNotEmpty)) {
            Log.instance.i('rag', 'Loaded ${chunks.length} chunks from cache for $sourceName (Model: $model)');
            return chunks;
          }
        }
      }

      // Fallback: Lookup by sourceName & model
      final files = await dir.list().toList();
      for (final f in files) {
        if (f is File && f.path.endsWith('.json')) {
          try {
            final jsonStr = await f.readAsString();
            final data = jsonDecode(jsonStr);
            if (data is Map<String, dynamic> &&
                data['sourceName'] == sourceName &&
                (data['model'] == model || model.isEmpty)) {
              if (data['chunks'] is List) {
                final chunksJson = data['chunks'] as List;
                final chunks = chunksJson
                    .map((c) => DocumentChunk.fromJson(c as Map<String, dynamic>))
                    .toList();
                if (chunks.isNotEmpty && chunks.every((c) => c.embedding != null && c.embedding!.isNotEmpty)) {
                  Log.instance.i('rag', 'Loaded ${chunks.length} chunks from fallback name cache for $sourceName');
                  return chunks;
                }
              }
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      Log.instance.w('rag', 'Failed to load cache for $sourceName: $e');
    }
    return null;
  }

  /// Saves generated embeddings for a file to disk cache.
  Future<void> saveChunksToCache({
    required String sourceName,
    required String content,
    required String model,
    required List<DocumentChunk> chunks,
    required SettingsService settings,
    String category = 'Général',
  }) async {
    try {
      final dir = await getEffectiveCacheDir(settings);
      final hash = computeFileHash(content);
      final cleanModel = model.replaceAll(RegExp(r'[^\w\.-]'), '_');
      final fileName = '${hash}_$cleanModel.json';
      final file = File(p.join(dir.path, fileName));
      final payload = {
        'sourceName': sourceName,
        'category': category.trim().isNotEmpty ? category.trim() : 'Général',
        'hash': hash,
        'model': model,
        'createdAt': DateTime.now().toIso8601String(),
        'chunkCount': chunks.length,
        'rawText': content,
        'chunks': chunks.map((c) => c.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(payload), flush: true);
      Log.instance.i('rag', 'Saved ${chunks.length} chunks to cache ($fileName)');
    } catch (e) {
      Log.instance.w('rag', 'Failed to save cache for $sourceName: $e');
    }
  }

  /// Alias for backward compatibility
  Future<void> saveToCache({
    required String sourceName,
    required String content,
    required String model,
    required List<DocumentChunk> chunks,
    required SettingsService settings,
    String category = 'Général',
  }) => saveChunksToCache(
    sourceName: sourceName,
    content: content,
    model: model,
    chunks: chunks,
    settings: settings,
    category: category,
  );

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
        if (f is File && f.path.endsWith('.json')) {
          try {
            final jsonStr = await f.readAsString();
            final data = jsonDecode(jsonStr);
            if (data is Map<String, dynamic> && data['chunks'] is List) {
              final chunksJson = data['chunks'] as List;
              final chunks = chunksJson
                  .map((c) => DocumentChunk.fromJson(c as Map<String, dynamic>))
                  .toList();
              final sourceName = data['sourceName'] as String? ?? p.basename(f.path);
              final category = data['category'] as String? ?? 'Général';
              final hash = data['hash'] as String? ?? '';
              final model = data['model'] as String? ?? '';
              final createdAt = DateTime.tryParse(data['createdAt'] as String? ?? '') ?? DateTime.now();
              final size = await f.length();
              final text = chunks.map((c) => c.text).join('\n\n');

              entries.add(CachedDocumentEntry(
                fileName: p.basename(f.path),
                sourceName: sourceName,
                category: category,
                hash: hash,
                model: model,
                createdAt: createdAt,
                chunkCount: chunks.length,
                fileSizeBytes: size,
                chunks: chunks,
                reconstructedText: text,
              ));
            }
          } catch (e) {
            Log.instance.w('rag', 'Failed to parse cache file ${f.path}: $e');
          }
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
        await file.writeAsString(jsonEncode(data), flush: true);
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
  Future<List<RagSearchResult>> retrieveTopChunks({
    required String query,
    required List<DocumentChunk> chunks,
    required String endpoint,
    String? model,
    int topK = 5,
    double minRelevance = 0.15,
    RagSearchMode mode = RagSearchMode.hybrid,
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
          semanticResults.sort((a, b) => b.score.compareTo(a.score));
        }
      } catch (e) {
        Log.instance.w('rag', 'Vector search unavailable, falling back to lexical: $e');
      }
    }

    // 2. Keyword Lexical Search (BM25 / Overlap)
    List<RagSearchResult> keywordResults = [];
    if (mode == RagSearchMode.hybrid || mode == RagSearchMode.keyword || semanticResults.isEmpty) {
      keywordResults = _keywordFallbackSearch(query, chunks, topK: chunks.length);
    }

    // 3. Dispatch based on requested mode
    if (mode == RagSearchMode.semantic && semanticResults.isNotEmpty) {
      return semanticResults.take(topK).toList();
    }

    if (mode == RagSearchMode.keyword) {
      return keywordResults.take(topK).toList();
    }

    // 4. Hybrid Mode: Reciprocal Rank Fusion (RRF)
    if (semanticResults.isEmpty) {
      return keywordResults.take(topK).toList();
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
    if (distinctSources.length <= 1) {
      return fusedResults.take(topK).toList();
    }

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

    return balanced;
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
    await saveChunksToCache(
      sourceName: docItem.name,
      content: text,
      model: model,
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
