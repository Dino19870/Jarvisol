import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/ai_knowledge_record.dart';
import 'llm_service.dart';
import 'log_service.dart';

import 'settings_service.dart';

/// Service managing persistence and instant search for AI-analyzed transcriptions.
class AiKnowledgeService {
  final Ref? _ref;
  Directory? _storageDir;
  final List<AiKnowledgeRecord> _cachedRecords = [];
  bool _initialized = false;

  AiKnowledgeService([this._ref]);

  Future<Directory> getEffectiveStorageDir() async {
    final customPath = _ref?.read(settingsServiceProvider).aiKnowledgeDirectory ?? '';
    if (customPath.isNotEmpty) {
      final dir = Directory(customPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'CrisperWeaver', 'ai_knowledge'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _ensureInitialized() async {
    try {
      final targetDir = await getEffectiveStorageDir();
      if (!_initialized || _storageDir?.path != targetDir.path) {
        _storageDir = targetDir;
        await _loadAllCached();
        _initialized = true;
      }
    } catch (e) {
      Log.instance.e('ai_knowledge', 'Failed to initialize storage directory', error: e);
    }
  }

  Future<void> reloadFromDisk() async {
    _initialized = false;
    await _ensureInitialized();
  }

  Future<void> _loadAllCached() async {
    if (_storageDir == null || !await _storageDir!.exists()) return;
    _cachedRecords.clear();
    try {
      final entities = await _storageDir!.list().toList();
      for (final entity in entities) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final json = jsonDecode(content);
            if (json is Map<String, dynamic>) {
              _cachedRecords.add(AiKnowledgeRecord.fromJson(json));
            }
          } catch (e) {
            Log.instance.w('ai_knowledge', 'Could not parse record file ${entity.path}: $e');
          }
        }
      }
      _cachedRecords.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      Log.instance.e('ai_knowledge', 'Error loading cached records', error: e);
    }
  }

  /// Save a new AI knowledge record.
  Future<AiKnowledgeRecord> saveRecord({
    required String title,
    String category = 'Général',
    required String rawTranscript,
    String? aiSummary,
    String? actionItems,
    List<LlmChatMessage> chatMessages = const [],
    String llmProvider = 'LM Studio',
    String llmModel = '',
    List<String> tags = const [],
    String? existingId,
  }) async {
    await _ensureInitialized();
    final id = existingId ?? const Uuid().v4();
    final record = AiKnowledgeRecord(
      id: id,
      createdAt: DateTime.now(),
      title: title.trim().isNotEmpty ? title.trim() : 'Analyse du ${DateTime.now().toString().substring(0, 16)}',
      category: category.trim().isNotEmpty ? category.trim() : 'Général',
      rawTranscript: rawTranscript,
      aiSummary: aiSummary,
      actionItems: actionItems,
      chatMessages: chatMessages,
      llmProvider: llmProvider,
      llmModel: llmModel,
      tags: tags,
    );

    try {
      final file = File(p.join(_storageDir!.path, '$id.json'));
      await file.writeAsString(jsonEncode(record.toJson()), flush: true);

      // Update in-memory cache
      _cachedRecords.removeWhere((r) => r.id == id);
      _cachedRecords.insert(0, record);
    } catch (e) {
      Log.instance.e('ai_knowledge', 'Failed to save record $id', error: e);
      rethrow;
    }

    return record;
  }

  /// Updates the category of an existing record.
  Future<bool> updateRecordCategory(String id, String newCategory) async {
    await _ensureInitialized();
    final idx = _cachedRecords.indexWhere((r) => r.id == id);
    if (idx == -1) return false;
    final old = _cachedRecords[idx];
    final updated = AiKnowledgeRecord(
      id: old.id,
      createdAt: old.createdAt,
      title: old.title,
      category: newCategory.trim().isNotEmpty ? newCategory.trim() : 'Général',
      rawTranscript: old.rawTranscript,
      aiSummary: old.aiSummary,
      actionItems: old.actionItems,
      chatMessages: old.chatMessages,
      llmProvider: old.llmProvider,
      llmModel: old.llmModel,
      tags: old.tags,
    );
    _cachedRecords[idx] = updated;
    try {
      final file = File(p.join(_storageDir!.path, '$id.json'));
      await file.writeAsString(jsonEncode(updated.toJson()), flush: true);
      return true;
    } catch (e) {
      Log.instance.e('ai_knowledge', 'Failed to update category for $id: $e');
      return false;
    }
  }

