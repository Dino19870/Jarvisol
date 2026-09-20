// lib/services/ai_conversations_service.dart
// Reads Antigravity conversation transcripts from the brain/ directory.
// Includes: JSON index for deduplication & tracking, multi-format export (TXT/MD/JSON).

import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../utils/app_paths.dart';
import 'log_service.dart';

// ── Models ────────────────────────────────────────────────────────────────────

class AiConversationMeta {
  final String id;
  final String title;
  final DateTime date;
  final int messageCount;
  final int sizeKb;
  final String transcriptPath;
  // Index fields (can be null if conversation never exported)
  final DateTime? ragExportedAt;
  final String?  ragExportPath;
  // Search fields
  final bool    contentMatch;   // true = trouvé dans le contenu (pas le titre)
  final String? matchSnippet;   // extrait de 120 cars autour de la correspondance

  const AiConversationMeta({
    required this.id,
    required this.title,
    required this.date,
    required this.messageCount,
    required this.sizeKb,
    required this.transcriptPath,
    this.ragExportedAt,
    this.ragExportPath,
    this.contentMatch  = false,
    this.matchSnippet,
  });

  bool get isRagExported => ragExportedAt != null;
}

class AiMessage {
  final int stepIndex;
  final bool isUser;
  final String content;
  const AiMessage({required this.stepIndex, required this.isUser, required this.content});
}

// ── Conversation Index (JSON-based lightweight DB) ────────────────────────────

class _ConvIndexEntry {
  final String id;
  final String title;
  final String date;           // ISO8601 date
  final int    messageCount;
  final int    sizeKb;
  final String transcriptPath;
  final String lastModified;   // ISO8601 — used for change detection
  final String? ragExportedAt;
  final String? ragExportPath;

  const _ConvIndexEntry({
    required this.id,
    required this.title,
    required this.date,
    required this.messageCount,
    required this.sizeKb,
    required this.transcriptPath,
    required this.lastModified,
    this.ragExportedAt,
    this.ragExportPath,
  });

  factory _ConvIndexEntry.fromJson(Map<String, dynamic> m) => _ConvIndexEntry(
    id:             m['id']            as String? ?? '',
    title:          m['title']         as String? ?? '(sans titre)',
    date:           m['date']          as String? ?? '',
    messageCount:   m['messageCount']  as int?    ?? 0,
    sizeKb:         m['sizeKb']        as int?    ?? 0,
    transcriptPath: m['transcriptPath']as String? ?? '',
    lastModified:   m['lastModified']  as String? ?? '',
    ragExportedAt:  m['ragExportedAt'] as String?,
    ragExportPath:  m['ragExportPath'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id':             id,
    'title':          title,
    'date':           date,
    'messageCount':   messageCount,
    'sizeKb':         sizeKb,
    'transcriptPath': transcriptPath,
    'lastModified':   lastModified,
    if (ragExportedAt != null) 'ragExportedAt': ragExportedAt,
    if (ragExportPath  != null) 'ragExportPath':  ragExportPath,
  };

  _ConvIndexEntry copyWith({
    String? ragExportedAt,
    String? ragExportPath,
    String? transcriptPath,
  }) =>
    _ConvIndexEntry(
      id: id,
      title: title,
      date: date,
      messageCount: messageCount,
      sizeKb: sizeKb,
      transcriptPath: transcriptPath ?? this.transcriptPath,
      lastModified: lastModified,
      ragExportedAt: ragExportedAt ?? this.ragExportedAt,
      ragExportPath: ragExportPath ?? this.ragExportPath,
    );
}

// ── Service ───────────────────────────────────────────────────────────────────

class AiConversationsService {
  AiConversationsService();

  // ── Paths ───────────────────────────────────────────────────────────────────

  /// Répertoire de stockage portable sous la racine de données applicative
  static String get defaultBrainDir {
    return p.join(AppPaths.dataDir.path, 'brain');
  }

