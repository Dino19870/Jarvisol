import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../services/settings_service.dart';
import '../services/mcp_tools_service.dart';

// ── Modèle MCP custom ─────────────────────────────────────────────────────────

class McpEntry {
  final String id;
  String name;
  String icon;
  String type;
  String trigger;
  List<String> keywords;
  bool enabled;
  String source;
  String systemInjection;
  String endpoint;
  String method;
  String bodyTemplate;
  String responsePath;
  String scriptPath;
  List<String> argsTemplate;

  McpEntry({
    required this.id, required this.name, required this.icon,
    required this.type, required this.trigger,
    this.keywords = const [], required this.enabled,
    required this.source, this.systemInjection = '',
    this.endpoint = '', this.method = 'POST',
    this.bodyTemplate = '', this.responsePath = '',
    this.scriptPath = '', this.argsTemplate = const [],
  });

  factory McpEntry.fromJson(Map<String, dynamic> j) => McpEntry(
    id: j['id'] ?? '', name: j['name'] ?? '', icon: j['icon'] ?? '🔧',
    type: j['type'] ?? 'prompt', trigger: j['trigger'] ?? 'always',
    keywords: List<String>.from(j['keywords'] ?? []),
    enabled: j['enabled'] != false, source: j['source'] ?? 'user',
    systemInjection: j['system_injection'] ?? '',
    endpoint: j['endpoint'] ?? '', method: j['method'] ?? 'POST',
    bodyTemplate: j['body_template'] ?? '', responsePath: j['response_path'] ?? '',
    scriptPath: j['script_path'] ?? '',
    argsTemplate: List<String>.from(j['args_template'] ?? []),
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'icon': icon, 'type': type,
    'trigger': trigger, 'keywords': keywords, 'enabled': enabled,
    'source': source, 'system_injection': systemInjection,
    'endpoint': endpoint, 'method': method,
    'body_template': bodyTemplate, 'response_path': responsePath,
    'script_path': scriptPath, 'args_template': argsTemplate,
  };
}

// ── MCP built-in descriptor ───────────────────────────────────────────────────

class BuiltinMcp {
  final String name;
  final String icon;
  final String description;
  final bool Function(SettingsService) getter;
  final void Function(SettingsService, bool) setter;
  BuiltinMcp({required this.name, required this.icon, required this.description,
    required this.getter, required this.setter});
}

final _builtins = [
  BuiltinMcp(name: 'Date & Heure', icon: '📅',
    description: 'Injecte la date du jour dans le system prompt',
    getter: (s) => s.enableCurrentDateTool,
    setter: (s, v) => s.enableCurrentDateTool = v),
  BuiltinMcp(name: 'Recherche Web', icon: '🌐',
    description: 'Effectue des recherches DuckDuckGo à la demande',
    getter: (s) => s.enableWebSearchTool,
    setter: (s, v) => s.enableWebSearchTool = v),
  BuiltinMcp(name: 'Gmail MCP', icon: '✉️',
    description: 'Accède à ta boîte Gmail via MCP',
    getter: (s) => s.enableGmailTool,
    setter: (s, v) => s.enableGmailTool = v),
  BuiltinMcp(name: "Génération d'image", icon: '🎨',
    description: 'Génère des images via Stable Diffusion local',
    getter: (s) => s.enableImageGenTool,
    setter: (s, v) => s.enableImageGenTool = v),
];

// ── API helper ────────────────────────────────────────────────────────────────

const _kBase = 'http://127.0.0.1:7862';

Future<List<McpEntry>> _fetchMcps() async {
  try {
    final req = await HttpClient().getUrl(Uri.parse('$_kBase/mcps'));
    final res = await req.close();
    if (res.statusCode == 200) {
      final body = await res.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      return (data['mcps'] as List? ?? [])
          .map((e) => McpEntry.fromJson(e as Map<String, dynamic>)).toList();
    }
  } catch (_) {}
  return [];
}

Future<bool> _saveMcp(McpEntry e) async {
  try {
    final bodyStr = jsonEncode(e.toJson());
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/mcps/save'));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    final bytes = utf8.encode(bodyStr);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    return res.statusCode == 200;
  } catch (_) { return false; }
}

