// lib/services/memory_service.dart
// Lecture/écriture de memory_store.json géré par memory_server.exe

import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

// ── Modèles ───────────────────────────────────────────────────────────────────

class MemoryFact {
  final String id;
  final String content;
  final String category;
  final String source;
  final DateTime created;
  final DateTime updated;

  const MemoryFact({
    required this.id,
    required this.content,
    required this.category,
    required this.source,
    required this.created,
    required this.updated,
  });

  factory MemoryFact.fromJson(Map<String, dynamic> j) => MemoryFact(
    id:       j['id']       as String? ?? '',
    content:  j['content']  as String? ?? '',
    category: j['category'] as String? ?? 'other',
    source:   j['source']   as String? ?? '',
    created:  DateTime.tryParse(j['created']  as String? ?? '') ?? DateTime.now(),
    updated:  DateTime.tryParse(j['updated']  as String? ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'content': content, 'category': category,
    'source': source,
    'created': created.toIso8601String(),
    'updated': updated.toIso8601String(),
  };

  MemoryFact copyWith({String? content, String? category}) => MemoryFact(
    id: id, source: source, created: created,
    content:  content  ?? this.content,
    category: category ?? this.category,
    updated:  DateTime.now(),
  );
}

class MemorySession {
  final String id;
  final String date;
  final DateTime timestamp;
  final String summary;
  final int factsCount;

  const MemorySession({
    required this.id, required this.date, required this.timestamp,
    required this.summary, required this.factsCount,
  });

  factory MemorySession.fromJson(Map<String, dynamic> j) => MemorySession(
    id:         j['id']          as String? ?? '',
    date:       j['date']        as String? ?? '',
    timestamp:  DateTime.tryParse(j['timestamp'] as String? ?? '') ?? DateTime.now(),
    summary:    j['summary']     as String? ?? '',
    factsCount: j['facts_count'] as int?    ?? 0,
  );
}

// ── Service ───────────────────────────────────────────────────────────────────

class MemoryService {
  MemoryService();

  /// Chemin vers memory_store.json (dossier memory/ à côté de l'exe)
  static String get memoryStorePath {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    return p.join(exeDir, 'memory', 'memory_store.json');
  }

  File get _file => File(memoryStorePath);

  /// Lit le fichier JSON et retourne (facts, sessions)
  Future<({List<MemoryFact> facts, List<MemorySession> sessions})> load() async {
    if (!await _file.exists()) {
      return (facts: <MemoryFact>[], sessions: <MemorySession>[]);
    }
    try {
      final raw  = await _file.readAsString();
      final data = json.decode(raw) as Map<String, dynamic>;
      final facts = (data['facts'] as List<dynamic>? ?? [])
          .map((e) => MemoryFact.fromJson(e as Map<String, dynamic>))
          .toList();
      final sessions = (data['sessions'] as List<dynamic>? ?? [])
          .map((e) => MemorySession.fromJson(e as Map<String, dynamic>))
          .toList();
      return (facts: facts, sessions: sessions);
    } catch (_) {
      return (facts: <MemoryFact>[], sessions: <MemorySession>[]);
    }
  }

  Future<void> _save(List<MemoryFact> facts, List<MemorySession> sessions) async {
    final data = {
      'version': 1,
      'facts':    facts.map((f) => f.toJson()).toList(),
      'sessions': sessions.map((s) => {
        'id': s.id, 'date': s.date,
        'timestamp':   s.timestamp.toIso8601String(),
        'summary':     s.summary,
        'facts_count': s.factsCount,
      }).toList(),
    };
    await _file.writeAsString(json.encode(data), flush: true);
  }

  Future<void> deleteFact(String id) async {
    final r = await load();
    final updated = r.facts.where((f) => f.id != id).toList();
    await _save(updated, r.sessions);
  }

  Future<void> updateFact(MemoryFact fact) async {
    final r = await load();
    final updated = r.facts.map((f) => f.id == fact.id ? fact : f).toList();
    await _save(updated, r.sessions);
  }

  Future<void> addFact({required String content, String category = 'manual'}) async {
    final r = await load();
    final newFact = MemoryFact(
      id:       DateTime.now().millisecondsSinceEpoch.toRadixString(16),
      content:  content,
      category: category,
      source:   'manual',
      created:  DateTime.now(),
      updated:  DateTime.now(),
    );
    await _save([...r.facts, newFact], r.sessions);
  }

  Future<void> deleteSession(String id) async {
    final r = await load();
    final updated = r.sessions.where((s) => s.id != id).toList();
    await _save(r.facts, updated);
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final memoryServiceProvider = Provider<MemoryService>((ref) => MemoryService());
