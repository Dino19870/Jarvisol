import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../services/document_rag_service.dart';
import '../services/settings_service.dart';
import 'ai_knowledge_dialog.dart';
import 'category_manager_dialog.dart';

/// Modal dialog for browsing, multi-selecting, and managing pre-indexed RAG cached documents.
class RagLibraryDialog extends ConsumerStatefulWidget {
  final String? initialSearchQuery;
  final String? initialCategory;

  const RagLibraryDialog({
    super.key,
    this.initialSearchQuery,
    this.initialCategory,
  });

  static Future<List<CachedDocumentEntry>?> show(
    BuildContext context, {
    String? initialSearchQuery,
    String? initialCategory,
  }) {
    return showDialog<List<CachedDocumentEntry>>(
      context: context,
      builder: (ctx) => RagLibraryDialog(
        initialSearchQuery: initialSearchQuery,
        initialCategory: initialCategory,
      ),
    );
  }

  @override
  ConsumerState<RagLibraryDialog> createState() => _RagLibraryDialogState();
}

class _RagLibraryDialogState extends ConsumerState<RagLibraryDialog> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _categoryScrollController = ScrollController();
  final Set<String> _selectedFiles = {};
  List<CachedDocumentEntry> _allEntries = [];
  bool _isLoading = true;
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
    _loadCacheEntries();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _categoryScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadCacheEntries() async {
    setState(() => _isLoading = true);
    final ragService = ref.read(documentRagServiceProvider);
    final settings = ref.read(settingsServiceProvider);
    final list = await ragService.listCachedDocuments(settings);
    if (mounted) {
      setState(() {
        _allEntries = list;
        _isLoading = false;
      });
    }
  }

  Set<String> _getDistinctCategories() {
    final settings = ref.read(settingsServiceProvider);
    final set = <String>{'Tous', ...settings.knowledgeCategories};
    for (final e in _allEntries) {
      if (e.category.isNotEmpty) set.add(e.category);
    }
    return set;
  }

  Future<void> _changeCategory(CachedDocumentEntry entry) async {
    final settings = ref.read(settingsServiceProvider);
    final categories = settings.knowledgeCategories;
    final customCtrl = TextEditingController();
    String current = entry.category;

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.folder_outlined, color: Colors.purpleAccent),
              SizedBox(width: 8),
              Text('Changer la catégorie RAG'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sélectionnez ou créez une catégorie pour ce document :', style: TextStyle(fontSize: 12)),
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
              style: FilledButton.styleFrom(backgroundColor: Colors.purpleAccent),
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
      final ragService = ref.read(documentRagServiceProvider);
      await ragService.updateCachedDocumentCategory(entry.fileName, selected, settings);
      await _loadCacheEntries();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Catégorie mise à jour : $selected')),
        );
      }
    }
  }

  Future<void> _batchMoveSelected() async {
    if (_selectedFiles.isEmpty) return;
    final settings = ref.read(settingsServiceProvider);
    final categories = settings.knowledgeCategories;
    String current = categories.first;

    final targetCategory = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.drive_file_move_outlined, color: Colors.purpleAccent, size: 20),
              const SizedBox(width: 8),
              Text('Déplacer ${_selectedFiles.length} document(s)'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Choisir la catégorie de destination :', style: TextStyle(fontSize: 12)),
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
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.purpleAccent),
              onPressed: () => Navigator.pop(ctx, current),
              child: const Text('Déplacer'),
            ),
          ],
        ),
      ),
    );

    if (targetCategory != null && targetCategory.isNotEmpty) {
      final ragService = ref.read(documentRagServiceProvider);
      final count = await ragService.batchUpdateCategory(_selectedFiles.toList(), targetCategory, settings);
      await _loadCacheEntries();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$count document(s) déplacé(s) vers "$targetCategory" !'),
            backgroundColor: Colors.purple.shade700,
          ),
        );
      }
    }
  }

  Future<void> _openCrossAiKnowledgeSearch(String query) async {
    Navigator.pop(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AiKnowledgeDialog(
        initialSearchQuery: query,
      ),
    );
  }

  Future<void> _deleteEntry(CachedDocumentEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.orangeAccent),
            SizedBox(width: 8),
            Text('Supprimer du cache ?'),
          ],
        ),
        content: Text(
          'Voulez-vous supprimer les vecteurs indexés de "${entry.sourceName}" ?\n\nLe document devra être vectorisé à nouveau lors d\'une prochaine ouverture.',
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final ragService = ref.read(documentRagServiceProvider);
      final settings = ref.read(settingsServiceProvider);
      await ragService.deleteCachedFile(entry.fileName, settings);
      _selectedFiles.remove(entry.fileName);
      await _loadCacheEntries();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final query = _searchController.text.trim().toLowerCase();
    final allCategories = _getDistinctCategories();

    final filtered = _allEntries.where((e) {
      if (_selectedCategory != 'Tous') {
        if (e.category.toLowerCase() != _selectedCategory.toLowerCase()) {
          return false;
        }
      }
      if (query.isEmpty) return true;
      return e.sourceName.toLowerCase().contains(query) ||
          e.model.toLowerCase().contains(query) ||
          e.category.toLowerCase().contains(query);
    }).toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 660),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade900.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.auto_stories, color: Colors.purpleAccent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Bibliothèque des Documents Indexés (Cache RAG)',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Cochez un ou plusieurs documents pour lancer une analyse simple ou croisée instantanée.',
                          style: TextStyle(fontSize: 11, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Search & Cross Search Actions
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Rechercher un document indexé...',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                              )
                            : null,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Déclencher la même recherche dans la base des synthèses & discussions IA',
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      ),
                      icon: const Icon(Icons.storage, size: 16, color: Colors.blueAccent),
                      label: const Text('Rechercher dans Base IA', style: TextStyle(fontSize: 11)),
                      onPressed: () => _openCrossAiKnowledgeSearch(_searchController.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (filtered.isNotEmpty)
                    TextButton.icon(
                      icon: Icon(
                        _selectedFiles.length == filtered.length ? Icons.deselect : Icons.select_all,
                        size: 16,
                      ),
                      label: Text(
                        _selectedFiles.length == filtered.length ? 'Tout décocher' : 'Tout cocher',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onPressed: () {
                        setState(() {
                          if (_selectedFiles.length == filtered.length) {
                            _selectedFiles.clear();
                          } else {
                            _selectedFiles.addAll(filtered.map((e) => e.fileName));
                          }
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),

              // Category Filter Bar with Scroll Support & Counts
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
                              final count = cat == 'Tous'
                                  ? _allEntries.length
                                  : _allEntries.where((e) => e.category.toLowerCase() == cat.toLowerCase()).length;

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
                                  selectedColor: Colors.purpleAccent,
                                  onSelected: (sel) {
                                    if (sel) {
                                      setState(() => _selectedCategory = cat);
                                    }
                                  },
                                ),
                              );
                            }),
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ActionChip(
                                avatar: const Icon(Icons.settings_outlined, size: 14, color: Colors.purpleAccent),
                                label: const Text('Gérer les catégories', style: TextStyle(fontSize: 11, color: Colors.purpleAccent)),
                                onPressed: () async {
                                  final changed = await CategoryManagerDialog.show(context);
                                  if (changed == true) {
                                    setState(() {});
                                    await _loadCacheEntries();
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

              // Document List
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.purpleAccent))
                    : filtered.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.inventory_2_outlined, size: 48, color: Colors.grey.shade500),
                                const SizedBox(height: 8),
                                Text(
                                  _allEntries.isEmpty
                                      ? 'Aucun document n\'est encore mémorisé en cache.\nImportez des fichiers via "Importer" pour les vectoriser.'
                                      : 'Aucun document ne correspond à votre recherche.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (ctx, i) => const Divider(height: 1),
                            itemBuilder: (ctx, index) {
                              final entry = filtered[index];
                              final isSelected = _selectedFiles.contains(entry.fileName);
                              final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(entry.createdAt);
                              final sizeKb = (entry.fileSizeBytes / 1024).toStringAsFixed(0);

                              return ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                leading: Checkbox(
                                  value: isSelected,
                                  activeColor: Colors.purpleAccent,
                                  onChanged: (val) {
                                    setState(() {
                                      if (val == true) {
                                        _selectedFiles.add(entry.fileName);
                                      } else {
                                        _selectedFiles.remove(entry.fileName);
                                      }
                                    });
                                  },
                                ),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        entry.sourceName,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    InkWell(
                                      onTap: () => _changeCategory(entry),
                                      borderRadius: BorderRadius.circular(4),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.purple.shade900.withValues(alpha: 0.25),
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5), width: 0.6),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              '📁 ${entry.category}',
                                              style: const TextStyle(fontSize: 9, color: Colors.purpleAccent, fontWeight: FontWeight.bold),
                                            ),
                                            const SizedBox(width: 3),
                                            const Icon(Icons.edit, size: 9, color: Colors.purpleAccent),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.purple.shade900.withValues(alpha: 0.3),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          '⚡ ${entry.chunkCount} fragments',
                                          style: const TextStyle(fontSize: 10, color: Colors.purpleAccent, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Modèle: ${entry.model.isNotEmpty ? entry.model : "Standard"}',
                                        style: TextStyle(fontSize: 10, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '• $sizeKb Ko • $dateStr',
                                        style: TextStyle(fontSize: 10, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                                      ),
                                    ],
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.psychology_outlined, size: 18, color: Colors.blueAccent),
                                      tooltip: 'Voir synthèses IA associées à ce document',
                                      onPressed: () => _openCrossAiKnowledgeSearch(entry.sourceName),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
                                      tooltip: 'Supprimer ce cache',
                                      onPressed: () => _deleteEntry(entry),
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  setState(() {
                                    if (isSelected) {
                                      _selectedFiles.remove(entry.fileName);
                                    } else {
                                      _selectedFiles.add(entry.fileName);
                                    }
                                  });
                                },
                              );
                            },
                          ),
              ),
              const SizedBox(height: 14),

              // Bottom Actions
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  Text(
                    '${_selectedFiles.length} document(s) sélectionné(s)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _selectedFiles.isNotEmpty ? Colors.purpleAccent : Colors.grey,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_selectedFiles.isNotEmpty) ...[
                        OutlinedButton.icon(
                          icon: const Icon(Icons.drive_file_move_outlined, size: 14, color: Colors.purpleAccent),
                          label: Text('Déplacer (${_selectedFiles.length})', style: const TextStyle(fontSize: 11)),
                          onPressed: _batchMoveSelected,
                        ),
                        const SizedBox(width: 8),
                      ],
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Fermer'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.purpleAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        ),
                        icon: const Icon(Icons.bolt, size: 16),
                        label: Text(
                          _selectedFiles.length > 1
                              ? 'Charger les ${_selectedFiles.length} documents (Croisé)'
                              : 'Charger dans la discussion',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        onPressed: _selectedFiles.isEmpty
                            ? null
                            : () {
                                final selected = _allEntries
                                    .where((e) => _selectedFiles.contains(e.fileName))
                                    .toList();
                                Navigator.pop(context, selected);
                              },
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
