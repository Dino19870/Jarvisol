import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

// ── Modèle projet ─────────────────────────────────────────────────────────────

class ProjectItem {
  final String id;
  String name;
  String status; // actif | pause | termine
  String description;
  String techStack;
  String notes;
  String path;

  ProjectItem({
    required this.id,
    required this.name,
    required this.status,
    required this.description,
    required this.techStack,
    required this.notes,
    required this.path,
  });

  factory ProjectItem.fromJson(Map<String, dynamic> j) => ProjectItem(
        id:          j['id'] ?? '',
        name:        j['name'] ?? '',
        status:      j['status'] ?? 'actif',
        description: j['description'] ?? '',
        techStack:   j['tech_stack'] ?? '',
        notes:       j['notes'] ?? '',
        path:        j['path'] ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id':          id,
        'name':        name,
        'status':      status,
        'description': description,
        'tech_stack':  techStack,
        'notes':       notes,
        'path':        path,
      };
}

// ── API helper ────────────────────────────────────────────────────────────────

const _kBase = 'http://127.0.0.1:7862';

Future<List<ProjectItem>> _fetchProjects() async {
  try {
    final req = await HttpClient().getUrl(Uri.parse('$_kBase/projects'));
    final res = await req.close();
    if (res.statusCode == 200) {
      final body = await res.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      return (data['projects'] as List? ?? [])
          .map((e) => ProjectItem.fromJson(e as Map<String, dynamic>))
          .toList();
    }
  } catch (_) {}
  return [];
}

Future<bool> _saveProject(ProjectItem p) async {
  try {
    final bodyStr = jsonEncode(p.toJson());
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/projects/save'));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    final bytes = utf8.encode(bodyStr);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

Future<bool> _deleteProject(String id) async {
  try {
    final bodyStr = jsonEncode({'id': id});
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/projects/delete'));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    final bytes = utf8.encode(bodyStr);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

// ── Dialog principal ──────────────────────────────────────────────────────────

class ProjectContextDialog extends StatefulWidget {
  const ProjectContextDialog({super.key});

  static Future<bool> show(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => const ProjectContextDialog(),
        ) ??
        false;
  }

  @override
  State<ProjectContextDialog> createState() => _ProjectContextDialogState();
}

class _ProjectContextDialogState extends State<ProjectContextDialog> {
  List<ProjectItem> _projects = [];
  bool _loading = true;
  bool _serverOffline = false;
  // null = vue liste  |  ProjectItem (empty id) = nouveau  |  ProjectItem (id) = édition
  ProjectItem? _editing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _serverOffline = false; });
    try {
      final list = await _fetchProjects();
      if (mounted) setState(() { _projects = list; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _serverOffline = true; });
    }
  }

  void _startNew() => setState(() => _editing = ProjectItem(
        id: '', name: '', status: 'actif',
        description: '', techStack: '', notes: '', path: ''));

  void _startEdit(ProjectItem p) => setState(() => _editing = ProjectItem(
        id: p.id, name: p.name, status: p.status,
        description: p.description, techStack: p.techStack,
        notes: p.notes, path: p.path));

  Future<void> _delete(ProjectItem p) async {
    final ok = await _deleteProject(p.id);
    if (ok && mounted) {
      setState(() => _projects.removeWhere((x) => x.id == p.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Projet supprimé'), duration: Duration(seconds: 2)));
    }
  }

  // Appelé depuis _ProjectFormWidget quand l'utilisateur valide
  Future<void> _onFormSaved(ProjectItem saved) async {
    final ok = await _saveProject(saved);
    if (!ok || !mounted) return;
    await _load();
    setState(() => _editing = null);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: 600,
        height: 600,
        child: Column(children: [
          // ── Header ──────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.purple.shade900.withValues(alpha: 0.5),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(children: [
              const Icon(Icons.folder_special, color: Colors.purpleAccent, size: 20),
              const SizedBox(width: 10),
              Text(
                _editing == null ? '📂 Mes Projets Actifs' : (_editing!.id.isEmpty ? '➕ Nouveau Projet' : '✏️ Modifier : ${_editing!.name}'),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
              const Spacer(),
              if (_editing != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 18),
                  tooltip: 'Retour à la liste',
                  onPressed: () => setState(() => _editing = null),
                ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                onPressed: () => Navigator.pop(context, _projects.isNotEmpty),
              ),
            ]),
          ),

          // ── Corps ────────────────────────────────────────────────────────────
          Expanded(child: _editing != null
              ? _ProjectFormWidget(item: _editing!, onSave: _onFormSaved)
              : _buildList()),

          // ── Footer ───────────────────────────────────────────────────────────
          if (_editing == null)
            Container(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                const Icon(Icons.info_outline, size: 12, color: Colors.grey),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Ces projets sont injectés automatiquement dans chaque conversation.',
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Ajouter un projet', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
                  onPressed: _serverOffline ? null : _startNew,
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.purpleAccent));
    }
    if (_serverOffline) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off, color: Colors.orange, size: 40),
        const SizedBox(height: 12),
        const Text('Memory server injoignable', style: TextStyle(color: Colors.orange)),
        const SizedBox(height: 6),
        const Text('Démarrez memory_server.exe et réessayez.',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: _load, child: const Text('Réessayer')),
      ]));
    }
    if (_projects.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.folder_open, color: Colors.grey, size: 48),
        const SizedBox(height: 12),
        const Text('Aucun projet défini', style: TextStyle(color: Colors.grey, fontSize: 14)),
        const SizedBox(height: 6),
        const Text('Ajoutez vos projets actifs pour que l\'assistant les connaisse.',
            style: TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center),
      ]));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) => _ProjectCard(
        project: _projects[i],
        onEdit: () => _startEdit(_projects[i]),
        onDelete: () => _delete(_projects[i]),
      ),
    );
  }
}