Future<bool> _deleteMcp(String id) async {
  try {
    final bodyStr = jsonEncode({'id': id});
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/mcps/delete'));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    final bytes = utf8.encode(bodyStr);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    return res.statusCode == 200;
  } catch (_) { return false; }
}

Future<bool> _toggleMcp(String id, bool enabled) async {
  try {
    final bodyStr = jsonEncode({'id': id, 'enabled': enabled});
    final req = await HttpClient().postUrl(Uri.parse('$_kBase/mcps/toggle'));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    final bytes = utf8.encode(bodyStr);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    return res.statusCode == 200;
  } catch (_) { return false; }
}

// ── Dialog principal ──────────────────────────────────────────────────────────

class McpLibraryDialog extends ConsumerStatefulWidget {
  const McpLibraryDialog({super.key});

  static Future<bool> show(BuildContext context) async =>
      await showDialog<bool>(context: context, builder: (_) => const McpLibraryDialog()) ?? false;

  @override
  ConsumerState<McpLibraryDialog> createState() => _McpLibraryDialogState();
}

class _McpLibraryDialogState extends ConsumerState<McpLibraryDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);
  List<McpEntry> _mcps = [];
  bool _loading = true;
  bool _serverOffline = false;
  bool _changed = false;
  McpEntry? _editing;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() { _loading = true; _serverOffline = false; });
    try {
      final list = await _fetchMcps();
      if (mounted) setState(() { _mcps = list; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _serverOffline = true; });
    }
  }

  void _startNew() {
    _tab.animateTo(2);
    setState(() => _editing = McpEntry(id: '', name: '', icon: '🔧', type: 'prompt',
      trigger: 'always', enabled: true, source: 'user'));
  }

  void _startEdit(McpEntry e) {
    _tab.animateTo(2);
    setState(() => _editing = McpEntry.fromJson(e.toJson()));
  }

  Future<void> _delete(McpEntry e) async {
    final ok = await _deleteMcp(e.id);
    if (ok && mounted) { _changed = true; setState(() => _mcps.removeWhere((x) => x.id == e.id)); }
  }

  Future<void> _toggleCustom(McpEntry e, bool val) async {
    await _toggleMcp(e.id, val);
    if (mounted) { _changed = true; setState(() => e.enabled = val); }
  }

  Future<void> _onSaved(McpEntry saved) async {
    final ok = await _saveMcp(saved);
    if (!ok || !mounted) return;
    _changed = true;
    await _load();
    setState(() { _editing = null; _tab.animateTo(0); });
  }

  Future<void> _importJson() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json'],
        dialogTitle: 'Importer une bibliothèque MCP');
      if (file?.path == null) return;
      final raw = await File(file!.path!).readAsString();
      final data = jsonDecode(raw);
      final List items = data is List ? data : (data['mcps'] as List? ?? []);
      int count = 0;
      for (final item in items) {
        final entry = McpEntry.fromJson({...item as Map<String, dynamic>, 'id': '', 'source': 'imported'});
        if (await _saveMcp(entry)) count++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$count MCP importé(s)'), backgroundColor: Colors.green));
        _changed = true;
        await _load();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _exportJson() async {
    try {
      final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Destination export');
      if (dir == null) return;
      final file = File('$dir\\mcp_library.json');
      await file.writeAsString(jsonEncode({'mcps': _mcps.map((e) => e.toJson()).toList()}));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Exporté → ${file.path}'), backgroundColor: Colors.green));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsServiceProvider);
    final activeBuiltins = _builtins.where((b) => b.getter(settings)).length;
    final activeCustom = _mcps.where((m) => m.enabled).length;
    final totalActive = activeBuiltins + activeCustom;

    return Dialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(width: 720, height: 650, child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
          decoration: BoxDecoration(
            color: Colors.deepPurple.shade900.withValues(alpha: 0.5),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14))),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.electric_bolt, color: Colors.deepPurpleAccent, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('⚡ Bibliothèque MCP',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                Text('$totalActive actif(s) · ${_builtins.length} built-in · ${_mcps.length} custom',
                  style: const TextStyle(fontSize: 10, color: Colors.white60)),
              ])),
              TextButton.icon(icon: const Icon(Icons.upload_file, size: 14),
                label: const Text('Importer', style: TextStyle(fontSize: 11)),
                onPressed: _serverOffline ? null : _importJson),
              TextButton.icon(icon: const Icon(Icons.download, size: 14),
                label: const Text('Exporter', style: TextStyle(fontSize: 11)),
                onPressed: _mcps.isEmpty ? null : _exportJson),
              IconButton(icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                onPressed: () => Navigator.pop(context, _changed)),
            ]),
            const SizedBox(height: 8),
            TabBar(
              controller: _tab,
              labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              unselectedLabelStyle: const TextStyle(fontSize: 11),
              indicatorColor: Colors.deepPurpleAccent,
              tabs: [
                const Tab(text: '📋 Tous'),
                Tab(text: '✅ Actifs ($totalActive)'),
                Tab(text: _editing == null ? '➕ Créer' : '✏️ Modifier'),
              ],
            ),
          ]),
        ),
        // Body
        Expanded(child: TabBarView(controller: _tab, children: [
          _buildAllTab(settings),
          _buildActiveTab(settings),
          _McpFormView(key: ValueKey(_editing?.id ?? 'new'), item: _editing,
            serverOffline: _serverOffline, onSave: _onSaved, onNew: _startNew),
        ])),
      ])),
    );
  }

  Widget _buildAllTab(SettingsService settings) => ListView(
    padding: const EdgeInsets.all(10),
    children: [
      _SectionHeader(title: '🔵 Outils built-in', count: _builtins.length),
      ..._builtins.map((b) => _BuiltinCard(mcp: b, settings: settings,
        onToggle: (v) => setState(() { b.setter(settings, v); _changed = true; }))),
      const SizedBox(height: 12),
      _SectionHeader(title: '🟣 Outils personnalisés', count: _mcps.length,
        trailing: FilledButton.icon(icon: const Icon(Icons.add, size: 13),
          label: const Text('Créer', style: TextStyle(fontSize: 11)),
          style: FilledButton.styleFrom(backgroundColor: Colors.deepPurple.shade700,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: _serverOffline ? null : _startNew)),
      if (_loading) const Center(child: Padding(padding: EdgeInsets.all(20),
        child: CircularProgressIndicator(color: Colors.deepPurpleAccent))),
      if (_serverOffline) _OfflineTile(onRetry: _load),
      if (!_loading && !_serverOffline && _mcps.isEmpty) const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Aucun MCP personnalisé — cliquez Créer',
          style: TextStyle(color: Colors.grey)))),
      ..._mcps.map((e) => _CustomCard(entry: e,
        onToggle: (v) => _toggleCustom(e, v),
        onEdit: () => _startEdit(e),
        onDelete: () => _confirmDelete(e),
        onRun: () => _executeScript(e))),
    ],
  );

  Widget _buildActiveTab(SettingsService settings) {
    final ab = _builtins.where((b) => b.getter(settings)).toList();
    final ac = _mcps.where((m) => m.enabled).toList();
    if (ab.isEmpty && ac.isEmpty) return const Center(
      child: Text('Aucun outil actif', style: TextStyle(color: Colors.grey)));
    return ListView(padding: const EdgeInsets.all(10), children: [
      if (ab.isNotEmpty) ...[
        _SectionHeader(title: '🔵 Built-in actifs', count: ab.length),
        ...ab.map((b) => _BuiltinCard(mcp: b, settings: settings,
          onToggle: (v) => setState(() { b.setter(settings, v); _changed = true; }))),
        const SizedBox(height: 12),
      ],
      if (ac.isNotEmpty) ...[
        _SectionHeader(title: '🟣 Custom actifs', count: ac.length),
        ...ac.map((e) => _CustomCard(entry: e,
          onToggle: (v) => _toggleCustom(e, v),
          onEdit: () => _startEdit(e),
          onDelete: () => _confirmDelete(e),
          onRun: () => _executeScript(e))),
      ],
    ]);
  }

  Future<void> _executeScript(McpEntry entry) async {
    final mcpTools = ref.read(mcpToolsServiceProvider);
    final result = await mcpTools.runMcpScript(entry.toJson());

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2430),
        title: Row(
          children: [
            Icon(
              result.success ? Icons.check_circle : Icons.error,
              color: result.success ? Colors.greenAccent : Colors.redAccent,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "Exécution Script : ${entry.name}",
                style: const TextStyle(fontSize: 16, color: Colors.white),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Commande : ${result.command}",
                  style: const TextStyle(fontSize: 12, color: Colors.white70, fontFamily: "monospace"),
                ),
                const SizedBox(height: 6),
                Text(
                  "Code de sortie : ${result.exitCode} (${result.success ? 'Succès' : 'Échec'})",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: result.success ? Colors.greenAccent : Colors.redAccent,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  "Sortie standard (stdout) :",
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    result.stdout.isEmpty ? "(aucune sortie standard)" : result.stdout,
                    style: const TextStyle(fontSize: 11, fontFamily: "monospace", color: Colors.greenAccent),
                  ),
                ),
                if (result.stderr.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    "Sortie d'erreur (stderr) :",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.redAccent),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      result.stderr,
                      style: const TextStyle(fontSize: 11, fontFamily: "monospace", color: Colors.redAccent),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("Fermer"),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(McpEntry e) => showDialog(context: context, builder: (_) => AlertDialog(
    title: const Text('Supprimer ce MCP ?'),
    content: Text('« ${e.name} »\nCette action est irréversible.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
      FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red),
        onPressed: () { Navigator.pop(context); _delete(e); },
        child: const Text('Supprimer')),
    ],
  ));
}

