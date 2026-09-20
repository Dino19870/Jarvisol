import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../utils/app_paths.dart';
import '../models/prompt_item.dart';
import '../utils/platform_utils.dart' as plat;
import 'log_service.dart';
import 'settings_service.dart';

/// Central service for managing the library of System Prompts and Conversation Prompts.
class PromptLibraryService {
  final SettingsService _settings;
  final List<PromptItem> _cachedPrompts = [];
  bool _isInitialized = false;
  File? _storageFile;

  PromptLibraryService(this._settings);

  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;
    try {
      final baseDir = await _getStorageDirectory();
      _storageFile = File(p.join(baseDir.path, 'prompts_library.json'));

      if (await _storageFile!.exists()) {
        final content = await _storageFile!.readAsString();
        if (content.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(content);
            if (decoded is List) {
              _cachedPrompts.clear();
              for (final item in decoded) {
                if (item is Map<String, dynamic>) {
                  _cachedPrompts.add(PromptItem.fromJson(item));
                }
              }
            }
          } catch (e) {
            Log.instance.e('prompt_lib', 'Corrupted prompts_library.json detected: $e');
            final ts = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_');
            final corruptBackup = File('${_storageFile!.path}.bak_corrupt_$ts');
            try {
              await _storageFile!.copy(corruptBackup.path);
              Log.instance.w('prompt_lib', 'Quarantined corrupted prompts_library.json to ${corruptBackup.path}');
            } catch (qErr) {
              Log.instance.e('prompt_lib', 'Failed to quarantine corrupted prompts library: $qErr');
            }
            _cachedPrompts.clear();
          }
        }
      }

