import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

// ── Modèle ────────────────────────────────────────────────────────────────────

class FileEntry {
  final String id;
  String label;
  String path;
  String description;
  String project;
  String type; // file | directory | url | other

  FileEntry({
    required this.id,
    required this.label,
    required this.path,
    required this.description,
    required this.project,
    required this.type,
  });

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        id:          j['id'] ?? '',
        label:       j['label'] ?? '',
        path:        j['path'] ?? '',
        description: j['description'] ?? '',
        project:     j['project'] ?? '',
        type:        j['type'] ?? 'file',
      );

  Map<String, dynamic> toJson() => {
        'id':          id,
        'label':       label,
        'path':        path,
        'description': description,
        'project':     project,
        'type':        type,
      };

  bool get exists {
    if (type == 'url') return true;
    return File(path).existsSync() || Directory(path).existsSync();
  }
}

// ── API helper ────────────────────────────────────────────────────────────────

const _kBase = 'http://127.0.0.1:7862';

Future<List<FileEntry>> _fetchFiles() async {
  try {
    final req = await HttpClient().getUrl(Uri.parse('$_kBase/files'));
    final res = await req.close();
    if (res.statusCode == 200) {
      final body = await res.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      return (data['files'] as List? ?? [])
          .map((e) => FileEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }
  } catch (_) {}
  return [];
}

Future<bool> _saveFile(FileEntry e) async {
  try {
    final bodyStr = jsonEncode(e.toJson());
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/files/save'));
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

Future<bool> _deleteFile(String id) async {
  try {
    final bodyStr = jsonEncode({'id': id});
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/files/delete'));
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

// ── Dialog ────────────────────────────────────────────────────────────────────

class FilePathsDialog extends StatefulWidget {
  const FilePathsDialog({super.key});

  static Future<bool> show(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => const FilePathsDialog(),
      ) ??
      false;

  @override
  State<FilePathsDialog> createState() => _FilePathsDialogState();
}

class _FilePathsDialogState extends State<FilePathsDialog> {
  List<FileEntry> _files = [];
  bool _loading = true;
  bool _serverOffline = false;
  bool _changed = false;
  FileEntry? _editing; // null = liste, sinon formulaire

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _serverOffline = false; });
    try {
      final list = await _fetchFiles();
      if (mounted) setState(() { _files = list; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _serverOffline = true; });
    }
  }

  void _startNew() => setState(() => _editing = FileEntry(
        id: '', label: '', path: '', description: '', project: '', type: 'file'));

  void _startEdit(FileEntry e) => setState(() => _editing = FileEntry(
        id: e.id, label: e.label, path: e.path,
        description: e.description, project: e.project, type: e.type));

  Future<void> _delete(FileEntry e) async {
    final ok = await _deleteFile(e.id);
    if (ok && mounted) {
      _changed = true;
      setState(() => _files.removeWhere((x) => x.id == e.id));
    }
  }

  Future<void> _onSaved(FileEntry saved) async {
    final ok = await _saveFile(saved);
    if (!ok || !mounted) return;
    _changed = true;
    await _load();
    setState(() => _editing = null);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: 680,
        height: 600,
        child: Column(children: [
          // ── Header ──────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.indigo.shade900.withValues(alpha: 0.55),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(children: [
              const Icon(Icons.folder_open, color: Colors.indigoAccent, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  _editing == null
                      ? '📁 Fichiers & Chemins importants'
                      : (_editing!.id.isEmpty ? '➕ Nouveau chemin' : '✏️ Modifier : ${_editing!.label}'),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                Text(
                  '${_files.length} entrée${_files.length != 1 ? "s" : ""} — '
                  'injectées automatiquement dans chaque session',
                  style: const TextStyle(fontSize: 10, color: Colors.white60)),
              ])),
              if (_editing != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 18),
                  tooltip: 'Retour à la liste',
                  onPressed: () => setState(() => _editing = null),
                ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                onPressed: () => Navigator.pop(context, _changed),
              ),
            ]),
          ),

          // ── Corps ────────────────────────────────────────────────────────────
          Expanded(child: _editing != null
              ? _FileFormWidget(item: _editing!, onSave: _onSaved)
              : _buildList()),

          // ── Footer ───────────────────────────────────────────────────────────
          if (_editing == null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                const Icon(Icons.tips_and_updates, size: 12, color: Colors.indigoAccent),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Ajoutez les fichiers config, modèles IA, sources importantes, URLs récurrentes…',
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Ajouter', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.indigo.shade700,
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
      return const Center(child: CircularProgressIndicator(color: Colors.indigoAccent));
    }
    if (_serverOffline) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off, color: Colors.orange, size: 40),
        const SizedBox(height: 12),
        const Text('Memory server injoignable', style: TextStyle(color: Colors.orange)),
        const SizedBox(height: 6),
        const Text('Démarrez memory_server.exe', style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: _load, child: const Text('Réessayer')),
      ]));
    }
    if (_files.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.folder_open, color: Colors.grey, size: 48),
        const SizedBox(height: 12),
        const Text('Aucun chemin enregistré', style: TextStyle(color: Colors.grey, fontSize: 14)),
        const SizedBox(height: 8),
        const Text(
          'Exemples :\n'
          '• Modèle SD principal → D:\\AI\\models\\...\\realistic.safetensors\n'
          '• Config HFSQL → D:\\Projets\\Config\\hfsql.ini\n'
          '• Doc PC SOFT → https://doc.pcsoft.fr',
          style: TextStyle(color: Colors.grey, fontSize: 11), textAlign: TextAlign.center),
      ]));
    }

    // Grouper par projet
    final byProject = <String, List<FileEntry>>{};
    for (final f in _files) {
      final proj = f.project.isNotEmpty ? f.project : 'Général';
      byProject.putIfAbsent(proj, () => []).add(f);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: byProject.length,
      itemBuilder: (ctx, pi) {
        final proj = byProject.keys.elementAt(pi);
        final entries = byProject[proj]!;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (byProject.length > 1) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Text(proj,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                      color: Colors.indigo.shade300)),
            ),
          ],
          ...entries.map((e) => _FileCard(
            entry: e,
            onEdit: () => _startEdit(e),
            onDelete: () => _delete(e),
          )),
          const SizedBox(height: 8),
        ]);
      },
    );
  }
}

