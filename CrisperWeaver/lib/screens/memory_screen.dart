// lib/screens/memory_screen.dart
// Écran de gestion de la mémoire de l'assistant (memory_store.json)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/memory_service.dart';

// ── State ─────────────────────────────────────────────────────────────────────

class _MemoryState {
  final List<MemoryFact>    facts;
  final List<MemorySession> sessions;
  final bool loading;
  final String? selected; // id du fait sélectionné
  final bool showSessions;
  const _MemoryState({
    this.facts = const [], this.sessions = const [],
    this.loading = false,  this.selected,
    this.showSessions = false,
  });
  _MemoryState copyWith({List<MemoryFact>? facts, List<MemorySession>? sessions,
    bool? loading, String? selected, bool clearSelected = false,
    bool? showSessions}) => _MemoryState(
      facts:        facts        ?? this.facts,
      sessions:     sessions     ?? this.sessions,
      loading:      loading      ?? this.loading,
      selected:     clearSelected ? null : selected ?? this.selected,
      showSessions: showSessions ?? this.showSessions,
    );
}

// ── Screen ────────────────────────────────────────────────────────────────────

class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});
  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  _MemoryState _s = const _MemoryState();
  final _editCtrl    = TextEditingController();
  final _addCtrl     = TextEditingController();
  String _addCategory = 'manual';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _load(); });
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _s = _s.copyWith(loading: true));
    final svc = ref.read(memoryServiceProvider);
    final r   = await svc.load();
    if (mounted) setState(() => _s = _s.copyWith(
      facts: r.facts, sessions: r.sessions, loading: false));
  }

  MemoryFact? get _selectedFact =>
      _s.selected == null ? null
      : _s.facts.where((f) => f.id == _s.selected).firstOrNull;

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(context: context, builder: (_) =>
      AlertDialog(title: const Text('Supprimer ce fait ?'),
        content: const Text('Cette action est irréversible.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Supprimer')),
        ]));
    if (ok != true) return;
    await ref.read(memoryServiceProvider).deleteFact(id);
    setState(() => _s = _s.copyWith(clearSelected: true));
    await _load();
  }

  Future<void> _saveEdit() async {
    final fact = _selectedFact;
    if (fact == null) return;
    await ref.read(memoryServiceProvider).updateFact(
      fact.copyWith(content: _editCtrl.text.trim()));
    await _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Fait modifié ✅'), duration: Duration(seconds: 2)));
  }

  Future<void> _addFact() async {
    final txt = _addCtrl.text.trim();
    if (txt.isEmpty) return;
    await ref.read(memoryServiceProvider).addFact(content: txt, category: _addCategory);
    _addCtrl.clear();
    await _load();
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 700;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🧠 Mémoire de l\'Assistant'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Rafraîchir',
            onPressed: _load),
          TextButton.icon(
            icon: Icon(_s.showSessions ? Icons.psychology : Icons.history_edu),
            label: Text(_s.showSessions ? 'Faits' : 'Sessions'),
            onPressed: () => setState(
              () => _s = _s.copyWith(showSessions: !_s.showSessions, clearSelected: true)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _s.loading
          ? const Center(child: CircularProgressIndicator())
          : _s.showSessions
              ? _buildSessions()
              : isWide ? _buildWide() : _buildNarrow(),
    );
  }

  // ── Vue Sessions ──────────────────────────────────────────────────────────

  Widget _buildSessions() {
    if (_s.sessions.isEmpty) return const Center(
        child: Text('Aucune session enregistrée', style: TextStyle(color: Colors.grey)));
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _s.sessions.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final ses = _s.sessions[_s.sessions.length - 1 - i];
        return ListTile(
          leading: const Icon(Icons.calendar_today, color: Colors.blueGrey),
          title: Text(ses.date, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(ses.summary, maxLines: 3, overflow: TextOverflow.ellipsis),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Chip(label: Text('${ses.factsCount} faits'),
              backgroundColor: Colors.deepPurple.withOpacity(0.15)),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () async {
                await ref.read(memoryServiceProvider).deleteSession(ses.id);
                await _load();
              }),
          ]),
        );
      },
    );
  }

  // ── Vue Faits (desktop large) ─────────────────────────────────────────────

  Widget _buildWide() => Row(children: [
    SizedBox(width: 320, child: _buildList()),
    const VerticalDivider(width: 1),
    Expanded(child: _buildDetail()),
  ]);

  Widget _buildNarrow() => _s.selected == null ? _buildList() : _buildDetail();

  // ── Liste des faits ───────────────────────────────────────────────────────

  static const _catColors = {
    'technical': Colors.blue,  'other': Colors.teal,
    'manual':    Colors.green, 'personal': Colors.orange,
  };

  Widget _buildList() {
    // Grouper par catégorie
    final cats = <String>{};
    for (final f in _s.facts) cats.add(f.category);

    // Panneau du bas : Ajouter un fait
    return Column(children: [
      Expanded(child: _s.facts.isEmpty
        ? const Center(child: Text('Aucun fait mémorisé',
            style: TextStyle(color: Colors.grey)))
        : ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: _s.facts.length,
            itemBuilder: (_, i) {
              final f = _s.facts[i];
              final isSelected = f.id == _s.selected;
              final color = _catColors[f.category] ?? Colors.grey;
              return ListTile(
                selected: isSelected,
                selectedTileColor: color.withOpacity(0.12),
                leading: CircleAvatar(backgroundColor: color.withOpacity(0.2),
                  child: Icon(Icons.lightbulb_outline, color: color, size: 18)),
                title: Text(f.content, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
                subtitle: Text(f.category,
                  style: TextStyle(color: color, fontSize: 11)),
                onTap: () {
                  setState(() => _s = _s.copyWith(selected: f.id));
                  _editCtrl.text = f.content;
                },
              );
            })),
      // ── Zone Ajouter ──
      Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.grey.shade800))),
        child: Column(children: [
          Row(children: [
            Expanded(child: TextField(
              controller: _addCtrl,
              decoration: const InputDecoration(
                hintText: 'Nouveau fait à mémoriser...',
                isDense: true, border: OutlineInputBorder()),
              maxLines: 2, style: const TextStyle(fontSize: 13),
            )),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            DropdownButton<String>(
              value: _addCategory,
              items: ['manual','technical','personal','other'].map((c) =>
                DropdownMenuItem(value: c, child: Text(c))).toList(),
              onChanged: (v) => setState(() => _addCategory = v ?? 'manual'),
              isDense: true,
            ),
            const Spacer(),
            FilledButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Ajouter'),
              onPressed: _addFact,
            ),
          ]),
        ]),
      ),
    ]);
  }

  // ── Détail / édition d'un fait ────────────────────────────────────────────

  Widget _buildDetail() {
    final fact = _selectedFact;
    if (fact == null) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.psychology_outlined, size: 64, color: Colors.grey),
      const SizedBox(height: 12),
      Text('Sélectionne un fait pour le voir et le modifier',
        style: TextStyle(color: Colors.grey.shade500)),
    ]));

    final color = _catColors[fact.category] ?? Colors.grey;

    return Padding(padding: const EdgeInsets.all(20), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Chip(label: Text(fact.category),
            backgroundColor: color.withOpacity(0.2),
            labelStyle: TextStyle(color: color)),
          const SizedBox(width: 8),
          Chip(label: Text(fact.source),
            backgroundColor: Colors.grey.shade800),
          const Spacer(),
          IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red),
            tooltip: 'Supprimer ce fait',
            onPressed: () => _delete(fact.id)),
        ]),
        const SizedBox(height: 8),
        Text('Créé : ${fact.created.toLocal().toString().substring(0, 16)}',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        Text('Modifié : ${fact.updated.toLocal().toString().substring(0, 16)}',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        const SizedBox(height: 16),
        const Text('Contenu', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        TextField(
          controller: _editCtrl,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        Row(children: [
          OutlinedButton(onPressed: () {
            setState(() => _s = _s.copyWith(clearSelected: true));
          }, child: const Text('Annuler')),
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Sauvegarder'),
            onPressed: _saveEdit,
          ),
        ]),
      ],
    ));
  }
}