  /// Emplacement legacy sous le profil utilisateur (pour migration non destructrice)
  static String? get legacyBrainDir {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return p.join(userProfile, '.gemini', 'antigravity', 'brain');
      }
    }
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, '.gemini', 'antigravity', 'brain');
      }
    }
    return null;
  }

  String _brainDir = defaultBrainDir;
  void setBrainDir(String dir) {
    _brainDir = dir;
    _indexCache = null; // reset cache when dir changes
  }
  String get brainDir => _brainDir;
  bool get isAvailable => Directory(_brainDir).existsSync();

  /// Path of the JSON index file (one level above brain/ -> dataDir)
  String get _indexPath =>
    p.join(p.dirname(_brainDir), 'conversations_index.json');

  // ── JSON Index I/O ──────────────────────────────────────────────────────────

  Map<String, _ConvIndexEntry>? _indexCache;

  /// Résolution dynamique et sûre du chemin de transcription pour garantir la portabilité
  String _resolveTranscriptPath(String storedPath) {
    if (storedPath.isEmpty) return storedPath;
    if (!p.isAbsolute(storedPath)) {
      return p.normalize(p.join(_brainDir, storedPath));
    }
    if (File(storedPath).existsSync()) return storedPath;

    // Si ancien chemin absolu qui n'existe plus (ex: déplacement de racine portable A -> B)
    final cleanPath = storedPath.replaceAll(r'\', '/');
    final brainIdx = cleanPath.lastIndexOf('/brain/');
    if (brainIdx != -1) {
      final afterBrain = cleanPath.substring(brainIdx + 7);
      if (afterBrain.contains('.system_generated') || afterBrain.contains('transcript.jsonl')) {
        final candidate = p.normalize(p.join(_brainDir, afterBrain));
        if (File(candidate).existsSync()) return candidate;
      }
    }
    // Fallback par identifiant de conversation si présent dans l'arborescence
    final segments = p.split(storedPath);
    final logIdx = segments.indexOf('.system_generated');
    if (logIdx > 0) {
      final convId = segments[logIdx - 1];
      final candidate = p.normalize(p.join(_brainDir, convId, '.system_generated', 'logs', 'transcript.jsonl'));
      if (File(candidate).existsSync()) return candidate;
    }
    return storedPath;
  }

  /// Extraction robuste et structurellement ancrée de l'ancien dataRoot depuis un transcriptPath historique.
  /// Vérifie la présence de '/brain/' (dernier segment) et la structure interne canonique
  /// ('.system_generated' ou 'transcript.jsonl') pour éliminer tout faux positif dû à un dossier parent nommé 'brain'.
  static String? _extractOldDataRootFromTranscript(String transcriptPath) {
    if (transcriptPath.isEmpty) return null;
    final clean = transcriptPath.replaceAll(r'\', '/');
    final brainIdx = clean.lastIndexOf('/brain/');
    if (brainIdx == -1) return null;
    final afterBrain = clean.substring(brainIdx + 7);
    if (!afterBrain.contains('.system_generated') && !afterBrain.contains('transcript.jsonl')) {
      return null;
    }
    final prefix = clean.substring(0, brainIdx);
    if (prefix.isEmpty) return null;
    return p.normalize(prefix);
  }

  /// Résolution sûre du chemin d'export RAG :
  /// - Relatif si interne portable (joint dynamiquement à dataRoot)
  /// - Préservé à l'identique si absolu existant (externe ou local)
  /// - Rebasé sous le nouveau dataRoot SI ET SEULEMENT SI le transcriptPath historique
  ///   de la même entrée prouve structurellement son appartenance à l'ancien dataRoot.
  /// - Strictement aucun fallback par simple nom de dossier (/rag_exports/) ou basename.
  String? _resolveRagExportPath(String? storedPath, {String? rawTranscriptPath}) {
    if (storedPath == null || storedPath.isEmpty) return storedPath;
    final dataRoot = p.normalize(p.dirname(_brainDir));
    if (!p.isAbsolute(storedPath)) {
      return p.normalize(p.join(dataRoot, storedPath));
    }
    if (File(storedPath).existsSync()) return storedPath;

    // Si ancien chemin absolu qui n'existe plus à cet emplacement :
    // On extrait l'ancienne racine de données (OLD_DATA_ROOT) à partir du transcriptPath historique
    if (rawTranscriptPath != null && rawTranscriptPath.isNotEmpty && p.isAbsolute(rawTranscriptPath)) {
      final oldDataRoot = _extractOldDataRootFromTranscript(rawTranscriptPath);
      if (oldDataRoot != null) {
        final normStored = p.normalize(storedPath);
        if (p.isWithin(oldDataRoot, normStored) || normStored == oldDataRoot) {
          final rel = p.relative(normStored, from: oldDataRoot);
          final candidate = p.normalize(p.join(dataRoot, rel));
          return candidate;
        }
      }
    }

    // Si le chemin n'a pas été prouvé comme appartenant à l'ancien dataRoot :
    // Préservation stricte du chemin externe sans rebasage ni capture arbitraire.
    return storedPath;
  }

  /// Sérialisation normalisée de ragExportPath :
  /// Règle unique et non ambiguë :
  /// A. Donnée interne Jarvisol sous dataRoot -> chemin relatif à dataRoot.
  /// B. Tout chemin situé hors dataRoot (même sous la racine de l'application) -> chemin absolu externe préservé.
  String? _storedRagExportPath(String? absoluteOrRelative) {
    if (absoluteOrRelative == null || absoluteOrRelative.isEmpty) return absoluteOrRelative;
    final dataRoot = p.normalize(p.dirname(_brainDir));
    if (!p.isAbsolute(absoluteOrRelative)) {
      return absoluteOrRelative.replaceAll(r'\', '/');
    }
    final absolute = p.normalize(absoluteOrRelative);
    if (p.isWithin(dataRoot, absolute) || absolute == dataRoot) {
      return p.relative(absolute, from: dataRoot).replaceAll(r'\', '/');
    }
    // Tout chemin hors dataRoot est préservé comme destination explicite/externe
    return absoluteOrRelative.replaceAll(r'\', '/');
  }

  Future<Map<String, _ConvIndexEntry>> _loadIndex() async {
    if (_indexCache != null) return _indexCache!;
    final file = File(_indexPath);
    if (!file.existsSync()) return _indexCache = {};
    try {
      final raw = jsonDecode(await file.readAsString(encoding: utf8)) as Map<String, dynamic>;
      final convs = raw['conversations'] as Map<String, dynamic>? ?? {};
      _indexCache = convs.map((k, v) {
        final entry = _ConvIndexEntry.fromJson(v as Map<String, dynamic>);
        return MapEntry(k, entry.copyWith(
          transcriptPath: _resolveTranscriptPath(entry.transcriptPath),
          ragExportPath: _resolveRagExportPath(
            entry.ragExportPath,
            rawTranscriptPath: entry.transcriptPath,
          ),
        ));
      });
    } catch (_) {
      _indexCache = {};
    }
    return _indexCache!;
  }

  Future<void> _saveIndex(Map<String, _ConvIndexEntry> index) async {
    _indexCache = index;
    final file = File(_indexPath);
    await file.create(recursive: true);

    // Normaliser transcriptPath et ragExportPath pour stocker des formes relatives portables
    final portableMap = index.map((k, v) {
      String rel = v.transcriptPath;
      if (p.isAbsolute(rel)) {
        if (p.isWithin(_brainDir, rel)) {
          rel = p.relative(rel, from: _brainDir).replaceAll(r'\', '/');
        } else {
          final clean = rel.replaceAll(r'\', '/');
          final bIdx = clean.lastIndexOf('/brain/');
          if (bIdx != -1) {
            final after = clean.substring(bIdx + 7);
            if (after.contains('.system_generated') || after.contains('transcript.jsonl')) {
              rel = after;
            }
          }
        }
      }
      return MapEntry(k, v.copyWith(
        transcriptPath: rel.replaceAll(r'\', '/'),
        ragExportPath: _storedRagExportPath(v.ragExportPath),
      ).toJson());
    });

    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version':  1,
        'lastSync': DateTime.now().toIso8601String(),
        'conversations': portableMap,
      }),
      encoding: utf8,
    );
  }

  /// Migration one-shot sécurisée depuis l'ancien store externe (Section 11)
  Future<int> migrateLegacyConversationsIfNeeded() async {
    final bDir = Directory(_brainDir);
    if (bDir.existsSync()) {
      try {
        final existing = bDir.listSync().whereType<Directory>().toList();
        if (existing.isNotEmpty) {
          return 0; // Le store portable existe déjà et contient des données
        }
      } catch (_) {}
    }
    final leg = legacyBrainDir;
    if (leg == null) return 0;
    final legDir = Directory(leg);
    if (!legDir.existsSync()) return 0;

    int migrated = 0;
    try {
      await bDir.create(recursive: true);
      for (final entity in legDir.listSync()) {
        if (entity is! Directory) continue;
        final convName = p.basename(entity.path);
        if (convName == 'tempmediaStorage') continue;
        final srcTranscript = File(p.join(entity.path, '.system_generated', 'logs', 'transcript.jsonl'));
        if (!srcTranscript.existsSync()) continue;

        final dstLogDir = Directory(p.join(bDir.path, convName, '.system_generated', 'logs'));
        await dstLogDir.create(recursive: true);
        final dstTranscript = File(p.join(dstLogDir.path, 'transcript.jsonl'));
        if (!dstTranscript.existsSync()) {
          await srcTranscript.copy(dstTranscript.path);
          migrated++;
        }
      }
      if (migrated > 0) {
        Log.instance.i('ai_conv', 'Migration legacy: $migrated conversations copiées vers le store portable');
      }
    } catch (e) {
      Log.instance.w('ai_conv', 'Erreur lors de la migration legacy des conversations: $e');
    }
    return migrated;
  }

  // ── List Conversations (updates index automatically) ────────────────────────

  Future<List<AiConversationMeta>> listConversations({String query = ''}) async {
    await migrateLegacyConversationsIfNeeded();
    final dir = Directory(_brainDir);
    if (!dir.existsSync()) return [];

    final index     = await _loadIndex();
    final allMetas  = <AiConversationMeta>[];   // toutes les convs scannées
    bool indexDirty = false;

    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      if (p.basename(entity.path) == 'tempmediaStorage') continue;
      final transcriptFile = File(
        p.join(entity.path, '.system_generated', 'logs', 'transcript.jsonl'));
      if (!transcriptFile.existsSync()) continue;

      final convId = p.basename(entity.path);
      final stat   = await transcriptFile.stat();
      final modStr = stat.modified.toIso8601String();
      final cached = index[convId];

      AiConversationMeta meta;

      // ⚡ Fast path — rien de changé depuis le dernier scan
      if (cached != null && cached.lastModified == modStr) {
        meta = AiConversationMeta(
          id: cached.id, title: cached.title,
          date: DateTime.parse(cached.date),
          messageCount: cached.messageCount,
          sizeKb: cached.sizeKb,
          transcriptPath: transcriptFile.path,
          ragExportedAt: cached.ragExportedAt != null
              ? DateTime.tryParse(cached.ragExportedAt!) : null,
          ragExportPath: cached.ragExportPath,
        );
      } else {
        // 🔄 Nouveau ou modifié — parse complet
        final built = await _buildMeta(entity, transcriptFile);
        if (built == null) continue;
        meta = built.copyWith(
          ragExportedAt: cached?.ragExportedAt != null
              ? DateTime.tryParse(cached!.ragExportedAt!) : null,
          ragExportPath: cached?.ragExportPath,
        );
        index[convId] = _ConvIndexEntry(
          id: convId, title: meta.title,
          date: meta.date.toIso8601String(),
          messageCount: meta.messageCount, sizeKb: meta.sizeKb,
          transcriptPath: transcriptFile.path,
          lastModified: modStr,
          ragExportedAt: cached?.ragExportedAt,
          ragExportPath: cached?.ragExportPath,
        );
        indexDirty = true;
      }

      allMetas.add(meta);
    }

    if (indexDirty) await _saveIndex(index);

    // ── Filtrage + recherche de contenu ──────────────────────────────────────

    if (query.isEmpty) {
      allMetas.sort((a, b) => b.date.compareTo(a.date));
      return allMetas;
    }

    // 1. Correspondances de titre (rapides, O(1))
    final titleMatches = allMetas
        .where((m) => _matchesQuery(m.title, query))
        .toList();

    // 2. Grep dans le contenu des autres — en parallèle, early-exit
    final noTitleMatch = allMetas
        .where((m) => !_matchesQuery(m.title, query))
        .toList();

    final contentResults = await Future.wait(
      noTitleMatch.map((meta) async {
        final snippet = await _contentSearch(meta.transcriptPath, query);
        if (snippet == null) return null;
        return AiConversationMeta(
          id: meta.id, title: meta.title, date: meta.date,
          messageCount: meta.messageCount, sizeKb: meta.sizeKb,
          transcriptPath: meta.transcriptPath,
          ragExportedAt: meta.ragExportedAt, ragExportPath: meta.ragExportPath,
          contentMatch: true, matchSnippet: snippet,
        );
      }),
    );

    final results = [
      ...titleMatches,
      ...contentResults.whereType<AiConversationMeta>(),
    ];
    results.sort((a, b) => b.date.compareTo(a.date));
    return results;
  }

  // ── Query helpers ────────────────────────────────────────────────────────────

  /// Vérifie si [text] contient [query].
  /// Sous-chaîne insensible à la casse par défaut.
  /// Si [query] contient * ou ?, converti en regex glob avant comparaison.
  static bool _matchesQuery(String text, String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    final t = text.toLowerCase();
    if (!q.contains('*') && !q.contains('?')) return t.contains(q);
    // Conversion glob → regex
    final buf = StringBuffer();
    for (final c in q.split('')) {
      if (c == '*') {
        buf.write('.*');
      } else if (c == '?') {
        buf.write('.');
      } else {
        buf.write(RegExp.escape(c));
      }
    }
    return RegExp(buf.toString(), caseSensitive: false).hasMatch(t);
  }

  /// Grep dans le fichier JSONL avec early-exit.
  /// Retourne un extrait de 120 cars autour de la 1ère correspondance, ou null.
  Future<String?> _contentSearch(String transcriptPath, String query) async {
    final file = File(transcriptPath);
    if (!file.existsSync()) return null;
    try {
      final stream = file.openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        if (line.trim().isEmpty) continue;
        try {
          final obj  = jsonDecode(line) as Map<String, dynamic>;
          final type = obj['type'] as String? ?? '';
          if (type != 'USER_INPUT' && type != 'PLANNER_RESPONSE') continue;
          final content = (obj['content'] as String? ?? '')
              .replaceAll(RegExp(r'<USER_REQUEST>\s*'), '')
              .replaceAll(RegExp(r'\s*</USER_REQUEST>'), '')
              .replaceAll(RegExp(r'<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>',
                  dotAll: true), '')
              .replaceAll('\n', ' ')
              .trim();
          if (content.isEmpty || !_matchesQuery(content, query)) continue;

          // Construire un extrait de 120 cars autour du mot trouvé
          final cleanQ = query.replaceAll('*', '').replaceAll('?', '');
          final idx = content.toLowerCase().indexOf(cleanQ.toLowerCase());
          final start = (idx > 0 ? idx - 40 : 0).clamp(0, content.length);
          final end   = (idx + 80).clamp(0, content.length);
          var snippet = content.substring(start, end).trim();
          if (start > 0)             snippet = '…$snippet';
          if (end < content.length)  snippet = '$snippet…';
          return snippet;
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  // ── Build meta from JSONL ───────────────────────────────────────────────────

  Future<_AiConversationMetaBase?> _buildMeta(Directory convDir, File transcriptFile) async {
    try {
      final stat    = await transcriptFile.stat();
      final sizeKb  = (stat.size / 1024).round();
      String title  = '(sans titre)';
      int messageCount = 0;
      final stream  = transcriptFile.openRead()
        .transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in stream) {
        if (line.trim().isEmpty) continue;
        try {
          final obj  = jsonDecode(line) as Map<String, dynamic>;
          final type = obj['type'] as String? ?? '';
          if (type == 'USER_INPUT' && title == '(sans titre)') {
            final raw = (obj['content'] as String? ?? '').trim();
            final cleaned = raw
              .replaceAll(RegExp(r'<USER_REQUEST>\s*'), '')
              .replaceAll(RegExp(r'\s*</USER_REQUEST>'), '')
              .replaceAll(RegExp(r'<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>', dotAll: true), '')
              .replaceAll('\n', ' ').trim();
            title = cleaned.length > 70
                ? '${cleaned.substring(0, 70)}...'
                : cleaned.isNotEmpty ? cleaned : '(sans titre)';
          }
          if (type == 'USER_INPUT' || type == 'PLANNER_RESPONSE') messageCount++;
        } catch (_) {}
      }
      return _AiConversationMetaBase(
        id: p.basename(convDir.path), title: title,
        date: stat.modified, messageCount: messageCount, sizeKb: sizeKb,
        transcriptPath: transcriptFile.path,
      );
    } catch (_) { return null; }
  }

  // ── Stream messages ─────────────────────────────────────────────────────────

  int _lastCorruptedLinesCount = 0;
  int get lastCorruptedLinesCount => _lastCorruptedLinesCount;

  Stream<AiMessage> streamMessages(String transcriptPath, {void Function(int corruptedLinesCount)? onCorruptedLines}) async* {
    final file = File(transcriptPath);
    if (!file.existsSync()) return;
    int corruptCount = 0;
    final stream = file.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in stream) {
      if (line.trim().isEmpty) continue;
      try {
        final obj     = jsonDecode(line) as Map<String, dynamic>;
        final type    = obj['type'] as String? ?? '';
        final content = obj['content'] as String? ?? '';
        if (type == 'USER_INPUT' && content.trim().isNotEmpty) {
          final cleaned = content
            .replaceAll(RegExp(r'<USER_REQUEST>\s*'), '')
            .replaceAll(RegExp(r'\s*</USER_REQUEST>'), '')
            .replaceAll(RegExp(r'<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>', dotAll: true), '')
            .trim();
          if (cleaned.isNotEmpty) {
            yield AiMessage(stepIndex: obj['step_index'] as int? ?? 0, isUser: true, content: cleaned);
          }
        } else if (type == 'PLANNER_RESPONSE' && content.trim().isNotEmpty) {
          yield AiMessage(stepIndex: obj['step_index'] as int? ?? 0, isUser: false, content: content.trim());
        }
      } catch (_) {
        corruptCount++;
      }
    }
    _lastCorruptedLinesCount = corruptCount;
    if (corruptCount > 0) {
      onCorruptedLines?.call(corruptCount);
      Log.instance.w('ai_conv', 'Transcript partiel ($corruptCount lignes corrompues ignorées): $transcriptPath');
    }
  }

  // ── Exports ─────────────────────────────────────────────────────────────────

  /// Stable filename key used for deduplication — same conv = same file name = overwrite (no duplicate).
  String _stableFilename(AiConversationMeta meta, String ext) =>
    'conv_${meta.id.substring(0, 8)}_${meta.date.toIso8601String().substring(0, 10)}.$ext';

  /// Export as TXT for RAG indexing (LanceDB upsert-safe via stable filename).
  Future<String> exportForRag(AiConversationMeta meta, String outputDir) async {
    final outFile = File(p.join(outputDir, _stableFilename(meta, 'txt')));
    final buffer  = StringBuffer();
    buffer.writeln('# Conversation Antigravity -- ${meta.date.toIso8601String().substring(0, 10)}');
    buffer.writeln('# Titre: ${meta.title}');
    buffer.writeln('# ID: ${meta.id}');
    buffer.writeln('');
    int corruptCount = 0;
    await for (final msg in streamMessages(meta.transcriptPath, onCorruptedLines: (c) => corruptCount = c)) {
      buffer.writeln(msg.isUser ? '### Utilisateur' : '### Assistant');
      buffer.writeln(msg.content);
      buffer.writeln('');
    }
    if (corruptCount > 0) {
      buffer.writeln('# AVERTISSEMENT: Export partiel ($corruptCount lignes corrompues omises)');
    }
    await outFile.create(recursive: true);
    await outFile.writeAsString(buffer.toString(), encoding: utf8);

    // Mettre à jour l'index — marquer comme exporté RAG
    await _markRagExported(meta.id, outFile.path);
    return outFile.path;
  }

  /// Export as Markdown (formatted, with code blocks preserved).
  Future<String> exportAsMarkdown(AiConversationMeta meta, String outputDir) async {
    final outFile = File(p.join(outputDir, _stableFilename(meta, 'md')));
    final buffer  = StringBuffer();
    buffer.writeln('# ${meta.title}');
    buffer.writeln('');
    buffer.writeln('> **Date :** ${meta.date.toIso8601String().substring(0, 10)}  ');
    buffer.writeln('> **Messages :** ${meta.messageCount}  ');
    buffer.writeln('> **ID :** `${meta.id}`');
    buffer.writeln('');
    buffer.writeln('---');
    buffer.writeln('');
    int corruptCount = 0;
    await for (final msg in streamMessages(meta.transcriptPath, onCorruptedLines: (c) => corruptCount = c)) {
      if (msg.isUser) {
        buffer.writeln('**👤 Utilisateur**');
        buffer.writeln('');
        buffer.writeln(msg.content);
      } else {
        buffer.writeln('**🤖 Assistant**');
        buffer.writeln('');
        buffer.writeln(msg.content);
      }
      buffer.writeln('');
      buffer.writeln('---');
      buffer.writeln('');
    }
    if (corruptCount > 0) {
      buffer.writeln('> ⚠️ **Avertissement :** Export partiel ($corruptCount lignes corrompues ignorées dans le transcript source).');
      buffer.writeln('');
    }
    await outFile.create(recursive: true);
    await outFile.writeAsString(buffer.toString(), encoding: utf8);
    return outFile.path;
  }

  /// Export as structured JSON (conversation + messages array).
  Future<String> exportAsJson(AiConversationMeta meta, String outputDir) async {
    final outFile = File(p.join(outputDir, _stableFilename(meta, 'json')));
    final messages = <Map<String, dynamic>>[];
    int corruptCount = 0;
    await for (final msg in streamMessages(meta.transcriptPath, onCorruptedLines: (c) => corruptCount = c)) {
      messages.add({
        'step_index': msg.stepIndex,
        'role':       msg.isUser ? 'user' : 'assistant',
        'content':    msg.content,
      });
    }
    final data = {
      'id':           meta.id,
      'title':        meta.title,
      'date':         meta.date.toIso8601String(),
      'messageCount': meta.messageCount,
      'sizeKb':       meta.sizeKb,
      'exportedAt':   DateTime.now().toIso8601String(),
      'is_partial':   corruptCount > 0,
      'corrupted_lines_count': corruptCount,
      'messages':     messages,
    };
    await outFile.create(recursive: true);
    await outFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data), encoding: utf8);
    return outFile.path;
  }

  /// Build plain-text string (for clipboard).
  Future<String> buildPlainText(AiConversationMeta meta) async {
    final buffer = StringBuffer();
    buffer.writeln('Conversation: ${meta.title}');
    buffer.writeln('Date: ${meta.date.toIso8601String().substring(0, 10)}');
    buffer.writeln('');
    await for (final msg in streamMessages(meta.transcriptPath)) {
      buffer.writeln(msg.isUser ? '[Utilisateur]' : '[Assistant]');
      buffer.writeln(msg.content);
      buffer.writeln('');
    }
    return buffer.toString();
  }

  /// Batch export all conversations to RAG (skip already-exported unless forced).
  Future<BatchExportResult> exportAllForRag(
      List<AiConversationMeta> conversations, String outputDir,
      {bool force = false}) async {
    int exported = 0, skipped = 0;
    final errors = <String>[];
    for (final meta in conversations) {
      if (!force && meta.isRagExported) { skipped++; continue; }
      try {
        await exportForRag(meta, outputDir);
        exported++;
      } catch (e) {
        errors.add('${meta.title}: $e');
      }
    }
    return BatchExportResult(exported: exported, skipped: skipped, errors: errors);
  }

  // ── Index helpers ───────────────────────────────────────────────────────────

  Future<void> _markRagExported(String convId, String exportPath) async {
    final index = await _loadIndex();
    final entry = index[convId];
    if (entry == null) return;
    index[convId] = entry.copyWith(
      ragExportedAt: DateTime.now().toIso8601String(),
      ragExportPath: exportPath,
    );
    await _saveIndex(index);
    // Invalidate cache so next listConversations picks up the new flag
    _indexCache = index;
  }
}

// ── Internal base class (avoids circular ref in _buildMeta) ──────────────────

class _AiConversationMetaBase {
  final String id, title, transcriptPath;
  final DateTime date;
  final int messageCount, sizeKb;
  const _AiConversationMetaBase({
    required this.id, required this.title, required this.transcriptPath,
    required this.date, required this.messageCount, required this.sizeKb,
  });

  AiConversationMeta copyWith({DateTime? ragExportedAt, String? ragExportPath,
      bool contentMatch = false, String? matchSnippet}) =>
    AiConversationMeta(
      id: id, title: title, date: date, messageCount: messageCount,
      sizeKb: sizeKb, transcriptPath: transcriptPath,
      ragExportedAt: ragExportedAt, ragExportPath: ragExportPath,
      contentMatch: contentMatch, matchSnippet: matchSnippet,
    );
}

class BatchExportResult {
  final int exported, skipped;
  final List<String> errors;
  const BatchExportResult({required this.exported, required this.skipped, required this.errors});
}

// ── Extension pour AiConversationMeta (copyWith) ─────────────────────────────

extension AiConversationMetaX on AiConversationMeta {
  AiConversationMeta copyWith({
    DateTime? ragExportedAt, String? ragExportPath,
    bool? contentMatch, String? matchSnippet,
  }) =>
    AiConversationMeta(
      id: id, title: title, date: date, messageCount: messageCount,
      sizeKb: sizeKb, transcriptPath: transcriptPath,
      ragExportedAt:  ragExportedAt  ?? this.ragExportedAt,
      ragExportPath:  ragExportPath  ?? this.ragExportPath,
      contentMatch:   contentMatch   ?? this.contentMatch,
      matchSnippet:   matchSnippet   ?? this.matchSnippet,
    );
}

// ── Provider ──────────────────────────────────────────────────────────────────

final aiConversationsServiceProvider = Provider<AiConversationsService>((ref) {
  return AiConversationsService();
});