// ── Carte fichier ─────────────────────────────────────────────────────────────

class _FileCard extends StatelessWidget {
  final FileEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _FileCard({required this.entry, required this.onEdit, required this.onDelete});

  IconData get _icon {
    switch (entry.type) {
      case 'directory': return Icons.folder;
      case 'url':       return Icons.link;
      case 'other':     return Icons.push_pin;
      default:          return Icons.insert_drive_file;
    }
  }

  Color get _color {
    switch (entry.type) {
      case 'directory': return Colors.amber;
      case 'url':       return Colors.lightBlueAccent;
      case 'other':     return Colors.grey;
      default:          return Colors.indigoAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final exists = entry.exists;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: exists ? _color.withValues(alpha: 0.25) : Colors.red.withValues(alpha: 0.3)),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: Stack(clipBehavior: Clip.none, children: [
          Icon(_icon, color: _color, size: 20),
          Positioned(
            bottom: -2, right: -4,
            child: Icon(
              exists ? Icons.check_circle : Icons.error_outline,
              size: 10,
              color: exists ? Colors.green : Colors.red,
            ),
          ),
        ]),
        title: Row(children: [
          Expanded(child: Text(entry.label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          if (entry.project.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.indigo.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(entry.project, style: const TextStyle(fontSize: 9, color: Colors.white70)),
            ),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(entry.path,
              style: TextStyle(fontSize: 10, color: exists ? Colors.white54 : Colors.red.shade300,
                  fontFamily: 'monospace'),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (entry.description.isNotEmpty)
            Text(entry.description,
                style: const TextStyle(fontSize: 10, color: Colors.white38),
                maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            icon: const Icon(Icons.edit, size: 15, color: Colors.blueAccent),
            tooltip: 'Modifier',
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 15, color: Colors.redAccent),
            tooltip: 'Supprimer',
            onPressed: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Supprimer ce chemin ?'),
                content: Text('« ${entry.label} »\n${entry.path}'),
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

class _FileFormWidget extends StatefulWidget {
  final FileEntry item;
  final Future<void> Function(FileEntry) onSave;
  const _FileFormWidget({required this.item, required this.onSave});

  @override
  State<_FileFormWidget> createState() => _FileFormWidgetState();
}

class _FileFormWidgetState extends State<_FileFormWidget> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _label       = TextEditingController(text: widget.item.label);
  late final TextEditingController _path        = TextEditingController(text: widget.item.path);
  late final TextEditingController _description = TextEditingController(text: widget.item.description);
  late final TextEditingController _project     = TextEditingController(text: widget.item.project);
  late String _type = widget.item.type.isEmpty ? 'file' : widget.item.type;
  bool _saving = false;

  @override
  void dispose() {
    _label.dispose(); _path.dispose();
    _description.dispose(); _project.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    try {
      if (_type == 'directory') {
        final result = await FilePicker.getDirectoryPath(
          dialogTitle: 'Sélectionner un dossier',
        );
        if (result != null && mounted) setState(() => _path.text = result);
      } else {
        final file = await FilePicker.pickFile(
          dialogTitle: 'Sélectionner un fichier',
          type: FileType.any,
        );
        if (file != null && mounted) {
          setState(() => _path.text = file.path ?? '');
          // Auto-déduire le label depuis le nom de fichier si vide
          if (_label.text.isEmpty && file.name.isNotEmpty) {
            setState(() => _label.text = file.name);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final updated = FileEntry(
      id:          widget.item.id,
      label:       _label.text.trim(),
      path:        _path.text.trim(),
      description: _description.text.trim(),
      project:     _project.text.trim(),
      type:        _type,
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
          // Type
          DropdownButtonFormField<String>(
            value: _type,
            decoration: _dec('Type'),
            items: const [
              DropdownMenuItem(value: 'file',      child: Text('📄 Fichier')),
              DropdownMenuItem(value: 'directory', child: Text('📁 Dossier / Répertoire')),
              DropdownMenuItem(value: 'url',       child: Text('🌐 URL / Lien web')),
              DropdownMenuItem(value: 'other',     child: Text('📌 Autre')),
            ],
            onChanged: (v) => setState(() => _type = v ?? 'file'),
          ),
          const SizedBox(height: 12),

          // Label
          TextFormField(
            controller: _label,
            decoration: _dec('Label *', hint: 'Modèle SD Principal, Config HFSQL, Doc PC SOFT…'),
            style: const TextStyle(fontWeight: FontWeight.bold),
            validator: (v) => (v?.trim().isEmpty ?? true) ? 'Champ requis' : null,
          ),
          const SizedBox(height: 12),

          // Chemin + bouton Parcourir
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _path,
                decoration: _dec(
                  _type == 'url' ? 'URL *' : 'Chemin *',
                  hint: _type == 'url'
                      ? 'https://doc.pcsoft.fr'
                      : _type == 'directory'
                          ? 'D:\\Projets\\MonProjet\\'
                          : 'D:\\AI\\models\\realisticVision.safetensors',
                ),
                validator: (v) => (v?.trim().isEmpty ?? true) ? 'Champ requis' : null,
              ),
            ),
            if (_type != 'url') ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open, size: 14),
                label: const Text('Parcourir', style: TextStyle(fontSize: 11)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
                onPressed: _browse,
              ),
            ],
          ]),
          const SizedBox(height: 12),

          // Description
          TextFormField(
            controller: _description,
            decoration: _dec('Description', hint: 'À quoi sert ce fichier / chemin ?'),
          ),
          const SizedBox(height: 12),

          // Projet associé
          TextFormField(
            controller: _project,
            decoration: _dec('Projet associé', hint: 'CrisperWeaver, Windev, AgentFolder… (optionnel)'),
          ),
          const SizedBox(height: 20),

          // Bouton
          FilledButton.icon(
            icon: _saving
                ? const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.indigo.shade700,
              padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: _saving ? null : _submit,
          ),
        ],
      ),
    );
  }
}
