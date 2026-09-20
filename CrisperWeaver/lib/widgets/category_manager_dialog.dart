import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ai_knowledge_service.dart';
import '../services/document_rag_service.dart';
import '../services/prompt_library_service.dart';
import '../services/settings_service.dart';

/// Scope of categories being managed
enum CategoryManagerScope {
  documents,
  prompts;

  String get title => switch (this) {
        CategoryManagerScope.documents => 'Gestionnaire des Catégories Documentaires',
        CategoryManagerScope.prompts => 'Gestionnaire des Catégories de Prompts',
      };

  String get subtitle => switch (this) {
        CategoryManagerScope.documents => 'Créez, renommez ou supprimez vos dossiers pour les documents RAG et synthèses IA.',
        CategoryManagerScope.prompts => 'Créez, renommez ou supprimez vos dossiers dédiés aux prompts système et discussion.',
      };
}

/// Modal dialog allowing the user to view, create, rename (with cascade), and delete categories.
class CategoryManagerDialog extends ConsumerStatefulWidget {
  final CategoryManagerScope scope;

  const CategoryManagerDialog({
    super.key,
    this.scope = CategoryManagerScope.documents,
  });

  static Future<bool?> show(
    BuildContext context, {
    CategoryManagerScope scope = CategoryManagerScope.documents,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => CategoryManagerDialog(scope: scope),
    );
  }

  @override
  ConsumerState<CategoryManagerDialog> createState() => _CategoryManagerDialogState();
}

class _CategoryManagerDialogState extends ConsumerState<CategoryManagerDialog> {
  final TextEditingController _newCategoryController = TextEditingController();
  bool _isProcessing = false;

  bool get _isPrompts => widget.scope == CategoryManagerScope.prompts;

  @override
  void dispose() {
    _newCategoryController.dispose();
    super.dispose();
  }