// ── Cartes ────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title; final int count; final Widget? trailing;
  const _SectionHeader({required this.title, required this.count, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
    child: Row(children: [
      Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
        color: Colors.deepPurple.shade300)),
      const SizedBox(width: 6),
      Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: Colors.deepPurple.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8)),
        child: Text('$count', style: const TextStyle(fontSize: 10, color: Colors.white70))),
      const Spacer(),
      if (trailing != null) trailing!,
    ]),
  );
}

class _BuiltinCard extends StatelessWidget {
  final BuiltinMcp mcp; final SettingsService settings; final ValueChanged<bool> onToggle;
  const _BuiltinCard({required this.mcp, required this.settings, required this.onToggle});
  @override
  Widget build(BuildContext context) {
    final active = mcp.getter(settings);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? Colors.blueAccent.withValues(alpha: 0.3) : Colors.white12)),
      child: ListTile(dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: Text(mcp.icon, style: const TextStyle(fontSize: 18)),
        title: Row(children: [
          Text(mcp.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4)),
            child: const Text('built-in', style: TextStyle(fontSize: 9, color: Colors.blueAccent))),
        ]),
        subtitle: Text(mcp.description, style: const TextStyle(fontSize: 10, color: Colors.white54)),
        trailing: Switch(value: active, onChanged: onToggle,
          activeColor: Colors.blueAccent,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap)),
    );
  }
}

