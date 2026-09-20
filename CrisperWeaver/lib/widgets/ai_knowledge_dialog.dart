import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../models/ai_knowledge_record.dart';
import '../services/ai_knowledge_service.dart';
import '../services/settings_service.dart';
import 'category_manager_dialog.dart';
import 'rag_library_dialog.dart';
import '../utils/ai_text_disclosure.dart';

class AiKnowledgeDialog extends ConsumerStatefulWidget {
  final void Function(AiKnowledgeRecord record)? onRestoreToChat;
  final String? initialSearchQuery;
  final String? initialCategory;

  const AiKnowledgeDialog({
    super.key,
    this.onRestoreToChat,
    this.initialSearchQuery,
    this.initialCategory,
  });

  @override
  ConsumerState<AiKnowledgeDialog> createState() => _AiKnowledgeDialogState();
}

class _AiKnowledgeDialogState extends ConsumerState<AiKnowledgeDialog> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _categoryScrollController = ScrollController();
  List<AiKnowledgeRecord> _records = [];
  bool _isLoading = true;
  AiKnowledgeRecord? _selectedRecord;
  String _selectedCategory = 'Tous';

  @override
  void initState() {
    super.initState();
    if (widget.initialSearchQuery != null && widget.initialSearchQuery!.isNotEmpty) {
      _searchController.text = widget.initialSearchQuery!;
    }
    if (widget.initialCategory != null && widget.initialCategory!.isNotEmpty) {
      _selectedCategory = widget.initialCategory!;
    }
    _loadRecords(_searchController.text);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _categoryScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadRecords([String query = '']) async {
    setState(() => _isLoading = true);
    final service = ref.read(aiKnowledgeServiceProvider);
    final results = await service.searchRecords(
      query,
      categoryFilter: _selectedCategory,
    );
    if (mounted) {
      setState(() {
        _records = results;
        _isLoading = false;
        if (_selectedRecord != null) {
          final found = results.where((r) => r.id == _selectedRecord!.id).firstOrNull;
          _selectedRecord = found;
        }
      });
    }
  }

  Set<String> _getDistinctCategories() {
    final settings = ref.read(settingsServiceProvider);
    final set = <String>{'Tous', ...settings.knowledgeCategories};
    final service = ref.read(aiKnowledgeServiceProvider);
    for (final r in service.listRecordsSync()) {
      if (r.category.isNotEmpty) set.add(r.category);
    }
    return set;
  }

  Future<void> _changeCategory(AiKnowledgeRecord record) async {
    final settings = ref.read(settingsServiceProvider);
    final categories = settings.knowledgeCategories;
    final customCtrl = TextEditingController();
    String current = record.category;

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.folder_outlined, color: Colors.blueAccent),
              SizedBox(width: 8),
              Text('Changer de catégorie'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sélectionnez ou créez une catégorie :', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: categories.map((cat) {
                  final isSel = current == cat;
                  return ChoiceChip(
                    label: Text(cat, style: const TextStyle(fontSize: 11)),
                    selected: isSel,
                    onSelected: (sel) {
                      if (sel) {
                        setDlgState(() => current = cat);
                      }
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: customCtrl,
                decoration: const InputDecoration(
                  labelText: 'Ou saisir une nouvelle catégorie',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (val) {
                  if (val.trim().isNotEmpty) {
                    setDlgState(() => current = val.trim());
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, current),
              child: const Text('Appliquer'),
            ),
          ],
        ),
      ),
    );

    if (selected != null && selected.isNotEmpty) {
      if (!settings.knowledgeCategories.contains(selected)) {
        settings.addKnowledgeCategory(selected);
      }
      final service = ref.read(aiKnowledgeServiceProvider);
      await service.updateRecordCategory(record.id, selected);
      await _loadRecords(_searchController.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Catégorie mise à jour : $selected')),
        );
      }
    }
  }

  Future<void> _openCrossRagSearch(String query) async {
    Navigator.pop(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => RagLibraryDialog(
        initialSearchQuery: query,
      ),
    );
  }

  Future<void> _deleteRecord(AiKnowledgeRecord record) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cet enregistrement ?'),
        content: Text('Voulez-vous vraiment supprimer "${record.title}" de la base IA ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final service = ref.read(aiKnowledgeServiceProvider);
      await service.deleteRecord(record.id);
      _loadRecords(_searchController.text);
      if (_selectedRecord?.id == record.id) {
        setState(() => _selectedRecord = null);
      }
    }
  }

  void _copyRecordContent(AiKnowledgeRecord record) {
    final sb = StringBuffer();
    sb.writeln('=== FICHE IA : ${record.title} ===');
    sb.writeln('Catégorie : ${record.category}');
    sb.writeln('Date : ${DateFormat('dd/MM/yyyy HH:mm').format(record.createdAt)}');
    sb.writeln('Modèle : ${record.llmProvider} (${record.llmModel})\n');

    sb.writeln('--- TRANSCRIPTION AUDIO ---');
    sb.writeln(record.rawTranscript);
    sb.writeln();

    if (record.aiSummary != null && record.aiSummary!.isNotEmpty) {
      sb.writeln('--- RÉSUMÉ IA ---');
      sb.writeln(record.aiSummary);
      sb.writeln();
    }

    if (record.chatMessages.isNotEmpty) {
      sb.writeln('--- HISTORIQUE DU CHAT ---');
      for (final m in record.chatMessages) {
        final sender = m.role == 'user' ? 'Utilisateur' : 'Assistant IA';
        sb.writeln('[$sender] : ${m.content}');
      }
    }

    Clipboard.setData(
        ClipboardData(text: AiTextDisclosure.forSummary(sb.toString().trim())));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Fiche complète copiée dans le presse-papier !'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = MediaQuery.of(context).size.width < 700;
    final allCategories = _getDistinctCategories();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 950,
        height: 680,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.storage_rounded, color: Colors.blueAccent, size: 24),
                const SizedBox(width: 10),
                const Text(
                  'Base de Connaissances & Recherches IA',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Search Bar & Cross Search Button
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Rechercher un mot, un sujet, un extrait audio ou une analyse...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                _loadRecords();
                              },
                            )
                          : null,
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onChanged: (val) => _loadRecords(val),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Déclencher la même recherche dans la bibliothèque RAG',
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    ),
                    icon: const Icon(Icons.travel_explore, size: 16, color: Colors.purpleAccent),
                    label: const Text('Rechercher dans Cache RAG', style: TextStyle(fontSize: 11)),
                    onPressed: () => _openCrossRagSearch(_searchController.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Categories Filter Bar with Scroll Support & Counts
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 28),
                  tooltip: 'Faire défiler vers la gauche',
                  onPressed: () {
                    if (_categoryScrollController.hasClients) {
                      _categoryScrollController.animateTo(
                        (_categoryScrollController.offset - 150).clamp(0.0, _categoryScrollController.position.maxScrollExtent),
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                      );
                    }
                  },
                ),
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        dragDevices: {
                          PointerDeviceKind.touch,
                          PointerDeviceKind.mouse,
                          PointerDeviceKind.trackpad,
                        },
                      ),
                      child: ListView(
                        controller: _categoryScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        children: [
                          ...allCategories.map((cat) {
                            final isSelected = _selectedCategory == cat;
                            final allSync = ref.read(aiKnowledgeServiceProvider).listRecordsSync();
                            final count = cat == 'Tous'
                                ? allSync.length
                                : allSync.where((r) => r.category.toLowerCase() == cat.toLowerCase()).length;

                            return Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(
                                  cat == 'Tous' ? '🌐 Tous ($count)' : '📁 $cat ($count)',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    color: isSelected ? Colors.white : null,
                                  ),
                                ),
                                selected: isSelected,
                                selectedColor: Colors.blueAccent,
                                onSelected: (sel) {
                                  if (sel) {
                                    setState(() => _selectedCategory = cat);
                                    _loadRecords(_searchController.text);
                                  }
                                },
                              ),
                            );
                          }),
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ActionChip(
                              avatar: const Icon(Icons.settings_outlined, size: 14, color: Colors.blueAccent),
                              label: const Text('Gérer les catégories', style: TextStyle(fontSize: 11, color: Colors.blueAccent)),
                              onPressed: () async {
                                final changed = await CategoryManagerDialog.show(context);
                                if (changed == true) {
                                  setState(() {});
                                  _loadRecords(_searchController.text);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 28),
                  tooltip: 'Faire défiler vers la droite',
                  onPressed: () {
                    if (_categoryScrollController.hasClients) {
                      _categoryScrollController.animateTo(
                        (_categoryScrollController.offset + 150).clamp(0.0, _categoryScrollController.position.maxScrollExtent),
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                      );
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Body: Split view (List on left, Detail on right)
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _records.isEmpty
                      ? _buildEmptyState()
                      : isMobile
                          ? _buildMobileView()
                          : _buildSplitView(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, size: 48, color: Colors.grey.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            _searchController.text.isNotEmpty
                ? 'Aucun enregistrement ne correspond à votre recherche.'
                : 'Aucune analyse IA enregistrée pour le moment.',
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileView() {
    if (_selectedRecord != null) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Retour à la liste'),
              onPressed: () => setState(() => _selectedRecord = null),
            ),
          ),
          Expanded(child: _buildDetailPanel(_selectedRecord!, Theme.of(context))),
        ],
      );
    }
    return ListView.builder(
      itemCount: _records.length,
      itemBuilder: (ctx, i) => _buildRecordCard(_records[i], false),
    );
  }

  Widget _buildSplitView(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left column: Record list
        SizedBox(
          width: 320,
          child: ListView.builder(
            itemCount: _records.length,
            itemBuilder: (ctx, i) {
              final r = _records[i];
              final isSelected = _selectedRecord?.id == r.id;
              return _buildRecordCard(r, isSelected);
            },
          ),
        ),

        const VerticalDivider(width: 20),

        // Right column: Detail preview
        Expanded(
          child: _selectedRecord == null
              ? Center(
                  child: Text(
                    'Sélectionnez un enregistrement pour lire l\'analyse complète',
                    style: TextStyle(color: theme.hintColor),
                  ),
                )
              : _buildDetailPanel(_selectedRecord!, theme),
        ),
      ],
    );
  }

  Widget _buildRecordCard(AiKnowledgeRecord record, bool isSelected) {
    final theme = Theme.of(context);
    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(record.createdAt);

    return Card(
      elevation: isSelected ? 2 : 0,
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: isSelected
            ? BorderSide(color: theme.colorScheme.primary)
            : BorderSide.none,
      ),
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _selectedRecord = record),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      record.title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    dateStr,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                record.rawTranscript,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      record.llmProvider,
                      style: const TextStyle(fontSize: 9, color: Colors.blueAccent, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.teal.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.teal.shade300, width: 0.5),
                    ),
                    child: Text(
                      '📁 ${record.category}',
                      style: const TextStyle(fontSize: 9, color: Colors.tealAccent, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (record.chatMessages.isNotEmpty)
                    Text(
                      '${record.chatMessages.length} msg',
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailPanel(AiKnowledgeRecord record, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Action Bar for selected record
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        'Enregistré le ${DateFormat('dd MMMM yyyy à HH:mm', 'fr_FR').format(record.createdAt)} • ${record.llmProvider}',
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _changeCategory(record),
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.teal.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.tealAccent, width: 0.6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '📁 ${record.category}',
                                style: const TextStyle(fontSize: 10, color: Colors.tealAccent, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 3),
                              const Icon(Icons.edit, size: 10, color: Colors.tealAccent),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy_rounded, size: 18),
              tooltip: 'Copier toute la fiche',
              onPressed: () => _copyRecordContent(record),
            ),
            if (widget.onRestoreToChat != null)
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                tooltip: 'Recharger dans l\'Assistant IA',
                onPressed: () {
                  widget.onRestoreToChat!(record);
                  Navigator.pop(context);
                },
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
              tooltip: 'Supprimer',
              onPressed: () => _deleteRecord(record),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Cross Database Search Banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.purple.shade900.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.4), width: 0.8),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_stories, size: 16, color: Colors.purpleAccent),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Recherche Croisée : Explorer les fichiers RAG associés à cette analyse',
                  style: TextStyle(fontSize: 11, color: Colors.purpleAccent),
                ),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: () {
                  // Extract keywords from title (e.g., first source name or cleaned subject)
                  final query = record.title.replaceAll(RegExp(r'^(Analyse Multi-Sources :|=== DOCUMENT \d+ :|Note IA Multi-Sources \(\d+/\d+\))'), '').trim();
                  _openCrossRagSearch(query.isNotEmpty ? query : record.title);
                },
                child: const Text('Voir Cache RAG 🔍', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        const Divider(),

        // Scrollable content
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Raw transcript section
                _buildSectionHeader('🎙️ Transcription Audio'),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    record.rawTranscript,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 16),

                // Chat / AI responses section
                if (record.chatMessages.isNotEmpty) ...[
                  _buildSectionHeader('🤖 Échanges & Analyses IA'),
                  ...record.chatMessages.map((m) {
                    final isUser = m.role == 'user';
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isUser
                            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
                            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isUser ? '👤 Question :' : '🤖 Réponse IA :',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isUser ? theme.colorScheme.primary : Colors.blueAccent,
                            ),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(m.content, style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
      ),
    );
  }
}
