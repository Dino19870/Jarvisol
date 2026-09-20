import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import '../services/log_service.dart';
import '../services/settings_service.dart';

class LogsWidget extends ConsumerStatefulWidget {
  const LogsWidget({super.key});

  @override
  ConsumerState<LogsWidget> createState() => _LogsWidgetState();
}

class _LogsWidgetState extends ConsumerState<LogsWidget>
    with AutomaticKeepAliveClientMixin {
  StreamSubscription<LogEntry>? _sub;
  List<LogEntry> _entries = const [];
  final TextEditingController _filterController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  LogLevel _minLevel = LogLevel.trace;
  String _selectedCategory = 'all'; // 'all', 'errors', 'warn', 'ai', 'pdf', 'audio'
  bool _autoScroll = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _entries = Log.instance.snapshot();
    _sub = Log.instance.stream.listen((e) {
      if (!mounted) return;
      setState(() {
        _entries = [..._entries, e];
      });
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _filterController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String get _currentLogFilePath {
    final docsFile = Log.instance.documentsLogFile;
    if (docsFile != null) return docsFile.path;
    final sinkFile = Log.instance.sinkFile;
    if (sinkFile != null) return sinkFile.path;
    return 'Documents/CrisperWeaver/crisperweaver.log';
  }

  Future<void> _openLogFolder() async {
    final docsFile = Log.instance.documentsLogFile ?? Log.instance.sinkFile;
    if (docsFile != null) {
      if (Platform.isWindows) {
        try {
          await Process.run('explorer.exe', ['/select,', docsFile.path]);
          return;
        } catch (_) {}
      }
      try {
        final parentDir = docsFile.parent;
        await url_launcher.launchUrl(Uri.file(parentDir.path));
      } catch (_) {}
    }
  }

  List<LogEntry> get _filteredEntries {
    final query = _filterController.text.trim().toLowerCase();

    return _entries.where((e) {
      // 1. Min level filter
      if (e.level.rank < _minLevel.rank) return false;

      // 2. Category preset filter
      if (_selectedCategory == 'errors' && e.level != LogLevel.error) return false;
      if (_selectedCategory == 'warn' && e.level != LogLevel.warn && e.level != LogLevel.error) return false;
      if (_selectedCategory == 'ai') {
        final t = e.tag.toLowerCase();
        final m = e.message.toLowerCase();
        if (!t.contains('llm') && !t.contains('litert') && !t.contains('ai') && !m.contains('litert') && !m.contains('model')) {
          return false;
        }
      }
      if (_selectedCategory == 'pdf') {
        final t = e.tag.toLowerCase();
        final m = e.message.toLowerCase();
        if (!t.contains('pdf') && !t.contains('doc') && !m.contains('pdf') && !m.contains('document')) {
          return false;
        }
      }
      if (_selectedCategory == 'audio') {
        final t = e.tag.toLowerCase();
        final m = e.message.toLowerCase();
        if (!t.contains('audio') && !t.contains('transcri') && !t.contains('engine') && !m.contains('audio')) {
          return false;
        }
      }

      // 3. Search query filter
      if (query.isEmpty) return true;
      return e.message.toLowerCase().contains(query) ||
          e.tag.toLowerCase().contains(query) ||
          (e.error?.toString().toLowerCase().contains(query) ?? false);
    }).toList();
  }

  Color _getColorForLevel(LogLevel l, BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (l) {
      case LogLevel.trace:
        return Colors.blueGrey;
      case LogLevel.debug:
        return isDark ? Colors.blue.shade300 : Colors.blue.shade700;
      case LogLevel.info:
        return isDark ? Colors.tealAccent : Colors.teal.shade700;
      case LogLevel.warn:
        return isDark ? Colors.orangeAccent : Colors.orange.shade800;
      case LogLevel.error:
        return isDark ? Colors.redAccent : Colors.red.shade700;
    }
  }

  void _copyErrorsOnly() {
    final errors = _entries.where((e) => e.level == LogLevel.error).toList();
    if (errors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune erreur enregistrée dans les logs'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final text = errors.map((e) => e.format(includeStack: true)).join('\n\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('📋 ${errors.length} erreur(s) copiée(s) dans le presse-papier'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _copyAllVisible() {
    final list = _filteredEntries;
    if (list.isEmpty) return;
    final text = list.map((e) => e.format(includeStack: true)).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('📋 ${list.length} ligne(s) de logs copiée(s)'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _shareLogs() async {
    final docsFile = Log.instance.documentsLogFile;
    final sinkFile = Log.instance.sinkFile;

    // 1. Try sharing public Documents file on mobile
    if (Platform.isAndroid || Platform.isIOS) {
      if (docsFile != null && await docsFile.exists()) {
        try {
          await const MethodChannel('crisperweaver/share').invokeMethod('shareFile', {
            'filePath': docsFile.path,
            'title': 'Partager les logs CrisperWeaver',
          });
          return;
        } catch (_) {}
      } else if (sinkFile != null && await sinkFile.exists()) {
        try {
          await const MethodChannel('crisperweaver/share').invokeMethod('shareFile', {
            'filePath': sinkFile.path,
            'title': 'Partager les logs CrisperWeaver',
          });
          return;
        } catch (_) {}
      }
    }

    // 2. On Desktop or fallback: copy text and open folder
    final text = _entries.map((e) => e.format(includeStack: true)).join('\n');
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Le journal de log est vide')),
        );
      }
      return;
    }

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await const MethodChannel('crisperweaver/share').invokeMethod('shareText', {
          'text': text,
          'title': 'Partager les logs CrisperWeaver',
        });
      } catch (_) {
        Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('📋 Logs copiés dans le presse-papier')),
          );
        }
      }
    } else {
      Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('📋 Logs copiés dans le presse-papier')),
        );
      }
      _openLogFolder();
    }
  }

  void _clearLogs() {
    Log.instance.clear();
    setState(() {
      _entries = [];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('🗑️ Journal et fichier de logs effacés'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _confirmClearLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Effacer les logs ?'),
        content: Text(
          'Voulez-vous effacer tout le journal en mémoire et le fichier de log ($_currentLogFilePath) ?',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Effacer'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      _clearLogs();
    }
  }

  void _openFullscreenLogs() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: const Text('Journal & Diagnostics', style: TextStyle(fontSize: 16)),
            actions: [
              IconButton(
                icon: const Icon(Icons.share),
                tooltip: 'Partager la log',
                onPressed: _shareLogs,
              ),
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                tooltip: 'Effacer la log',
                onPressed: _confirmClearLogs,
              ),
            ],
          ),
          body: const LogsWidget(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final items = _filteredEntries;
    final errorCount = _entries.where((e) => e.level == LogLevel.error).length;
    final isLogActive = Log.instance.isEnabled;

    return Column(
      children: [
        // Top Path info & Status banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          color: isDark ? Colors.blueGrey.shade900 : Colors.blue.shade50,
          child: Row(
            children: [
              const Icon(Icons.description, size: 15, color: Colors.blueAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _currentLogFilePath,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.blue.shade200 : Colors.blue.shade900,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
                InkWell(
                  onTap: _openLogFolder,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      'Ouvrir dossier',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                        color: isDark ? Colors.blue.shade200 : Colors.blue.shade900,
                      ),
                    ),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.fullscreen, size: 20),
                tooltip: 'Agrandir en plein écran',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: _openFullscreenLogs,
              ),
            ],
          ),
        ),

        // Compact Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
            border: Border(bottom: BorderSide(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Row 1: Action Buttons + Switch
              Row(
                children: [
                  // Switch
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.black26 : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isLogActive ? Colors.green.shade400 : Colors.orange.shade400,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.scale(
                          scale: 0.75,
                          child: Switch(
                            value: isLogActive,
                            activeThumbColor: Colors.greenAccent,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            onChanged: (val) {
                              setState(() {
                                ref.read(settingsServiceProvider).loggingEnabled = val;
                              });
                            },
                          ),
                        ),
                        Text(
                          isLogActive ? 'Actifs' : 'Pause',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: isLogActive
                                ? (isDark ? Colors.greenAccent : Colors.green.shade800)
                                : Colors.orangeAccent,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),

                  // Partager
                  IconButton.filledTonal(
                    icon: const Icon(Icons.share, size: 16),
                    tooltip: 'Partager la log',
                    visualDensity: VisualDensity.compact,
                    onPressed: _shareLogs,
                  ),
                  const SizedBox(width: 4),

                  // Effacer
                  IconButton.outlined(
                    icon: const Icon(Icons.delete_sweep, size: 16, color: Colors.redAccent),
                    tooltip: 'Effacer la log',
                    visualDensity: VisualDensity.compact,
                    onPressed: _confirmClearLogs,
                  ),

                  if (errorCount > 0) ...[
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent.shade700,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.error_outline, size: 14),
                      label: Text(
                        '$errorCount',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _copyErrorsOnly,
                    ),
                  ],

                  const Spacer(),

                  // Menu options (Copy all, auto scroll, cycle level)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (val) {
                      if (val == 'copy_all') _copyAllVisible();
                      if (val == 'clear') _confirmClearLogs();
                      if (val == 'open_folder') _openLogFolder();
                      if (val == 'fullscreen') _openFullscreenLogs();
                      if (val == 'toggle_autoscroll') setState(() => _autoScroll = !_autoScroll);
                      if (val == 'cycle_level') {
                        setState(() {
                          final nextIndex = (_minLevel.index + 1) % LogLevel.values.length;
                          _minLevel = LogLevel.values[nextIndex];
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Niveau de log min : ${_minLevel.tag}'), duration: const Duration(seconds: 1)),
                        );
                      }
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'copy_all',
                        child: ListTile(
                          leading: Icon(Icons.copy, size: 18),
                          title: Text('Copier tous les logs affichés'),
                          dense: true,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'fullscreen',
                        child: ListTile(
                          leading: Icon(Icons.fullscreen, size: 18),
                          title: Text('Ouvrir en plein écran'),
                          dense: true,
                        ),
                      ),
                      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
                        const PopupMenuItem(
                          value: 'open_folder',
                          child: ListTile(
                            leading: Icon(Icons.folder_open, size: 18),
                            title: Text('Ouvrir l\'emplacement dans l\'Explorateur'),
                            dense: true,
                          ),
                        ),
                      PopupMenuItem(
                        value: 'cycle_level',
                        child: ListTile(
                          leading: const Icon(Icons.filter_list, size: 18),
                          title: Text('Niveau min : ${_minLevel.tag}'),
                          dense: true,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'toggle_autoscroll',
                        child: ListTile(
                          leading: Icon(_autoScroll ? Icons.pause : Icons.play_arrow, size: 18),
                          title: Text(_autoScroll ? 'Pause défilement auto' : 'Activer défilement auto'),
                          dense: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 4),

              // Row 2: Search input + Category Filter Chips
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _filterController,
                      decoration: InputDecoration(
                        hintText: 'Filtrer (texte, tag, erreur)...',
                        prefixIcon: const Icon(Icons.search, size: 16),
                        suffixIcon: _filterController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 14),
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  _filterController.clear();
                                  setState(() {});
                                },
                              )
                            : null,
                        border: const OutlineInputBorder(),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      ),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 4),

              // Category Preset Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildCategoryChip('Tous', 'all'),
                    const SizedBox(width: 4),
                    _buildCategoryChip('🔴 Erreurs ($errorCount)', 'errors', isError: errorCount > 0),
                    const SizedBox(width: 4),
                    _buildCategoryChip('🟠 Warnings', 'warn'),
                    const SizedBox(width: 4),
                    _buildCategoryChip('🤖 IA & LiteRT', 'ai'),
                    const SizedBox(width: 4),
                    _buildCategoryChip('📄 PDF & Docs', 'pdf'),
                    const SizedBox(width: 4),
                    _buildCategoryChip('🎙️ Audio & ASR', 'audio'),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Logs List (Optimized for mobile readability with stacked header + full-width text)
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.assignment_turned_in_outlined, size: 48, color: Colors.grey.shade500),
                      const SizedBox(height: 12),
                      Text(
                        'Aucun événement correspondant',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                )
              : Container(
                  color: isDark ? const Color(0xFF121212) : const Color(0xFFF7F8FA),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final e = items[index];
                      final color = _getColorForLevel(e.level, context);
                      final timeStr = '${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}:${e.timestamp.second.toString().padLeft(2, '0')}.${e.timestamp.millisecond.toString().padLeft(3, '0')}';
                      final isError = e.level == LogLevel.error;

                      return InkWell(
                        onTap: () {
                          // Copy single log line on tap
                          Clipboard.setData(ClipboardData(text: e.format(includeStack: true)));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Ligne de log copiée'), duration: Duration(milliseconds: 700)),
                          );
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                          decoration: BoxDecoration(
                            color: isError
                                ? (isDark ? Colors.red.shade900.withValues(alpha: 0.25) : Colors.red.shade50)
                                : (isDark ? (index.isEven ? Colors.white.withValues(alpha: 0.03) : Colors.transparent) : (index.isEven ? Colors.white : Colors.transparent)),
                            borderRadius: BorderRadius.circular(4),
                            border: isError ? Border.all(color: Colors.redAccent.withValues(alpha: 0.5), width: 1) : null,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Line 1: Header (Time • Level • Tag)
                              Row(
                                children: [
                                  Text(
                                    timeStr,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: color.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      e.level.tag,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: color,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '[${e.tag}]',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: isDark ? Colors.cyan.shade300 : Colors.blueGrey.shade800,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),

                              // Line 2: Full-width Readable Message Text
                              SelectableText(
                                '${e.message}${e.error != null ? '\nERREUR: ${e.error}' : ''}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  height: 1.35,
                                  fontWeight: isError ? FontWeight.bold : FontWeight.normal,
                                  color: isError
                                      ? (isDark ? Colors.redAccent.shade100 : Colors.red.shade900)
                                      : (isDark ? Colors.grey.shade200 : Colors.black87),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildCategoryChip(String label, String categoryId, {bool isError = false}) {
    final selected = _selectedCategory == categoryId;
    return ChoiceChip(
      selected: selected,
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          color: isError && !selected ? Colors.redAccent : null,
        ),
      ),
      onSelected: (val) {
        if (val) {
          setState(() {
            _selectedCategory = categoryId;
          });
        }
      },
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
