import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/prompt_item.dart';
import '../services/prompt_library_service.dart';
import '../services/settings_service.dart';
import 'category_manager_dialog.dart';

/// Modal dialog for browsing, managing, and picking System and Conversation prompts.
class PromptLibraryDialog extends ConsumerStatefulWidget {
  final PromptType? initialType;
  final String? initialCategory;
  final String? initialSearchQuery;
  final void Function(PromptItem prompt)? onSelectPrompt;

  const PromptLibraryDialog({
    super.key,
    this.initialType,
    this.initialCategory,
    this.initialSearchQuery,
    this.onSelectPrompt,
  });

  static Future<PromptItem?> show(
    BuildContext context, {
    PromptType? initialType,
    String? initialCategory,
    String? initialSearchQuery,
    void Function(PromptItem prompt)? onSelectPrompt,
  }) {
    return showDialog<PromptItem>(
      context: context,
      builder: (ctx) => PromptLibraryDialog(
        initialType: initialType,
        initialCategory: initialCategory,
        initialSearchQuery: initialSearchQuery,
        onSelectPrompt: onSelectPrompt,
      ),
    );
  }

  @override
  ConsumerState<PromptLibraryDialog> createState() => _PromptLibraryDialogState();
}

class _PromptLibraryDialogState extends ConsumerState<PromptLibraryDialog> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _categoryScrollController = ScrollController();
  List<PromptItem> _prompts = [];
  bool _isLoading = true;
  PromptItem? _selectedPrompt;
  PromptType? _selectedType;
  String _selectedCategory = 'Tous';

  @override
  void initState() {
    super.initState();
    _selectedType = widget.initialType;
    if (widget.initialCategory != null && widget.initialCategory!.isNotEmpty) {
      _selectedCategory = widget.initialCategory!;
    }
    if (widget.initialSearchQuery != null && widget.initialSearchQuery!.isNotEmpty) {
      _searchController.text = widget.initialSearchQuery!;
    }
    _loadPrompts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _categoryScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPrompts() async {
    setState(() => _isLoading = true);
    final service = ref.read(promptLibraryServiceProvider);
    final results = await service.listPrompts(
      type: _selectedType,
      category: _selectedCategory,
      query: _searchController.text,
    );
    if (mounted) {
      setState(() {
        _prompts = results;
        _isLoading = false;
        if (_selectedPrompt != null) {
          _selectedPrompt = results.where((p) => p.id == _selectedPrompt!.id).firstOrNull;
        }
        if (_selectedPrompt == null && results.isNotEmpty) {
          _selectedPrompt = results.first;
        }
      });
    }
  }

  Set<String> _getDistinctCategories() {
    final settings = ref.read(settingsServiceProvider);
    final service = ref.read(promptLibraryServiceProvider);
    final set = <String>{'Tous', ...settings.promptCategories};
    for (final p in service.listPromptsSync()) {
      if (p.category.trim().isNotEmpty) {
        set.add(p.category.trim());
      }
    }
    return set;
  }

  Future<void> _openEditPromptDialog([PromptItem? existing]) async {
    final service = ref.read(promptLibraryServiceProvider);
    final promptCategories = service
        .listPromptsSync()
        .map((p) => p.category.trim())
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    if (!promptCategories.contains('Général')) {
      promptCategories.insert(0, 'Général');
    }

    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final contentCtrl = TextEditingController(text: existing?.content ?? '');
    final customCatCtrl = TextEditingController();
    PromptType type = existing?.type ?? (_selectedType ?? PromptType.conversation);
    String category = existing?.category ?? (promptCategories.contains(_selectedCategory) ? _selectedCategory : promptCategories.first);
    bool isCustomCategory = false;

    final saved = await showDialog<PromptItem>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  existing != null ? Icons.edit_note : Icons.add_circle_outline,
                  color: Colors.amberAccent,
                ),
                const SizedBox(width: 8),
                Text(existing != null ? 'Modifier le prompt' : 'Nouveau prompt'),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 550),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Type Selector
                    SegmentedButton<PromptType>(
                      segments: const [
                        ButtonSegment(
                          value: PromptType.conversation,
                          label: Text('💬 Discussion'),
                          icon: Icon(Icons.chat_bubble_outline, size: 16),
                        ),
                        ButtonSegment(
                          value: PromptType.system,
                          label: Text('🤖 Système'),
                          icon: Icon(Icons.terminal_rounded, size: 16),
                        ),
                      ],
                      selected: {type},
                      onSelectionChanged: (set) => setDlgState(() => type = set.first),
                    ),
                    const SizedBox(height: 12),

                    // Title
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Titre du prompt',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Category Selector
                    if (!isCustomCategory) ...[
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: promptCategories.contains(category) ? category : promptCategories.first,
                              decoration: const InputDecoration(
                                labelText: 'Catégorie de classement',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: promptCategories
                                  .map((cat) => DropdownMenuItem(value: cat, child: Text('📁 $cat')))
                                  .toList(),
                              onChanged: (val) {
                                if (val != null) setDlgState(() => category = val);
                              },
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            icon: const Icon(Icons.add_box_outlined, color: Colors.amberAccent),
                            tooltip: 'Créer une nouvelle catégorie de prompt',
                            onPressed: () {
                              setDlgState(() {
                                isCustomCategory = true;
                              });
                            },
                          ),
                        ],
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: customCatCtrl,
                              autofocus: true,
                              decoration: const InputDecoration(
                                labelText: 'Nouvelle catégorie',
                                hintText: 'ex: Stratégie, Juridique...',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (val) => category = val.trim(),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            icon: const Icon(Icons.list, color: Colors.blueAccent),
                            tooltip: 'Choisir parmi les catégories existantes',
                            onPressed: () {
                              setDlgState(() {
                                isCustomCategory = false;
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),

                    // Description
                    TextField(
                      controller: descCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Courte description / Rôle (optionnel)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Content Field
                    TextField(
                      controller: contentCtrl,
                      maxLines: 8,
                      decoration: InputDecoration(
                        labelText: 'Contenu du Prompt',
                        hintText: type == PromptType.system
                            ? 'Consignes du rôle IA...\nVariables supportées : {DOCUMENTS_LIST}, {RAG_EXTRACTS}'
                            : 'Formulation de la question ou requête type pour le chat...',
                        border: const OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
              FilledButton(
                onPressed: () {
                  if (titleCtrl.text.trim().isEmpty || contentCtrl.text.trim().isEmpty) return;
                  final item = PromptItem(
                    id: existing?.id ?? 'prompt_${DateTime.now().millisecondsSinceEpoch}',
                    title: titleCtrl.text.trim(),
                    description: descCtrl.text.trim(),
                    content: contentCtrl.text.trim(),
                    type: type,
                    category: category,
                    createdAt: existing?.createdAt ?? DateTime.now(),
                    updatedAt: DateTime.now(),
                    isBuiltIn: false,
                  );
                  Navigator.pop(ctx, item);
                },
                child: const Text('Enregistrer'),
              ),
            ],
          );
        },
      ),
    );

    if (saved != null) {
      final service = ref.read(promptLibraryServiceProvider);
      await service.savePrompt(saved);
      await _loadPrompts();
      setState(() => _selectedPrompt = saved);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Prompt "${saved.title}" enregistré !')),
        );
      }
    }
  }

  Future<void> _duplicatePrompt(PromptItem prompt) async {
    final service = ref.read(promptLibraryServiceProvider);
    final copy = await service.duplicatePrompt(prompt);
    await _loadPrompts();
    setState(() => _selectedPrompt = copy);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copie créée : "${copy.title}"')),
      );
    }
  }

  Future<void> _deletePrompt(PromptItem prompt) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce prompt ?'),
        content: Text('Voulez-vous vraiment supprimer "${prompt.title}" de votre bibliothèque ?'),
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
      final service = ref.read(promptLibraryServiceProvider);
      await service.deletePrompt(prompt.id);
      await _loadPrompts();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Prompt "${prompt.title}" supprimé.')),
        );
      }
    }
  }

  void _applySystemPrompt(PromptItem prompt) {
    final settings = ref.read(settingsServiceProvider);
    settings.activeSystemPromptId = prompt.id;
    settings.activeSystemPromptText = prompt.content;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚡ Prompt Système actif défini sur "${prompt.title}" !'),
        backgroundColor: Colors.teal.shade700,
      ),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Theme.of(context);
    final settings = ref.watch(settingsServiceProvider);
    final allCategories = _getDistinctCategories();
    final allSync = ref.read(promptLibraryServiceProvider).listPromptsSync();
    final isMobile = MediaQuery.of(context).size.width < 700;

    final systemCount = allSync.where((p) => p.type == PromptType.system).length;
    final convCount = allSync.where((p) => p.type == PromptType.conversation).length;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 680),
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
                      color: Colors.amber.shade900.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.bookmark_added_rounded, color: Colors.amberAccent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Bibliothèque de Prompts & Requêtes Types',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Gérez vos prompts système et vos modèles de requêtes de discussion classés par dossiers.',
                          style: TextStyle(fontSize: 11, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.amber.shade800,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Nouveau Prompt', style: TextStyle(fontSize: 11)),
                    onPressed: () => _openEditPromptDialog(),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Search & Type Filters
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Rechercher un prompt par mot-clé...',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () {
                                  _searchController.clear();
                                  _loadPrompts();
                                },
                              )
                            : null,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      onChanged: (_) => _loadPrompts(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Type Segments
                  SegmentedButton<PromptType?>(
                    segments: [
                      ButtonSegment(
                        value: null,
                        label: Text('Tous (${allSync.length})', style: const TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: PromptType.system,
                        label: Text('🤖 Système ($systemCount)', style: const TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: PromptType.conversation,
                        label: Text('💬 Discussion ($convCount)', style: const TextStyle(fontSize: 11)),
                      ),
                    ],
                    selected: {_selectedType},
                    onSelectionChanged: (set) {
                      setState(() => _selectedType = set.first);
                      _loadPrompts();
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
                                  ? allSync.length
                                  : allSync.where((p) => p.category.toLowerCase() == cat.toLowerCase()).length;

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
                                  selectedColor: Colors.amber.shade800,
                                  onSelected: (sel) {
                                    if (sel) {
                                      setState(() => _selectedCategory = cat);
                                      _loadPrompts();
                                    }
                                  },
                                ),
                              );
                            }),
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ActionChip(
                                avatar: const Icon(Icons.settings_outlined, size: 14, color: Colors.amberAccent),
                                label: const Text('Gérer les catégories', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
                                onPressed: () async {
                                  final changed = await CategoryManagerDialog.show(
                                    context,
                                    scope: CategoryManagerScope.prompts,
                                  );
                                  if (changed == true) {
                                    setState(() {});
                                    _loadPrompts();
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

              // Split View (List on left, Detail on right)
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.amberAccent))
                    : _prompts.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bookmarks_outlined, size: 48, color: Colors.grey.shade500),
                                const SizedBox(height: 8),
                                const Text('Aucun prompt ne correspond aux filtres sélectionnés.', style: TextStyle(color: Colors.grey)),
                              ],
                            ),
                          )
                        : isMobile
                            ? _buildMobileList()
                            : _buildSplitView(theme, settings),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileList() {
    return ListView.builder(
      itemCount: _prompts.length,
      itemBuilder: (ctx, i) => _buildPromptCard(_prompts[i], false),
    );
  }

  Widget _buildSplitView(ThemeData theme, SettingsService settings) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left Column: Prompt Cards
        SizedBox(
          width: 340,
          child: ListView.builder(
            itemCount: _prompts.length,
            itemBuilder: (ctx, i) {
              final p = _prompts[i];
              final isSelected = _selectedPrompt?.id == p.id;
              return _buildPromptCard(p, isSelected);
            },
          ),
        ),

        const VerticalDivider(width: 20),

        // Right Column: Detail & Actions
        Expanded(
          child: _selectedPrompt == null
              ? const Center(child: Text('Sélectionnez un prompt pour voir son contenu et l\'utiliser.'))
              : _buildPromptDetail(_selectedPrompt!, theme, settings),
        ),
      ],
    );
  }

  Widget _buildPromptCard(PromptItem prompt, bool isSelected) {
    final theme = Theme.of(context);
    final isSystem = prompt.type == PromptType.system;
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: isSelected ? 2 : 0,
      color: isSelected
          ? (isSystem ? Colors.amber.shade900.withValues(alpha: 0.3) : Colors.purple.shade900.withValues(alpha: 0.3))
          : (isDark ? Colors.grey.shade900.withValues(alpha: 0.4) : Colors.grey.shade200),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: isSelected
            ? BorderSide(color: isSystem ? Colors.amberAccent : Colors.purpleAccent, width: 1.5)
            : BorderSide.none,
      ),
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _selectedPrompt = prompt),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isSystem ? Colors.amber.shade900.withValues(alpha: 0.4) : Colors.purple.shade900.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      prompt.type.badgeLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isSystem ? Colors.amberAccent : Colors.purpleAccent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '📁 ${prompt.category}',
                      style: const TextStyle(fontSize: 10, color: Colors.blueGrey),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                prompt.title,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (prompt.description.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  prompt.description,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPromptDetail(PromptItem prompt, ThemeData theme, SettingsService settings) {
    final isSystem = prompt.type == PromptType.system;
    final isActiveSystem = isSystem && settings.activeSystemPromptId == prompt.id;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title & Status
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      prompt.title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    if (prompt.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(prompt.description, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ],
                ),
              ),
              if (isActiveSystem)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade900.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.tealAccent),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, size: 14, color: Colors.tealAccent),
                      SizedBox(width: 4),
                      Text('Prompt Système Actif', style: TextStyle(fontSize: 11, color: Colors.tealAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Main Action Buttons
          Row(
            children: [
              if (isSystem) ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: isActiveSystem ? Colors.grey.shade700 : Colors.teal.shade700,
                  ),
                  icon: Icon(isActiveSystem ? Icons.check : Icons.bolt, size: 16),
                  label: Text(isActiveSystem ? 'Actif dans les réglages' : 'Définir comme Prompt Système Actif'),
                  onPressed: () => _applySystemPrompt(prompt),
                ),
              ] else ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.purpleAccent),
                  icon: const Icon(Icons.chat_bubble, size: 16),
                  label: const Text('Insérer dans la Discussion'),
                  onPressed: () {
                    widget.onSelectPrompt?.call(prompt);
                    Navigator.pop(context, prompt);
                  },
                ),
              ],
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copier le texte',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: prompt.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Contenu du prompt copié !'), duration: Duration(seconds: 2)),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.control_point_duplicate, size: 18, color: Colors.blueAccent),
                tooltip: 'Dupliquer',
                onPressed: () => _duplicatePrompt(prompt),
              ),
              IconButton(
                icon: const Icon(Icons.edit, size: 18, color: Colors.amberAccent),
                tooltip: 'Modifier',
                onPressed: () => _openEditPromptDialog(prompt),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                tooltip: 'Supprimer',
                onPressed: () => _deletePrompt(prompt),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 10),

          // Content Box
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  prompt.content,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