// ── Carte projet ──────────────────────────────────────────────────────────────

class _ProjectCard extends StatelessWidget {
  final ProjectItem project;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ProjectCard({required this.project, required this.onEdit, required this.onDelete});

  Color get _statusColor {
    switch (project.status) {
      case 'actif':   return Colors.green;
      case 'pause':   return Colors.orange;
      default:        return Colors.grey;
    }
  }

  String get _statusLabel {
    switch (project.status) {
      case 'actif':   return '🟢 Actif';
      case 'pause':   return '🟡 En pause';
      default:        return '⚫ Terminé';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _statusColor.withValues(alpha: 0.3)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: _statusColor.withValues(alpha: 0.15),
          radius: 20,
          child: Icon(Icons.folder, color: _statusColor, size: 20),
        ),
        title: Row(children: [
          Expanded(child: Text(project.name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(_statusLabel, style: TextStyle(fontSize: 10, color: _statusColor)),
          ),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (project.techStack.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(project.techStack,
                style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          if (project.description.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(project.description,
                style: const TextStyle(fontSize: 11, color: Colors.white60),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (project.path.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(project.path,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ]),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            icon: const Icon(Icons.edit, size: 16, color: Colors.blueAccent),
            tooltip: 'Modifier',
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
            tooltip: 'Supprimer',
            onPressed: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Supprimer ce projet ?'),
                content: Text('« ${project.name} » sera retiré de la mémoire.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () { Navigator.pop(context); onDelete(); },
                    child: const Text('Supprimer'),
                  ),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Formulaire ajout/édition ──────────────────────────────────────────────────

class _ProjectFormWidget extends StatefulWidget {
  final ProjectItem item;
  final Future<void> Function(ProjectItem) onSave;

  const _ProjectFormWidget({required this.item, required this.onSave});

  @override
  State<_ProjectFormWidget> createState() => _ProjectFormWidgetState();
}

class _ProjectFormWidgetState extends State<_ProjectFormWidget> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name        = TextEditingController(text: widget.item.name);
  late final TextEditingController _description = TextEditingController(text: widget.item.description);
  late final TextEditingController _techStack   = TextEditingController(text: widget.item.techStack);
  late final TextEditingController _notes       = TextEditingController(text: widget.item.notes);
  late final TextEditingController _path        = TextEditingController(text: widget.item.path);
  late String _status = widget.item.status.isEmpty ? 'actif' : widget.item.status;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose(); _description.dispose();
    _techStack.dispose(); _notes.dispose(); _path.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final updated = ProjectItem(
      id:          widget.item.id,
      name:        _name.text.trim(),
      status:      _status,
      description: _description.text.trim(),
      techStack:   _techStack.text.trim(),
      notes:       _notes.text.trim(),
      path:        _path.text.trim(),
    );
    await widget.onSave(updated);
    if (mounted) setState(() => _saving = false);
  }

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(
    labelText: label, hintText: hint, isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  );

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Nom
          TextFormField(
            controller: _name,
            decoration: _dec('Nom du projet *'),
            style: const TextStyle(fontWeight: FontWeight.bold),
            validator: (v) => (v?.trim().isEmpty ?? true) ? 'Champ requis' : null,
          ),
          const SizedBox(height: 12),

          // Statut
          DropdownButtonFormField<String>(
            value: _status,
            decoration: _dec('Statut'),
            items: const [
              DropdownMenuItem(value: 'actif',   child: Text('🟢 Actif')),
              DropdownMenuItem(value: 'pause',   child: Text('🟡 En pause')),
              DropdownMenuItem(value: 'termine', child: Text('⚫ Terminé')),
            ],
            onChanged: (v) => setState(() => _status = v ?? 'actif'),
          ),
          const SizedBox(height: 12),

          // Stack technique
          TextFormField(
            controller: _techStack,
            decoration: _dec('Technologies / Stack', hint: 'Flutter, Dart, Python, WLangage, HFSQL…'),
          ),
          const SizedBox(height: 12),

          // Description
          TextFormField(
            controller: _description,
            maxLines: 3,
            decoration: _dec('Description', hint: 'Objectif principal du projet, fonctionnalités clés…'),
          ),
          const SizedBox(height: 12),

          // Chemin
          TextFormField(
            controller: _path,
            decoration: _dec('Chemin / Répertoire', hint: 'D:\\Projets\\MonProjet'),
          ),
          const SizedBox(height: 12),

          // Notes importantes
          TextFormField(
            controller: _notes,
            maxLines: 3,
            decoration: _dec('Notes importantes', hint: 'Décisions techniques, pièges connus, état actuel…'),
          ),
          const SizedBox(height: 20),

          // Bouton sauvegarder
          FilledButton.icon(
            icon: _saving
                ? const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: Text(_saving ? 'Enregistrement…' : 'Enregistrer le projet'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: _saving ? null : _submit,
          ),
        ],
      ),
    );
  }
}