class _CustomCard extends StatelessWidget {
  final McpEntry entry; final ValueChanged<bool> onToggle;
  final VoidCallback onEdit; final VoidCallback onDelete;
  final VoidCallback? onRun;
  const _CustomCard({required this.entry, required this.onToggle,
    required this.onEdit, required this.onDelete, this.onRun});

  Color get _c { switch (entry.type) {
    case 'http': return Colors.greenAccent;
    case 'script': return Colors.orangeAccent;
    default: return Colors.deepPurpleAccent; } }

  String get _trig { switch (entry.trigger) {
    case 'keyword': return '🔑 keyword';
    case 'manual': return '🖱 manuel';
    default: return '♾ toujours'; } }

  String get _sub {
    if (entry.type == 'prompt') {
      final s = entry.systemInjection;
      return s.isEmpty ? 'Pas d\'injection définie' : s.substring(0, s.length.clamp(0, 80)) + (s.length > 80 ? '…' : '');
    }
    return entry.type == 'http' ? entry.endpoint : entry.scriptPath;
  }

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 6),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: entry.enabled ? _c.withValues(alpha: 0.3) : Colors.white12)),
    child: ListTile(dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Text(entry.icon, style: const TextStyle(fontSize: 18)),
      title: Row(children: [
        Expanded(child: Text(entry.name,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(color: _c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
          child: Text(entry.type, style: TextStyle(fontSize: 9, color: _c))),
        const SizedBox(width: 4),
        Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(4)),
          child: Text(_trig, style: const TextStyle(fontSize: 9, color: Colors.white60))),
      ]),
      subtitle: Text(_sub, style: const TextStyle(fontSize: 10, color: Colors.white54),
        maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (entry.type == 'script')
          IconButton(icon: const Icon(Icons.play_arrow, size: 18, color: Colors.orangeAccent),
            onPressed: onRun, tooltip: 'Tester / Exécuter ce script'),
        Switch(value: entry.enabled, onChanged: onToggle, activeColor: _c,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
        IconButton(icon: const Icon(Icons.edit, size: 15, color: Colors.blueAccent),
          onPressed: onEdit, tooltip: 'Modifier'),
        IconButton(icon: const Icon(Icons.delete_outline, size: 15, color: Colors.redAccent),
          onPressed: onDelete, tooltip: 'Supprimer'),
      ])),
  );
}