      // If empty, populate with default built-in presets and migrate existing custom settings
      if (_cachedPrompts.isEmpty) {
        _populateBuiltIns();
        _migrateSettingsPresets();
        await _persistToFile();
      }
    } catch (e) {
      Log.instance.e('prompt_lib', 'Failed to initialize PromptLibraryService: $e');
      if (_cachedPrompts.isEmpty) {
        _populateBuiltIns();
      }
    }
    _isInitialized = true;
  }

  Future<Directory> _getStorageDirectory() async {
    if (plat.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final exeDir = Directory(p.dirname(exePath));
      final promptsDir = Directory(p.join(exeDir.path, 'prompts_library'));
      if (!await promptsDir.exists()) {
        await promptsDir.create(recursive: true);
      }
      return promptsDir;
    }
    final appDir = AppPaths.dataDir;
    final promptsDir = Directory(p.join(appDir.path, 'prompts_library'));
    if (!await promptsDir.exists()) {
      await promptsDir.create(recursive: true);
    }
    return promptsDir;
  }

  Future<void> _persistToFile() async {
    if (_storageFile == null) return;
    try {
      final jsonList = _cachedPrompts.map((p) => p.toJson()).toList();
      final tmp = File('${_storageFile!.path}.tmp');
      await tmp.writeAsString(jsonEncode(jsonList), flush: true);
      if (Platform.isWindows && await _storageFile!.exists()) {
        try {
          await _storageFile!.delete();
        } catch (_) {}
      }
      await tmp.rename(_storageFile!.path);
    } catch (e) {
      Log.instance.e('prompt_lib', 'Failed to persist prompts library: $e');
    }
  }

  void _populateBuiltIns() {
    final now = DateTime.now();

    // 1. Prompts Système Intégrés
    _cachedPrompts.addAll([
      PromptItem(
        id: 'sys_default_rag',
        title: '🤖 Expert RAG & Synthèse Documentaire (Standard)',
        category: 'Général',
        type: PromptType.system,
        description: 'Cadre de référence pour l\'analyse rigoureuse de documents sans hallucination.',
        content: defaultSystemPromptText,
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
      PromptItem(
        id: 'sys_detective',
        title: '🔍 Analyse Critique & Détective',
        category: 'Juridique & Audit',
        type: PromptType.system,
        description: 'Examine les preuves, indices, dates, contradictions et zones d\'ombre.',
        content: '''Tu es un enquêteur et analyste critique minutieux.
DOCUMENTS ACTIFS :
{DOCUMENTS_LIST}

EXTRAITS DU DOCUMENT :
===
{RAG_EXTRACTS}
===
Consignes :
1. Examine les preuves, indices, dates, lieux, personnages et contradictions dans ces extraits.
2. Présente tes constatations sous forme de rapport d'enquête rigoureux en français.
3. N'invente aucun fait non présent dans le texte.''',
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
      PromptItem(
        id: 'sys_concise',
        title: '⚡ Réponses Courtes en Puces',
        category: 'Synthèses',
        type: PromptType.system,
        description: 'Réponses ultra-concises en 3 à 5 puces sans bavardage.',
        content: '''Tu es un assistant IA concis et direct.
DOCUMENTS ACTIFS :
{DOCUMENTS_LIST}

EXTRAITS DU DOCUMENT :
===
{RAG_EXTRACTS}
===
Consignes :
1. Réponds en 3 à 5 puces courtes maximum.
2. Pas de longues phrases, va immédiatement aux faits bruts.
3. Réponds exclusivement en français.''',
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
      PromptItem(
        id: 'sys_finance',
        title: '📊 Auditeur Financier & Comptable',
        category: 'Finances & Factures',
        type: PromptType.system,
        description: 'Vérification méticuleuse des chiffres, devises, montants HT/TTC et dates de paiement.',
        content: '''Tu es un expert-comptable et contrôleur de gestion financier rigoureux.
DOCUMENTS ACTIFS :
{DOCUMENTS_LIST}

EXTRAITS DU DOCUMENT :
===
{RAG_EXTRACTS}
===
Consignes :
1. Extrais avec une précision chirurgicale tous les montants financiers, devises, totaux HT/TTC, remises et échéances.
2. Présente les données sous forme de tableaux clairs et signale toute anomalie ou incohérence de calcul.
3. Reste factuel et précis en français.''',
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
    ]);

    // 2. Prompts de Conversation / Requêtes Types Intégrées
    _cachedPrompts.addAll([
      PromptItem(
        id: 'conv_resume_3_points',
        title: '💡 Résumé Stratégique en 3 Points Clés',
        category: 'Synthèses',
        type: PromptType.conversation,
        description: 'Dégage les 3 enseignements majeurs du document.',
        content: 'Fais-moi un résumé stratégique de ce document en exactement 3 grands points clés essentiels.',
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
      PromptItem(
        id: 'conv_risques_echeances',
        title: '⚠️ Analyse des Risques, Engagements & Délais',
        category: 'Juridique & Audit',
        type: PromptType.conversation,
        description: 'Identifie les obligations, clauses contraignantes et dates limites.',
        content: 'Quels sont les principaux risques, engagements contractuels, clauses importantes et échéances critiques mentionnés dans ce document ?',
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
      PromptItem(
        id: 'conv_table_montants',
        title: '💰 Tableau Récapitulatif des Chiffres et Montants',
        category: 'Finances & Factures',
        type: PromptType.conversation,
        description: 'Génère un tableau markdown de tous les montants et dépenses.',
        content: 'Dresse un tableau récapitulatif clair de tous les chiffres, coûts, tarifs et montants financiers identifiés dans ce document.',
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
      PromptItem(
        id: 'conv_email_synthese',
        title: '✉️ Rédaction d\'un E-mail de Synthèse Pro',
        category: 'Général',
        type: PromptType.conversation,
        description: 'Rédige un courriel prêt à l\'envoi pour votre équipe ou client.',
        content: 'Rédige un e-mail professionnel, concis et structuré destiné à mon équipe pour leur présenter la synthèse et les décisions issues de ce document.',
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
      PromptItem(
        id: 'conv_questions_faq',
        title: '❓ Générateur de FAQ & Questions/Réponses',
        category: 'Général',
        type: PromptType.conversation,
        description: 'Crée une FAQ pertinente à partir du contenu fourni.',
        content: 'Génère une Foire Aux Questions (FAQ) de 5 questions/réponses pertinentes et pédagogiques basées sur ce document.',
        createdAt: now,
        updatedAt: now,
        isBuiltIn: true,
      ),
    ]);
  }

  void _migrateSettingsPresets() {
    try {
      final customPresets = _settings.systemPromptPresets;
      final now = DateTime.now();
      for (final p in customPresets) {
        if (!_cachedPrompts.any((item) => item.id == p.id)) {
          _cachedPrompts.add(PromptItem(
            id: p.id,
            title: p.name,
            category: 'Général',
            type: PromptType.system,
            description: 'Preset importé depuis les réglages',
            content: p.prompt,
            createdAt: now,
            updatedAt: now,
            isBuiltIn: false,
          ));
        }
      }
    } catch (_) {}
  }

  // --- Public CRUD Methods ---

  Future<List<PromptItem>> listPrompts({
    PromptType? type,
    String? category,
    String? query,
  }) async {
    await _ensureInitialized();
    return _cachedPrompts.where((p) {
      if (type != null && p.type != type) return false;
      if (category != null && category != 'Tous') {
        if (p.category.toLowerCase() != category.toLowerCase()) return false;
      }
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        final matchTitle = p.title.toLowerCase().contains(q);
        final matchContent = p.content.toLowerCase().contains(q);
        final matchDesc = p.description.toLowerCase().contains(q);
        final matchCat = p.category.toLowerCase().contains(q);
        if (!matchTitle && !matchContent && !matchDesc && !matchCat) return false;
      }
      return true;
    }).toList();
  }

  List<PromptItem> listPromptsSync() => List.unmodifiable(_cachedPrompts);

  Future<PromptItem?> getPromptById(String id) async {
    await _ensureInitialized();
    return _cachedPrompts.where((p) => p.id == id).firstOrNull;
  }

  Future<void> savePrompt(PromptItem item) async {
    await _ensureInitialized();
    final index = _cachedPrompts.indexWhere((p) => p.id == item.id);
    if (index != -1) {
      _cachedPrompts[index] = item.copyWith(updatedAt: DateTime.now());
    } else {
      _cachedPrompts.add(item);
    }
    await _persistToFile();
  }

  Future<bool> deletePrompt(String id) async {
    await _ensureInitialized();
    final index = _cachedPrompts.indexWhere((p) => p.id == id);
    if (index != -1) {
      _cachedPrompts.removeAt(index);
      await _persistToFile();
      return true;
    }
    return false;
  }

  Future<PromptItem> duplicatePrompt(PromptItem item) async {
    await _ensureInitialized();
    final newItem = item.copyWith(
      id: 'copy_${DateTime.now().millisecondsSinceEpoch}',
      title: '${item.title} (Copie)',
      isBuiltIn: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _cachedPrompts.add(newItem);
    await _persistToFile();
    return newItem;
  }

  Future<bool> updatePromptCategory(String id, String newCategory) async {
    await _ensureInitialized();
    final index = _cachedPrompts.indexWhere((p) => p.id == id);
    if (index != -1) {
      _cachedPrompts[index] = _cachedPrompts[index].copyWith(
        category: newCategory.trim().isNotEmpty ? newCategory.trim() : 'Général',
        updatedAt: DateTime.now(),
      );
      await _persistToFile();
      return true;
    }
    return false;
  }

  Future<int> renameCategoryInPrompts(String oldCategory, String newCategory) async {
    await _ensureInitialized();
    int count = 0;
    for (int i = 0; i < _cachedPrompts.length; i++) {
      if (_cachedPrompts[i].category.toLowerCase() == oldCategory.toLowerCase()) {
        _cachedPrompts[i] = _cachedPrompts[i].copyWith(
          category: newCategory,
          updatedAt: DateTime.now(),
        );
        count++;
      }
    }
    if (count > 0) {
      await _persistToFile();
    }
    return count;
  }

  Future<int> reassignCategoryInPrompts(String oldCategory, String fallbackCategory) async {
    return renameCategoryInPrompts(oldCategory, fallbackCategory);
  }
}

/// Riverpod provider for the PromptLibraryService
final promptLibraryServiceProvider = Provider<PromptLibraryService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  return PromptLibraryService(settings);
});