  /// Renames all occurrences of oldCategory to newCategory across all saved records.
  Future<int> renameCategoryInRecords(String oldCategory, String newCategory) async {
    await _ensureInitialized();
    int updatedCount = 0;
    for (final r in List<AiKnowledgeRecord>.from(_cachedRecords)) {
      if (r.category.toLowerCase() == oldCategory.toLowerCase()) {
        await updateRecordCategory(r.id, newCategory);
        updatedCount++;
      }
    }
    return updatedCount;
  }

  /// Reassigns records in oldCategory to fallbackCategory (e.g. 'Général' when deleting a category).
  Future<int> reassignCategoryInRecords(String oldCategory, String fallbackCategory) async {
    return renameCategoryInRecords(oldCategory, fallbackCategory);
  }

  /// List all saved records sorted by creation date descending.
  Future<List<AiKnowledgeRecord>> listRecords() async {
    await _ensureInitialized();
    return List.unmodifiable(_cachedRecords);
  }

  /// Synchronous getter for in-memory records
  List<AiKnowledgeRecord> listRecordsSync() {
    return List.unmodifiable(_cachedRecords);
  }

  /// Get storage stats (record count & total bytes)
  Future<(int count, int bytes)> getStorageStats() async {
    await _ensureInitialized();
    if (_storageDir == null || !await _storageDir!.exists()) return (0, 0);
    int totalBytes = 0;
    int count = 0;
    try {
      final files = await _storageDir!.list().toList();
      for (final f in files) {
        if (f is File && f.path.endsWith('.json')) {
          count++;
          totalBytes += await f.length();
        }
      }
    } catch (_) {}
    return (count, totalBytes);
  }

  /// Instant search across all saved records by keywords and category.
  Future<List<AiKnowledgeRecord>> searchRecords(String query, {String? categoryFilter}) async {
    await _ensureInitialized();
    final q = query.trim().toLowerCase();
    final terms = q.isNotEmpty ? q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList() : <String>[];

    return _cachedRecords.where((record) {
      if (categoryFilter != null && categoryFilter.isNotEmpty && categoryFilter != 'Tous') {
        if (record.category.toLowerCase() != categoryFilter.toLowerCase()) {
          return false;
        }
      }

      if (terms.isEmpty) return true;

      final fullContent = [
        record.title,
        record.category,
        record.rawTranscript,
        record.aiSummary ?? '',
        record.actionItems ?? '',
        record.llmModel,
        record.llmProvider,
        ...record.tags,
        ...record.chatMessages.map((m) => '${m.role}: ${m.content}'),
      ].join(' ').toLowerCase();

      return terms.every((term) => fullContent.contains(term));
    }).toList();
  }

  /// Delete a record by ID.
  Future<bool> deleteRecord(String id) async {
    await _ensureInitialized();
    try {
      final file = File(p.join(_storageDir!.path, '$id.json'));
      if (await file.exists()) {
        await file.delete();
      }
      _cachedRecords.removeWhere((r) => r.id == id);
      return true;
    } catch (e) {
      Log.instance.e('ai_knowledge', 'Failed to delete record $id', error: e);
      return false;
    }
  }

  /// Purge all knowledge records from disk and memory.
  Future<int> clearAllRecords() async {
    await _ensureInitialized();
    if (_storageDir == null || !await _storageDir!.exists()) return 0;
    int deleted = 0;
    try {
      final files = await _storageDir!.list().toList();
      for (final f in files) {
        if (f is File && f.path.endsWith('.json')) {
          await f.delete();
          deleted++;
        }
      }
      _cachedRecords.clear();
    } catch (e) {
      Log.instance.e('ai_knowledge', 'Failed to clear knowledge base: $e');
    }
    return deleted;
  }
}

/// Riverpod provider for AiKnowledgeService.
final aiKnowledgeServiceProvider = Provider<AiKnowledgeService>((ref) {
  return AiKnowledgeService(ref);
});
