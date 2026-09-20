import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/ai_knowledge_record.dart';
import '../models/prompt_item.dart';
import '../services/ai_knowledge_service.dart';
import '../services/document_rag_service.dart';
import '../services/document_source_service.dart';
import '../services/llm_service.dart';
import '../services/log_service.dart';
import '../services/mcp_tools_service.dart';
import '../services/settings_service.dart';
import '../services/litert_model_registry.dart';
import '../utils/file_picker_util.dart';
import '../utils/platform_utils.dart' as plat;
import 'ai_knowledge_dialog.dart';
import 'llm_settings_dialog.dart';
import 'prompt_library_dialog.dart';
import 'rag_library_dialog.dart';

class DocumentChatWidget extends ConsumerStatefulWidget {
  final bool isFullscreen;

  const DocumentChatWidget({
    super.key,
    this.isFullscreen = false,
  });

  @override
  ConsumerState<DocumentChatWidget> createState() => _DocumentChatWidgetState();
}

class _DocumentChatWidgetState extends ConsumerState<DocumentChatWidget>
    with AutomaticKeepAliveClientMixin {
  final List<DocumentSourceItem> _sources = [];
  final List<LlmChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _chipsScrollController = ScrollController();

  bool _isStreaming = false;
  String _currentStreamingText = '';
  StreamSubscription<String>? _streamSub;
  String? _loadedRecordTitle;
  int _llmContextCutoffIndex = 0;

  // Hybrid Mode RAG states
  List<DocumentChunk> _indexedChunks = [];
  bool _isIndexing = false;
  double _indexingProgress = 0.0;
  int _indexingCurrent = 0;
  int _indexingTotal = 0;

  bool? _ragModeOverride;
  bool get _isRagMode => _ragModeOverride ?? ref.read(settingsServiceProvider).ragModeEnabled;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _streamSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _chipsScrollController.dispose();
    super.dispose();
  }

  Future<void> _rebuildRagIndex() async {
    if (_sources.isEmpty) {
      if (mounted) {
        setState(() {
          _indexedChunks.clear();
          _isIndexing = false;
          _indexingProgress = 0.0;
          _indexingCurrent = 0;
          _indexingTotal = 0;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isIndexing = true;
        _indexingProgress = 0.0;
        _indexingCurrent = 0;
        _indexingTotal = 0;
      });
    }

    final ragService = ref.read(documentRagServiceProvider);
    final settings = ref.read(settingsServiceProvider);
    final llm = ref.read(llmServiceProvider);

    final chunkSize = settings.getModelRagChunkSize(settings.llmModel);
    final overlap = (chunkSize * 0.10).round().clamp(15, 60);

    final allChunks = <DocumentChunk>[];
    final unindexedChunks = <DocumentChunk>[];

    for (final s in _sources) {
      // 1. Try disk cache first
      final cached = await ragService.loadFromCache(
        sourceName: s.name,
        content: s.textContent,
        model: settings.llmEmbeddingModel,
        settings: settings,
      );

      if (cached != null && cached.isNotEmpty) {
        allChunks.addAll(cached);
      } else {
        // Compute chunks to be embedded
        final chunks = ragService.createChunks(
          sourceName: s.name,
          sourceType: s.type,
          text: s.textContent,
          targetWords: chunkSize,
          overlapWords: overlap,
        );
        allChunks.addAll(chunks);
        unindexedChunks.addAll(chunks);
      }
    }

    // If 100% loaded from disk cache without new unindexed chunks
    if (unindexedChunks.isEmpty && allChunks.isNotEmpty && allChunks.every((c) => c.embedding != null)) {
      if (mounted) {
        setState(() {
          _indexedChunks = allChunks;
          _isIndexing = false;
          _indexingProgress = 1.0;
        });
      }
      return;
    }

    // Set initial chunks so lexical/fallback search works immediately
    if (mounted) {
      setState(() {
        _indexedChunks = List.from(allChunks);
        _indexingTotal = unindexedChunks.length;
        _indexingCurrent = 0;
        _indexingProgress = 0.0;
      });
    }

    // Attempt vector embeddings for unindexed chunks
    final texts = unindexedChunks.map((c) => c.text).toList();
    if (texts.isNotEmpty) {
      try {
        final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
        final embeddingEndpoint = isLiteRt
            ? 'http://127.0.0.1:1234/v1'
            : (settings.llmApiUrl.isNotEmpty ? settings.llmApiUrl : llm.endpoint);

        final embeddings = await ragService.fetchEmbeddings(
          texts: texts,
          endpoint: embeddingEndpoint,
          model: settings.llmEmbeddingModel,
          onProgress: (cur, tot) {
            if (mounted) {
              setState(() {
                _indexingCurrent = cur;
                _indexingTotal = tot;
                _indexingProgress = tot > 0 ? (cur / tot) : 0.0;
              });
            }
          },
        );

        for (int i = 0; i < unindexedChunks.length && i < embeddings.length; i++) {
          if (embeddings[i].isNotEmpty) {
            unindexedChunks[i].embedding = embeddings[i];
          }
        }

        // Save successfully indexed chunks to disk cache
        for (final s in _sources) {
          final sourceChunks = allChunks.where((c) => c.sourceName == s.name).toList();
          if (sourceChunks.isNotEmpty && sourceChunks.every((c) => c.embedding != null)) {
            await ragService.saveToCache(
              sourceName: s.name,
              content: s.textContent,
              model: settings.llmEmbeddingModel,
              chunks: sourceChunks,
              settings: settings,
            );
          }
        }
      } catch (e) {
        Log.instance.w('rag', 'Vector embeddings failed: $e');
      }
    }

    if (mounted) {
      setState(() {
        _indexedChunks = allChunks;
        _isIndexing = false;
        _indexingProgress = 1.0;
      });
    }
  }

  String get _combinedContext {
    if (_sources.isEmpty) return '';
    final buffer = StringBuffer();
    for (int i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      buffer.writeln('=== DOCUMENT ${i + 1} : ${s.name} (${s.type.toUpperCase()}) ===');
      buffer.writeln(s.textContent);
      buffer.writeln();
    }
    final full = buffer.toString().trim();

    final settings = ref.read(settingsServiceProvider);
    final provider = settings.llmProvider;
    final maxTok = settings.llmMaxTokens;

    // Calcul de la fenêtre de contexte maximale :
    // - LM Studio / Ollama / Modèles Cloud (128K context) : supporte le livre entier sans bridage (jusqu'à 1 000 000 car.).
    // - LiteRT Windows : jusqu'à 32 000 - 64 000 car.
    // - LiteRT Android Embarqué : 14 000 car. (pour respecter la VRAM mobile).
    int maxChars;
    if (provider == LlmProvider.liteRtAndroid) {
      maxChars = 14000;
    } else if (provider == LlmProvider.lmStudio || provider == LlmProvider.ollama || provider == LlmProvider.custom) {
      maxChars = (maxTok >= 16000) ? (maxTok * 4).clamp(32000, 1500000) : 600000;
    } else {
      maxChars = (maxTok * 3.5).toInt().clamp(16000, 120000);
    }

    if (full.length > maxChars) {
      return '${full.substring(0, maxChars)}\n\n[... Contenu tronqué pour respecter la limite configurée de $maxChars caractères ...]';
    }
    return full;
  }

  int get _totalWordCount {
    if (_sources.isEmpty) return 0;
    int total = 0;
    for (final s in _sources) {
      total += s.textContent.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    }
    return total;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _importFile() async {
    try {
      final pick = await pickFilesRobust(
        type: FileType.any,
        allowMultiple: true,
        dialogTitle: 'Importer des documents, images ou fichiers',
      );

      if (pick.isEmpty) return;

      final docService = ref.read(documentSourceServiceProvider);
      int addedCount = 0;

      if (pick.hasBytesOnly && pick.fileBytes != null) {
        for (int i = 0; i < pick.fileBytes!.length; i++) {
          final name = (pick.fileNames != null && pick.fileNames!.length > i)
              ? pick.fileNames![i]
              : 'document_${i + 1}';
          if (_sources.any((s) => s.name == name)) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Le document "$name" est déjà ouvert dans la session.')),
              );
            }
            continue;
          }
          final bytes = pick.fileBytes![i];
          final item = await docService.parseFile(name, fileBytes: bytes);
          setState(() {
            _sources.add(item);
          });
          addedCount++;
        }
      } else {
        for (final path in pick.localPaths) {
          final item = await docService.parseFile(path);
          if (_sources.any((s) => s.name == item.name || s.path == item.path)) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Le document "${item.name}" est déjà ouvert dans la session.')),
              );
            }
            continue;
          }
          setState(() {
            _sources.add(item);
          });
          addedCount++;
        }
      }

      if (mounted && addedCount > 0) {
        _rebuildRagIndex();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$addedCount source(s) importée(s) et indexée(s) pour le RAG'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur lors de l\'import : $e')),
        );
      }
    }
  }

  Future<void> _openRagLibraryDialog() async {
    final selectedEntries = await RagLibraryDialog.show(context);
    if (selectedEntries == null || selectedEntries.isEmpty) return;

    final docService = ref.read(documentSourceServiceProvider);
    int addedCount = 0;

    for (final entry in selectedEntries) {
      if (_sources.any((s) => s.name == entry.sourceName)) {
        continue;
      }

      final item = docService.createFromText(
        title: entry.sourceName,
        text: entry.reconstructedText,
        type: 'cache',
      );

      _sources.add(item);
      // Directly inject pre-calculated chunks and embeddings (Instant 0.0s load!)
      _indexedChunks.removeWhere((c) => c.sourceName == entry.sourceName);
      _indexedChunks.addAll(entry.chunks);
      addedCount++;
    }

    if (addedCount > 0) {
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexingProgress = 1.0;
          _indexingCurrent = _indexedChunks.length;
          _indexingTotal = _indexedChunks.length;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              addedCount > 1
                  ? '$addedCount documents chargés instantanément depuis le cache (${_indexedChunks.length} fragments prêts).'
                  : 'Document "${selectedEntries.first.sourceName}" chargé instantanément (${selectedEntries.first.chunkCount} fragments prêts).',
            ),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.purple.shade700,
          ),
        );
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Le presse-papier est vide ou ne contient pas de texte')),
          );
        }
        return;
      }

      final docService = ref.read(documentSourceServiceProvider);
      final title = 'Presse-papier (${DateTime.now().hour}h${DateTime.now().minute.toString().padLeft(2, '0')})';
      final item = docService.createFromText(title: title, text: text, type: 'clipboard');

      setState(() {
        _sources.add(item);
      });
      _rebuildRagIndex();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contenu du presse-papier collé (${item.textContent.length} caractères)'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Impossible d\'accéder au presse-papier : $e')),
        );
      }
    }
  }

  void _showDirectTextInputDialog() {
    final textController = TextEditingController();
    final titleController = TextEditingController(
      text: 'Note directe ${DateTime.now().hour}h${DateTime.now().minute.toString().padLeft(2, '0')}',
    );

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.edit_note, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Saisie / Note Directe'),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: 'Titre de la note ou du document',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Contenu du texte',
                  hintText: 'Saisissez ou collez votre texte ici...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Ajouter au contexte'),
            onPressed: () {
              final text = textController.text.trim();
              if (text.isNotEmpty) {
                final docService = ref.read(documentSourceServiceProvider);
                final title = titleController.text.trim().isNotEmpty
                    ? titleController.text.trim()
                    : 'Note directe';
                final item = docService.createFromText(title: title, text: text, type: 'manual');
                setState(() {
                  _sources.add(item);
                });
                _rebuildRagIndex();
              }
              Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }


  Future<void> _sendMessage([
    String? overrideText,
    bool forceTextMode = false,
    bool forceImageMode = false,
    bool allowLlmTranslation = true,
  ]) async {
    final text = overrideText ?? _inputController.text.trim();
    if (text.isEmpty || _isStreaming) return;

    if (overrideText == null) {
      _inputController.clear();
    }

    if (!forceTextMode && !forceImageMode) {
      final userMsg = LlmChatMessage(
        role: 'user',
        content: text,
        timestamp: DateTime.now(),
      );

      setState(() {
        _messages.add(userMsg);
        _isStreaming = true;
        _currentStreamingText = '';
      });
      _scrollToBottom();
    } else {
      setState(() {
        _isStreaming = true;
        _currentStreamingText = '';
      });
      _scrollToBottom();
    }

    final llm = ref.read(llmServiceProvider);
    final ragService = ref.read(documentRagServiceProvider);
    final settings = ref.read(settingsServiceProvider);

    String systemPrompt;

    if (_isRagMode && _indexedChunks.isNotEmpty) {
      // ⚡ MODE RAG : Extraction chirurgicale des extraits les plus pertinents
      final rawTopK = settings.getModelRagTopK(settings.llmModel);
      final modelContextLimit = settings.getModelMaxTokens(settings.llmModel);
      final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
      
      // Calibrage dynamique automatique du budget selon la capacité réelle du modèle
      final responseBudget = (modelContextLimit * 0.25).clamp(500, 2048).toInt();
      final contextTokenBudget = (modelContextLimit - responseBudget).clamp(1500, 120000);
      final maxContextChars = (contextTokenBudget * 3.2).toInt();
      final maxPossibleExtracts = (maxContextChars / 1200).floor().clamp(3, 50);
      final topK = rawTopK.clamp(1, maxPossibleExtracts);

      final minRel = settings.getModelRagMinRelevance(settings.llmModel);
      final searchMode = settings.getModelRagSearchMode(settings.llmModel);
      final embeddingEndpoint = isLiteRt
          ? 'http://127.0.0.1:1234/v1'
          : llm.endpoint;
      final topChunks = await ragService.retrieveTopChunks(
        query: text,
        chunks: _indexedChunks,
        endpoint: embeddingEndpoint,
        model: settings.llmEmbeddingModel,
        topK: topK,
        minRelevance: minRel,
        mode: searchMode,
      );

      final buffer = StringBuffer();
      if (topChunks.isNotEmpty) {
        for (int i = 0; i < topChunks.length; i++) {
          final r = topChunks[i];
          final ch = r.chunk;
          if (buffer.length + ch.text.length > maxContextChars) break;
          buffer.writeln('--- EXTRAIT ${i + 1} [Source: ${ch.sourceName}${ch.chapterTitle != null ? ' - ${ch.chapterTitle}' : ''}] (Pertinence: ${(r.score * 100).toStringAsFixed(0)}%) ---');
          buffer.writeln(ch.text);
          buffer.writeln();
        }
      } else {
        final fallbackCount = maxPossibleExtracts > 5 ? 5 : 3;
        final fallbackChunks = _indexedChunks.take(fallbackCount).toList();
        for (int i = 0; i < fallbackChunks.length; i++) {
          final ch = fallbackChunks[i];
          buffer.writeln('--- EXTRAIT ${i + 1} [Source: ${ch.sourceName}${ch.chapterTitle != null ? ' - ${ch.chapterTitle}' : ''}] ---');
          buffer.writeln(ch.text);
          buffer.writeln();
        }
      }

      final sourceNamesList = _sources.map((s) => '- ${s.name} (${s.type.toUpperCase()})').join('\n');
      final ragExtractsText = buffer.toString().trim();
      final userTemplate = settings.activeSystemPromptText;

      if (userTemplate.contains('{DOCUMENTS_LIST}') || userTemplate.contains('{RAG_EXTRACTS}')) {
        systemPrompt = userTemplate
            .replaceAll('{DOCUMENTS_LIST}', sourceNamesList.isNotEmpty ? sourceNamesList : '(Aucun document joint)')
            .replaceAll('{RAG_EXTRACTS}', ragExtractsText.isNotEmpty ? ragExtractsText : '(Aucun extrait RAG)');
      } else {
        systemPrompt = '''$userTemplate

DOCUMENTS ACTIFS DANS LA SESSION (${_sources.length} sources) :
$sourceNamesList

Voici les EXTRAITS PERTINENTS issus de la recherche sémantique ciblée (Mode RAG) :
===
$ragExtractsText
===''';
      }
    } else {
      // 📖 MODE CONTEXTE COMPLET (128K) : Injection intégrale
      String contextData = _combinedContext;
      final modelMaxTokens = settings.getModelMaxTokens(settings.llmModel);
      final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
      
      // Limite de sécurité stricte pour modèles 4K (LiteRT) pour laisser de la place à l'historique et à la réponse
      final maxAllowedContextChars = isLiteRt || modelMaxTokens <= 4096 ? 7500 : (modelMaxTokens * 3.0).toInt();
      if (contextData.length > maxAllowedContextChars) {
        contextData = '${contextData.substring(0, maxAllowedContextChars)}\n\n[... Contexte limité aux $maxAllowedContextChars premiers caractères pour respecter la capacité du modèle ($modelMaxTokens tokens). Activez le mode "⚡ RAG" pour interroger 100% du document sans restriction ...]';
      }
      systemPrompt = '''Tu es un assistant IA expert polyvalent intégré dans CrisperWeaver.
Voici les documents, fichiers et notes textuelles fournis par l'utilisateur :
---
${contextData.isNotEmpty ? contextData : "(Aucun document importé pour l'instant. Réponds aux questions générales de l'utilisateur.)"}
---
Réponds de manière concise, structurée, claire et pertinente en français en t'appuyant sur ces documents.''';
    }

    // 🛠️ Connecteurs & Outils MCP (Date, Web Search & Gmail)
    final mcpTools = ref.read(mcpToolsServiceProvider);
    systemPrompt = mcpTools.enrichPromptWithDate(systemPrompt);

    final textLower = text.toLowerCase();
    final isExplicitGmailQuery = textLower.contains('gmail') ||
        textLower.contains('mes mails') ||
        textLower.contains('mon mail') ||
        textLower.contains('mes courriels') ||
        textLower.contains('mon courriel') ||
        textLower.contains('ma boîte') ||
        textLower.contains('mes messages');

    if (settings.enableWebSearchTool && (!isExplicitGmailQuery || !settings.enableGmailTool)) {
      final searchQuery = mcpTools.extractSearchQuery(text, _messages);
      final webResults = await mcpTools.searchWeb(searchQuery);
      systemPrompt += '''

🌐 RÉSULTATS DE LA RECHERCHE WEB EN DIRECT SUR INTERNET (Sujet : "$searchQuery") :
===
$webResults
===
DIRECTIVE ABSOLUE POUR L'ASSISTANT :
La recherche Internet a DÉJÀ été effectuée avec succès et les données réelles sont fournies ci-dessus.
Ne dis JAMAIS que tu n'as pas accès à Internet ou que tu ne peux pas faire de recherche en direct. Rédige immédiatement une réponse fluide, détaillée et factuelle en français en synthétisant ces articles et informations du web.''';
    }

    if (settings.enableGmailTool) {
      final gmailResults = await mcpTools.queryGmail(text);
      systemPrompt += '''

✉️ RÉSULTATS RÉELS DU CONNECTEUR GMAIL :
===
$gmailResults
===
DIRECTIVE ABSOLUE POUR L'ASSISTANT :
Les e-mails récents de la boîte Gmail de l'utilisateur ont été récupérés en direct et sont fournis ci-dessus.
Résume, présente ou analyse directement ces courriels (expéditeurs, sujets, dates). Ne dis JAMAIS que tu n'as pas accès à la boîte mail puisque les données sont transmises ci-dessus.''';
    }

    if (settings.enableImageGenTool && !forceTextMode) {
      final isExplicit = mcpTools.isExplicitImageCommand(text) || forceImageMode;
      if (isExplicit) {
        final rawImgPrompt = mcpTools.extractImagePrompt(text);
        final activeModelName = settings.activeImageModel.isNotEmpty ? settings.activeImageModel : 'sd1.5-Q4_0.gguf';

        String promptToSend = rawImgPrompt;
        if (allowLlmTranslation) {
          setState(() {
            _isStreaming = true;
            _currentStreamingText = '🎨 **Préparation de l\'image...**\n\n'
                '🧠 *Traduction fidèle du prompt avec le modèle de texte...*\n\n'
                '*(Prompt brut : "$rawImgPrompt")*';
          });
          _scrollToBottom();
          promptToSend = await mcpTools.translateToEnglishPrompt(rawImgPrompt, allowLlm: true);
        }

        setState(() {
          _isStreaming = true;
          _currentStreamingText = '🎨 **Génération d\'image en cours...**\n\n'
              '⏳ *Calcul graphique avec $activeModelName...*\n\n'
              '*(Prompt : "$promptToSend")*';
        });
        _scrollToBottom();

        final imgResult = await mcpTools.generateImage(promptToSend, allowLlmTranslation: false);
        if (mounted) {
          if (!_isStreaming) {
            // Annulé manuellement par l'utilisateur
            return;
          }
          setState(() {
            _messages.add(LlmChatMessage(
              role: 'assistant',
              content: imgResult,
              timestamp: DateTime.now(),
            ));
            _isStreaming = false;
            _currentStreamingText = '';
          });
          _scrollToBottom();
        }
        return;
      } else if (mcpTools.isImageGenerationRequest(text)) {
        // Demande de confirmation interactive pour éviter toute ambiguïté avec le chat textuel
        final imgPrompt = mcpTools.extractImagePrompt(text);
        final confirmationMsg = '🎨 **Détection d\'intention visuelle**\n\n'
            'Votre message décrit une scène visuelle : *"$imgPrompt"*.\n\n'
            '👉 **Comment souhaitez-vous traiter cette demande ?**';

        setState(() {
          _messages.add(LlmChatMessage(
            role: 'assistant',
            content: confirmationMsg,
            timestamp: DateTime.now(),
            actionPrompt: text,
          ));
          _isStreaming = false;
          _currentStreamingText = '';
        });
        _scrollToBottom();
        return;
      }
    }

    Log.instance.i('chat', 'Envoi message: "$text" | Provider: ${llm.provider.name} | Endpoint: ${llm.endpoint} | Mode RAG: $_isRagMode | Fragments: ${_indexedChunks.length} | Cutoff: $_llmContextCutoffIndex');

    final candidateHistory = _llmContextCutoffIndex < _messages.length
        ? _messages.sublist(_llmContextCutoffIndex)
        : <LlmChatMessage>[];

    final validHistory = candidateHistory
        .where((m) =>
            !m.content.startsWith('❌ Erreur') &&
            !m.content.startsWith('⚠️ Aucune') &&
            !m.content.startsWith('⚠️'))
        .toList();

    // Fenêtre glissante dynamique : limite l'historique pour ne jamais dépasser le modèle
    final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
    final maxHistoryMessages = isLiteRt ? 4 : 10;
    final recentMessages = validHistory.length > maxHistoryMessages
        ? validHistory.sublist(validHistory.length - maxHistoryMessages)
        : validHistory;

    final requestMessages = [
      LlmChatMessage(role: 'system', content: systemPrompt),
      ...recentMessages,
    ];

    try {
      final stream = llm.streamChat(messages: requestMessages);
      final buffer = StringBuffer();

      _streamSub = stream.listen(
        (String chunk) {
          buffer.write(chunk);
          if (mounted) {
            setState(() {
              _currentStreamingText = buffer.toString();
            });
            _scrollToBottom();
          }
        },
        onError: (dynamic err) {
          Log.instance.e('chat', 'Erreur stream chat: $err');
          if (mounted) {
            setState(() {
              _messages.add(LlmChatMessage(
                role: 'assistant',
                content: '❌ Erreur : $err\n\nVérifiez que le serveur IA (${llm.provider.displayName} sur ${llm.endpoint}) est bien démarré.',
                timestamp: DateTime.now(),
              ));
              _isStreaming = false;
              _currentStreamingText = '';
            });
            _scrollToBottom();
          }
        },
        onDone: () {
          Log.instance.i('chat', 'Réponse terminée (total: ${buffer.length} car.)');
          if (mounted) {
            if (buffer.isNotEmpty) {
              setState(() {
                _messages.add(LlmChatMessage(
                  role: 'assistant',
                  content: buffer.toString(),
                  timestamp: DateTime.now(),
                ));
                _isStreaming = false;
                _currentStreamingText = '';
              });
              _scrollToBottom();
            } else {
              setState(() {
                _messages.add(LlmChatMessage(
                  role: 'assistant',
                  content: '⚠️ Aucune réponse reçue du serveur ${llm.provider.displayName} (${llm.endpoint}). Vérifiez que le modèle est bien chargé.',
                  timestamp: DateTime.now(),
                ));
                _isStreaming = false;
                _currentStreamingText = '';
              });
            }
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(LlmChatMessage(
            role: 'assistant',
            content: '❌ Erreur de connexion : $e',
            timestamp: DateTime.now(),
          ));
          _isStreaming = false;
          _currentStreamingText = '';
        });
        _scrollToBottom();
      }
    }
  }

  void _cancelStreaming() {
    if (!_isStreaming) return;
    _streamSub?.cancel();
    _streamSub = null;

    // Déclenche l'interruption immédiate du processus de calcul d'image si en cours
    ref.read(mcpToolsServiceProvider).cancelImageGeneration();

    final partial = _currentStreamingText.trim();
    setState(() {
      if (partial.isNotEmpty) {
        _messages.add(LlmChatMessage(
          role: 'assistant',
          content: '$partial\n\n*(Génération interrompue par l\'utilisateur)*',
          timestamp: DateTime.now(),
        ));
      }
      _isStreaming = false;
      _currentStreamingText = '';
    });
    _scrollToBottom();
  }

  List<int> _generatePdfExport() {
    final PdfDocument document = PdfDocument();
    document.pageSettings.margins.all = 36;

    final PdfStandardFont titleFont = PdfStandardFont(PdfFontFamily.helvetica, 16, style: PdfFontStyle.bold);
    final PdfStandardFont subtitleFont = PdfStandardFont(PdfFontFamily.helvetica, 9, style: PdfFontStyle.italic);
    final PdfStandardFont sectionFont = PdfStandardFont(PdfFontFamily.helvetica, 11, style: PdfFontStyle.bold);
    final PdfStandardFont bodyFont = PdfStandardFont(PdfFontFamily.helvetica, 9.5);
    final PdfStandardFont roleFont = PdfStandardFont(PdfFontFamily.helvetica, 10, style: PdfFontStyle.bold);

    PdfPage page = document.pages.add();
    final Size pageSize = page.getClientSize();

    final PdfTextElement titleEl = PdfTextElement(
      text: 'Discussion & Synthèse Documentaire - CrisperWeaver',
      font: titleFont,
      brush: PdfSolidBrush(PdfColor(21, 101, 192)),
    );
    PdfLayoutResult? layoutResult = titleEl.draw(
      page: page,
      bounds: Rect.fromLTWH(0, 0, pageSize.width, 30),
    );

    final dateStr = 'Date d\'exportation : ${DateTime.now().toLocal().toString().split(".")[0]}';
    final PdfTextElement dateEl = PdfTextElement(
      text: dateStr,
      font: subtitleFont,
      brush: PdfSolidBrush(PdfColor(110, 110, 110)),
    );
    layoutResult = dateEl.draw(
      page: layoutResult!.page,
      bounds: Rect.fromLTWH(0, layoutResult.bounds.bottom + 3, pageSize.width, 20),
    );

    if (_sources.isNotEmpty) {
      final sourcesHeader = PdfTextElement(
        text: 'Documents sources analysés :',
        font: sectionFont,
        brush: PdfSolidBrush(PdfColor(40, 40, 40)),
      );
      layoutResult = sourcesHeader.draw(
        page: layoutResult!.page,
        bounds: Rect.fromLTWH(0, layoutResult.bounds.bottom + 8, pageSize.width, 20),
      );

      final sourcesText = _sources.map((s) => '• ${s.name} (${s.type.toUpperCase()}) - ${s.textContent.length} caractères').join('\n');
      final sourcesEl = PdfTextElement(
        text: sourcesText,
        font: bodyFont,
        brush: PdfSolidBrush(PdfColor(70, 70, 70)),
      );
      layoutResult = sourcesEl.draw(
        page: layoutResult!.page,
        bounds: Rect.fromLTWH(10, layoutResult.bounds.bottom + 3, pageSize.width - 10, 0),
      );
    }

    final lineY = layoutResult!.bounds.bottom + 8;
    layoutResult.page.graphics.drawLine(
      PdfPen(PdfColor(210, 210, 210), width: 0.8),
      Offset(0, lineY),
      Offset(pageSize.width, lineY),
    );

    double currentY = lineY + 12;
    PdfPage curPage = layoutResult.page;

    for (final m in _messages) {
      final isUser = m.role == 'user';
      final roleTitle = isUser ? 'UTILISATEUR' : 'ASSISTANT IA';
      final timeStr = '${m.timestamp.hour}h${m.timestamp.minute.toString().padLeft(2, '0')}';
      final headerText = '[$roleTitle • $timeStr]';

      final roleColor = isUser ? PdfColor(25, 118, 210) : PdfColor(123, 31, 162);
      final headerEl = PdfTextElement(
        text: headerText,
        font: roleFont,
        brush: PdfSolidBrush(roleColor),
      );

      final paginateFormat = PdfLayoutFormat(layoutType: PdfLayoutType.paginate);
      final headResult = headerEl.draw(
        page: curPage,
        bounds: Rect.fromLTWH(0, currentY, pageSize.width, 0),
        format: paginateFormat,
      );

      curPage = headResult!.page;

      final contentEl = PdfTextElement(
        text: m.content,
        font: bodyFont,
        brush: PdfSolidBrush(PdfColor(35, 35, 35)),
      );

      final contentResult = contentEl.draw(
        page: curPage,
        bounds: Rect.fromLTWH(10, headResult.bounds.bottom + 3, pageSize.width - 10, 0),
        format: paginateFormat,
      );

      curPage = contentResult!.page;
      currentY = contentResult.bounds.bottom + 12;
      if (currentY > curPage.getClientSize().height - 30) {
        curPage = document.pages.add();
        currentY = 10;
      }
    }

    final List<int> bytes = document.saveSync();
    document.dispose();
    return bytes;
  }

  List<int> _generateDocxExport() {
    final archive = Archive();

    const contentTypesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
        '  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n'
        '  <Default Extension="xml" ContentType="application/xml"/>\n'
        '  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\n'
        '</Types>';
    archive.addFile(ArchiveFile('[Content_Types].xml', contentTypesXml.length, utf8.encode(contentTypesXml)));

    const relsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
        '  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\n'
        '</Relationships>';
    archive.addFile(ArchiveFile('_rels/.rels', relsXml.length, utf8.encode(relsXml)));

    final docBuffer = StringBuffer();
    docBuffer.writeln('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    docBuffer.writeln('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">');
    docBuffer.writeln('<w:body>');

    docBuffer.writeln('<w:p><w:r><w:rPr><w:b/><w:sz w:val="36"/><w:color w:val="1565C0"/></w:rPr><w:t>Discussion &amp; Synthèse CrisperWeaver</w:t></w:r></w:p>');

    final dateStr = 'Date d\'exportation : ${DateTime.now().toLocal().toString().split(".")[0]}';
    docBuffer.writeln('<w:p><w:r><w:rPr><w:i/><w:sz w:val="20"/><w:color w:val="777777"/></w:rPr><w:t>${_escapeXml(dateStr)}</w:t></w:r></w:p>');

    if (_sources.isNotEmpty) {
      docBuffer.writeln('<w:p><w:r><w:rPr><w:b/><w:sz w:val="24"/><w:color w:val="333333"/></w:rPr><w:t>Documents sources :</w:t></w:r></w:p>');
      for (final s in _sources) {
        final srcLine = '• ${s.name} (${s.type.toUpperCase()}) - ${s.textContent.length} caractères';
        docBuffer.writeln('<w:p><w:r><w:rPr><w:sz w:val="20"/><w:color w:val="555555"/></w:rPr><w:t>${_escapeXml(srcLine)}</w:t></w:r></w:p>');
      }
    }

    docBuffer.writeln('<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="CCCCCC"/></w:pBdr></w:pPr></w:p>');

    for (final m in _messages) {
      final isUser = m.role == 'user';
      final roleText = isUser ? 'UTILISATEUR' : 'ASSISTANT IA';
      final timeStr = '${m.timestamp.hour}h${m.timestamp.minute.toString().padLeft(2, '0')}';
      final roleColor = isUser ? '1976D2' : '7B1FA2';

      docBuffer.writeln('<w:p><w:r><w:rPr><w:b/><w:sz w:val="22"/><w:color w:val="$roleColor"/></w:rPr><w:t>${_escapeXml("[$roleText • $timeStr]")}</w:t></w:r></w:p>');

      final lines = m.content.split('\n');
      for (final l in lines) {
        docBuffer.writeln('<w:p><w:r><w:rPr><w:sz w:val="21"/><w:color w:val="222222"/></w:rPr><w:t xml:space="preserve">${_escapeXml(l)}</w:t></w:r></w:p>');
      }
      docBuffer.writeln('<w:p/>');
    }

    docBuffer.writeln('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>');
    docBuffer.writeln('</w:body></w:document>');

    final docBytes = utf8.encode(docBuffer.toString());
    archive.addFile(ArchiveFile('word/document.xml', docBytes.length, docBytes));

    return ZipEncoder().encode(archive);
  }

  String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  String _generateMarkdownExport() {
    final buffer = StringBuffer();
    buffer.writeln('# 📑 Discussion CrisperWeaver - Assistant Documents');
    buffer.writeln('**Date d\'exportation :** ${DateTime.now().toLocal().toString().split(".")[0]}');
    if (_sources.isNotEmpty) {
      buffer.writeln('\n### 📚 Documents sources chargés :');
      for (final s in _sources) {
        buffer.writeln('- **${s.name}** (${s.type}) - ${s.textContent.length} caractères');
      }
    }
    buffer.writeln('\n---\n');
    for (final m in _messages) {
      final sender = m.role == 'user' ? '👤 **Vous**' : '🤖 **Assistant IA**';
      final timeStr = '${m.timestamp.hour}h${m.timestamp.minute.toString().padLeft(2, '0')}';
      buffer.writeln('$sender *($timeStr)* :\n');
      buffer.writeln(m.content);
      buffer.writeln('\n---\n');
    }
    return buffer.toString();
  }

  String _generatePlainTextExport() {
    final buffer = StringBuffer();
    buffer.writeln('=== DISCUSSION CRISPERWEAVER - ASSISTANT DOCUMENTS ===');
    buffer.writeln('Date : ${DateTime.now().toLocal().toString().split(".")[0]}');
    if (_sources.isNotEmpty) {
      buffer.writeln('\nDocuments sources :');
      for (final s in _sources) {
        buffer.writeln(' - ${s.name} (${s.type})');
      }
    }
    buffer.writeln('\n----------------------------------------\n');
    for (final m in _messages) {
      final sender = m.role == 'user' ? 'VOUS' : 'ASSISTANT IA';
      final timeStr = '${m.timestamp.hour}h${m.timestamp.minute.toString().padLeft(2, '0')}';
      buffer.writeln('[$sender - $timeStr]');
      buffer.writeln(m.content);
      buffer.writeln('\n----------------------------------------\n');
    }
    return buffer.toString();
  }

  String _generateHtmlExport() {
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html><html><head><meta charset="utf-8">');
    buffer.writeln('<title>Discussion CrisperWeaver</title>');
    buffer.writeln('<style>');
    buffer.writeln('body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 800px; margin: 40px auto; padding: 20px; line-height: 1.6; color: #222; background: #f8f9fa; }');
    buffer.writeln('.msg { margin-bottom: 24px; padding: 16px; border-radius: 12px; }');
    buffer.writeln('.user { background: #e3f2fd; border-left: 4px solid #1976d2; }');
    buffer.writeln('.assistant { background: #ffffff; border: 1px solid #e0e0e0; border-left: 4px solid #7b1fa2; box-shadow: 0 2px 4px rgba(0,0,0,0.05); }');
    buffer.writeln('.header { font-weight: bold; margin-bottom: 8px; font-size: 0.9em; color: #666; }');
    buffer.writeln('.content { white-space: pre-wrap; font-size: 1.05em; }');
    buffer.writeln('h1 { color: #1a237e; border-bottom: 2px solid #1a237e; padding-bottom: 8px; }');
    buffer.writeln('</style></head><body>');
    buffer.writeln('<h1>📑 Discussion CrisperWeaver</h1>');
    buffer.writeln('<p><em>Exporté le ${DateTime.now().toLocal().toString().split(".")[0]}</em></p>');
    for (final m in _messages) {
      final isUser = m.role == 'user';
      final sender = isUser ? '👤 Vous' : '🤖 Assistant IA';
      final timeStr = '${m.timestamp.hour}h${m.timestamp.minute.toString().padLeft(2, '0')}';
      buffer.writeln('<div class="msg ${isUser ? "user" : "assistant"}">');
      buffer.writeln('<div class="header">$sender • $timeStr</div>');
      buffer.writeln('<div class="content">${m.content.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}</div>');
      buffer.writeln('</div>');
    }
    buffer.writeln('</body></html>');
    return buffer.toString();
  }

  String _generateJsonExport() {
    final data = {
      'title': 'Discussion CrisperWeaver',
      'exportedAt': DateTime.now().toIso8601String(),
      'sources': _sources.map((s) => {'name': s.name, 'type': s.type, 'sizeBytes': s.sizeBytes}).toList(),
      'messages': _messages.map((m) => {
        'role': m.role,
        'content': m.content,
        'timestamp': m.timestamp.toIso8601String(),
      }).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  Future<void> _exportDiscussion(String format) async {
    try {
      final ext = format;
      final timeStamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final defaultFileName = 'Discussion_CrisperWeaver_$timeStamp.$ext';

      Uint8List encodedBytes;
      if (format == 'pdf') {
        encodedBytes = Uint8List.fromList(_generatePdfExport());
      } else if (format == 'docx') {
        encodedBytes = Uint8List.fromList(_generateDocxExport());
      } else if (format == 'md') {
        encodedBytes = Uint8List.fromList(utf8.encode(_generateMarkdownExport()));
      } else if (format == 'txt') {
        encodedBytes = Uint8List.fromList(utf8.encode(_generatePlainTextExport()));
      } else if (format == 'html') {
        encodedBytes = Uint8List.fromList(utf8.encode(_generateHtmlExport()));
      } else if (format == 'json') {
        encodedBytes = Uint8List.fromList(utf8.encode(_generateJsonExport()));
      } else {
        encodedBytes = Uint8List.fromList(utf8.encode(_generatePlainTextExport()));
      }

      String? savePath;
      if (plat.isDesktop) {
        savePath = await FilePicker.saveFile(
          dialogTitle: 'Exporter la discussion CrisperWeaver',
          fileName: defaultFileName,
          type: FileType.custom,
          allowedExtensions: [ext],
          bytes: encodedBytes,
        );
      } else {
        final docsDir = await getApplicationDocumentsDirectory();
        final exportDir = Directory(p.join(docsDir.path, 'CrisperWeaver', 'Exports'));
        if (!await exportDir.exists()) await exportDir.create(recursive: true);
        savePath = p.join(exportDir.path, defaultFileName);
        final file = File(savePath);
        await file.writeAsBytes(encodedBytes);
      }

      if (savePath != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Discussion exportée avec succès (${p.basename(savePath)})'),
            action: SnackBarAction(
              label: 'Ouvrir',
              onPressed: () {
                launchUrl(Uri.file(savePath!));
              },
            ),
            backgroundColor: Colors.teal.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur lors de l\'exportation : $e')),
        );
      }
    }
  }

  void _showExportDiscussionDialog() {
    if (_messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La discussion est vide : posez une question avant d\'exporter.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.file_download_outlined, color: Colors.tealAccent),
            SizedBox(width: 8),
            Text('Exporter la Discussion'),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Exportez l\'ensemble de l\'échange avec l\'IA (${_messages.length} messages) ainsi que la liste des documents joints dans le format de votre choix :',
                  style: TextStyle(fontSize: 12, color: isDark ? Colors.grey.shade300 : Colors.grey.shade700),
                ),
                const SizedBox(height: 14),
                _buildExportFormatOption(
                  ctx: ctx,
                  format: 'pdf',
                  title: 'Document PDF Natif (.pdf)',
                  description: 'Recommandé pour partage & impression : mise en page soignée et paginée.',
                  icon: Icons.picture_as_pdf_outlined,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 8),
                _buildExportFormatOption(
                  ctx: ctx,
                  format: 'docx',
                  title: 'Document Microsoft Word (.docx)',
                  description: 'Recommandé pour modification : compatible Word, Google Docs et LibreOffice.',
                  icon: Icons.article_outlined,
                  color: Colors.blue.shade700,
                ),
                const SizedBox(height: 8),
                _buildExportFormatOption(
                  ctx: ctx,
                  format: 'md',
                  title: 'Format Markdown (.md)',
                  description: 'Idéal pour Obsidian, Notion ou GitHub avec blocs de code et listes.',
                  icon: Icons.text_snippet_outlined,
                  color: Colors.blueAccent,
                ),
                const SizedBox(height: 8),
                _buildExportFormatOption(
                  ctx: ctx,
                  format: 'html',
                  title: 'Page Web Imprimable (.html)',
                  description: 'Mise en page web stylisée avec bulles de dialogue colorées.',
                  icon: Icons.html_outlined,
                  color: Colors.purpleAccent,
                ),
                const SizedBox(height: 8),
                _buildExportFormatOption(
                  ctx: ctx,
                  format: 'txt',
                  title: 'Texte Brut Universel (.txt)',
                  description: 'Format texte standard léger lisible sur n\'importe quel appareil.',
                  icon: Icons.description_outlined,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(height: 8),
                _buildExportFormatOption(
                  ctx: ctx,
                  format: 'json',
                  title: 'Données Structurées (.json)',
                  description: 'Format structuré avec métadonnées, rôles et horodatages précis.',
                  icon: Icons.code,
                  color: Colors.tealAccent,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  Widget _buildExportFormatOption({
    required BuildContext ctx,
    required String format,
    required String title,
    required String description,
    required IconData icon,
    required Color color,
  }) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Navigator.pop(ctx);
        _exportDiscussion(format);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(description, style: TextStyle(fontSize: 10.5, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade500),
          ],
        ),
      ),
    );
  }

  Future<void> _saveToKnowledgeBase(String summaryContent) async {
    final titleController = TextEditingController(
      text: _sources.isNotEmpty
          ? 'Analyse Multi-Sources : ${_sources.first.name}'
          : 'Note IA Multi-Sources (${DateTime.now().day}/${DateTime.now().month})',
    );
    final settings = ref.read(settingsServiceProvider);
    final categories = settings.knowledgeCategories;
    String selectedCategory = categories.first;
    final tagsController = TextEditingController(text: 'documents, analyse, synthèse');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.save_as, color: Colors.blueAccent),
              SizedBox(width: 8),
              Text('Enregistrer dans la Base IA'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: 'Titre de l\'enregistrement',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selectedCategory,
                decoration: const InputDecoration(
                  labelText: 'Catégorie de classement',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: categories
                    .map((cat) => DropdownMenuItem(value: cat, child: Text('📁 $cat')))
                    .toList(),
                onChanged: (val) {
                  if (val != null) {
                    setDlgState(() => selectedCategory = val);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tagsController,
                decoration: const InputDecoration(
                  labelText: 'Tags (séparés par des virgules)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && mounted) {
      final settings = ref.read(settingsServiceProvider);
      final record = await ref.read(aiKnowledgeServiceProvider).saveRecord(
        title: titleController.text.trim().isNotEmpty
            ? titleController.text.trim()
            : 'Synthèse Documentaire',
        category: selectedCategory,
        rawTranscript: _combinedContext,
        aiSummary: summaryContent,
        chatMessages: _messages,
        llmProvider: settings.llmProvider.displayName,
        llmModel: settings.llmModel,
        tags: tagsController.text
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Enregistré dans la base de connaissances IA : "${record.title}"'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _openAiKnowledgeDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AiKnowledgeDialog(
        onRestoreToChat: (AiKnowledgeRecord record) {
          setState(() {
            _sources.clear();
            final docService = ref.read(documentSourceServiceProvider);
            _sources.add(docService.createFromText(
              title: record.title,
              text: record.rawTranscript,
              type: 'restored',
            ));
            _loadedRecordTitle = record.title;

            _messages.clear();
            if (record.aiSummary != null && record.aiSummary!.isNotEmpty) {
              _messages.add(LlmChatMessage(
                role: 'assistant',
                content: '📚 **Synthèse restaurée :**\n\n${record.aiSummary}',
                timestamp: record.createdAt,
              ));
            }
            _messages.addAll(record.chatMessages);
          });
          _rebuildRagIndex();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Document restauré : "${record.title}"'),
              duration: const Duration(seconds: 2),
            ),
          );
        },
      ),
    );
  }

  void _showSettingsDialog() {
    showLlmSettingsDialog(context, ref, onModelChanged: () {
      if (mounted) setState(() {});
    });
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case 'doc':
        return Icons.description;
      case 'sheet':
        return Icons.table_chart;
      case 'slide':
        return Icons.slideshow;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'book':
        return Icons.menu_book;
      case 'image':
        return Icons.image;
      case 'audio':
        return Icons.audio_file;
      case 'clipboard':
        return Icons.paste;
      case 'manual':
        return Icons.edit_note;
      default:
        return Icons.article;
    }
  }

  void _openFullscreenDocChat() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: const Text('📂 Assistant Documents (Plein écran)', style: TextStyle(fontSize: 16)),
            actions: [
              IconButton(
                icon: const Icon(Icons.auto_awesome, color: Colors.amber),
                tooltip: 'Base de Connaissances IA',
                onPressed: _openAiKnowledgeDialog,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Configuration LLM',
                onPressed: _showSettingsDialog,
              ),
            ],
          ),
          body: const SafeArea(
            child: DocumentChatWidget(isFullscreen: true),
          ),
        ),
      ),
    );
  }

  void _resetLlmContextKeepScreen() {
    if (_messages.isEmpty) return;
    setState(() {
      _llmContextCutoffIndex = _messages.length;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🔄 Mémoire LLM réinitialisée au document seul. L\'historique reste affiché pour lecture.'),
        backgroundColor: Colors.blueAccent,
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _clearAllContext() {
    setState(() {
      _sources.clear();
      _messages.clear();
      _llmContextCutoffIndex = 0;
      _currentStreamingText = '';
      _loadedRecordTitle = null;
    });
    _rebuildRagIndex();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🗑️ Contexte, documents et discussion réinitialisés.'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  int get _estimatedDiscussionTokens {
    int charCount = 0;
    if (_isRagMode && _indexedChunks.isNotEmpty) {
      final settings = ref.read(settingsServiceProvider);
      final rawTopK = settings.getModelRagTopK(settings.llmModel);
      final chunkSize = settings.getModelRagChunkSize(settings.llmModel);
      charCount += (rawTopK.clamp(1, 15) * chunkSize * 5.5).round();
    } else {
      charCount += _combinedContext.length;
    }

    final activeMessages = _llmContextCutoffIndex < _messages.length
        ? _messages.sublist(_llmContextCutoffIndex)
        : <LlmChatMessage>[];

    for (final m in activeMessages) {
      charCount += m.content.length;
    }

    charCount += _currentStreamingText.length;
    return (charCount / 3.2).round();
  }

  int get _activeModelMaxTokens {
    final settings = ref.read(settingsServiceProvider);
    return settings.getModelMaxTokens(settings.llmModel);
  }

  String _getActiveModelDisplayName(SettingsService settings) {
    if (settings.llmProvider == LlmProvider.custom && settings.activeCloudProviderId.isNotEmpty) {
      final match = settings.customCloudProviders.where((p) => p.id == settings.activeCloudProviderId).toList();
      if (match.isNotEmpty) {
        final cp = match.first;
        final model = settings.llmModel.isNotEmpty ? settings.llmModel : cp.defaultModel;
        return '☁️ ${cp.name} ($model)';
      }
    }
    final raw = settings.llmModel;
    if (raw.isEmpty) {
      return plat.isAndroid ? 'LiteRT Android' : 'Gemma 4 GPU';
    }
    final regList = LiteRtModelRegistry().models;
    for (final m in regList) {
      if (m.id == raw || m.localPath == raw || (m.localPath != null && p.basename(m.localPath!) == p.basename(raw))) {
        return m.name;
      }
    }
    final base = p.basenameWithoutExtension(raw);
    if (base.isNotEmpty) return base;
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final settings = ref.watch(settingsServiceProvider);

    return Column(
      children: [
        // Top Multi-Source Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
            border: Border(bottom: BorderSide(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Action Buttons Row (scrollable on desktop with mouse drag & wheel)
              ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                  },
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                    if (!widget.isFullscreen) ...[
                      IconButton.filledTonal(
                        icon: const Icon(Icons.open_in_full, size: 16, color: Colors.blueAccent),
                        tooltip: 'Maximiser en plein écran',
                        visualDensity: VisualDensity.compact,
                        onPressed: _openFullscreenDocChat,
                      ),
                      const SizedBox(width: 6),
                    ],

                    // Active LLM Model Badge & Quick Selector (Prominent First Position)
                    InkWell(
                      onTap: _showSettingsDialog,
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.blueGrey.shade900.withValues(alpha: 0.8) : Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.smart_toy, size: 14, color: Colors.blueAccent),
                            const SizedBox(width: 5),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 160),
                              child: Text(
                                _getActiveModelDisplayName(settings),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.blueAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),

                    // Live Token Meter Badge (Real-time Context Memory Monitor)
                    Builder(
                      builder: (bCtx) {
                        final totalTok = _estimatedDiscussionTokens;
                        final maxTok = _activeModelMaxTokens;
                        final usagePercent = maxTok > 0 ? (totalTok / maxTok * 100).round() : 0;
                        final isHighRisk = usagePercent >= 80;
                        final isModerateRisk = usagePercent >= 60 && usagePercent < 80;
                        final badgeColor = isHighRisk
                            ? Colors.redAccent
                            : isModerateRisk
                                ? Colors.amberAccent
                                : Colors.cyanAccent;

                        final displayTotal = totalTok >= 1000 ? '${(totalTok / 1000).toStringAsFixed(1)}K' : '$totalTok';
                        final displayMax = maxTok >= 1000 ? '${(maxTok / 1000).round()}K' : '$maxTok';

                        return Tooltip(
                          message: 'Consommation mémoire en direct :\n'
                              '• Tokens estimés : $totalTok / $maxTok tokens max ($usagePercent%)\n'
                              '${isHighRisk ? "⚠️ Attention : Risque élevé de tronquage ou d'amnésie !" : "🟢 Budget mémoire optimal."}',
                          child: InkWell(
                            onTap: _showSettingsDialog,
                            borderRadius: BorderRadius.circular(15),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: badgeColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(color: badgeColor.withValues(alpha: 0.5), width: 0.8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isHighRisk ? Icons.warning_amber_rounded : Icons.analytics_outlined,
                                    size: 13,
                                    color: badgeColor,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$displayTotal / $displayMax ($usagePercent%)',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: badgeColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 6),

                    // Hybrid Mode Selector (⚡ RAG vs 📖 Complet 128K)
                    Container(
                      height: 30,
                      decoration: BoxDecoration(
                        color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: _isRagMode
                              ? Colors.purpleAccent.withValues(alpha: 0.6)
                              : Colors.blueAccent.withValues(alpha: 0.6),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(15)),
                            onTap: () {
                              setState(() {
                                _ragModeOverride = true;
                                settings.ragModeEnabled = true;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _isRagMode
                                    ? Colors.purpleAccent.withValues(alpha: 0.3)
                                    : Colors.transparent,
                                borderRadius: const BorderRadius.horizontal(left: Radius.circular(15)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.bolt, size: 13, color: _isRagMode ? Colors.purpleAccent : Colors.grey),
                                  const SizedBox(width: 3),
                                  Text(
                                    '⚡ RAG',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: _isRagMode ? FontWeight.bold : FontWeight.normal,
                                      color: _isRagMode ? Colors.purpleAccent : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          InkWell(
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(15)),
                            onTap: () {
                              setState(() {
                                _ragModeOverride = false;
                                settings.ragModeEnabled = false;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: !_isRagMode
                                    ? Colors.blueAccent.withValues(alpha: 0.3)
                                    : Colors.transparent,
                                borderRadius: const BorderRadius.horizontal(right: Radius.circular(15)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.auto_stories, size: 13, color: !_isRagMode ? Colors.blueAccent : Colors.grey),
                                  const SizedBox(width: 3),
                                  Text(
                                    '📖 128K',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: !_isRagMode ? FontWeight.bold : FontWeight.normal,
                                      color: !_isRagMode ? Colors.blueAccent : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),

                    // Thinking mode quick toggle
                    Tooltip(
                      message: settings.getModelThinkingEnabled(settings.llmModel)
                          ? 'Mode Pensée / Raisonnement : Activé\nCliquez pour désactiver le bloc <think> et obtenir des réponses directes.'
                          : 'Mode Pensée / Raisonnement : Désactivé\nCliquez pour réactiver le raisonnement <think>.',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(15),
                        onTap: () {
                          setState(() {
                            final cur = settings.getModelThinkingEnabled(settings.llmModel);
                            settings.setModelThinkingEnabled(settings.llmModel, !cur);
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: settings.getModelThinkingEnabled(settings.llmModel)
                                ? Colors.cyanAccent.withValues(alpha: 0.2)
                                : Colors.grey.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: settings.getModelThinkingEnabled(settings.llmModel)
                                  ? Colors.cyanAccent.withValues(alpha: 0.5)
                                  : Colors.grey.withValues(alpha: 0.3),
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.psychology,
                                size: 13,
                                color: settings.getModelThinkingEnabled(settings.llmModel) ? Colors.cyanAccent : Colors.grey,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                settings.getModelThinkingEnabled(settings.llmModel) ? '🧠 Pensée' : '⚡ Direct',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: settings.getModelThinkingEnabled(settings.llmModel) ? FontWeight.bold : FontWeight.normal,
                                  color: settings.getModelThinkingEnabled(settings.llmModel) ? Colors.cyanAccent : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),

                    // Import file button
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('Importer', style: TextStyle(fontSize: 13)),
                      onPressed: _importFile,
                    ),
                    const SizedBox(width: 6),

                    // RAG Cache Library Button
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.purpleAccent,
                        side: const BorderSide(color: Colors.purpleAccent, width: 0.9),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      icon: const Icon(Icons.auto_stories, size: 16),
                      label: const Text('Bibliothèque', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      onPressed: _openRagLibraryDialog,
                    ),
                    const SizedBox(width: 6),

                    // Paste clipboard button
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      icon: const Icon(Icons.paste, size: 16),
                      label: const Text('Coller', style: TextStyle(fontSize: 13)),
                      onPressed: _pasteFromClipboard,
                    ),
                    const SizedBox(width: 6),

                    // Direct text note button
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      icon: const Icon(Icons.edit_note, size: 16),
                      label: const Text('Écrire', style: TextStyle(fontSize: 13)),
                      onPressed: _showDirectTextInputDialog,
                    ),
                    const SizedBox(width: 8),

                    // AI Knowledge Base
                    IconButton(
                      tooltip: 'Bibliothèque & Base de Connaissances IA',
                      icon: const Icon(Icons.auto_awesome, color: Colors.amber, size: 20),
                      onPressed: _openAiKnowledgeDialog,
                    ),

                    // Export Discussion Button
                    IconButton(
                      tooltip: 'Exporter l\'intégralité de la discussion (Markdown, HTML, TXT, JSON)',
                      icon: const Icon(Icons.file_download_outlined, color: Colors.tealAccent, size: 20),
                      onPressed: _showExportDiscussionDialog,
                    ),

                    // LLM Settings
                    IconButton(
                      tooltip: 'Configuration LLM / Modèles',
                      icon: const Icon(Icons.settings_outlined, size: 20),
                      onPressed: _showSettingsDialog,
                    ),

                    // Reset LLM conversation memory (Keep screen visible)
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Réinitialiser la mémoire du LLM (Conserver l\'historique visible à l\'écran)',
                      icon: const Icon(Icons.restart_alt, color: Colors.cyanAccent, size: 20),
                      onPressed: () {
                        if (_messages.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Aucune question/réponse à détacher.'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        } else {
                          _resetLlmContextKeepScreen();
                        }
                      },
                    ),

                    // Clear all button (Always visible for fast reset)
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Tout vider (Documents et discussion)',
                      icon: const Icon(Icons.delete_sweep, color: Colors.orangeAccent, size: 20),
                      onPressed: () {
                        if (_sources.isEmpty && _messages.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Le contexte et la discussion sont déjà vides.'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        } else {
                          _clearAllContext();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),

              // Loaded Sources Chips Row
              if (_sources.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '${_sources.length} source(s) ($_totalWordCount mots)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_isIndexing) ...[
                      Expanded(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 80,
                              height: 6,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: _indexingProgress > 0 ? _indexingProgress : null,
                                  backgroundColor: Colors.purple.shade900.withValues(alpha: 0.3),
                                  color: Colors.purpleAccent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _indexingTotal > 0
                                    ? 'Indexation : ${(_indexingProgress * 100).toStringAsFixed(0)}% ($_indexingCurrent/$_indexingTotal fragments)'
                                    : 'Indexation RAG en cours...',
                                style: const TextStyle(fontSize: 10, color: Colors.purpleAccent, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else if (_indexedChunks.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: _isRagMode
                              ? Colors.purple.shade900.withValues(alpha: 0.4)
                              : Colors.blue.shade900.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _isRagMode ? Colors.purpleAccent.withValues(alpha: 0.5) : Colors.blueAccent.withValues(alpha: 0.5),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isRagMode ? Icons.bolt : Icons.auto_stories,
                              size: 11,
                              color: _isRagMode ? Colors.purpleAccent : Colors.blueAccent,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _isRagMode
                                  ? 'RAG Prêt : ${_indexedChunks.length} fragments'
                                  : 'Mode 128K actif',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: _isRagMode ? Colors.purpleAccent : Colors.blueAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _sources.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final s = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Chip(
                          avatar: Icon(_getIconForType(s.type), size: 14, color: Colors.blueAccent),
                          label: Text(
                            s.name,
                            style: const TextStyle(fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                          deleteIcon: const Icon(Icons.close, size: 14),
                          onDeleted: () {
                            setState(() {
                              _sources.removeAt(idx);
                            });
                            _rebuildRagIndex();
                          },
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.all(2),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),

        // Chat messages body (Selectable across all messages)
        Expanded(
          child: _messages.isEmpty && !_isStreaming
              ? _buildWelcomeState()
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length + (_isStreaming ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _messages.length && _isStreaming) {
                        final loadingText = _currentStreamingText.isEmpty
                            ? '⏳ *Chargement du modèle en mémoire VRAM & initialisation de la réponse...*'
                            : _currentStreamingText;
                        return _buildAssistantMessage(
                          loadingText,
                          isStreaming: true,
                        );
                      }
                      final msg = _messages[index];
                      final msgWidget = msg.role == 'user'
                          ? _buildUserMessage(msg.content)
                          : _buildAssistantMessage(msg.content, actionPrompt: msg.actionPrompt);

                      if (index == _llmContextCutoffIndex && _llmContextCutoffIndex > 0) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 12),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.blueAccent.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.4)),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.restart_alt, size: 16, color: Colors.blueAccent),
                                  SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      '🔄 Mémoire LLM réinitialisée ici : seul le document joint est transmis à l\'IA (l\'historique au-dessus reste affiché pour lecture).',
                                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            msgWidget,
                          ],
                        );
                      }
                      return msgWidget;
                    },
                  ),
                ),
        ),

        // Quick prompts & MCP tools toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
                PointerDeviceKind.stylus,
              },
              scrollbars: false,
            ),
            child: SingleChildScrollView(
              controller: _chipsScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  // MCP Tools FilterChips
                  FilterChip(
                    avatar: const Icon(Icons.today, size: 14, color: Colors.cyanAccent),
                    label: Text('📅 Date (${McpToolsService.formattedCurrentDate})', style: const TextStyle(fontSize: 10.5)),
                    selected: settings.enableCurrentDateTool,
                    selectedColor: Colors.cyan.shade900.withValues(alpha: 0.4),
                    onSelected: (val) {
                      setState(() {
                        settings.enableCurrentDateTool = val;
                      });
                    },
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    avatar: const Icon(Icons.language, size: 14, color: Colors.lightBlueAccent),
                    label: const Text('🌐 Recherche Web', style: TextStyle(fontSize: 10.5)),
                    selected: settings.enableWebSearchTool,
                    selectedColor: Colors.blue.shade900.withValues(alpha: 0.4),
                    onSelected: (val) {
                      setState(() {
                        settings.enableWebSearchTool = val;
                      });
                    },
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    avatar: const Icon(Icons.mail_outline, size: 14, color: Colors.redAccent),
                    label: const Text('✉️ Gmail MCP', style: TextStyle(fontSize: 10.5)),
                    selected: settings.enableGmailTool,
                    selectedColor: Colors.red.shade900.withValues(alpha: 0.4),
                    onSelected: (val) {
                      setState(() {
                        settings.enableGmailTool = val;
                      });
                    },
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    avatar: const Icon(Icons.palette_outlined, size: 14, color: Colors.pinkAccent),
                    label: const Text('🎨 Image MCP', style: TextStyle(fontSize: 10.5)),
                    selected: settings.enableImageGenTool,
                    selectedColor: Colors.pink.shade900.withValues(alpha: 0.4),
                    onSelected: (val) {
                      setState(() {
                        settings.enableImageGenTool = val;
                      });
                      if (val) {
                        ref.read(mcpToolsServiceProvider).ensureImageServerStarted();
                      }
                    },
                  ),
                  const SizedBox(width: 10),
                  ActionChip(
                    avatar: const Icon(Icons.bookmark_added_rounded, size: 14, color: Colors.amberAccent),
                    label: const Text('📚 Prompts', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
                    backgroundColor: Colors.amber.shade900.withValues(alpha: 0.25),
                    side: BorderSide(color: Colors.amberAccent.withValues(alpha: 0.5)),
                    onPressed: () async {
                      final picked = await PromptLibraryDialog.show(context);
                      if (picked != null) {
                        if (picked.type == PromptType.conversation) {
                          _inputController.text = picked.content;
                        } else {
                          setState(() {});
                        }
                      }
                    },
                  ),
                  if (_sources.isNotEmpty && !_isStreaming) ...[
                    const SizedBox(width: 6),
                    _buildQuickActionChip('📝 Résumer les sources', 'Fais une synthèse claire et structurée des documents fournis.'),
                    const SizedBox(width: 6),
                    _buildQuickActionChip('🔑 Points clés & Idées', 'Extrais les points clés, décisions et idées principales de ces documents.'),
                    const SizedBox(width: 6),
                    _buildQuickActionChip('📊 Données & Chiffres', 'Extrais tous les chiffres, dates et éléments factuels importants sous forme de tableau ou liste.'),
                    const SizedBox(width: 6),
                    _buildQuickActionChip('❓ FAQ / Questions', 'Génère les 5 questions/réponses les plus pertinentes sur ce contenu.'),
                  ],
                ],
              ),
            ),
          ),
        ),

        // Live Context Saturation Warning Banner (> 80% capacity)
        Builder(
          builder: (bCtx) {
            final totalTok = _estimatedDiscussionTokens;
            final maxTok = _activeModelMaxTokens;
            final usagePercent = maxTok > 0 ? (totalTok / maxTok * 100).round() : 0;
            if (usagePercent < 80) return const SizedBox.shrink();

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.amber.shade900.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amberAccent, width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amberAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '⚠️ Contexte saturé à $usagePercent% ($totalTok / $maxTok tokens). Les prochaines questions risquent de déborder.',
                      style: const TextStyle(fontSize: 11, color: Colors.amberAccent, fontWeight: FontWeight.bold),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.amberAccent.withValues(alpha: 0.25),
                      foregroundColor: Colors.amberAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.restart_alt, size: 14),
                    label: const Text('Réinitialiser la mémoire (Garder l\'affichage)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    onPressed: _resetLlmContextKeepScreen,
                  ),
                  const SizedBox(width: 6),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.grey.shade400,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.delete_sweep, size: 14),
                    label: const Text('Tout vider', style: TextStyle(fontSize: 11)),
                    onPressed: _clearAllContext,
                  ),
                ],
              ),
            );
          },
        ),

        // Bottom Input Row
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
            border: Border(top: BorderSide(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Bibliothèque de Prompts & Requêtes types',
                icon: const Icon(Icons.bookmark_added_rounded, color: Colors.amberAccent, size: 22),
                onPressed: () async {
                  final picked = await PromptLibraryDialog.show(context);
                  if (picked != null) {
                    if (picked.type == PromptType.conversation) {
                      _inputController.text = picked.content;
                    } else {
                      setState(() {});
                    }
                  }
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: _inputController,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: _sources.isNotEmpty
                        ? 'Posez une question sur les documents importés...'
                        : 'Importez un document ou posez votre question...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: isDark ? Colors.grey.shade800 : Colors.white,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              if (_isStreaming)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  icon: const Icon(Icons.stop_circle_rounded, size: 18),
                  label: const Text('Arrêter', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  onPressed: _cancelStreaming,
                )
              else
                IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.send, size: 18),
                  onPressed: _sendMessage,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActionChip(String label, String prompt) {
    return ActionChip(
      avatar: const Icon(Icons.bolt, size: 14, color: Colors.amber),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: _isStreaming ? null : () => _sendMessage(prompt),
    );
  }

  Widget _buildWelcomeState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_shared, size: 56, color: Colors.blueAccent),
            const SizedBox(height: 16),
            const Text(
              'Assistant IA Multi-Sources & Documents',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Analysez et synthétisez facilement vos documents, notes et fichiers multimédia.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
            if (_loadedRecordTitle != null) ...[
              const SizedBox(height: 8),
              Chip(
                avatar: const Icon(Icons.bookmark, size: 14, color: Colors.amber),
                label: Text('Restauré : $_loadedRecordTitle'),
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Importer (.docx, .pdf, .epub, .xlsx...)'),
                  onPressed: _importFile,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.paste, size: 16),
                  label: const Text('Coller le presse-papier'),
                  onPressed: _pasteFromClipboard,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_note, size: 16),
                  label: const Text('Écrire une note'),
                  onPressed: _showDirectTextInputDialog,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserMessage(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12, left: 24),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * (widget.isFullscreen ? 0.96 : 0.90),
        ),
        decoration: BoxDecoration(
          color: Colors.blueAccent.shade700,
          borderRadius: BorderRadius.circular(16).copyWith(bottomRight: const Radius.circular(2)),
        ),
        child: SelectableText(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.45),
        ),
      ),
    );
  }

  Widget _buildAssistantMessage(String text, {bool isStreaming = false, String? actionPrompt}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final llm = ref.read(llmServiceProvider);
    final settings = ref.read(settingsServiceProvider);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16, right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * (widget.isFullscreen ? 0.96 : 0.90),
        ),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(16).copyWith(bottomLeft: const Radius.circular(2)),
          border: Border.all(
            color: isStreaming ? Colors.blueAccent.withValues(alpha: 0.5) : Colors.transparent,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_awesome, size: 14, color: Colors.blueAccent),
                const SizedBox(width: 6),
                const Text(
                  'Assistant IA',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueAccent),
                ),
                if (isStreaming) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            MarkdownBody(
              data: text,
              selectable: false,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  fontSize: 14.5,
                  height: 1.5,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                h1: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.blueAccent.shade100 : Colors.blueAccent.shade700,
                ),
                h2: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.blueAccent.shade100 : Colors.blueAccent.shade700,
                ),
                h3: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.cyanAccent.shade100 : Colors.blueAccent,
                ),
                code: TextStyle(
                  backgroundColor: isDark ? Colors.black54 : Colors.grey.shade300,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                codeblockDecoration: BoxDecoration(
                  color: isDark ? Colors.black87 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
                ),
                tableBody: TextStyle(
                  fontSize: 13.5,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
                tableHead: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                ),
                tableBorder: TableBorder.all(
                  color: isDark ? Colors.grey.shade700 : Colors.grey.shade400,
                  width: 1,
                ),
                tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                blockquote: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                ),
                blockquoteDecoration: BoxDecoration(
                  color: isDark ? Colors.grey.shade800.withValues(alpha: 0.5) : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(4),
                  border: const Border(left: BorderSide(color: Colors.blueAccent, width: 4)),
                ),
                listBullet: TextStyle(
                  fontSize: 14.5,
                  color: isDark ? Colors.cyanAccent : Colors.blueAccent,
                ),
              ),
              onTapLink: (text, href, title) {
                if (href != null && href.isNotEmpty) {
                  final uri = Uri.tryParse(href);
                  if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
            if (actionPrompt != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.pinkAccent.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('🎨 Générer avec Traduction IA', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                    onPressed: () => _sendMessage(actionPrompt, false, true, true),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.deepPurpleAccent.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.palette_outlined, size: 16),
                    label: const Text('🎨 Générer sans Traduction (Prompt brut)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                    onPressed: () => _sendMessage(actionPrompt, false, true, false),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: isDark ? Colors.lightBlueAccent : Colors.blueAccent.shade700,
                      side: BorderSide(color: isDark ? Colors.lightBlueAccent : Colors.blueAccent.shade700),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.chat_outlined, size: 16),
                    label: const Text('💬 Répondre en texte', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                    onPressed: () => _sendMessage(actionPrompt, true, false, false),
                  ),
                ],
              ),
            ],
            if (!isStreaming && text.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Copier la réponse',
                    icon: const Icon(Icons.copy, size: 16),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Réponse copiée'), duration: Duration(seconds: 1)),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Enregistrer dans la Base de Connaissances IA',
                    icon: const Icon(Icons.bookmark_add, size: 16, color: Colors.amber),
                    onPressed: () => _saveToKnowledgeBase(text),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
