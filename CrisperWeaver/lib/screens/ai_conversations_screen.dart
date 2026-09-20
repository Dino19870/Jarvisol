// lib/screens/ai_conversations_screen.dart
// Viewer for Antigravity AI conversation transcripts.
// Features: multi-format export (TXT/MD/JSON/Clipboard), RAG badge, batch export.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import '../services/ai_conversations_service.dart';
import '../utils/ai_text_disclosure.dart';

class AiConversationsScreen extends ConsumerStatefulWidget {
  const AiConversationsScreen({super.key});
  @override
  ConsumerState<AiConversationsScreen> createState() => _AiConversationsScreenState();
}

class _AiConversationsScreenState extends ConsumerState<AiConversationsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String  _query        = '';
  List<AiConversationMeta>? _conversations;
  AiConversationMeta? _selected;
  final List<AiMessage> _messages = [];
  StreamSubscription<AiMessage>? _msgSub;
  bool    _loading      = false;
  bool    _loadingList  = false;
  bool    _batchRunning = false;
  String? _exportStatus;
  final ScrollController _msgScroll = ScrollController();
  // ── Navigation entre occurrences de recherche ──
  List<_SearchMatch> _searchMatches  = [];
  int               _currentMatchIdx = -1;
  final GlobalKey   _currentMatchKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadList();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _msgSub?.cancel();
    _msgScroll.dispose();
    super.dispose();
  }

  // ── List ────────────────────────────────────────────────────────────────────

  Future<void> _loadList() async {
    setState(() => _loadingList = true);
    final svc  = ref.read(aiConversationsServiceProvider);
    final list = await svc.listConversations(query: _query);
    if (mounted) setState(() { _conversations = list; _loadingList = false; });
  }

  void _selectConversation(AiConversationMeta meta) {
    _msgSub?.cancel();
    setState(() {
      _selected = meta;
      _messages.clear();
      _loading = true;
      _exportStatus = null;
    });
    final svc = ref.read(aiConversationsServiceProvider);
    _msgSub = svc.streamMessages(meta.transcriptPath).listen(
      (msg) { if (mounted) setState(() { _messages.add(msg); _loading = false; }); },
      onError: (_) { if (mounted) setState(() => _loading = false); },
      onDone:  () {
        if (!mounted) return;
        setState(() => _loading = false);
        if (_query.isNotEmpty) _rebuildSearchMatches();
      },
    );
  }

  // ── Export helpers ──────────────────────────────────────────────────────────

  Future<String?> _pickOutputDir(String title) async {
    try {
      return await FilePicker.getDirectoryPath(dialogTitle: title);
    } catch (_) { return null; }
  }

  String _defaultExportDir(AiConversationsService svc) =>
    p.join(p.dirname(svc.brainDir), 'rag_exports');

  Future<void> _exportRag() async {
    if (_selected == null) return;
    final svc = ref.read(aiConversationsServiceProvider);
    final dir = await _pickOutputDir('Dossier RAG (TXT)')
             ?? _defaultExportDir(svc);
    setState(() => _exportStatus = 'Export TXT en cours...');
    try {
      final path = await svc.exportForRag(_selected!, dir);
      // Refresh list so badge updates
      await _loadList();
      if (mounted) setState(() => _exportStatus = '✅ TXT exporté : $path');
    } catch (e) {
      if (mounted) setState(() => _exportStatus = '❌ Erreur : $e');
    }
  }

  Future<void> _exportMarkdown() async {
    if (_selected == null) return;
    final svc = ref.read(aiConversationsServiceProvider);
    final dir = await _pickOutputDir('Dossier export Markdown')
             ?? _defaultExportDir(svc);
    setState(() => _exportStatus = 'Export Markdown en cours...');
    try {
      final path = await svc.exportAsMarkdown(_selected!, dir);
      if (mounted) setState(() => _exportStatus = '✅ Markdown exporté : $path');
    } catch (e) {
      if (mounted) setState(() => _exportStatus = '❌ Erreur : $e');
    }
  }

  Future<void> _exportJson() async {
    if (_selected == null) return;
    final svc = ref.read(aiConversationsServiceProvider);
    final dir = await _pickOutputDir('Dossier export JSON')
             ?? _defaultExportDir(svc);
    setState(() => _exportStatus = 'Export JSON en cours...');
    try {
      final path = await svc.exportAsJson(_selected!, dir);
      if (mounted) setState(() => _exportStatus = '✅ JSON exporté : $path');
    } catch (e) {
      if (mounted) setState(() => _exportStatus = '❌ Erreur : $e');
    }
  }

  Future<void> _copyToClipboard() async {
    if (_selected == null) return;
    final svc = ref.read(aiConversationsServiceProvider);
    setState(() => _exportStatus = 'Copie en cours...');
    try {
      final text = await svc.buildPlainText(_selected!);
      await Clipboard.setData(
          ClipboardData(text: AiTextDisclosure.forSummary(text)));
      if (mounted) setState(() => _exportStatus = '✅ Conversation copiée dans le presse-papier');
    } catch (e) {
      if (mounted) setState(() => _exportStatus = '❌ Erreur : $e');
    }
  }

  Future<void> _batchExportAllRag() async {
    if (_conversations == null || _conversations!.isEmpty) return;
    final svc = ref.read(aiConversationsServiceProvider);
    final dir = await _pickOutputDir('Dossier RAG — Export de toutes les conversations')
             ?? _defaultExportDir(svc);
    setState(() { _batchRunning = true; _exportStatus = 'Export batch en cours...'; });
    try {
      final result = await svc.exportAllForRag(_conversations!, dir);
      await _loadList(); // refresh badges
      if (mounted) setState(() {
        _batchRunning = false;
        _exportStatus = '✅ Batch terminé — ${result.exported} exportées, ${result.skipped} déjà à jour'
            + (result.errors.isEmpty ? '' : '\n⚠️ Erreurs : ${result.errors.join(', ')}');
      });
    } catch (e) {
      if (mounted) setState(() { _batchRunning = false; _exportStatus = '❌ Erreur batch : $e'; });
    }
  }

  Future<void> _changeBrainDir() async {
    final svc = ref.read(aiConversationsServiceProvider);
    String? dir;
    try { dir = await FilePicker.getDirectoryPath(dialogTitle: 'Dossier brain Antigravity'); }
    catch (_) {}
    if (dir != null) {
      svc.setBrainDir(dir);
      setState(() { _conversations = null; _selected = null; _messages.clear(); });
      _loadList();
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final svc    = ref.read(aiConversationsServiceProvider);
    final isWide = MediaQuery.of(context).size.width > 700;

    final listPanel   = _buildListPanel(svc, isWide);
    final viewerPanel = _buildViewerPanel();

    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.forum_outlined, color: Colors.deepPurpleAccent, size: 20),
          SizedBox(width: 8),
          Text('Conversations IA', style: TextStyle(fontSize: 15)),
        ]),
        backgroundColor: const Color(0xFF12122A),
        actions: [
          // Batch export button
          if (_conversations != null && _conversations!.isNotEmpty)
            Tooltip(
              message: 'Exporter toutes les conversations non-indexées → RAG',
              child: _batchRunning
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    onPressed: _batchExportAllRag,
                  ),
            ),
          IconButton(
            icon: const Icon(Icons.folder_open, size: 18),
            tooltip: 'Changer le dossier brain',
            onPressed: _changeBrainDir,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Actualiser',
            onPressed: _loadList,
          ),
        ],
      ),
      body: !svc.isAvailable
          ? _buildNotAvailable(svc)
          : isWide
              ? Row(children: [
                  SizedBox(width: 290, child: listPanel),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(child: viewerPanel),
                ])
              : _selected == null ? listPanel : viewerPanel,
    );
  }

  Widget _buildNotAvailable(AiConversationsService svc) {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.folder_off, size: 48, color: Colors.white38),
      const SizedBox(height: 12),
      Text('Dossier Antigravity introuvable :', style: TextStyle(color: Colors.white60)),
      SelectableText(svc.brainDir, style: const TextStyle(fontSize: 11, color: Colors.white38)),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _changeBrainDir,
        icon: const Icon(Icons.folder_open),
        label: const Text('Choisir le dossier brain'),
      ),
    ]));
  }

  Widget _buildListPanel(AiConversationsService svc, bool isWide) {
    final ragCount = _conversations?.where((c) => c.isRagExported).length ?? 0;
    final total    = _conversations?.length ?? 0;

    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: 'Rechercher...',
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: _query.isNotEmpty
                ? IconButton(icon: const Icon(Icons.clear, size: 16),
                    onPressed: () { _searchCtrl.clear(); setState(() => _query = ''); _loadList(); })
                : null,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (v) {
            setState(() => _query = v);
            _loadList();
            if (_selected != null && _messages.isNotEmpty) _rebuildSearchMatches();
          },
        ),
      ),
      if (_conversations != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(children: [
            Text('$total conversation(s)',
              style: const TextStyle(fontSize: 10, color: Colors.white38)),
            const Spacer(),
            if (ragCount > 0)
              Tooltip(
                message: '$ragCount/$total indexées dans le RAG',
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_done, size: 11, color: Colors.green),
                  const SizedBox(width: 2),
                  Text('$ragCount RAG',
                    style: const TextStyle(fontSize: 10, color: Colors.green)),
                ]),
              ),
          ]),
        ),
      Expanded(child: _loadingList
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _conversations == null || _conversations!.isEmpty
              ? Center(child: Text(
                  svc.isAvailable ? 'Aucune conversation trouvée' : 'Dossier introuvable',
                  style: const TextStyle(color: Colors.white38, fontSize: 12)))
              : ListView.builder(
                  itemCount: _conversations!.length,
                  itemBuilder: (ctx, i) => _buildConvTile(_conversations![i]),
                ),
      ),
    ]);
  }

  Widget _buildConvTile(AiConversationMeta meta) {
    final isSelected = _selected?.id == meta.id;
    final date = '${meta.date.day.toString().padLeft(2,'0')}/${meta.date.month.toString().padLeft(2,'0')}/${meta.date.year}';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isSelected ? Colors.deepPurple.shade900.withValues(alpha: 0.5) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: isSelected ? Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.4)) : null,
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.chat_bubble_outline,
              color: isSelected ? Colors.deepPurpleAccent : Colors.white38, size: 18),
            // Badge RAG vert (exporté)
            if (meta.isRagExported)
              Positioned(
                right: -4, top: -4,
                child: Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.green, shape: BoxShape.circle),
                ),
              ),
            // Badge 📄 orange (correspondance dans le contenu)
            if (meta.contentMatch && !meta.isRagExported)
              Positioned(
                right: -4, top: -4,
                child: Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.orange, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
        title: Text(meta.title,
          style: TextStyle(fontSize: 12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal),
          maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(
                '$date  •  ${meta.messageCount} msgs  •  ${meta.sizeKb > 1024 ? "${(meta.sizeKb/1024).toStringAsFixed(1)} MB" : "${meta.sizeKb} KB"}',
                style: const TextStyle(fontSize: 10, color: Colors.white38))),
              if (meta.isRagExported)
                Tooltip(
                  message: 'RAG exporté le ${meta.ragExportedAt!.toIso8601String().substring(0, 10)}',
                  child: const Icon(Icons.cloud_done, size: 11, color: Colors.green)),
              if (meta.contentMatch)
                const Tooltip(
                  message: 'Trouvé dans le contenu',
                  child: Icon(Icons.article_outlined, size: 11, color: Colors.orange)),
            ]),
            // Extrait de la correspondance de contenu
            if (meta.contentMatch && meta.matchSnippet != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  meta.matchSnippet!,
                  style: const TextStyle(
                    fontSize: 10, color: Colors.orange,
                    fontStyle: FontStyle.italic),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        onTap: () => _selectConversation(meta),
      ),
    );
  }

  Widget _buildViewerPanel() {
    if (_selected == null) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.forum_outlined, size: 48, color: Colors.white24),
        SizedBox(height: 12),
        Text('Sélectionne une conversation', style: TextStyle(color: Colors.white38)),
      ]));
    }

    return Column(children: [
      // Header
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        color: const Color(0xFF1A1A2E),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_selected!.title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            Row(children: [
              Text('${_selected!.messageCount} messages • ${_selected!.sizeKb > 1024 ? "${(_selected!.sizeKb/1024).toStringAsFixed(1)} MB" : "${_selected!.sizeKb} KB"}',
                style: const TextStyle(fontSize: 10, color: Colors.white38)),
              if (_selected!.isRagExported) ...[ 
                const SizedBox(width: 6),
                const Icon(Icons.cloud_done, size: 11, color: Colors.green),
                const SizedBox(width: 2),
                Text(
                  'RAG ${_selected!.ragExportedAt!.toIso8601String().substring(0, 10)}',
                  style: const TextStyle(fontSize: 10, color: Colors.green)),
              ],
            ]),
          ])),
          // Bouton copier ID
          IconButton(
            icon: const Icon(Icons.copy, size: 16, color: Colors.white38),
            tooltip: "Copier l'ID de la conversation",
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _selected!.id));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('ID copié'), duration: Duration(seconds: 1)));
            },
          ),
          // Menu export multi-format
          PopupMenuButton<String>(
            tooltip: 'Exporter la conversation',
            icon: const Icon(Icons.ios_share, size: 18),
            onSelected: (value) {
              switch (value) {
                case 'rag':  _exportRag();       break;
                case 'md':   _exportMarkdown();  break;
                case 'json': _exportJson();      break;
                case 'clip': _copyToClipboard(); break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rag',
                child: Row(children: [
                  Icon(Icons.upload_file, size: 16, color: Colors.deepPurpleAccent),
                  SizedBox(width: 10),
                  Text('→ RAG (TXT, dédup)', style: TextStyle(fontSize: 13)),
                ])),
              const PopupMenuItem(value: 'md',
                child: Row(children: [
                  Icon(Icons.article_outlined, size: 16, color: Colors.blueAccent),
                  SizedBox(width: 10),
                  Text('Markdown (.md)', style: TextStyle(fontSize: 13)),
                ])),
              const PopupMenuItem(value: 'json',
                child: Row(children: [
                  Icon(Icons.data_object, size: 16, color: Colors.amber),
                  SizedBox(width: 10),
                  Text('JSON structuré (.json)', style: TextStyle(fontSize: 13)),
                ])),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'clip',
                child: Row(children: [
                  Icon(Icons.content_paste, size: 16, color: Colors.teal),
                  SizedBox(width: 10),
                  Text('Copier (presse-papier)', style: TextStyle(fontSize: 13)),
                ])),
            ],
          ),
        ]),
      ),
      // Status export
      if (_exportStatus != null)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          color: Colors.deepPurple.shade900.withValues(alpha: 0.3),
          child: Text(_exportStatus!, style: const TextStyle(fontSize: 10, color: Colors.white70)),
        ),
      const Divider(height: 1),
      // ── Barre de navigation entre occurrences ────────────────────────────
      if (_query.isNotEmpty && _searchMatches.isNotEmpty)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          color: const Color(0xFF16162A),
          child: Row(children: [
            Text(
              '${_currentMatchIdx + 1} / ${_searchMatches.length} occurrence${_searchMatches.length > 1 ? "s" : ""}',
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
            const Spacer(),
            // ← précédent
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: const Icon(Icons.keyboard_arrow_up, size: 18),
              tooltip: 'Occurrence précédente',
              onPressed: _currentMatchIdx > 0
                  ? () => _navigateToMatch(_currentMatchIdx - 1)
                  : null,
            ),
            // → suivant
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: const Icon(Icons.keyboard_arrow_down, size: 18),
              tooltip: 'Occurrence suivante',
              onPressed: _currentMatchIdx < _searchMatches.length - 1
                  ? () => _navigateToMatch(_currentMatchIdx + 1)
                  : null,
            ),
          ]),
        ),
      if (_query.isNotEmpty && _searchMatches.isEmpty && !_loading)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          color: const Color(0xFF16162A),
          child: const Text('Aucune occurrence dans cette conversation',
              style: TextStyle(fontSize: 11, color: Colors.white38)),
        ),
      // Messages
      Expanded(
        child: _loading && _messages.isEmpty
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : ListView.builder(
                controller: _msgScroll,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (ctx, i) {
                  final bool isActiveMsg = _currentMatchIdx >= 0 &&
                      _currentMatchIdx < _searchMatches.length &&
                      _searchMatches[_currentMatchIdx].messageIndex == i;
                  return _buildMessageBubble(
                    _messages[i],
                    key: isActiveMsg ? _currentMatchKey : null,
                    query: _query,
                    activeMatchStart: isActiveMsg ? _searchMatches[_currentMatchIdx].charStart : null,
                    activeMatchEnd:   isActiveMsg ? _searchMatches[_currentMatchIdx].charEnd   : null,
                  );
                },
              ),
      ),
    ]);
  }

  Widget _buildMessageBubble(AiMessage msg, {
    Key? key,
    String query = '',
    int? activeMatchStart,
    int? activeMatchEnd,
  }) {
    final isUser = msg.isUser;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(radius: 14, backgroundColor: Colors.deepPurple.shade800,
              child: const Text('A', style: TextStyle(fontSize: 11, color: Colors.white))),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 640),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isUser
                    ? Colors.blue.shade900.withValues(alpha: 0.5)
                    : const Color(0xFF1E1E3A),
                borderRadius: BorderRadius.only(
                  topLeft:     Radius.circular(isUser ? 12 : 2),
                  topRight:    Radius.circular(isUser ? 2 : 12),
                  bottomLeft:  const Radius.circular(12),
                  bottomRight: const Radius.circular(12),
                ),
                border: Border.all(
                  color: (isUser ? Colors.blueAccent : Colors.deepPurpleAccent)
                      .withValues(alpha: 0.2)),
              ),
              child: query.isEmpty
                  ? SelectableText(
                      msg.content,
                      style: const TextStyle(fontSize: 12.5, height: 1.5),
                    )
                  : SelectableText.rich(
                      _buildHighlightedSpan(msg.content, query,
                          activeStart: activeMatchStart, activeEnd: activeMatchEnd),
                      style: const TextStyle(fontSize: 12.5, height: 1.5),
                    ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(radius: 14, backgroundColor: Colors.blue.shade800,
              child: const Text('U', style: TextStyle(fontSize: 11, color: Colors.white))),
          ],
        ],
      ),
    );
  }

  // ── Navigation entre occurrences ─────────────────────────────────────────────

  void _rebuildSearchMatches() {
    if (_query.isEmpty || _messages.isEmpty) {
      setState(() { _searchMatches = []; _currentMatchIdx = -1; });
      return;
    }
    final regex = _searchRegex(_query);
    final found = <_SearchMatch>[];
    for (int i = 0; i < _messages.length; i++) {
      for (final m in regex.allMatches(_messages[i].content)) {
        found.add(_SearchMatch(messageIndex: i, charStart: m.start, charEnd: m.end));
      }
    }
    setState(() {
      _searchMatches  = found;
      _currentMatchIdx = found.isEmpty ? -1 : 0;
    });
    if (found.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentMatch());
    }
  }

  void _navigateToMatch(int newIdx) {
    if (_searchMatches.isEmpty) return;
    setState(() => _currentMatchIdx = newIdx.clamp(0, _searchMatches.length - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentMatch());
  }

  void _scrollToCurrentMatch() {
    if (!_msgScroll.hasClients || _searchMatches.isEmpty || _currentMatchIdx < 0) return;

    // Étape 1 : si l'item est déjà visible → ensureVisible direct
    final ctx = _currentMatchKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut);
      return;
    }

    // Étape 2 : scroll proportionnel pour amener l'item dans la zone de build,
    //           puis on retente ensureVisible après la fin de l'animation.
    final msgIdx  = _searchMatches[_currentMatchIdx].messageIndex;
    final fraction = _messages.length <= 1 ? 0.0 : msgIdx / (_messages.length - 1);
    final target   = (_msgScroll.position.maxScrollExtent * fraction)
        .clamp(0.0, _msgScroll.position.maxScrollExtent);

    _msgScroll
        .animateTo(target,
            duration: const Duration(milliseconds: 250), curve: Curves.easeInOut)
        .then((_) {
      // Après l'animation, l'item est buildé → ensureVisible précis
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx2 = _currentMatchKey.currentContext;
        if (ctx2 != null) {
          Scrollable.ensureVisible(ctx2,
              alignment: 0.3,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut);
        }
      });
    });
  }

  // ── Regex helper partagé ──────────────────────────────────────────────────

  static RegExp _searchRegex(String query) {
    if (query.contains('*') || query.contains('?')) {
      final buf = StringBuffer();
      for (final c in query.split('')) {
        if (c == '*')      buf.write('.*');
        else if (c == '?') buf.write('.');
        else               buf.write(RegExp.escape(c));
      }
      return RegExp(buf.toString(), caseSensitive: false);
    }
    return RegExp(RegExp.escape(query), caseSensitive: false);
  }

  /// Construit un [TextSpan] avec les occurrences de [query] en surbrillance.
  /// Occurrence active : orange vif. Autres : ambre/jaune.
  static TextSpan _buildHighlightedSpan(String text, String query,
      {int? activeStart, int? activeEnd}) {
    if (query.isEmpty) return TextSpan(text: text);

    final regex   = _searchRegex(query);
    final matches = regex.allMatches(text).toList();
    if (matches.isEmpty) return TextSpan(text: text);

    const passiveStyle = TextStyle(
      backgroundColor: Color(0xFFFFD54F), // ambre
      color: Colors.black87,
      fontWeight: FontWeight.bold,
    );
    const activeStyle = TextStyle(
      backgroundColor: Color(0xFFFF6D00), // orange vif = occurrence courante
      color: Colors.white,
      fontWeight: FontWeight.bold,
    );

    final spans = <TextSpan>[];
    int cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) spans.add(TextSpan(text: text.substring(cursor, m.start)));
      final isActive = activeStart != null && m.start == activeStart && m.end == activeEnd;
      spans.add(TextSpan(
        text:  text.substring(m.start, m.end),
        style: isActive ? activeStyle : passiveStyle,
      ));
      cursor = m.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(children: spans);
  }
}

// ── Donnée d'une occurrence trouvée ──────────────────────────────────────────

class _SearchMatch {
  final int messageIndex;
  final int charStart;
  final int charEnd;
  const _SearchMatch({
    required this.messageIndex,
    required this.charStart,
    required this.charEnd,
  });
}