  Future<void> _addNewCategory() async {
    final name = _newCategoryController.text.trim();
    if (name.isEmpty) return;

    final settings = ref.read(settingsServiceProvider);
    if (_isPrompts) {
      settings.addPromptCategory(name);
    } else {
      settings.addKnowledgeCategory(name);
    }
    _newCategoryController.clear();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Catégorie "$name" créée avec succès !')),
    );
  }

  Future<void> _renameCategory(String oldName) async {
    final editController = TextEditingController(text: oldName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.edit_outlined, color: Colors.blueAccent, size: 20),
            const SizedBox(width: 8),
            Text('Renommer "$oldName"'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isPrompts
                  ? 'Tous les prompts de cette catégorie seront automatiquement mis à jour.'
                  : 'Tous les enregistrements IA et documents RAG associés à cette catégorie seront automatiquement mis à jour.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: editController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Nouveau nom de la catégorie',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, editController.text.trim()),
            child: const Text('Renommer en cascade'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != oldName) {
      setState(() => _isProcessing = true);
      final settings = ref.read(settingsServiceProvider);

      if (_isPrompts) {
        // Renommer uniquement pour les prompts
        settings.renamePromptCategory(oldName, newName);
        final promptService = ref.read(promptLibraryServiceProvider);
        final updatedPrompts = await promptService.renameCategoryInPrompts(oldName, newName);

        if (mounted) {
          setState(() => _isProcessing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Catégorie de prompt renommée en "$newName" ($updatedPrompts prompts mis à jour).'),
              backgroundColor: Colors.teal.shade700,
            ),
          );
        }
      } else {
        // Renommer pour les documents et synthèses RAG
        settings.renameKnowledgeCategory(oldName, newName);
        final aiService = ref.read(aiKnowledgeServiceProvider);
        final ragService = ref.read(documentRagServiceProvider);
        final updatedAi = await aiService.renameCategoryInRecords(oldName, newName);
        final updatedRag = await ragService.renameCategoryInCachedDocuments(oldName, newName, settings);

        if (mounted) {
          setState(() => _isProcessing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Catégorie renommée en "$newName" ($updatedAi synthèses et $updatedRag documents RAG mis à jour).'),
              backgroundColor: Colors.teal.shade700,
            ),
          );
        }
      }
    }
  }

  Future<void> _deleteCategory(String categoryName) async {
    if (categoryName == 'Général') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La catégorie par défaut "Général" ne peut pas être supprimée.')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.delete_forever, color: Colors.redAccent, size: 20),
            const SizedBox(width: 8),
            Text('Supprimer "$categoryName" ?'),
          ],
        ),
        content: Text(
          _isPrompts
              ? 'Voulez-vous vraiment supprimer la catégorie de prompt "$categoryName" ?\n\nTous les prompts qui y étaient classés seront reclassés dans "Général" sans aucune perte.'
              : 'Voulez-vous vraiment supprimer la catégorie "$categoryName" ?\n\nTous les enregistrements et documents indexés qui y étaient rangés seront automatiquement reclassés dans la catégorie "Général" sans aucune perte de données.',
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer et Reclasser'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isProcessing = true);
      final settings = ref.read(settingsServiceProvider);

      if (_isPrompts) {
        // Supprimer pour les prompts uniquement
        settings.deletePromptCategory(categoryName);
        final promptService = ref.read(promptLibraryServiceProvider);
        final reclassifiedPrompts = await promptService.reassignCategoryInPrompts(categoryName, 'Général');

        if (mounted) {
          setState(() => _isProcessing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Catégorie de prompt supprimée. $reclassifiedPrompts prompts reclassés dans "Général".'),
            ),
          );
        }
      } else {
        // Supprimer pour les documents et synthèses RAG
        settings.deleteKnowledgeCategory(categoryName);
        final aiService = ref.read(aiKnowledgeServiceProvider);
        final ragService = ref.read(documentRagServiceProvider);
        final reclassifiedAi = await aiService.reassignCategoryInRecords(categoryName, 'Général');
        final reclassifiedRag = await ragService.reassignCategoryInCachedDocuments(categoryName, 'Général', settings);

        if (mounted) {
          setState(() => _isProcessing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Catégorie supprimée. $reclassifiedAi synthèses et $reclassifiedRag documents ont été reclassés dans "Général".'),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsServiceProvider);
    final categories = _isPrompts ? settings.promptCategories : settings.knowledgeCategories;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.category_rounded, color: Colors.blueAccent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Gestionnaire des Catégories',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Créez, renommez ou supprimez vos dossiers de classement unifiés.',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context, true),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Add Category Row
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newCategoryController,
                      decoration: const InputDecoration(
                        hintText: 'Nom de la nouvelle catégorie (ex: Impôts, Projets...)...',
                        prefixIcon: Icon(Icons.add_circle_outline, size: 18),
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (_) => _addNewCategory(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Ajouter'),
                    onPressed: _addNewCategory,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),

              // Categories List
              Expanded(
                child: _isProcessing
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.separated(
                        itemCount: categories.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final cat = categories[i];
                          final isGeneral = cat == 'Général';

                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            leading: const Icon(Icons.folder, color: Colors.amber, size: 20),
                            title: Text(
                              cat,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isGeneral ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            subtitle: isGeneral
                                ? const Text('Dossier racine par défaut', style: TextStyle(fontSize: 10, color: Colors.grey))
                                : null,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit, size: 16, color: Colors.blueAccent),
                                  tooltip: 'Renommer cette catégorie en cascade',
                                  onPressed: isGeneral ? null : () => _renameCategory(cat),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    size: 16,
                                    color: isGeneral ? Colors.grey.shade400 : Colors.redAccent,
                                  ),
                                  tooltip: isGeneral ? 'Catégorie par défaut non supprimable' : 'Supprimer cette catégorie',
                                  onPressed: isGeneral ? null : () => _deleteCategory(cat),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),

              // Bottom Close Button
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Terminer'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
