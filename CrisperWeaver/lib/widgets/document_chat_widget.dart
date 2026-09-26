import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../utils/app_paths.dart';
import 'dart:ui';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../constants/timeout_policy.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/ai_knowledge_record.dart';
import '../models/prompt_item.dart';
import '../services/ai_knowledge_service.dart';
import '../services/document_rag_service.dart';
import '../services/embedding_provider.dart';
import '../services/document_source_service.dart';
import '../services/llm_service.dart';
import '../services/log_service.dart';
import '../services/mcp_tools_service.dart';
import '../services/settings_service.dart';
import '../services/litert_model_registry.dart';
import '../native/crispembed_import.dart' show CrispEmbed;
import '../main.dart' show crispEmbedProvider;
import '../utils/ai_text_disclosure.dart';
import '../utils/file_picker_util.dart';
import '../utils/platform_utils.dart' as plat;
import 'ai_knowledge_dialog.dart';
import 'llm_settings_dialog.dart';
import 'prompt_library_dialog.dart';
import 'rag_library_dialog.dart';
import 'inpaint_editor_dialog.dart';
import 'project_context_dialog.dart';
import 'correction_dialog.dart';
import 'file_paths_dialog.dart';
import 'mcp_library_dialog.dart';
import 'web_media_import_dialog.dart';
import '../services/audiobook_service.dart';
import '../models/audiobook_models.dart';
import '../models/conversation_capsule.dart';
import '../services/conversation_compactor_service.dart';
import 'context_capsule_dialog.dart';
import 'voice_dictation_button.dart';
import 'assistant_voice_settings_dialog.dart';
import '../services/assistant_voice_service.dart';

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
  bool _documentDropHover = false;
  bool _clipboardImageProbeInFlight = false;
  final List<DocumentSourceItem> _sources = [];
  final List<LlmChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _chipsScrollController = ScrollController();
  // ── Recherche dans la conversation (SANS GlobalKey — incompatible avec SelectionArea) ──
  bool   _docShowFind  = false;
  String _docFindQuery = '';
  List<_DocChatMatch> _docFindMatches = [];
  int    _docFindIdx   = -1;
  final TextEditingController _docFindCtrl = TextEditingController();

  bool _isStreaming = false;
  String _currentStreamingText = '';
  StreamSubscription<String>? _streamSub;
  String? _loadedRecordTitle;
  int _llmContextCutoffIndex = 0;
  /// Cache des images décodées : évite base64Decode() à chaque rebuild du streaming.
  final Map<int, Uint8List> _decodedImageCache = {};

  // Hybrid Mode RAG states
  List<DocumentChunk> _indexedChunks = [];
  bool _isIndexing = false;
  double _indexingProgress = 0.0;
  int _indexingCurrent = 0;
  int _indexingTotal = 0;

  /// The retrieval mode actually used in the last RAG query.
  /// Null before any retrieval or when not in RAG mode.
  RagRetrievalMode? _lastRetrievalMode;

  bool? _ragModeOverride;
  bool get _isRagMode => _ragModeOverride ?? ref.read(settingsServiceProvider).ragModeEnabled;

  // ── Mémoire persistante inter-sessions ─────────────────────────────────────
  /// Fragments mémorisés injectés dans le system prompt à chaque message.
  String _memoryContext = '';
  /// true pendant l'extraction LLM des faits de la session.
  bool _isMemorizing = false;
  /// Compteur de réponses IA terminées (non-erreur) — auto-mémorisation à chaque 10.
  /// Réinitialisé par _clearAllContext() uniquement.
  /// _resetLlmContextKeepScreen() ne le remet PAS à zéro.
  int _aiResponseCount = 0;
  /// Nombre de faits actuellement en mémoire (affiché dans l'UI).
  int _memoryFactCount = 0;

  // ── Compactage progressif du contexte (R4-CMP) ─────────────────────────────
  bool? _compactContextEnabledOverride;
  bool get _isCompactContextEnabled =>
      _compactContextEnabledOverride ??
      ref.read(settingsServiceProvider).autoCompactContextDefault;
  bool _compactContextAutoMode = true;
  bool _isCompacting = false;
  Completer<void>? _compactionCompleter;
  ConversationCapsule? _activeCapsule;
  List<ConversationCapsule> _historyCapsules = [];
  int _compactionEpoch = 0;
  String? _compactionError;

  // ── Contexte projets actifs ────────────────────────────────────────────────
  /// Texte formaté des projets actifs, injecté dans le system prompt.
  String _projectContext = '';
  /// Nombre de projets actifs/en pause (pour le badge du bouton).
  int _projectCount = 0;

  // ── Correctifs & leçons apprises ──────────────────────────────────────────
  /// Tous les correctifs formatés — injectés systématiquement dans le system prompt.
  String _correctionsContext = '';
  /// Nombre de correctifs enregistrés (pour le badge du bouton).
  int _correctionCount = 0;

  // ── Fichiers & chemins importants ──────────────────────────────────────────
  /// Chemins de fichiers importants, injectés dans le system prompt.
  String _filesContext = '';
  /// Nombre de fichiers enregistrés (pour le badge du bouton).
  int _fileCount = 0;

  // ── MCPs personnalisés ────────────────────────────────────────────────────
  /// Contexte des MCPs type=prompt actifs, injecté dans le system prompt.
  String _mcpCustomContext = '';
  /// Nombre total de MCPs custom (pour le badge ⚡ MCP).
  int _mcpCustomCount = 0;
  /// Nombre de MCPs custom actifs (pour le badge).
  int _mcpCustomActive = 0;
  /// Liste complète des MCPs custom (pour déclenchement keyword).
  List<McpEntry> _mcpEntries = [];

  // ── Modèles Text-to-Image disponibles (excluant inpainting) ───────────────
  List<String>? _availableImageModels;
  bool _loadingImageModels = false;

  Future<void> _loadImageModels() async {
    if (_loadingImageModels) return;
    _loadingImageModels = true;
    try {
      final models = await ref.read(mcpToolsServiceProvider).listAvailableImageModels();
      if (mounted) {
        setState(() {
          _availableImageModels = models;
          final settings = ref.read(settingsServiceProvider);
          if (models.isNotEmpty && !models.contains(settings.activeImageModel)) {
            settings.activeImageModel = models.first;
          }
        });
      }
    } catch (_) {
    } finally {
      _loadingImageModels = false;
    }
  }

  @override
  bool get wantKeepAlive => true;

  final FocusNode _focusNode = FocusNode();

  // ── Lecture audio TTS des réponses (Voice I/O R1 / R1E) ───────────────────
  final AudioPlayer _voiceIoAudioPlayer = AudioPlayer();
  StreamSubscription<PlayerState>? _voiceIoPlayerSub;
  int _voiceIoGenerationId = 0;
  String? _voiceIoReadingMessageId;
  bool _voiceIoIsSynthesizing = false;
  bool _voiceIoIsPlaying = false;
  bool _isVoiceDictationBusy = false;
  String? _voiceIoCurrentAudioFilePath;

  @override
  void initState() {
    super.initState();
    _loadMemoryContext();
    _loadProjectContext();
    _loadCorrectionsContext();
    _loadFilesContext();
    _loadMcpCustomContext();
    _loadImageModels();
    _loadCompactionState();
    _voiceIoPlayerSub = _voiceIoAudioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        _voiceIoStopAndCleanup();
      }
      if (mounted) {
        final isReallyPlaying = playerState.playing &&
            playerState.processingState != ProcessingState.completed &&
            playerState.processingState != ProcessingState.idle;
        setState(() {
          _voiceIoIsPlaying = isReallyPlaying;
          if (!isReallyPlaying && !_voiceIoIsSynthesizing) {
            _voiceIoReadingMessageId = null;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _voiceIoGenerationId++;
    _voiceIoPlayerSub?.cancel();
    _streamSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _chipsScrollController.dispose();
    _docFindCtrl.dispose();
    _focusNode.dispose();
    _voiceIoAudioPlayer.stop().catchError((_) {});
    _voiceIoAudioPlayer.dispose();
    _voiceIoCleanupTempFile();
    super.dispose();
  }

  Future<void> _loadMemoryContext() async {
    try {
      // Récupérer le nombre total de faits pour le badge de la barre d'état
      final statsReq = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:7862/memory/stats'));
      final statsRes = await statsReq.close();
      int factCount = 0;
      if (statsRes.statusCode == 200) {
        final statsBody = await statsRes.transform(utf8.decoder).join();
        factCount = (jsonDecode(statsBody)['total_facts'] as num?)?.toInt() ?? 0;
      }
      if (mounted) {
        setState(() {
          _memoryContext = '';
          _memoryFactCount = factCount;
        });
      }
    } catch (_) {
      // Memory server absent ou injoignable — mode sans mémoire
    }
  }

  // ── Chargement du contexte projets ────────────────────────────────────────

  Future<void> _loadProjectContext() async {
    try {
      final ctxReq = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:7862/projects/context'));
      final ctxRes = await ctxReq.close();
      if (ctxRes.statusCode == 200) {
        final body = await ctxRes.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final ctx = data['context'] as String? ?? '';
        // Nombre de projets pour le badge
        final listReq = await HttpClient()
            .getUrl(Uri.parse('http://127.0.0.1:7862/projects'));
        final listRes = await listReq.close();
        int count = 0;
        if (listRes.statusCode == 200) {
          final listBody = await listRes.transform(utf8.decoder).join();
          count = (jsonDecode(listBody)['count'] as num?)?.toInt() ?? 0;
        }
        if (mounted) {
          setState(() {
            _projectContext = ctx;
            _projectCount   = count;
          });
        }
      }
    } catch (_) {
      // Memory server absent — pas de contexte projets
    }
  }

  // ── Chargement des correctifs & leçons apprises ───────────────────────────

  Future<void> _loadCorrectionsContext() async {
    try {
      final ctxReq = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:7862/corrections/context'));
      final ctxRes = await ctxReq.close();
      if (ctxRes.statusCode == 200) {
        final body = await ctxRes.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final ctx = data['context'] as String? ?? '';
        final listReq = await HttpClient()
            .getUrl(Uri.parse('http://127.0.0.1:7862/corrections'));
        final listRes = await listReq.close();
        int count = 0;
        if (listRes.statusCode == 200) {
          final listBody = await listRes.transform(utf8.decoder).join();
          count = (jsonDecode(listBody)['count'] as num?)?.toInt() ?? 0;
        }
        if (mounted) {
          setState(() {
            _correctionsContext = ctx;
            _correctionCount    = count;
          });
        }
      }
    } catch (_) {}
  }

  // ── Chargement des fichiers & chemins importants ──────────────────────────

  Future<void> _loadFilesContext() async {
    try {
      final ctxReq = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:7862/files/context'));
      final ctxRes = await ctxReq.close();
      if (ctxRes.statusCode == 200) {
        final body = await ctxRes.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final ctx = data['context'] as String? ?? '';
        final listReq = await HttpClient()
            .getUrl(Uri.parse('http://127.0.0.1:7862/files'));
        final listRes = await listReq.close();
        int count = 0;
        if (listRes.statusCode == 200) {
          final listBody = await listRes.transform(utf8.decoder).join();
          count = (jsonDecode(listBody)['count'] as num?)?.toInt() ?? 0;
        }
        if (mounted) setState(() { _filesContext = ctx; _fileCount = count; });
      }
    } catch (_) {}
  }

  // ── Chargement des MCPs personnalisés ─────────────────────────────────────

  Future<void> _loadMcpCustomContext() async {
    try {
      // Contexte type=prompt pour injection system prompt
      final ctxReq = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:7862/mcps/context'));
      final ctxRes = await ctxReq.close();
      String ctx = '';
      if (ctxRes.statusCode == 200) {
        final body = await ctxRes.transform(utf8.decoder).join();
        ctx = (jsonDecode(body) as Map<String, dynamic>)['context'] as String? ?? '';
      }
      // Liste complète pour keyword-trigger + badges
      final listReq = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:7862/mcps'));
      final listRes = await listReq.close();
      List<McpEntry> entries = [];
      int total = 0;
      int active = 0;
      if (listRes.statusCode == 200) {
        final listBody = await listRes.transform(utf8.decoder).join();
        final data = jsonDecode(listBody) as Map<String, dynamic>;
        entries = (data['mcps'] as List? ?? [])
            .map((e) => McpEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        total  = entries.length;
        active = entries.where((e) => e.enabled).length;
      }
      if (mounted) {
        setState(() {
          _mcpCustomContext = ctx;
          _mcpCustomCount   = total;
          _mcpCustomActive  = active;
          _mcpEntries       = entries;
        });
      }
    } catch (_) {}
  }

  // ── Mémorisation — point d'entrée unique ─────────────────────────────────
  //
  // [messages]           : snapshot EXPLICITE passé par l'appelant
  //                        (jamais _messages directement pour les appels async)
  // [showSuccessSnackBar]: true → bouton manuel ; false → auto silencieux
  //
  // Trois appelants :
  //   1. Bouton Mémorise : _memorize(List.of(_messages), showSuccessSnackBar: true)
  //   2. Auto (10 réponses) : unawaited(_memorize(List.of(_messages)))
  //   3. Tout vider       : unawaited(_memorize(snapshot)) — snapshot pré-clear

  Future<void> _memorize(
    List<LlmChatMessage> messages, {
    bool showSuccessSnackBar = false,
  }) async {
    if (messages.isEmpty || _isMemorizing) return;
    if (mounted) setState(() => _isMemorizing = true);

    try {
      // Construire le texte de conversation depuis le snapshot fourni
      final sb = StringBuffer();
      for (final msg in messages) {
        if (msg.role == 'system') continue;
        final prefix = msg.role == 'user' ? 'Utilisateur' : 'Assistant';
        sb.writeln('$prefix : ${msg.content.length > 800 ? msg.content.substring(0, 800) + "…" : msg.content}');
        sb.writeln();
      }
      final conversation = sb.toString().trim();
      if (conversation.isEmpty) {
        if (mounted) setState(() => _isMemorizing = false);
        return;
      }

      final settings = ref.read(settingsServiceProvider);
      final llm      = ref.read(llmServiceProvider);
      final endpoint = (settings.llmApiUrl.isNotEmpty ? settings.llmApiUrl : llm.endpoint)
          .replaceFirst(RegExp(r'/v1/?$'), '') + '/v1';

      final bodyStr = jsonEncode({
        'conversation': conversation,
        'endpoint': endpoint,
        'model': settings.llmModel,
      });

      final req = await HttpClient()
          .postUrl(Uri.parse('http://127.0.0.1:7862/memory/extract'));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      final bodyBytes = utf8.encode(bodyStr);
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      final res      = await req.close();
      final respBody = await res.transform(utf8.decoder).join();
      final result   = jsonDecode(respBody) as Map<String, dynamic>;

      if (res.statusCode == 200 && result['status'] == 'ok') {
        final saved = result['facts_saved'] as int? ?? 0;
        await _loadMemoryContext();
        if (showSuccessSnackBar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('🧠 $saved fait${saved > 1 ? "s" : ""} mémorisé${saved > 1 ? "s" : ""} — '
                '${result["summary"] ?? ""}'),
            duration: const Duration(seconds: 4),
            backgroundColor: Colors.deepPurple.shade800,
          ));
        }
      } else {
        // Échec serveur : log toujours, SnackBar seulement si manuel
        Log.instance.w('memory', 'Mémorisation échouée : ${result["message"] ?? ""}');
        if (showSuccessSnackBar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('⚠️ Mémorisation échouée : ${result["message"] ?? "erreur inconnue"}'),
            backgroundColor: Colors.red.shade800,
          ));
        }
      }
    } catch (e) {
      // Serveur injoignable : log silencieux, aucun popup répétitif en auto
      Log.instance.w('memory', 'Auto-mémorisation ignorée (serveur down) : $e');
      if (showSuccessSnackBar && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('⚠️ Memory server injoignable : $e'),
          backgroundColor: Colors.orange.shade800,
        ));
      }
    } finally {
      if (mounted) setState(() => _isMemorizing = false);
    }
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

    // Resolve embedding config once for the whole indexing pass.
    // Routing: crispEmbed → FFI local (dim 384) | lmStudio → HTTP :1234
    final embConfig = EmbeddingProviderConfig.fromSettings(settings, llm);

    // Résoudre l'instance CrispEmbed si le provider est crispEmbed.
    // FIX RACE CONDITION : await .future garantit que le FutureProvider est
    // réellement résolu avant de conclure à une absence. ref.read().value peut
    // retourner null pendant la phase loading même si le GGUF est présent.
    final CrispEmbed? crispEmbedder;
    if (embConfig.provider == EmbeddingProvider.crispEmbed) {
      crispEmbedder = await ref.read(crispEmbedProvider.future);
      if (crispEmbedder == null) {
        Log.instance.w('rag',
            'CrispEmbed: Future résolu à null (GGUF absent ou DLL non chargée). '
            'Indexation sans embeddings vectoriels — mode mots-clés.');
      } else {
        Log.instance.i('rag', 'Indexation via CrispEmbed FFI (dim=${embConfig.dimension})');
      }
    } else {
      crispEmbedder = null;
    }

    final allChunks = <DocumentChunk>[];
    final unindexedChunks = <DocumentChunk>[];

    for (final s in _sources) {
      // 1. Try disk cache first (v2-first policy, legacy only if metadata proves compatibility)
      final cached = await ragService.loadFromCache(
        sourceName: s.name,
        content: s.textContent,
        embConfig: embConfig,
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
        final embeddings = await ragService.fetchEmbeddings(
          texts: texts,
          endpoint: embConfig.endpoint,
          model: embConfig.modelId.isNotEmpty ? embConfig.modelId : null,
          crispEmbedder: crispEmbedder,
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

        // Persist actual embedding dimension after first successful indexing
        if (embeddings.isNotEmpty && embeddings.first.isNotEmpty) {
          final actualDim = embeddings.first.length;
          if (settings.embeddingDimension != actualDim) {
            settings.embeddingDimension = actualDim;
            Log.instance.i('rag',
                'embeddingDimension updated: $actualDim '
                '(provider=${embConfig.provider.name}, model=${embConfig.modelId})');
          }
        }

        // Save successfully indexed chunks to disk cache (v2 format, atomic write)
        for (final s in _sources) {
          final sourceChunks = allChunks.where((c) => c.sourceName == s.name).toList();
          if (sourceChunks.isNotEmpty && sourceChunks.every((c) => c.embedding != null)) {
            await ragService.saveChunksToCache(
              sourceName: s.name,
              content: s.textContent,
              embConfig: embConfig,
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

  Future<void> _openWebMediaImportDialog() async {
    await WebMediaImportDialog.show(
      context,
      onImportDocument: (textContent, meta, sourceTitle) {
        final docService = ref.read(documentSourceServiceProvider);
        final item = docService.createFromText(
          title: sourceTitle,
          text: textContent,
          type: 'web_media_subtitles',
        );
        setState(() {
          _sources.add(item);
        });
        _rebuildRagIndex();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Transcription Web importée : $sourceTitle'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      },
    );
  }

  Future<void> _pasteClipboardImageFromShortcut() async {
    if (!Platform.isWindows || _clipboardImageProbeInFlight) return;
    _clipboardImageProbeInFlight = true;
    try {
      final textData = await Clipboard.getData(Clipboard.kTextPlain);
      if (textData?.text?.isNotEmpty == true) return;
      final imageBytes = await _getClipboardImage();
      if (!mounted || imageBytes == null || imageBytes.isEmpty) return;
      await _pasteImageToAI(imageBytes);
    } finally {
      _clipboardImageProbeInFlight = false;
    }
  }

  Future<void> _onDocumentsDropped(DropDoneDetails details) async {
    if (mounted) setState(() => _documentDropHover = false);
    if (details.files.isEmpty) return;
    final docService = ref.read(documentSourceServiceProvider);
    var imported = 0;
    for (final file in details.files) {
      final path = file.path;
      if (path.isEmpty) continue;
      try {
        // Keep drag/drop in the document pipeline.  In particular, dropped
        // images go through DocumentSourceService's OCR branch and become a
        // source/RAG document; clipboard images use the separate Vision flow.
        final item = await docService.parseFile(path);
        if (!mounted) return;
        if (_sources.any((s) => s.name == item.name || s.path == item.path)) {
          continue;
        }
        setState(() => _sources.add(item));
        imported++;
      } catch (e, st) {
        Log.instance.w('document-chat', 'Dropped document import failed',
            fields: {'path': path}, error: e, stack: st);
      }
    }
    if (imported > 0) {
      await _rebuildRagIndex();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$imported document(s) importé(s) et indexé(s).')),
        );
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      // 1. Essai texte d'abord (comportement existant inchangé)
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.trim().isNotEmpty) {
        final docService = ref.read(documentSourceServiceProvider);
        final title = 'Presse-papier (${DateTime.now().hour}h${DateTime.now().minute.toString().padLeft(2, '0')})';
        final item = docService.createFromText(title: title, text: text, type: 'clipboard');
        setState(() { _sources.add(item); });
        _rebuildRagIndex();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Contenu du presse-papier collé (${item.textContent.length} caractères)'),
            duration: const Duration(seconds: 2),
          ));
        }
        return;
      }

      // 2. Essai image (Windows uniquement via PowerShell)
      if (Platform.isWindows) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Lecture de l\'image dans le presse-papier…'),
            duration: Duration(seconds: 2),
          ));
        }
        final imageBytes = await _getClipboardImage();
        if (imageBytes != null) {
          await _pasteImageToAI(imageBytes);
          return;
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Le presse-papier est vide ou ne contient ni texte ni image')),
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

  /// Extrait l'image du presse-papier Windows via PowerShell + System.Windows.Forms.
  Future<Uint8List?> _getClipboardImage() async {
    try {
      final tempPath = p.join(Directory.systemTemp.path,
          'cw_clip_${DateTime.now().millisecondsSinceEpoch}.png');
      const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$img = [System.Windows.Forms.Clipboard]::GetImage()
if ($img -ne $null) {
  $img.Save($env:CW_CLIP_PATH)
  Write-Host "OK"
} else {
  Write-Host "NO_IMAGE"
}
''';
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
        environment: {'CW_CLIP_PATH': tempPath},
      );
      if (result.stdout.toString().trim() == 'OK') {
        final f = File(tempPath);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          await f.delete().catchError((_) {});
          return bytes;
        }
      }
    } catch (e) {
      // Silencieux — on retourne null
    }
    return null;
  }

  /// Affiche un dialog de prévisualisation + question, puis envoie l'image à l'IA vision.
  /// Ouvre un fichier image depuis le disque et lance l'éditeur d'inpainting.
  Future<void> _openImageEditorFromDisk() async {
    RobustFilePick pick;
    try {
      pick = await pickFilesRobust(
        type: FileType.image,
        allowMultiple: false,
        dialogTitle: 'Choisir une image à modifier',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Impossible d\'ouvrir le sélecteur : $e')));
      }
      return;
    }

    if (pick.isEmpty || !mounted) return;

    Uint8List imageBytes;
    try {
      if (pick.hasBytesOnly && pick.fileBytes != null) {
        imageBytes = pick.fileBytes!.first;
      } else {
        final path = pick.localPaths.first;
        imageBytes = await File(path).readAsBytes();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erreur lecture fichier : $e')));
      }
      return;
    }

    if (!mounted) return;
    final settings = ref.read(settingsServiceProvider);
    final resultBytes = await showDialog<Uint8List?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InpaintEditorDialog(
        imageBytes: imageBytes,
        // P2 — restauration des prefs
        savedInpaintModel: settings.activeInpaintModel.isNotEmpty
            ? settings.activeInpaintModel : null,
        savedGenModel: settings.activeImageModel.isNotEmpty
            ? settings.activeImageModel : null,
        // P2 — persistance à la sélection
        onModelChanged: (inpaint, gen) {
          if (inpaint != null) settings.activeInpaintModel = inpaint;
          if (gen != null) settings.activeImageModel = gen;
        },
      ),
    );

    if (resultBytes == null || !mounted) return;

    final base64Result = base64Encode(resultBytes);
    setState(() {
      _messages.add(LlmChatMessage(
        role: 'user',
        content: '🎨 Image modifiée par inpainting',
        imageBase64: base64Result,
        imageMimeType: 'image/png',
      ));
      _messages.add(LlmChatMessage(
        role: 'assistant',
        content: 'Image modifiée avec succès. '
            'Posez vos questions ou envoyez-la à l\'IA pour analyse.',
      ));
    });
    _scrollToBottom();
  }

  Future<void> _pasteImageToAI(Uint8List imageBytes) async {
    if (!mounted) return;
    final promptCtrl = TextEditingController(text: 'Décris cette image en détail.');

    final question = await showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E2130) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            const Icon(Icons.image_search, color: Colors.blueAccent),
            const SizedBox(width: 10),
            const Text('Image depuis le presse-papier'),
          ]),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Aperçu de l'image
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    imageBytes,
                    height: 220,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, size: 48),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Votre question :', style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black87,
                )),
                const SizedBox(height: 6),
                TextField(
                  controller: promptCtrl,
                  maxLines: 3,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Ex: Que vois-tu dans cette image ?',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Annuler'),
            ),
            // Bouton éditeur de masque (inpainting)
            OutlinedButton.icon(
              icon: const Icon(Icons.brush, size: 16, color: Colors.orangeAccent),
              label: const Text('🎨 Masque',
                  style: TextStyle(color: Colors.orangeAccent)),
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.orangeAccent)),
              onPressed: () => Navigator.pop(ctx, '__inpaint__'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.send, size: 16),
              label: const Text('Envoyer à l\'IA'),
              onPressed: () => Navigator.pop(ctx, promptCtrl.text.trim()),
            ),
          ],
        );
      },
    );

    promptCtrl.dispose();
    if (question == null) return;

    // Ouverture de l'éditeur de masque
    if (question == '__inpaint__') {
      if (!mounted) return;
      final settings2 = ref.read(settingsServiceProvider);
      final resultBytes = await showDialog<Uint8List?>(
        context: context,
        barrierDismissible: false,
        builder: (_) => InpaintEditorDialog(
          imageBytes: imageBytes,
          // P2 — restauration des prefs
          savedInpaintModel: settings2.activeInpaintModel.isNotEmpty
              ? settings2.activeInpaintModel : null,
          savedGenModel: settings2.activeImageModel.isNotEmpty
              ? settings2.activeImageModel : null,
          // P2 — persistance à la sélection
          onModelChanged: (inpaint, gen) {
            if (inpaint != null) settings2.activeInpaintModel = inpaint;
            if (gen != null) settings2.activeImageModel = gen;
          },
        ),
      );
      if (resultBytes == null || !mounted) return;
      // Affiche le résultat dans le chat comme un message image
      final base64Result = base64Encode(resultBytes);
      final userMsg = LlmChatMessage(
        role: 'user',
        content: '🎨 Image modifiée par inpainting',
        imageBase64: base64Result,
        imageMimeType: 'image/png',
      );
      final assistantMsg = LlmChatMessage(
        role: 'assistant',
        content: 'Image modifiée avec succès par inpainting. '
            'Vous pouvez continuer à modifier ou poser des questions sur le résultat.',
      );
      setState(() {
        _messages.add(userMsg);
        _messages.add(assistantMsg);
      });
      _scrollToBottom();
      return;
    }

    final userQuestion =
        question.isEmpty ? 'Décris cette image en détail.' : question;
    await _sendVisionMessage(imageBytes: imageBytes, userText: userQuestion);
  }

  /// Envoie un message vision (image + texte) au LLM et streame la réponse.
  Future<void> _sendVisionMessage({
    required Uint8List imageBytes,
    required String userText,
  }) async {
    if (_isStreaming) return;

    // ── B3 — Provider-aware Vision capability guard ──────────────────────────
    // Verify that the currently active model genuinely supports vision
    // (native LM Studio VLM detection, LiteRT vision encoder, etc.)
    // before encoding the image or touching the message history.
    final llm = ref.read(llmServiceProvider);
    final visionCheck = await llm.checkVisionCapability();
    if (!visionCheck.isSupported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.visibility_off, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    visionCheck.reason ??
                        '⚠️ Le modèle "${visionCheck.activeModelId}" ne supporte pas Vision.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 6),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return; // No server call, no history entry, no automatic model switch.
    }
    // ── End of B3 guard ──────────────────────────────────────────────────────

    final base64Img = base64Encode(imageBytes);

    // Message user affiché dans la bulle chat
    final userMsg = LlmChatMessage(
      role: 'user',
      content: userText,
      imageBase64: base64Img,
      imageMimeType: 'image/png',
    );

    setState(() {
      _messages.add(userMsg);
      _isStreaming = true;
      _currentStreamingText = '';
    });
    _scrollToBottom();

    // Prompt système léger pour la vision
    const sysVision = 'Tu es un assistant expert en analyse d\'images. '
        'Décris avec précision ce que tu vois. Réponds en français.';

    final historyForLlm = [
      LlmChatMessage(role: 'system', content: sysVision),
      userMsg,
    ];

    try {
      String full = '';
      await for (final chunk in llm.streamChat(messages: historyForLlm)) {
        if (!mounted) break;
        full += chunk;
        setState(() { _currentStreamingText = full; });
      }

      if (mounted) {
        final assistantMsg = LlmChatMessage(role: 'assistant', content: full);
        setState(() {
          _messages.add(assistantMsg);
          _isStreaming = false;
          _currentStreamingText = '';
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() { _isStreaming = false; _currentStreamingText = ''; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur vision : $e\n(Vérifiez que votre modèle supporte les images)'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 5),
          ),
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
    if (_isVoiceDictationBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Veuillez terminer la dictée vocale avant d\'envoyer le message.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
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
    final mcpTools = ref.read(mcpToolsServiceProvider);

    // 🎨 ROUTAGE COURT-CIRCUIT IMMÉDIAT : GÉNÉRATION D'IMAGES
    // Ne jamais exécuter le RAG, ni le Web, ni Gmail pour une demande d'image !
    if (settings.enableImageGenTool && !forceTextMode) {
      final isExplicit = mcpTools.isExplicitImageCommand(text) || forceImageMode;
      if (isExplicit) {
        final rawImgPrompt = mcpTools.extractImagePrompt(text);
        final activeModelName = settings.activeImageModel.isNotEmpty ? settings.activeImageModel : 'sd1.5-Q4_0.gguf';

        // Preuves de diagnostic journalisées conformément à l'oracle strict
        Log.instance.i('image', '[image] rawPrompt="$rawImgPrompt"');
        Log.instance.i('image', '[image] translationRequested=$allowLlmTranslation');

        String promptToSend = rawImgPrompt;
        if (allowLlmTranslation) {
          setState(() {
            _isStreaming = true;
            _currentStreamingText = '🎨 **Préparation de l\'image...**\n\n'
                '🧠 *Traduction fidèle du prompt avec le modèle de texte...*\n\n'
                '*(Prompt brut : "$rawImgPrompt")*';
          });
          _scrollToBottom();
          try {
            promptToSend = await mcpTools.translateToEnglishPrompt(rawImgPrompt, allowLlm: true, llmService: llm);
            Log.instance.i('image', '[image] translatedPrompt="$promptToSend"');
          } on LlmTranslationException catch (e) {
            Log.instance.w('image', '[image] Échec traduction LLM: ${e.message}');
            if (mounted) {
              final activeTextModel = '${llm.provider.displayName} (${settings.llmModel.isNotEmpty ? settings.llmModel : "défaut"})';
              setState(() {
                _messages.add(LlmChatMessage(
                  role: 'assistant',
                  content: '⚠️ **Échec de la traduction IA du prompt**\n\n'
                      'Le modèle de texte (*$activeTextModel*) n\'a pas pu traduire le prompt :\n'
                      '> *${e.message}*\n\n'
                      '👉 Vous pouvez démarrer/charger votre modèle LLM, ou cliquer ci-dessous sur **🎨 Générer sans Traduction (Prompt brut)** pour lancer l\'image avec votre prompt original.',
                  timestamp: DateTime.now(),
                  actionPrompt: text,
                ));
                _isStreaming = false;
                _currentStreamingText = '';
              });
              _scrollToBottom();
            }
            return;
          } catch (e) {
            Log.instance.w('image', '[image] Erreur inattendue traduction: $e');
            if (mounted) {
              setState(() {
                _messages.add(LlmChatMessage(
                  role: 'assistant',
                  content: '⚠️ **Échec de la traduction IA du prompt**\n\n'
                      'Une erreur est survenue lors de la communication avec le modèle de texte : *$e*.\n\n'
                      '👉 Vous pouvez relancer en mode **🎨 Générer sans Traduction (Prompt brut)** ci-dessous.',
                  timestamp: DateTime.now(),
                  actionPrompt: text,
                ));
                _isStreaming = false;
                _currentStreamingText = '';
              });
              _scrollToBottom();
            }
            return;
          }
        } else {
          Log.instance.i('image', '[image] translatedPrompt=null');
        }

        Log.instance.i('image', '[image] finalPrompt="$promptToSend"');

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
        // Rafraîchir les modèles image disponibles à chaud
        _loadImageModels();
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

    final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
    final maxHistoryMessages = isLiteRt ? 4 : 10;

    final candidateHistory = _llmContextCutoffIndex < _messages.length
        ? _messages.sublist(_llmContextCutoffIndex)
        : <LlmChatMessage>[];

    final validHistory = candidateHistory
        .where((m) =>
            !m.content.startsWith('❌ Erreur') &&
            !m.content.startsWith('⚠️ Aucune') &&
            !m.content.startsWith('⚠️') &&
            !m.content.contains('🎨 **Image générée avec succès') &&
            !m.content.contains('🎨 **Détection d\'intention visuelle'))
        .toList();

    String systemPrompt;

    if (_isRagMode && _indexedChunks.isNotEmpty) {
      // ⚡ MODE RAG : Extraction chirurgicale des extraits les plus pertinents
      final rawTopK = settings.getModelRagTopK(settings.llmModel);
      final modelContextLimit = settings.getModelMaxTokens(settings.llmModel);

      // Calibrage dynamique automatique du budget selon la capacité réelle du modèle
      final responseBudget = (modelContextLimit * 0.25).clamp(500, 2048).toInt();
      final safetyMargin = (modelContextLimit * 0.05).round().clamp(80, 500);

      // Décompte précis des tokens consommés hors RAG
      final userTemplate = settings.activeSystemPromptText;
      final sourceNamesList = _sources.map((s) => '- ${s.name} (${s.type.toUpperCase()})').join('\n');
      final baseSystemTokens = ConversationCompactorService.estimateTextTokens(userTemplate) +
          ConversationCompactorService.estimateTextTokens(sourceNamesList) + 120;

      int convTokens = 0;
      if (_isCompactContextEnabled && _activeCapsule != null) {
        convTokens += ConversationCompactorService.estimateTextTokens(_activeCapsule!.toContextPrompt());
        final capsuleEnd = _activeCapsule!.messageEndIndex;
        final recentMessages = validHistory.where((m) => _messages.indexOf(m) > capsuleEnd);
        for (final m in recentMessages) {
          convTokens += ConversationCompactorService.estimateTextTokens(m.content) + 4;
        }
      } else {
        final recentMessages = validHistory.length > maxHistoryMessages
            ? validHistory.sublist(validHistory.length - maxHistoryMessages)
            : validHistory;
        for (final m in recentMessages) {
          convTokens += ConversationCompactorService.estimateTextTokens(m.content) + 4;
        }
      }

      final currentUserTokens = ConversationCompactorService.estimateTextTokens(text);
      const chatTemplateOverhead = 20;

      final nonRagTotalTokens = baseSystemTokens + convTokens + currentUserTokens + chatTemplateOverhead;
      final maxRagTokens = (modelContextLimit - responseBudget - safetyMargin - nonRagTotalTokens).clamp(0, modelContextLimit);
      final maxContextChars = (maxRagTokens * 2.8).toInt();
      final maxPossibleExtracts = (maxContextChars / 1200).floor().clamp(1, 50);
      final topK = rawTopK.clamp(1, maxPossibleExtracts > 0 ? maxPossibleExtracts : 1);

      final minRel = settings.getModelRagMinRelevance(settings.llmModel);
      final searchMode = settings.getModelRagSearchMode(settings.llmModel);

      // Resolve embedding config — même routing que l'indexation :
      //   crispEmbed → FFI local (dim 384) | lmStudio → HTTP :1234
      final embConfig = EmbeddingProviderConfig.fromSettings(settings, llm);

      // Résoudre l'instance CrispEmbed pour l'encodage de la requête.
      final CrispEmbed? queryCrispEmbedder;
      if (embConfig.provider == EmbeddingProvider.crispEmbed) {
        queryCrispEmbedder = await ref.read(crispEmbedProvider.future);
        if (queryCrispEmbedder == null) {
          Log.instance.w('rag',
              'CrispEmbed: Future résolu à null pour la requête (GGUF absent). '
              'Mode dégradé mots-clés.');
        }
      } else {
        queryCrispEmbedder = null;
      }

      final topChunks = await ragService.retrieveTopChunks(
        query: text,
        chunks: _indexedChunks,
        endpoint: embConfig.endpoint,
        model: embConfig.modelId.isNotEmpty ? embConfig.modelId : null,
        topK: topK,
        minRelevance: minRel,
        mode: searchMode,
        crispEmbedder: queryCrispEmbedder,
      );

      // Capture actual retrieval mode for status bar display
      if (mounted) {
        setState(() {
          _lastRetrievalMode = ragService.lastRetrievalMode;
        });
      }

      final buffer = StringBuffer();
      int accumulatedRagTokens = 0;
      if (topChunks.isNotEmpty) {
        for (int i = 0; i < topChunks.length; i++) {
          final r = topChunks[i];
          final ch = r.chunk;
          final header = '--- EXTRAIT ${i + 1} [Source: ${ch.sourceName}${ch.chapterTitle != null ? ' - ${ch.chapterTitle}' : ''}] (Pertinence: ${(r.score * 100).toStringAsFixed(0)}%) ---\n';
          final chunkTokens = ConversationCompactorService.estimateTextTokens(header + ch.text);
          if (accumulatedRagTokens + chunkTokens > maxRagTokens || buffer.length + ch.text.length > maxContextChars) {
            if (i == 0 && maxRagTokens > 80) {
              final allowedChars = (maxRagTokens * 2.5).toInt() - header.length;
              if (allowedChars > 150 && allowedChars < ch.text.length) {
                buffer.writeln(header.trim());
                buffer.writeln(ch.text.substring(0, allowedChars));
                buffer.writeln();
              }
            }
            break;
          }
          buffer.writeln(header.trim());
          buffer.writeln(ch.text);
          buffer.writeln();
          accumulatedRagTokens += chunkTokens;
        }
      } else {
        final fallbackCount = maxPossibleExtracts > 5 ? 5 : 3;
        final fallbackChunks = _indexedChunks.take(fallbackCount).toList();
        for (int i = 0; i < fallbackChunks.length; i++) {
          final ch = fallbackChunks[i];
          final header = '--- EXTRAIT ${i + 1} [Source: ${ch.sourceName}${ch.chapterTitle != null ? ' - ${ch.chapterTitle}' : ''}] ---\n';
          final chunkTokens = ConversationCompactorService.estimateTextTokens(header + ch.text);
          if (accumulatedRagTokens + chunkTokens > maxRagTokens || buffer.length + ch.text.length > maxContextChars) {
            break;
          }
          buffer.writeln(header.trim());
          buffer.writeln(ch.text);
          buffer.writeln();
          accumulatedRagTokens += chunkTokens;
        }
      }

      final ragExtractsText = buffer.toString().trim();

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
    systemPrompt = mcpTools.enrichPromptWithDate(systemPrompt);

    // 🔧 Injection MCPs custom type=prompt (priorité 0 — définitions métier)
    if (_mcpCustomContext.isNotEmpty) {
      systemPrompt += '\n\n$_mcpCustomContext';
    }

    // 📂 Injection contexte projets actifs (priorité 1 — curé explicitement)
    if (_projectContext.isNotEmpty) {
      systemPrompt += '\n\n$_projectContext';
    }

    // 📁 Injection fichiers & chemins importants (priorité 2 — chemins récurrents)
    if (_filesContext.isNotEmpty) {
      systemPrompt += '\n\n$_filesContext';
    }

    // 📋 Injection correctifs & leçons apprises (priorité 3 — pièges connus)
    if (_correctionsContext.isNotEmpty) {
      systemPrompt += '\n\n$_correctionsContext';
    }

    // 🧠 Injection mémoire persistante ciblée par la requête utilisateur (priorité 4)
    String targetedMemory = '';
    try {
      final qEnc = Uri.encodeQueryComponent(text.trim());
      final req = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:7862/memory/recall?q=$qEnc&n=5'))
          .timeout(TimeoutPolicy.memoryRecall);
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final results = (data['results'] as List? ?? []).cast<String>();
        if (results.isNotEmpty) {
          targetedMemory = results.map((r) => '• $r').join('\n');
        }
      }
    } catch (e) {
      // Memory server indisponible ou timeout — log explicite, poursuite normale sans mémoire
      Log.instance.d('chat-memory', 'Rappel mémoire long-terme ignoré (serveur non joignable ou timeout > ${TimeoutPolicy.memoryRecall.inMilliseconds}ms): $e');
    }

    if (targetedMemory.isNotEmpty) {
      systemPrompt += '''

## 🧠 MÉMOIRE LONG-TERME (faits pertinents mémorisés)
Ces informations proviennent de ta mémoire persistante et concernent directement le sujet de la question :
$targetedMemory
''';
    }

    // 🔗 MCPs custom type=http — déclenchement par keyword
    final textLowerMcp = text.toLowerCase();
    for (final mcp in _mcpEntries) {
      if (!mcp.enabled || mcp.type != 'http' || mcp.trigger != 'keyword') continue;
      final matched = mcp.keywords.any((kw) => textLowerMcp.contains(kw.toLowerCase()));
      if (matched && mcp.endpoint.isNotEmpty) {
        try {
          final result = await ref.read(mcpToolsServiceProvider)
              .executeMcpHttp(mcp.toJson(), text);
          if (result.isNotEmpty) {
            systemPrompt += '\n\n### 🔗 ${mcp.name} (MCP HTTP)\n$result';
          }
        } catch (_) {}
      }
    }

    // Strict MCP isolation (MCP-007):
    // 1. Gmail is ONLY invoked if explicitly requested AND enabled.
    // 2. Web search is ONLY invoked if explicitly requested AND enabled.
    // 3. Document / RAG / conversation requests invoke NEITHER Web nor Gmail.
    final hasGmailIntent = mcpTools.isGmailIntent(text);
    final hasWebIntent = mcpTools.isWebSearchIntent(text);

    if (settings.enableGmailTool && hasGmailIntent) {
      final gmailResults = await mcpTools.queryGmail(text);
      systemPrompt += '''

📬 RÉSULTATS RÉELS DU CONNECTEUR GMAIL :
===
$gmailResults
===
DIRECTIVE ABSOLUE POUR L'ASSISTANT :
Les e-mails récents de la boîte Gmail de l'utilisateur ont été récupérés en direct et sont fournis ci-dessus.
Résume, présente ou analyse directement ces courriels (expéditeurs, sujets, dates). Ne dis JAMAIS que tu n'as pas accès à la boîte mail puisque les données sont transmises ci-dessus.''';
    } else if (settings.enableWebSearchTool && hasWebIntent) {
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

    Log.instance.i('chat', 'Envoi message (longueur: ${text.length} car.) | Provider: ${llm.provider.name} | Endpoint: ${llm.endpoint} | Mode RAG: $_isRagMode | Fragments: ${_indexedChunks.length} | Cutoff: $_llmContextCutoffIndex');

    // Concurrency guard : attendre la fin d'un compactage en cours
    if (_isCompacting && _compactionCompleter != null) {
      Log.instance.i('compactor', 'Attente de la fin du compactage avant envoi...');
      await _compactionCompleter!.future;
    }

    List<LlmChatMessage> requestMessages;
    if (_isCompactContextEnabled && _activeCapsule != null) {
      final capsuleEnd = _activeCapsule!.messageEndIndex;
      final recentMessages = validHistory.where((m) {
        final idx = _messages.indexOf(m);
        return idx > capsuleEnd;
      }).toList();
      requestMessages = [
        LlmChatMessage(
          role: 'system',
          content: '$systemPrompt\n\n${_activeCapsule!.toContextPrompt()}',
        ),
        ...recentMessages,
      ];
    } else {
      final recentMessages = validHistory.length > maxHistoryMessages
          ? validHistory.sublist(validHistory.length - maxHistoryMessages)
          : validHistory;
      requestMessages = [
        LlmChatMessage(role: 'system', content: systemPrompt),
        ...recentMessages,
      ];
    }

    // 🛡️ Garde-fou pré-envoi : validation globale contre tout dépassement de capacité
    int totalPreSendTokens = 0;
    for (final m in requestMessages) {
      totalPreSendTokens += ConversationCompactorService.estimateTextTokens(m.content) + 4;
    }
    totalPreSendTokens += 20; // overhead template chat

    final activeModelCapacity = settings.getModelMaxTokens(settings.llmModel);
    if (totalPreSendTokens >= activeModelCapacity) {
      Log.instance.e('chat', 'Garde-fou pré-envoi : payload estimé ($totalPreSendTokens tokens) dépasse la capacité ($activeModelCapacity tokens)');
      if (mounted) {
        setState(() { _isStreaming = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ Requête rejetée : le prompt d\'entrée ($totalPreSendTokens tokens) dépasse la capacité maximale du modèle ($activeModelCapacity tokens). Veuillez raccourcir la discussion ou vider l\'historique.'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 6),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

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
            // ── LiteRT infrastructure errors → SnackBar only ─────────────────
            // LitertServerNotReadyException / LitertRuntimeMissingException are
            // runtime/infrastructure failures, NOT LLM-generated content.
            // They must NOT be stored as assistant messages in the chat history.
            final isLitertInfraError = err is LitertServerNotReadyException ||
                err is LitertRuntimeMissingException;

            setState(() {
              if (!isLitertInfraError) {
                // Regular LLM/network errors: store as assistant message (existing behaviour)
                _messages.add(LlmChatMessage(
                  role: 'assistant',
                  content:
                      '❌ Erreur : $err\n\nVérifiez que le serveur IA '
                      '(${llm.provider.displayName} sur ${llm.endpoint}) est bien démarré.',
                  timestamp: DateTime.now(),
                ));
              }
              _isStreaming = false;
              _currentStreamingText = '';
            });

            if (isLitertInfraError) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('⚠️ Serveur LiteRT non prêt : $err'),
                backgroundColor: Colors.deepOrange.shade700,
                duration: const Duration(seconds: 10),
                action: SnackBarAction(
                  label: 'Fermer',
                  textColor: Colors.white,
                  onPressed: () =>
                      ScaffoldMessenger.of(context).hideCurrentSnackBar(),
                ),
              ));
            }
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
              // ── Auto-mémorisation silencieuse toutes les 10 réponses IA ──
              // Incrément basé sur les réponses non-erreur terminées.
              // _resetLlmContextKeepScreen() ne remet PAS ce compteur à zéro.
              _aiResponseCount++;
              if (_aiResponseCount % 10 == 0) {
                Log.instance.i('memory',
                    'Auto-mémorisation : $_aiResponseCount réponses IA terminées');
                unawaited(_memorize(List.of(_messages)));
              }

              // ── Auto-compactage progressif du contexte (R4-CMP) ──
              if (_isCompactContextEnabled && _compactContextAutoMode) {
                unawaited(_checkAndAutoCompact());
              }

              // ── Auto-TTS Response (AUA-004 / DOC-VOICE-R1B) ──
              final autoTts = ref.read(settingsServiceProvider).autoTtsResponseEnabled;
              final replyText = buffer.toString();
              if (autoTts && replyText.trim().isNotEmpty) {
                final messageId = 'doc_${replyText.hashCode}_${replyText.length}';
                unawaited(_voiceIoReadAloud(messageId, replyText));
              }
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
        final isLitertInfraError =
            e is LitertServerNotReadyException || e is LitertRuntimeMissingException;
        setState(() {
          if (!isLitertInfraError) {
            _messages.add(LlmChatMessage(
              role: 'assistant',
              content: '❌ Erreur de connexion : $e',
              timestamp: DateTime.now(),
            ));
          }
          _isStreaming = false;
          _currentStreamingText = '';
        });
        if (isLitertInfraError) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('⚠️ Serveur LiteRT non prêt : $e'),
            backgroundColor: Colors.deepOrange.shade700,
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: 'Fermer',
              textColor: Colors.white,
              onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
            ),
          ));
        }
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

    final titleFont = getUnicodePdfFont(16, style: PdfFontStyle.bold);
    final subtitleFont = getUnicodePdfFont(9, style: PdfFontStyle.italic);
    final sectionFont = getUnicodePdfFont(11, style: PdfFontStyle.bold);
    final bodyFont = getUnicodePdfFont(9.5);
    final roleFont = getUnicodePdfFont(10, style: PdfFontStyle.bold);

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
        final docsDir = AppPaths.dataDir;
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

  /// Ouvre un dialogue de sauvegarde et copie l'image générée vers la destination choisie.
  Future<void> _saveGeneratedImage(String sourceFilePath) async {
    try {
      String resolvedPath = Uri.decodeComponent(sourceFilePath.trim());
      if (resolvedPath.startsWith('file:///')) {
        try {
          resolvedPath = Uri.parse(resolvedPath).toFilePath(windows: true);
        } catch (_) {
          resolvedPath = resolvedPath.replaceFirst('file:///', '');
        }
      }

      File sourceFile = File(resolvedPath);
      // Fallback résilient : chercher dans le dossier canonique des images générées
      if (!sourceFile.existsSync()) {
        final fallbackPath = p.join(AppPaths.imagesDir.path, p.basename(resolvedPath));
        final fallbackFile = File(fallbackPath);
        if (fallbackFile.existsSync()) {
          sourceFile = fallbackFile;
          resolvedPath = fallbackPath;
        }
      }

      if (!sourceFile.existsSync()) {
        Log.instance.w('image', 'Sauvegarde image impossible : fichier introuvable à "$sourceFilePath" ni dans "${AppPaths.imagesDir.path}"');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('❌ Fichier image introuvable sur le disque.'), backgroundColor: Colors.redAccent),
          );
        }
        return;
      }

      final imageBytes = await sourceFile.readAsBytes();
      final originalName = p.basename(resolvedPath);

      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Sauvegarder l\'image générée',
        fileName: originalName,
        type: FileType.custom,
        allowedExtensions: ['png'],
        bytes: imageBytes,
      );

      if (savePath == null) return; // Annulé par l'utilisateur

      // Sur Windows, FilePicker.saveFile avec bytes écrit déjà le fichier.
      // Si ce n'est pas le cas (plateforme sans écriture auto), on copie manuellement.
      if (!File(savePath).existsSync()) {
        await File(savePath).writeAsBytes(imageBytes);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Image sauvegardée : ${p.basename(savePath)}'),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(label: 'OK', textColor: Colors.white, onPressed: () {}),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Erreur sauvegarde : $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
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
      _compactionEpoch++;
      _activeCapsule = null;
    });
    unawaited(_saveCompactionState());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🔄 Mémoire LLM réinitialisée au document seul. L\'historique reste affiché pour lecture.'),
        backgroundColor: Colors.blueAccent,
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _clearAllContext() {
    _streamSub?.cancel();
    _streamSub = null;

    // ── Snapshot EXPLICITE avant clear ────────────────────────────────────
    // List.of() crée une copie figée — impossible pour _messages.clear()
    // d'en corrompre le contenu après le setState ci-dessous.
    // Mémorisation fire-and-forget : silencieuse (pas de SnackBar),
    // aucun crash si le serveur est down.
    final snapshot = List<LlmChatMessage>.of(_messages);
    if (snapshot.isNotEmpty) {
      Log.instance.i('memory',
          'Mémorisation avant Tout vider — ${snapshot.length} messages');
      unawaited(_memorize(snapshot));  // snapshot passé explicitement, pas _messages
    }

    setState(() {
      _sources.clear();
      _messages.clear();
      _llmContextCutoffIndex = 0;
      _currentStreamingText  = '';
      _loadedRecordTitle     = null;
      _isStreaming           = false;
      _aiResponseCount       = 0;    // reset compteur — Tout vider repart de zéro
      _compactionEpoch++;
      _activeCapsule         = null;
      _historyCapsules.clear();
    });
    unawaited(_saveCompactionState());
    _rebuildRagIndex();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🗑️ Contexte, documents et discussion réinitialisés.'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  int get _estimatedDiscussionTokens {
    final settings = ref.read(settingsServiceProvider);
    final modelMax = settings.getModelMaxTokens(settings.llmModel);

    // 1. En-tête système, instructions de document et connecteurs
    final userTemplate = settings.activeSystemPromptText;
    int fixedTokens = ConversationCompactorService.estimateTextTokens(userTemplate);
    if (_sources.isNotEmpty) {
      final sourceNames = _sources.map((s) => '- ${s.name} (${s.type.toUpperCase()})').join('\n');
      fixedTokens += ConversationCompactorService.estimateTextTokens(sourceNames) + 40;
    }
    if (_mcpCustomContext.isNotEmpty) fixedTokens += ConversationCompactorService.estimateTextTokens(_mcpCustomContext);
    if (_projectContext.isNotEmpty) fixedTokens += ConversationCompactorService.estimateTextTokens(_projectContext);
    if (_filesContext.isNotEmpty) fixedTokens += ConversationCompactorService.estimateTextTokens(_filesContext);
    if (_correctionsContext.isNotEmpty) fixedTokens += ConversationCompactorService.estimateTextTokens(_correctionsContext);
    fixedTokens += 60; // date MCP + consigne thinking

    // 2. Historique conversationnel ou Capsule
    int convTokens = 0;
    if (_isCompactContextEnabled && _activeCapsule != null) {
      convTokens += ConversationCompactorService.estimateTextTokens(_activeCapsule!.toContextPrompt());
      final capsuleEnd = _activeCapsule!.messageEndIndex;
      final activeMessages = _messages.where((m) {
        final idx = _messages.indexOf(m);
        return idx > capsuleEnd && idx >= _llmContextCutoffIndex;
      });
      for (final m in activeMessages) {
        convTokens += ConversationCompactorService.estimateTextTokens(m.content) + 4;
      }
    } else {
      final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
      final maxHistoryMessages = isLiteRt ? 4 : 10;
      final candidateHistory = _llmContextCutoffIndex < _messages.length
          ? _messages.sublist(_llmContextCutoffIndex)
          : <LlmChatMessage>[];
      final activeMessages = candidateHistory.length > maxHistoryMessages
          ? candidateHistory.sublist(candidateHistory.length - maxHistoryMessages)
          : candidateHistory;

      for (final m in activeMessages) {
        convTokens += ConversationCompactorService.estimateTextTokens(m.content) + 4;
      }
    }

    // 3. Document / RAG Tokens
    int docTokens = 0;
    if (_isRagMode && _indexedChunks.isNotEmpty) {
      final responseBudget = (modelMax * 0.25).clamp(500, 2048).toInt();
      final safetyMargin = (modelMax * 0.05).round().clamp(80, 500);
      final remainingRagBudget = (modelMax - responseBudget - safetyMargin - fixedTokens - convTokens).clamp(0, modelMax);

      final rawTopK = settings.getModelRagTopK(settings.llmModel);
      final chunkSize = settings.getModelRagChunkSize(settings.llmModel);
      final estimatedTopKTokens = (rawTopK.clamp(1, 15) * chunkSize * 1.3).round();
      docTokens = estimatedTopKTokens.clamp(0, remainingRagBudget);
    } else {
      docTokens = ConversationCompactorService.estimateTextTokens(_combinedContext);
    }

    final streamingTokens = ConversationCompactorService.estimateTextTokens(_currentStreamingText);

    return fixedTokens + convTokens + docTokens + streamingTokens;
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
    String modelName = raw;
    if (raw.isEmpty) {
      modelName = (settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid)
          ? 'gemma-4-e4b-it'
          : 'Défaut';
    } else {
      final regList = LiteRtModelRegistry().models;
      for (final m in regList) {
        if (m.id == raw || m.localPath == raw || (m.localPath != null && p.basename(m.localPath!) == p.basename(raw))) {
          modelName = m.name;
          break;
        }
      }
      if (modelName == raw) {
        final base = p.basenameWithoutExtension(raw);
        if (base.isNotEmpty) modelName = base;
      }
    }

    final providerPrefix = switch (settings.llmProvider) {
      LlmProvider.liteRtWindows => 'LiteRT',
      LlmProvider.liteRtAndroid => 'LiteRT',
      LlmProvider.lmStudio      => 'LM Studio',
      LlmProvider.ollama        => 'Ollama',
      LlmProvider.custom        => 'Custom',
    };

    return '$providerPrefix · $modelName';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final settings = ref.watch(settingsServiceProvider);

    return DropTarget(
      onDragEntered: (_) {
        if (mounted) setState(() => _documentDropHover = true);
      },
      onDragExited: (_) {
        if (mounted) setState(() => _documentDropHover = false);
      },
      onDragDone: _onDocumentsDropped,
      child: Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final ctrl = HardwareKeyboard.instance.isControlPressed;
        if (ctrl && event.logicalKey == LogicalKeyboardKey.keyV) {
          // Probe only the image clipboard flavor.  Returning ignored is
          // intentional: a focused TextField must retain normal text Ctrl+V
          // semantics (no document source and no Vision dialog for text).
          unawaited(_pasteClipboardImageFromShortcut());
          return KeyEventResult.ignored;
        }
        if (ctrl && event.logicalKey == LogicalKeyboardKey.keyF) {
          setState(() {
            _docShowFind = !_docShowFind;
            if (!_docShowFind) { _docFindQuery=''; _docFindCtrl.clear(); _docFindMatches=[]; _docFindIdx=-1; }
          });
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape && _docShowFind) {
          setState(() { _docShowFind=false; _docFindQuery=''; _docFindCtrl.clear(); _docFindMatches=[]; _docFindIdx=-1; });
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        children: [
        if (_documentDropHover)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6),
            color: Colors.blueAccent.withValues(alpha: 0.12),
            alignment: Alignment.center,
            child: const Text(
              'Déposez pour importer comme document (images : OCR)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
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

                    _buildCompactionControl(isDark),
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

                    // Web Media Import Button (yt-dlp)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent, width: 0.9),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      icon: const Icon(Icons.video_library_outlined, size: 16),
                      label: const Text('Web Media', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      onPressed: _openWebMediaImportDialog,
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

                    // Modifier image depuis le disque
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        side: const BorderSide(color: Colors.orangeAccent, width: 1),
                      ),
                      icon: const Icon(Icons.brush, size: 16, color: Colors.orangeAccent),
                      label: const Text('Modifier', style: TextStyle(fontSize: 13, color: Colors.orangeAccent)),
                      onPressed: _openImageEditorFromDisk,
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
                    // 🔍 Recherche dans la conversation (aussi via Ctrl+F / Échap)
                    IconButton(
                      icon: Icon(
                        _docShowFind ? Icons.search_off : Icons.search,
                        color: _docShowFind ? Colors.amber : null,
                        size: 20,
                      ),
                      tooltip: _docShowFind
                          ? 'Fermer la recherche  (Échap)'
                          : 'Rechercher dans la discussion  (Ctrl+F)',
                      onPressed: () => setState(() {
                        _docShowFind = !_docShowFind;
                        if (!_docShowFind) {
                          _docFindQuery = ''; _docFindCtrl.clear();
                          _docFindMatches = []; _docFindIdx = -1;
                        }
                      }),
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
                      // RAG status badge — shows actual retrieval mode used
                      Builder(builder: (context) {
                        final mode = _lastRetrievalMode;
                        final isDegraded = mode?.isDegraded ?? false;
                        final badgeColor = isDegraded
                            ? Colors.orange.shade900.withValues(alpha: 0.4)
                            : (_isRagMode
                                ? Colors.purple.shade900.withValues(alpha: 0.4)
                                : Colors.blue.shade900.withValues(alpha: 0.4));
                        final borderColor = isDegraded
                            ? Colors.orange.withValues(alpha: 0.6)
                            : (_isRagMode
                                ? Colors.purpleAccent.withValues(alpha: 0.5)
                                : Colors.blueAccent.withValues(alpha: 0.5));
                        final textColor = isDegraded
                            ? Colors.orange
                            : (_isRagMode ? Colors.purpleAccent : Colors.blueAccent);
                        final iconData = isDegraded
                            ? Icons.warning_amber_rounded
                            : (_isRagMode ? Icons.bolt : Icons.auto_stories);

                        final label = _isRagMode
                            ? (mode != null
                                ? '${mode.label} · ${_indexedChunks.length} frag.'
                                : 'RAG Prêt · ${_indexedChunks.length} frag.')
                            : 'Mode 128K actif';

                        final tooltip = mode?.tooltip ??
                            'Recherche RAG prête — envoyez une question pour démarrer';

                        return Tooltip(
                          message: tooltip,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: badgeColor,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: borderColor, width: 0.8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(iconData, size: 11, color: textColor),
                                const SizedBox(width: 4),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
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

        // ── Barre de recherche (SANS GlobalKey — scroll proportionnel uniquement) ──
        if (_docShowFind) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: const Color(0xFF1A1A2E),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _docFindCtrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'Rechercher dans la discussion…',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    suffixIcon: _docFindQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 14),
                            onPressed: () { _docFindCtrl.clear(); setState(() { _docFindQuery = ''; _docFindMatches = []; _docFindIdx = -1; }); })
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) { setState(() => _docFindQuery = v); _rebuildDocFind(); },
                  onSubmitted: (_) => _navigateDocFind(_docFindIdx + 1),
                ),
              ),
              const SizedBox(width: 6),
              if (_docFindMatches.isNotEmpty) ...[
                Text('${_docFindIdx + 1}/${_docFindMatches.length}',
                    style: const TextStyle(fontSize: 11, color: Colors.white60)),
                const SizedBox(width: 4),
              ] else if (_docFindQuery.isNotEmpty)
                const Text('0 résultat', style: TextStyle(fontSize: 11, color: Colors.white38)),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                onPressed: _docFindIdx > 0 ? () => _navigateDocFind(_docFindIdx - 1) : null,
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                onPressed: _docFindIdx < _docFindMatches.length - 1 ? () => _navigateDocFind(_docFindIdx + 1) : null,
              ),
            ]),
          ),
        ],

        // Chat messages body — _buildUserMessage et _buildAssistantMessage NON modifiés
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
                        return _buildAssistantMessage(loadingText, isStreaming: true);
                      }
                      final msg = _messages[index];
                      // Builders INCHANGÉS — aucun GlobalKey transmis à l'intérieur
                      Widget msgWidget = msg.role == 'user'
                          ? _buildUserMessage(msg)
                          : _buildAssistantMessage(msg.content, actionPrompt: msg.actionPrompt);

                      // Highlight occurrence active : DecoratedBox externe, neutre vis-à-vis
                      // de SelectionArea (pas de GlobalKey, pas de déplacement d'élément).
                      if (_docFindIdx >= 0 &&
                          _docFindIdx < _docFindMatches.length &&
                          _docFindMatches[_docFindIdx].messageIndex == index) {
                        msgWidget = DecoratedBox(
                          position: DecorationPosition.foreground,
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFFF6D00), width: 2.5),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: msgWidget,
                        );
                      }

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
                  // ── ⚡ Chip MCP ─────────────────────────────────────────────────
                  Builder(builder: (chipCtx) {
                    final settings = ref.watch(settingsServiceProvider);
                    final builtinActive = [
                      settings.enableCurrentDateTool,
                      settings.enableWebSearchTool,
                      settings.enableGmailTool,
                      settings.enableImageGenTool,
                    ].where((v) => v).length;
                    final totalActive  = builtinActive + _mcpCustomActive;
                    final totalCount   = 4 + _mcpCustomCount;
                    return ActionChip(
                      avatar: const Icon(Icons.electric_bolt, size: 14, color: Colors.deepPurpleAccent),
                      label: Text(
                        '⚡ MCP $totalActive/$totalCount',
                        style: const TextStyle(fontSize: 10.5, color: Colors.deepPurpleAccent)),
                      backgroundColor: Colors.deepPurple.shade900.withValues(alpha: 0.3),
                      side: BorderSide(color: Colors.deepPurpleAccent.withValues(alpha: 0.5)),
                      tooltip: 'Gérer les outils MCP actifs',
                      onPressed: () async {
                        final changed = await McpLibraryDialog.show(chipCtx);
                        if (changed && mounted) {
                          // Recharger si des toggles built-in ont changé
                          setState(() {});
                          await _loadMcpCustomContext();
                        }
                      },
                    );
                  }),
                  const SizedBox(width: 6),
                  // ── 📝 Chip Contexte ────────────────────────────────────────────
                  ActionChip(
                    avatar: const Icon(Icons.layers, size: 14, color: Colors.tealAccent),
                    label: Text(
                      '📝 Contexte${(_projectCount + _fileCount + _correctionCount) > 0 ? " (${_projectCount + _fileCount + _correctionCount})" : ""}',
                      style: const TextStyle(fontSize: 10.5, color: Colors.tealAccent)),
                    backgroundColor: Colors.teal.shade900.withValues(alpha: 0.25),
                    side: BorderSide(color: Colors.tealAccent.withValues(alpha: 0.4)),
                    tooltip: 'Projets · Fichiers · Correctifs',
                    onPressed: () => _showContextMenu(context),
                  ),
                  const SizedBox(width: 10),
                  // ── 📚 Chip Prompts ────────────────────────────────────────────
                  ActionChip(
                    avatar: const Icon(Icons.bookmark_added_rounded, size: 14, color: Colors.amberAccent),
                    label: const Text('📚 Prompts',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
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
                  const SizedBox(width: 6),
                  // ── 🧠 Chip Mémorise ───────────────────────────────────────────
                  ActionChip(
                    avatar: _isMemorizing
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.purpleAccent))
                        : const Icon(Icons.psychology, size: 14, color: Colors.purpleAccent),
                    label: Text(
                      _isMemorizing
                          ? '⏳ Mémorisation…'
                          : '🧠 Mémorise${_memoryFactCount > 0 ? " ($_memoryFactCount)" : ""}',
                      style: const TextStyle(fontSize: 10.5, color: Colors.purpleAccent)),
                    backgroundColor: Colors.purple.shade900.withValues(alpha: 0.25),
                    side: BorderSide(color: Colors.purpleAccent.withValues(alpha: 0.5)),
                    tooltip: _memoryFactCount > 0
                        ? '$_memoryFactCount faits mémorisés — cliquer pour mémoriser cette session'
                        : 'Mémoriser les faits importants de cette session',
                    onPressed: (_isMemorizing || _messages.isEmpty)
                        ? null
                        : () => unawaited(
                            _memorize(List.of(_messages), showSuccessSnackBar: true)),
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
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(_docShowFind ? Icons.search_off : Icons.search, size: 16),
                    tooltip: _docShowFind ? 'Fermer la recherche' : 'Rechercher dans la discussion',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() {
                      _docShowFind = !_docShowFind;
                      if (!_docShowFind) {
                        _docFindQuery = ''; _docFindCtrl.clear();
                        _docFindMatches = []; _docFindIdx = -1;
                      }
                    }),
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
              const SizedBox(width: 4),
              AutoTtsToggleButton(
                isAudioPlaying: _voiceIoIsPlaying,
                isSynthesizing: _voiceIoIsSynthesizing,
                onStopRequested: _stopReadingAloudDocument,
              ),
              const SizedBox(width: 2),
              VoiceDictationButton(
                controller: _inputController,
                enabled: !_isStreaming,
                onRecordingStarted: _stopReadingAloudDocument,
                onBusyChanged: (busy) {
                  if (busy) _stopReadingAloudDocument();
                  if (mounted) setState(() => _isVoiceDictationBusy = busy);
                },
              ),
              const SizedBox(width: 4),
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
                  onPressed: _isVoiceDictationBusy ? null : _sendMessage,
                ),
            ],
          ),
        ),
      ],         // ferme Column.children
    ),           // ferme child: Column(
    ),           // ferme child: Focus(
    );           // ferme return DropTarget(
  }

  Widget _buildQuickActionChip(String label, String prompt) {
    return ActionChip(
      avatar: const Icon(Icons.bolt, size: 14, color: Colors.amber),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: _isStreaming ? null : () => _sendMessage(prompt),
    );
  }

  // ── Popover Contexte (📝) ─────────────────────────────────────────────────

  Future<void> _showContextMenu(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black38,
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              decoration: BoxDecoration(
                color: Colors.teal.shade900.withValues(alpha: 0.5),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
              child: Row(children: [
                const Icon(Icons.layers, color: Colors.tealAccent, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('📝 Contexte injecté',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  Text(
                    '${_projectCount + _fileCount + _correctionCount} éléments dans le system prompt',
                    style: const TextStyle(fontSize: 10, color: Colors.white60)),
                ])),
                IconButton(icon: const Icon(Icons.close, size: 16, color: Colors.white54),
                  onPressed: () => Navigator.pop(context)),
              ]),
            ),
            // Items
            _ContextMenuRow(
              icon: Icons.folder_special, iconColor: Colors.tealAccent,
              label: 'Projets actifs', badge: _projectCount,
              description: 'Stack tech, statut, notes par projet',
              onTap: () async {
                Navigator.pop(context);
                await ProjectContextDialog.show(context);
                await _loadProjectContext();
              },
            ),
            _ContextMenuRow(
              icon: Icons.folder_open, iconColor: Colors.indigoAccent,
              label: 'Fichiers & Chemins', badge: _fileCount,
              description: 'Chemins récurrents, modèles, configs',
              onTap: () async {
                Navigator.pop(context);
                await FilePathsDialog.show(context);
                await _loadFilesContext();
              },
            ),
            _ContextMenuRow(
              icon: Icons.auto_fix_high, iconColor: Colors.orangeAccent,
              label: 'Correctifs & Leçons', badge: _correctionCount,
              description: 'Pièges connus, correctifs importants',
              onTap: () async {
                Navigator.pop(context);
                await CorrectionDialog.show(context);
                await _loadCorrectionsContext();
              },
              isLast: true,
            ),
          ]),
        ),
      ),
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
                OutlinedButton.icon(
                  icon: const Icon(Icons.video_library_outlined, size: 16, color: Colors.redAccent),
                  label: const Text('Web Media (yt-dlp)'),
                  onPressed: _openWebMediaImportDialog,
                ),
              ],
            ),
          ],
        ),
      ),   // fin Column
    );     // fin Focus — return
  }

  Widget _buildUserMessage(LlmChatMessage msg) {
    // Cache des bytes décodés : même instance Uint8List → Image.memory stable pendant le streaming
    Uint8List? imageBytes;
    if (msg.hasImage) {
      final idx = _messages.indexOf(msg);
      imageBytes = _decodedImageCache.putIfAbsent(
        idx,
        () => base64Decode(msg.imageBase64!),
      );
    }

    // RepaintBoundary : isole cette bulle des repaints causés par le streaming de l'assistant
    return RepaintBoundary(
      child: Align(
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (imageBytes != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    imageBytes,
                    height: 160,
                    fit: BoxFit.contain,
                    // gaplessPlayback évite le flash blanc entre les rebuilds
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, color: Colors.white54, size: 32),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SelectableText(
                msg.content,
                style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _voiceIoCleanupTempFile() {
    if (_voiceIoCurrentAudioFilePath != null) {
      try {
        final f = File(_voiceIoCurrentAudioFilePath!);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      _voiceIoCurrentAudioFilePath = null;
    }
    _voiceIoCleanupTempWavFile();
  }

  void _voiceIoCleanupTempWavFile() {
    try {
      final wavFile = File(p.join(
        AppPaths.tmpDir.path,
        'document_assistant_read_aloud.wav',
      ));
      if (wavFile.existsSync()) wavFile.deleteSync();
    } catch (_) {
      Future<void>.delayed(const Duration(milliseconds: 150), () {
        try {
          final wavFile = File(p.join(
            AppPaths.tmpDir.path,
            'document_assistant_read_aloud.wav',
          ));
          if (wavFile.existsSync()) wavFile.deleteSync();
        } catch (_) {}
      });
    }
  }

  Future<void> _voiceIoStopAndCleanup() async {
    _voiceIoGenerationId++;
    try {
      await _voiceIoAudioPlayer.stop();
    } catch (_) {}
    _voiceIoCleanupTempFile();
  }

  void _stopReadingAloudDocument() {
    unawaited(_voiceIoStopAndCleanup());
    if (mounted) {
      setState(() {
        _voiceIoIsSynthesizing = false;
        _voiceIoIsPlaying = false;
        _voiceIoReadingMessageId = null;
      });
    }
  }

  Future<void> _voiceIoReadAloud(String messageId, String rawText) async {
    if (_voiceIoIsSynthesizing) return;
    if (_voiceIoIsPlaying && _voiceIoReadingMessageId == messageId) {
      await _voiceIoStopAndCleanup();
      if (mounted) {
        setState(() {
          _voiceIoIsPlaying = false;
          _voiceIoReadingMessageId = null;
        });
      }
      return;
    }

    if (_voiceIoIsPlaying) {
      await _voiceIoStopAndCleanup();
    }

    final cleanText = AudiobookService.stripStyleTags(rawText);
    if (cleanText.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Le message ne contient aucun texte à lire.')),
        );
      }
      return;
    }

    final settings = ref.read(settingsServiceProvider);

    // Fallback narrateur legacy si explicitement configuré
    if (settings.voiceIoEngine == 'legacy_narrator') {
      setState(() {
        _voiceIoReadingMessageId = messageId;
        _voiceIoIsSynthesizing = true;
      });

      try {
        final savedConfig = settings.getSpeakerVoiceConfig('narrator');
        AudiobookSpeaker narratorSpeaker;
        if (savedConfig.isNotEmpty) {
          narratorSpeaker = AudiobookSpeaker.fromJson(savedConfig);
          if (settings.defaultNarratorVoice.isNotEmpty &&
              narratorSpeaker.voiceModelName != settings.defaultNarratorVoice) {
            narratorSpeaker = narratorSpeaker.copyWith(
              voiceModelName: settings.defaultNarratorVoice,
            );
          }
        } else {
          narratorSpeaker = AudiobookSpeaker(
            id: 'narrator',
            name: 'Narrateur',
            voiceModelName: settings.defaultNarratorVoice,
          );
        }

        final line = AudiobookLine(
          id: 'doc_msg_${DateTime.now().millisecondsSinceEpoch}',
          speakerId: 'narrator',
          speakerName: 'Narrateur',
          text: cleanText,
        );
        final currentGen = ++_voiceIoGenerationId;
        final svc = ref.read(audiobookServiceProvider);
        final wavBytes = await svc.synthesizeLinesToMemory(
          lines: [line],
          speakers: {'narrator': narratorSpeaker},
        );

        if (!mounted || currentGen != _voiceIoGenerationId) {
          _voiceIoCleanupTempWavFile();
          return;
        }

        final previewFile = File(p.join(
          AppPaths.tmpDir.path,
          'document_assistant_read_aloud.wav',
        ));
        await previewFile.writeAsBytes(wavBytes);

        if (!mounted || currentGen != _voiceIoGenerationId) {
          _voiceIoCleanupTempWavFile();
          return;
        }
        setState(() => _voiceIoIsSynthesizing = false);
        await _voiceIoAudioPlayer.setFilePath(previewFile.path);
        await _voiceIoAudioPlayer.play();
      } catch (e) {
        _voiceIoCleanupTempWavFile();
        if (mounted) {
          setState(() {
            _voiceIoIsSynthesizing = false;
            _voiceIoReadingMessageId = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Erreur de synthèse vocale : $e'),
              backgroundColor: Colors.red.shade800,
            ),
          );
        }
      }
      return;
    }

    // Moteur Assistant Microsoft (OneCore offline + Edge neural online)
    if (settings.voiceIoMode != 'offline_only' && settings.voiceIoOnlineConsent == null) {
      if (!mounted) return;
      await AssistantVoiceSettingsDialog.ensureOnlineConsent(context, settings);
    }

    setState(() {
      _voiceIoReadingMessageId = messageId;
      _voiceIoIsSynthesizing = true;
    });

    final currentGen = ++_voiceIoGenerationId;

    try {
      final voiceSvc = ref.read(assistantVoiceServiceProvider);
      final res = await voiceSvc.synthesize(
        text: cleanText,
        mode: settings.voiceIoMode,
        onlineVoiceId: settings.voiceIoOnlineVoice,
        offlineVoiceId: settings.voiceIoOfflineVoice,
        allowOnline: settings.voiceIoOnlineConsent == true,
      );

      if (!mounted || currentGen != _voiceIoGenerationId) {
        if (res.filePath != null) {
          try {
            File(res.filePath!).deleteSync();
          } catch (_) {}
        }
        return;
      }

      setState(() => _voiceIoIsSynthesizing = false);

      if (!res.isSuccess || res.filePath == null) {
        if (mounted) {
          setState(() => _voiceIoReadingMessageId = null);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(res.errorMessage ?? 'Erreur lors de la synthèse vocale.'),
              backgroundColor: Colors.red.shade800,
            ),
          );
        }
        return;
      }

      if (res.usedOfflineFallback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Voix en ligne inaccessible : repli automatique sur la voix locale.'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      _voiceIoCurrentAudioFilePath = res.filePath;
      await _voiceIoAudioPlayer.setFilePath(res.filePath!);
      await _voiceIoAudioPlayer.play();
    } catch (e) {
      _voiceIoCleanupTempFile();
      if (mounted) {
        setState(() {
          _voiceIoIsSynthesizing = false;
          _voiceIoReadingMessageId = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur de synthèse vocale : $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  Widget _buildAssistantMessage(String text, {bool isStreaming = false, String? actionPrompt}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                if (!isStreaming && text.trim().isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Builder(
                    builder: (context) {
                      final messageId = 'doc_${text.hashCode}_${text.length}';
                      final active = _voiceIoReadingMessageId == messageId;
                      return InkWell(
                        onTap: () => _voiceIoReadAloud(messageId, text),
                        child: _voiceIoIsSynthesizing && active
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                _voiceIoIsPlaying && active
                                    ? Icons.stop_rounded
                                    : Icons.volume_up_rounded,
                                size: 15,
                                color: _voiceIoIsPlaying && active
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey,
                              ),
                      );
                    },
                  ),
                ],
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
              // Images locales (file://) → cliquables pour sauvegarde
              // ignore: deprecated_member_use
              imageBuilder: (uri, title, alt) {
                if (uri.scheme == 'file') {
                  final filePath = uri.toFilePath(windows: true);
                  return GestureDetector(
                    onTap: () => _saveGeneratedImage(filePath),
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(
                            File(filePath),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 48),
                          ),
                        ),
                        // Badge de sauvegarde toujours visible
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Tooltip(
                            message: 'Cliquer pour sauvegarder l\'image',
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.save_alt, color: Colors.white, size: 16),
                                  SizedBox(width: 5),
                                  Text('Sauvegarder', style: TextStyle(color: Colors.white, fontSize: 12)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                // Image réseau normale
                return Image.network(uri.toString(),
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 48));
              },
            ),
            if (actionPrompt != null) ...[
              const SizedBox(height: 12),
              _buildVisualIntentImageModelSelector(settings, isDark),
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
                    onPressed: _isStreaming ? null : () => _sendMessage(actionPrompt, false, true, true),
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
                    onPressed: _isStreaming ? null : () => _sendMessage(actionPrompt, false, true, false),
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
                    onPressed: _isStreaming ? null : () => _sendMessage(actionPrompt, true, false, false),
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
                      Clipboard.setData(ClipboardData(
                          text: AiTextDisclosure.forSummary(text)));
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

  /// Sélecteur compact de modèle d'image pour le panneau de confirmation d'intention visuelle.
  /// - Si plusieurs modèles T2I compatibles existent : dropdown [ modèle actif ▼ ]
  /// - Si un seul modèle disponible : affichage simple "Modèle image : 'nom'" sans dropdown
  /// - Exclut strictement tout modèle d'inpainting (filtré en amont par listAvailableImageModels)
  /// - Persiste directement dans settings.activeImageModel
  Widget _buildVisualIntentImageModelSelector(SettingsService settings, bool isDark) {
    if (_availableImageModels == null && !_loadingImageModels) {
      _loadImageModels();
    }

    final models = _availableImageModels;
    final activeModel = settings.activeImageModel;

    // Cas 1 : Plusieurs modèles T2I compatibles -> Dropdown interactif
    if (models != null && models.length > 1) {
      final currentSelected = models.contains(activeModel) ? activeModel : models.first;
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? Colors.black38 : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark ? Colors.pinkAccent.withValues(alpha: 0.3) : Colors.pinkAccent.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined, size: 15, color: Colors.pinkAccent),
            const SizedBox(width: 6),
            Text(
              'Modèle image : ',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.grey.shade300 : Colors.grey.shade800,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: currentSelected,
                isDense: true,
                dropdownColor: isDark ? Colors.grey.shade900 : Colors.white,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.pinkAccent.shade100 : Colors.pinkAccent.shade700,
                ),
                icon: const Icon(Icons.arrow_drop_down, size: 18, color: Colors.pinkAccent),
                items: models.map((m) {
                  return DropdownMenuItem<String>(
                    value: m,
                    child: Text(m, overflow: TextOverflow.ellipsis),
                  );
                }).toList(),
                onChanged: (newVal) {
                  if (newVal != null && newVal != settings.activeImageModel) {
                    setState(() {
                      settings.activeImageModel = newVal;
                    });
                  }
                },
              ),
            ),
          ],
        ),
      );
    }

    // Cas 2 : Un seul modèle disponible -> affichage texte simple sans dropdown
    if (models != null && models.length == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined, size: 15, color: Colors.pinkAccent),
            const SizedBox(width: 6),
            Text(
              'Modèle image : ',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.grey.shade300 : Colors.grey.shade800,
              ),
            ),
            Text(
              models.first,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.pinkAccent.shade100 : Colors.pinkAccent.shade700,
              ),
            ),
          ],
        ),
      );
    }

    // Cas 3 : 0 modèle disponible -> message d'avertissement clair
    if (models != null && models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded, size: 15, color: Colors.amberAccent),
            const SizedBox(width: 6),
            Text(
              'Aucun modèle de génération d’image disponible',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.amberAccent.shade100 : Colors.amber.shade800,
              ),
            ),
          ],
        ),
      );
    }

    // Cas 4 : Détection initiale en cours (models == null)
    final displayModel = activeModel.isNotEmpty ? activeModel : 'sd1.5-Q4_0.gguf';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_outlined, size: 15, color: Colors.pinkAccent),
          const SizedBox(width: 6),
          Text(
            'Modèle image : ',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade800,
            ),
          ),
          Text(
            displayModel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  // ── Recherche dans la conversation — SANS GlobalKey (incompatible SelectionArea) ─

  void _rebuildDocFind() {
    if (_docFindQuery.isEmpty || _messages.isEmpty) {
      setState(() { _docFindMatches = []; _docFindIdx = -1; });
      return;
    }
    final regex = _docChatRegex(_docFindQuery);
    final found = <_DocChatMatch>[];
    for (int i = 0; i < _messages.length; i++) {
      for (final m in regex.allMatches(_messages[i].content)) {
        found.add(_DocChatMatch(messageIndex: i, charStart: m.start, charEnd: m.end));
      }
    }
    setState(() { _docFindMatches = found; _docFindIdx = found.isEmpty ? -1 : 0; });
    if (found.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToDocFind());
    }
  }

  void _navigateDocFind(int newIdx) {
    if (_docFindMatches.isEmpty) return;
    setState(() => _docFindIdx = newIdx.clamp(0, _docFindMatches.length - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToDocFind());
  }

  /// Scroll proportionnel uniquement — pas de GlobalKey (incompatible SelectionArea).
  void _scrollToDocFind() {
    if (!_scrollController.hasClients || _docFindMatches.isEmpty || _docFindIdx < 0) return;
    final msgIdx = _docFindMatches[_docFindIdx].messageIndex;
    final fraction = _messages.length <= 1 ? 0.0 : msgIdx / (_messages.length - 1);
    final target = (_scrollController.position.maxScrollExtent * fraction)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(target,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  static RegExp _docChatRegex(String q) {
    if (q.contains('*') || q.contains('?')) {
      final buf = StringBuffer();
      for (final c in q.split('')) {
        if (c == '*') buf.write('.*');
        else if (c == '?') buf.write('.');
        else buf.write(RegExp.escape(c));
      }
      return RegExp(buf.toString(), caseSensitive: false);
    }
    return RegExp(RegExp.escape(q), caseSensitive: false);
  }

  // ── Compactage progressif du contexte conversationnel (R4-CMP) ───────────

  Future<void> _loadCompactionState() async {
    try {
      final compactor = ref.read(conversationCompactorServiceProvider);
      final session = await compactor.loadCompactionState('default_doc_session');
      if (session != null && mounted) {
        setState(() {
          _compactionEpoch = session.epoch;
          _activeCapsule = session.activeCapsule;
          _historyCapsules = List.from(session.history);
        });
      }
    } catch (e) {
      Log.instance.w('compactor', 'Impossible de charger l\'état de compactage : ');
    }
  }

  Future<void> _saveCompactionState() async {
    try {
      final compactor = ref.read(conversationCompactorServiceProvider);
      final session = CompactionSessionState(
        conversationId: 'default_doc_session',
        epoch: _compactionEpoch,
        activeCapsule: _activeCapsule,
        history: _historyCapsules,
        lastUpdated: DateTime.now(),
      );
      await compactor.saveCompactionStateAtomically(session);
    } catch (e) {
      Log.instance.w('compactor', 'Impossible de sauvegarder l\'état de compactage : ');
    }
  }

  Future<void> _checkAndAutoCompact() async {
    if (!_isCompactContextEnabled || !_compactContextAutoMode || _isCompacting) return;
    if (_messages.length < 6) return;

    final compactor = ref.read(conversationCompactorServiceProvider);
    final modelMax = _activeModelMaxTokens;
    final budget = compactor.computeBudget(
      modelMaxTokens: modelMax,
      systemPromptTokens: 300,
      docOrRagTokens: _isRagMode ? (modelMax * 0.4).round() : (_combinedContext.length / 3.2).round(),
    );

    final currentTokens = _estimatedDiscussionTokens;
    final uncompactedStart = _activeCapsule != null ? _activeCapsule!.messageEndIndex + 1 : _llmContextCutoffIndex;
    final uncompactedCount = _messages.length - uncompactedStart;

    if (budget.shouldTriggerAutoCompaction(currentTokens) || uncompactedCount >= 14) {
      Log.instance.i('compactor', 'Auto-compactage déclenché : tokens=$currentTokens (seuil=${budget.triggerThresholdTokens}), non-compactés=$uncompactedCount');
      await _triggerCompaction(isManual: false);
    }
  }

  Future<void> _triggerCompaction({bool isManual = false}) async {
    if (_isCompacting) return;

    final uncompactedStart = _activeCapsule != null ? _activeCapsule!.messageEndIndex + 1 : _llmContextCutoffIndex;
    if (_messages.length - uncompactedStart < 3) {
      if (isManual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ℹ️ Historique récent trop court pour être compacté.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() {
      _isCompacting = true;
      _compactionCompleter = Completer<void>();
      _compactionError = null;
    });

    try {
      final settings = ref.read(settingsServiceProvider);
      final llm = ref.read(llmServiceProvider);
      final compactor = ref.read(conversationCompactorServiceProvider);
      final modelMax = _activeModelMaxTokens;

      final budget = compactor.computeBudget(
        modelMaxTokens: modelMax,
        systemPromptTokens: 300,
        docOrRagTokens: _isRagMode ? (modelMax * 0.4).round() : (_combinedContext.length / 3.2).round(),
      );

      final partition = compactor.partitionHistory(
        allMessages: _messages,
        startIndex: uncompactedStart,
        budget: budget,
      );

      if (partition.zoneToCompact.isEmpty) {
        if (isManual && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ℹ️ Les messages actuels sont déjà dans la zone récente protégée.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      final newCapsule = await compactor.executeCompaction(
        messagesToCompact: partition.zoneToCompact,
        previousCapsule: _activeCapsule,
        cutoffEpoch: _compactionEpoch,
        llmService: llm,
        settings: settings,
        budget: budget,
      );

      if (newCapsule != null && mounted) {
        setState(() {
          _activeCapsule = newCapsule;
          _historyCapsules.add(newCapsule);
        });
        await _saveCompactionState();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✨ Contexte compacté (Capsule v${newCapsule.version} : +${newCapsule.tokensSaved} tokens préservés)'),
              backgroundColor: Colors.teal.shade700,
              duration: const Duration(seconds: 3),
              action: SnackBarAction(
                label: 'Voir',
                textColor: Colors.white,
                onPressed: () => _showCapsuleDialog(),
              ),
            ),
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _compactionError = 'Échec de génération de la capsule par le modèle.';
          });
          if (isManual) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('⚠️ Échec du compactage : réponse du modèle invalide ou non structurée.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          }
        }
      }
    } catch (e) {
      Log.instance.w('compactor', 'Erreur lors du compactage : ');
      if (mounted) {
        setState(() {
          _compactionError = e.toString();
        });
        if (isManual) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⚠️ Erreur lors du compactage : '),
              backgroundColor: Colors.red.shade700,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCompacting = false;
        });
      }
      _compactionCompleter?.complete();
      _compactionCompleter = null;
    }
  }

  void _showCapsuleDialog() {
    if (_activeCapsule == null) return;
    ContextCapsuleDialog.show(
      context,
      capsule: _activeCapsule!,
      onTriggerManualCompaction: () => _triggerCompaction(isManual: true),
      isCompacting: _isCompacting,
    );
  }

  Widget _buildCompactionControl(bool isDark) {
    final hasCapsule = _activeCapsule != null;
    final isEnabled = _isCompactContextEnabled;

    Color badgeColor;
    Color borderColor;
    String label;
    IconData icon;

    if (_isCompacting) {
      badgeColor = Colors.tealAccent;
      borderColor = Colors.teal;
      label = 'Compactage...';
      icon = Icons.hourglass_top_rounded;
    } else if (hasCapsule) {
      badgeColor = Colors.tealAccent;
      borderColor = Colors.teal.withValues(alpha: 0.8);
      label = 'CMP v';
      icon = Icons.inventory_2_rounded;
    } else if (isEnabled) {
      badgeColor = isDark ? Colors.grey.shade400 : Colors.grey.shade700;
      borderColor = isDark ? Colors.grey.shade700 : Colors.grey.shade400;
      label = _compactContextAutoMode ? 'CMP AUTO' : 'CMP MAN';
      icon = Icons.compress;
    } else {
      badgeColor = Colors.grey.shade500;
      borderColor = Colors.grey.shade700;
      label = 'CMP OFF';
      icon = Icons.compress;
    }

    final tooltip = hasCapsule
        ? 'Compacté v (+ tokens libérés)\nCliquer pour voir la capsule'
        : 'Compactage progressif de contexte\nÉtat : ';

    return PopupMenuButton<String>(
      tooltip: tooltip,
      offset: const Offset(0, 36),
      onSelected: (action) {
        switch (action) {
          case 'view':
            _showCapsuleDialog();
            break;
          case 'compact_now':
            _triggerCompaction(isManual: true);
            break;
          case 'toggle_enabled':
            setState(() {
              _compactContextEnabledOverride = !isEnabled;
            });
            break;
          case 'toggle_auto':
            setState(() {
              _compactContextAutoMode = !_compactContextAutoMode;
            });
            break;
          case 'clear_capsule':
            setState(() {
              _activeCapsule = null;
            });
            unawaited(_saveCompactionState());
            break;
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'view',
          enabled: hasCapsule,
          child: Row(
            children: [
              Icon(Icons.visibility_outlined, size: 16, color: hasCapsule ? Colors.tealAccent : Colors.grey),
              const SizedBox(width: 8),
              Text(hasCapsule ? 'Inspecter la capsule (v)' : 'Aucune capsule active'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'compact_now',
          enabled: !_isCompacting,
          child: const Row(
            children: [
              Icon(Icons.compress, size: 16, color: Colors.teal),
              SizedBox(width: 8),
              Text('Compacter maintenant'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'toggle_enabled',
          child: Row(
            children: [
              Icon(isEnabled ? Icons.check_box_outlined : Icons.check_box_outline_blank, size: 16),
              const SizedBox(width: 8),
              const Text('Compactage activé'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'toggle_auto',
          enabled: isEnabled,
          child: Row(
            children: [
              Icon(_compactContextAutoMode ? Icons.check_box_outlined : Icons.check_box_outline_blank, size: 16),
              const SizedBox(width: 8),
              const Text('Mode automatique'),
            ],
          ),
        ),
        if (hasCapsule) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'clear_capsule',
            child: Row(
              children: [
                Icon(Icons.restart_alt, size: 16, color: Colors.orangeAccent),
                SizedBox(width: 8),
                Text('Réinitialiser la capsule', style: TextStyle(color: Colors.orangeAccent)),
              ],
            ),
          ),
        ],
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isCompacting)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.tealAccent),
              )
            else
              Icon(icon, size: 13, color: badgeColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.bold,
                color: badgeColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocChatMatch {
  final int messageIndex, charStart, charEnd;
  const _DocChatMatch({required this.messageIndex, required this.charStart, required this.charEnd});
}

// ── _ContextMenuRow — ligne d'accès rapide du popover Contexte ───────────────

class _ContextMenuRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final int badge;
  final String description;
  final VoidCallback onTap;
  final bool isLast;

  const _ContextMenuRow({
    required this.icon, required this.iconColor, required this.label,
    required this.badge, required this.description, required this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: isLast
            ? const BorderRadius.vertical(bottom: Radius.circular(12))
            : BorderRadius.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border(bottom: isLast
                ? BorderSide.none
                : BorderSide(color: Colors.white.withValues(alpha: 0.07)))),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: iconColor, size: 16)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              Text(description, style: const TextStyle(fontSize: 10, color: Colors.white54)),
            ])),
            if (badge > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10)),
                child: Text('$badge', style: TextStyle(fontSize: 11, color: iconColor,
                  fontWeight: FontWeight.bold))),
              const SizedBox(width: 4),
            ],
            Icon(Icons.chevron_right, color: Colors.white38, size: 18),
          ]),
        ),
      ),
    );
  }
}