class _OfflineTile extends StatelessWidget {
  final VoidCallback onRetry;
  const _OfflineTile({required this.onRetry});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.cloud_off, color: Colors.orange, size: 36),
      const SizedBox(height: 8),
      const Text('Memory server injoignable', style: TextStyle(color: Colors.orange)),
      const SizedBox(height: 12),
      OutlinedButton(onPressed: onRetry, child: const Text('Réessayer')),
    ]),
  );
}

// ── Formulaire ────────────────────────────────────────────────────────────────

class _McpFormView extends StatefulWidget {
  final McpEntry? item; final bool serverOffline;
  final Future<void> Function(McpEntry) onSave; final VoidCallback onNew;
  const _McpFormView({super.key, required this.item, required this.serverOffline,
    required this.onSave, required this.onNew});
  @override State<_McpFormView> createState() => _McpFormViewState();
}

class _McpFormViewState extends State<_McpFormView> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _icon, _injection, _endpoint, _body, _rpath, _script, _kw;
  late String _type, _trigger, _method;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.item;
    _name = TextEditingController(text: e?.name ?? '');
    _icon = TextEditingController(text: e?.icon ?? '🔧');
    _injection = TextEditingController(text: e?.systemInjection ?? '');
    _endpoint = TextEditingController(text: e?.endpoint ?? '');
    _body = TextEditingController(text: e?.bodyTemplate ?? '');
    _rpath = TextEditingController(text: e?.responsePath ?? '');
    _script = TextEditingController(text: e?.scriptPath ?? '');
    _kw = TextEditingController(text: (e?.keywords ?? []).join(', '));
    _type = e?.type ?? 'prompt';
    _trigger = e?.trigger ?? 'always';
    _method = e?.method ?? 'POST';
  }

  @override
  void dispose() {
    for (final c in [_name,_icon,_injection,_endpoint,_body,_rpath,_script,_kw]) c.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final kw = _kw.text.trim().isEmpty ? <String>[] :
      _kw.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final entry = McpEntry(
      id: widget.item?.id ?? '', name: _name.text.trim(),
      icon: _icon.text.trim().isEmpty ? '🔧' : _icon.text.trim(),
      type: _type, trigger: _trigger, keywords: kw,
      enabled: widget.item?.enabled ?? true, source: widget.item?.source ?? 'user',
      systemInjection: _injection.text.trim(),
      endpoint: _endpoint.text.trim(), method: _method,
      bodyTemplate: _body.text.trim(), responsePath: _rpath.text.trim(),
      scriptPath: _script.text.trim(),
    );
    await widget.onSave(entry);
    if (mounted) setState(() => _saving = false);
  }

  InputDecoration _dec(String l, {String? h}) => InputDecoration(
    labelText: l, hintText: h, isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8));

  @override
  Widget build(BuildContext context) {
    if (widget.serverOffline) return _OfflineTile(onRetry: () {});
    if (widget.item == null) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.add_circle_outline, color: Colors.grey, size: 48),
      const SizedBox(height: 12),
      const Text('Créer un nouvel outil MCP', style: TextStyle(color: Colors.grey)),
      const SizedBox(height: 16),
      FilledButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('Commencer'),
        style: FilledButton.styleFrom(backgroundColor: Colors.deepPurple.shade700),
        onPressed: widget.onNew),
    ]));

    return Form(key: _form, child: ListView(padding: const EdgeInsets.all(14), children: [
      Row(children: [
        SizedBox(width: 70, child: TextFormField(controller: _icon, decoration: _dec('Icône'),
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 18))),
        const SizedBox(width: 10),
        Expanded(child: TextFormField(controller: _name,
          decoration: _dec('Nom *', h: 'Expert SQL, API HFSQL, OCR…'),
          style: const TextStyle(fontWeight: FontWeight.bold),
          validator: (v) => (v?.trim().isEmpty ?? true) ? 'Requis' : null)),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: DropdownButtonFormField<String>(value: _type, decoration: _dec('Type'),
          items: const [
            DropdownMenuItem(value: 'prompt', child: Text('💬 Prompt — injection')),
            DropdownMenuItem(value: 'http',   child: Text('🔗 HTTP — API REST')),
            DropdownMenuItem(value: 'script', child: Text('🐍 Script local')),
          ],
          onChanged: (v) => setState(() => _type = v ?? 'prompt'))),
        const SizedBox(width: 10),
        Expanded(child: DropdownButtonFormField<String>(value: _trigger, decoration: _dec('Déclenchement'),
          items: const [
            DropdownMenuItem(value: 'always',  child: Text('♾ Toujours')),
            DropdownMenuItem(value: 'keyword', child: Text('🔑 Sur keyword')),
            DropdownMenuItem(value: 'manual',  child: Text('🖱 Manuel')),
          ],
          onChanged: (v) => setState(() => _trigger = v ?? 'always'))),
      ]),
      const SizedBox(height: 10),
      if (_trigger == 'keyword') ...[
        TextFormField(controller: _kw,
          decoration: _dec('Keywords', h: 'hfsql, sql, base de données (séparés par virgule)')),
        const SizedBox(height: 10),
      ],
      if (_type == 'prompt') ...[
        TextFormField(controller: _injection,
          decoration: _dec('Texte injecté dans le system prompt *',
            h: 'Tu es un expert SQL Server et HFSQL...'),
          maxLines: 6,
          validator: (v) => (v?.trim().isEmpty ?? true) ? 'Requis pour type=prompt' : null),
      ] else if (_type == 'http') ...[
        TextFormField(controller: _endpoint, decoration: _dec('URL Endpoint *', h: 'http://localhost:5000/api'),
          validator: (v) => (v?.trim().isEmpty ?? true) ? 'Requis' : null),
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(width: 100, child: DropdownButtonFormField<String>(value: _method,
            decoration: _dec('Méthode'),
            items: ['GET','POST','PUT'].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
            onChanged: (v) => setState(() => _method = v ?? 'POST'))),
          const SizedBox(width: 10),
          Expanded(child: TextFormField(controller: _rpath,
            decoration: _dec('Réponse JSON path', h: 'result'))),
        ]),
        const SizedBox(height: 8),
        TextFormField(controller: _body,
          decoration: _dec('Body template', h: '{"query": "{{user_message}}"}'), maxLines: 3),
      ] else if (_type == 'script') ...[
        Row(children: [
          Expanded(child: TextFormField(controller: _script,
            decoration: _dec('Chemin du script *', h: 'D:\\scripts\\ocr.py'),
            validator: (v) => (v?.trim().isEmpty ?? true) ? 'Requis' : null)),
          const SizedBox(width: 8),
          OutlinedButton.icon(icon: const Icon(Icons.folder_open, size: 14),
            label: const Text('Parcourir', style: TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
            onPressed: () async {
              final f = await FilePicker.pickFile(type: FileType.any);
              if (f?.path != null && mounted) setState(() => _script.text = f!.path!);
            }),
        ]),
      ],
      const SizedBox(height: 16),
      FilledButton.icon(
        icon: _saving ? const SizedBox(width: 14, height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.save, size: 16),
        label: Text(_saving ? 'Enregistrement…' : 'Enregistrer le MCP'),
        style: FilledButton.styleFrom(backgroundColor: Colors.deepPurple.shade700,
          padding: const EdgeInsets.symmetric(vertical: 12)),
        onPressed: _saving ? null : _submit),
    ]));
  }
}
