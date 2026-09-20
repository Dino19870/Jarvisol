import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

// ── API helper ────────────────────────────────────────────────────────────────

const _kBase = 'http://127.0.0.1:7862';

Future<List<Map<String, dynamic>>> _fetchCorrections() async {
  try {
    final req = await HttpClient().getUrl(Uri.parse('$_kBase/corrections'));
    final res = await req.close();
    if (res.statusCode == 200) {
      final body = await res.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      return (data['corrections'] as List? ?? [])
          .cast<Map<String, dynamic>>();
    }
  } catch (_) {}
  return [];
}

Future<bool> _saveCorrection(String text) async {
  try {
    final bodyStr = jsonEncode({'text': text, 'source': 'user'});
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/corrections/save'));
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

Future<Map<String, dynamic>> _importLessons(String? path) async {
  try {
    final bodyStr = jsonEncode(path != null ? {'path': path} : {});
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/corrections/import'));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    final bytes = utf8.encode(bodyStr);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final respBody = await res.transform(utf8.decoder).join();
    return jsonDecode(respBody) as Map<String, dynamic>;
  } catch (e) {
    return {'status': 'error', 'message': '$e'};
  }
}

Future<bool> _deleteCorrection(String id) async {
  try {
    final bodyStr = jsonEncode({'id': id});
    final req = await HttpClient()
        .postUrl(Uri.parse('$_kBase/corrections/delete'));
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

class CorrectionDialog extends StatefulWidget {
  const CorrectionDialog({super.key});

  /// Ouvre le dialog. Retourne true si des corrections ont été modifiées.
  static Future<bool> show(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => const CorrectionDialog(),
      ) ??
      false;

  @override
  State<CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<CorrectionDialog> {
  List<Map<String, dynamic>> _corrections = [];
  bool _loading = true;
  bool _serverOffline = false;
  bool _importing = false;
  bool _changed = false;

  // Formulaire ajout rapide
  final _addCtrl = TextEditingController();
  bool _showAddForm = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _serverOffline = false; });
    try {
      final list = await _fetchCorrections();
      if (mounted) setState(() { _corrections = list; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _serverOffline = true; });
    }
  }

  Future<void> _addCorrection() async {
    final text = _addCtrl.text.trim();
    if (text.isEmpty) return;
    final ok = await _saveCorrection(text);
    if (ok && mounted) {
      _addCtrl.clear();
      _changed = true;
      setState(() => _showAddForm = false);
      await _load();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Correctif ajouté'),
        duration: Duration(seconds: 2),
        backgroundColor: Colors.green,
      ));
    }
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    final result = await _importLessons(null);  // chemin auto-détecté
    if (mounted) {
      setState(() { _importing = false; _changed = true; });
      final imported = result['imported'] as int? ?? 0;
      final status = result['status'] as String? ?? 'error';
      if (status == 'ok') {
        await _load();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('📥 $imported correctif${imported > 1 ? "s" : ""} importé${imported > 1 ? "s" : ""} depuis lessons_learned.md'),
          duration: const Duration(seconds: 4),
          backgroundColor: Colors.teal.shade800,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('⚠️ Import échoué : ${result["message"] ?? "erreur"}'),
          backgroundColor: Colors.red.shade800,
        ));
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final id = c['id'] as String? ?? '';
    if (id.isEmpty) return;
    final ok = await _deleteCorrection(id);
    if (ok && mounted) {
      _changed = true;
      setState(() => _corrections.removeWhere((x) => x['id'] == id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: 680,
        height: 620,
        child: Column(children: [
          // ── Header ──────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.orange.shade900.withValues(alpha: 0.45),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(children: [
              const Icon(Icons.auto_fix_high, color: Colors.orangeAccent, size: 20),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('📋 Correctifs & Leçons apprises',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                Text('${_corrections.length} correctif${_corrections.length != 1 ? "s" : ""} — '
                    'injectés automatiquement dans chaque session',
                    style: const TextStyle(fontSize: 10, color: Colors.white60)),
              ]),
              const Spacer(),
              // Bouton import
              Tooltip(
                message: 'Importer lessons_learned.md',
                child: OutlinedButton.icon(
                  icon: _importing
                      ? const SizedBox(width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))
                      : const Icon(Icons.upload_file, size: 14, color: Colors.orangeAccent),
                  label: const Text('📥 Importer MD', style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.orangeAccent),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4)),
                  onPressed: (_importing || _serverOffline) ? null : _import,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                onPressed: () => Navigator.pop(context, _changed),
              ),
            ]),
          ),

          // ── Corps ────────────────────────────────────────────────────────────
          Expanded(child: _loading
              ? const Center(child: CircularProgressIndicator(color: Colors.orangeAccent))
              : _serverOffline
                  ? _buildOffline()
                  : _buildList()),

          // ── Formulaire ajout ─────────────────────────────────────────────────
          if (_showAddForm)
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white.withValues(alpha: 0.03),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _addCtrl,
                    autofocus: true,
                    maxLines: 2,
                    decoration: InputDecoration(
                      hintText: 'Ex: [WLangage] TANTQUE s\'écrit en un seul mot (sans espace)',
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    onSubmitted: (_) => _addCorrection(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.orange.shade800,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
                  onPressed: _addCorrection,
                  child: const Text('Ajouter', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => setState(() { _showAddForm = false; _addCtrl.clear(); }),
                  child: const Text('Annuler', style: TextStyle(fontSize: 11)),
                ),
              ]),
            ),

          // ── Footer ───────────────────────────────────────────────────────────
          if (!_showAddForm)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                const Icon(Icons.lightbulb_outline, size: 12, color: Colors.orange),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Chaque correctif = une ligne courte, ex: [TAG] Problème : Solution',
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Ajouter un correctif', style: TextStyle(fontSize: 11)),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.orange.shade800,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
                  onPressed: _serverOffline ? null : () => setState(() => _showAddForm = true),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _buildOffline() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.cloud_off, color: Colors.orange, size: 40),
    const SizedBox(height: 12),
    const Text('Memory server injoignable', style: TextStyle(color: Colors.orange)),
    const SizedBox(height: 6),
    const Text('Démarrez memory_server.exe',
        style: TextStyle(color: Colors.grey, fontSize: 12)),
    const SizedBox(height: 14),
    OutlinedButton(onPressed: _load, child: const Text('Réessayer')),
  ]));

  Widget _buildList() {
    if (_corrections.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check_circle_outline, color: Colors.grey, size: 48),
        const SizedBox(height: 12),
        const Text('Aucun correctif enregistré', style: TextStyle(color: Colors.grey, fontSize: 14)),
        const SizedBox(height: 8),
        const Text('Importez lessons_learned.md ou ajoutez manuellement\nles pièges et corrections identifiés.',
            style: TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: const Icon(Icons.upload_file, size: 14, color: Colors.orangeAccent),
          label: const Text('📥 Importer lessons_learned.md', style: TextStyle(color: Colors.orangeAccent)),
          style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.orangeAccent)),
          onPressed: _importing ? null : _import,
        ),
      ]));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(10),
      itemCount: _corrections.length,
      separatorBuilder: (_, __) => const SizedBox(height: 5),
      itemBuilder: (ctx, i) {
        final c = _corrections[i];
        final content = c['content'] as String? ?? '';
        final source = c['source'] as String? ?? '';
        final isImported = source.startsWith('import:');

        return Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: (isImported ? Colors.orange : Colors.amber).withValues(alpha: 0.2)),
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            leading: Icon(
              isImported ? Icons.file_download_done : Icons.edit_note,
              size: 16,
              color: isImported ? Colors.orangeAccent : Colors.amberAccent,
            ),
            title: Text(content,
                style: const TextStyle(fontSize: 11, height: 1.4),
                maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: isImported
                ? Text('Source : ${source.replaceFirst("import:", "")}',
                    style: const TextStyle(fontSize: 9, color: Colors.grey))
                : null,
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
              tooltip: 'Supprimer',
              onPressed: () => showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Supprimer ce correctif ?'),
                  content: Text(content.length > 80 ? '${content.substring(0, 80)}…' : content,
                      style: const TextStyle(fontSize: 12)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () { Navigator.pop(context); _delete(c); },
                      child: const Text('Supprimer'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
