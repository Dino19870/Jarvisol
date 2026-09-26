import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import '../models/audiobook_models.dart';
import '../services/ai_knowledge_service.dart';
import '../services/audiobook_service.dart';
import '../services/llm_service.dart';
import '../services/settings_service.dart';
import '../services/litert_model_registry.dart';
import '../utils/app_paths.dart';
import '../utils/platform_utils.dart' as plat;
import 'ai_knowledge_dialog.dart';
import 'llm_settings_dialog.dart';
import 'voice_dictation_button.dart';
import 'assistant_voice_settings_dialog.dart';
import '../services/assistant_voice_service.dart';
import '../utils/ai_text_disclosure.dart';

class LlmChatWidget extends ConsumerStatefulWidget {
  final String transcript;
  final bool isFullscreen;
  final bool enableReadAloud;

  const LlmChatWidget({
    super.key,
    required this.transcript,
    this.isFullscreen = false,
    this.enableReadAloud = true,
  });

  @override
  ConsumerState<LlmChatWidget> createState() => _LlmChatWidgetState();
}

class _LlmChatWidgetState extends ConsumerState<LlmChatWidget>
    with AutomaticKeepAliveClientMixin {
  final List<LlmChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isStreaming = false;
  bool _isConnected = false;
  String _currentStreamingText = '';
  StreamSubscription<String>? _streamSub;
  String? _detectedModel;
  String? _activeTranscriptOverride;
  String? _loadedRecordTitle;
  // ── Recherche dans la conversation ──────────────────────────────────────────
  bool   _showFind    = false;
  String _findQuery   = '';
  List<_ChatMatch> _findMatches = [];
  int    _findIdx     = -1;
  final GlobalKey        _findKey  = GlobalKey();
  final TextEditingController _findCtrl = TextEditingController();

  // ── Lecture audio TTS (AUA-004 / VOICE I/O R1E) ───────────────────────────
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _readingMessageId;
  bool _isSynthesizing = false;
  bool _isVoiceDictationBusy = false;
  bool _isPlayingAudio = false;
  int _readAloudGen = 0;
  String? _currentAudioFilePath;

  @override
  bool get wantKeepAlive => true;

  void _cleanupTempAudioFile() {
    if (_currentAudioFilePath != null) {
      try {
        final f = File(_currentAudioFilePath!);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      _currentAudioFilePath = null;
    }
    _cleanupTempWavFile();
  }

  void _cleanupTempWavFile() {
    try {
      final wavFile = File(p.join(AppPaths.tmpDir.path, 'assistant_read_aloud.wav'));
      if (wavFile.existsSync()) {
        wavFile.deleteSync();
      }
    } catch (_) {
      Future.delayed(const Duration(milliseconds: 150), () {
        try {
          final wavFile = File(p.join(AppPaths.tmpDir.path, 'assistant_read_aloud.wav'));
          if (wavFile.existsSync()) {
            wavFile.deleteSync();
          }
        } catch (_) {}
      });
    }
  }

  Future<void> _stopAndCleanup() async {
    _readAloudGen++;
    try {
      await _audioPlayer.stop();
    } catch (_) {}
    _cleanupTempAudioFile();
  }

  void _stopReadingAloud() {
    unawaited(_stopAndCleanup());
    if (mounted) {
      setState(() {
        _isSynthesizing = false;
        _isPlayingAudio = false;
        _readingMessageId = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _checkServerStatus();
    _audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        _stopAndCleanup();
      }
      if (mounted) {
        final isReallyPlaying = playerState.playing &&
            playerState.processingState != ProcessingState.completed &&
            playerState.processingState != ProcessingState.idle;
        setState(() {
          _isPlayingAudio = isReallyPlaying;
          if (!isReallyPlaying && !_isSynthesizing) {
            _readingMessageId = null;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _inputController.dispose();
    _findCtrl.dispose();
    _scrollController.dispose();
    _audioPlayer.stop().catchError((_) {});
    _audioPlayer.dispose();
    _cleanupTempWavFile();
    super.dispose();
  }

  Future<void> _checkServerStatus() async {
    final llm = ref.read(llmServiceProvider);
    try {
      final models = await llm.getAvailableModels();
      if (mounted) {
        setState(() {
          _isConnected = models.isNotEmpty;
          if (models.isNotEmpty) {
            _detectedModel = models.first;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isConnected = false;
        });
      }
    }
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

  Future<void> _sendPrompt(String userText) async {
    if (_isVoiceDictationBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Veuillez terminer la dictée vocale avant d\'envoyer le message.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (userText.trim().isEmpty || _isStreaming) return;
    final text = userText.trim();
    _inputController.clear();

    final userMsg = LlmChatMessage(role: 'user', content: text);
    setState(() {
      _messages.add(userMsg);
      _isStreaming = true;
      _currentStreamingText = '';
    });
    _scrollToBottom();

    final llm = ref.read(llmServiceProvider);
    final systemPrompt = '''Tu es un assistant IA expert intégré dans l'application de transcription CrisperWeaver.
Voici le texte issu de la transcription audio en cours :
---
${widget.transcript.isNotEmpty ? widget.transcript : "(Aucune transcription disponible pour l'instant.)"}
---
Réponds de manière concise, précise, claire et parfaitement structurée en français aux demandes de l'utilisateur basées sur cette transcription.''';

    final requestMessages = [
      LlmChatMessage(role: 'system', content: systemPrompt),
      ..._messages,
    ];

    final stream = llm.streamChat(messages: requestMessages);
    final buffer = StringBuffer();

    _streamSub = stream.listen(
      (chunk) {
        buffer.write(chunk);
        if (mounted) {
          setState(() {
            _currentStreamingText = buffer.toString();
          });
          _scrollToBottom();
        }
      },
      onDone: () {
        if (mounted) {
          final replyText = buffer.toString();
          final assistantMsg = LlmChatMessage(
            role: 'assistant',
            content: replyText,
          );
          setState(() {
            _messages.add(assistantMsg);
            _currentStreamingText = '';
            _isStreaming = false;
          });
          _scrollToBottom();

          // Auto-TTS Response (AUA-004 / DOC-VOICE-R1B)
          final autoTts = ref.read(settingsServiceProvider).autoTtsResponseEnabled;
          if (autoTts && replyText.trim().isNotEmpty) {
            final msgId =
                '${assistantMsg.timestamp.millisecondsSinceEpoch}_${assistantMsg.content.hashCode}';
            unawaited(_readAloud(msgId, replyText));
          }
        }
      },
      onError: (Object e) {
        if (mounted) {
          // ── LiteRT infrastructure errors → SnackBar only ─────────────────
          final isLitertInfraError =
              e is LitertServerNotReadyException || e is LitertRuntimeMissingException;

          setState(() {
            if (!isLitertInfraError) {
              _messages.add(LlmChatMessage(
                role: 'assistant',
                content: "❌ Une erreur est survenue lors de l'échange avec le LLM : $e",
              ));
            }
            _currentStreamingText = '';
            _isStreaming = false;
          });

          if (isLitertInfraError) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('⚠️ Serveur LiteRT non prêt : $e'),
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
    );
  }

  void _showSettingsDialog() {
    showLlmSettingsDialog(context, ref, onModelChanged: () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _openSaveRecordDialog() async {
    final activeTranscript = _activeTranscriptOverride ?? widget.transcript;
    if (activeTranscript.trim().isEmpty && _messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rien à enregistrer : transcription et discussion vides.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final titleController = TextEditingController(
      text: _loadedRecordTitle ?? 'Analyse du ${DateTime.now().day.toString().padLeft(2, '0')}/${DateTime.now().month.toString().padLeft(2, '0')}/${DateTime.now().year} ${DateTime.now().hour.toString().padLeft(2, '0')}h${DateTime.now().minute.toString().padLeft(2, '0')}',
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.save_rounded, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Enregistrer dans la base IA'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Donnez un titre à cet enregistrement pour le retrouver facilement lors de vos recherches.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Titre de la fiche',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );

    if (saved == true && titleController.text.trim().isNotEmpty) {
      final service = ref.read(aiKnowledgeServiceProvider);
      final settings = ref.read(settingsServiceProvider);
      await service.saveRecord(
        title: titleController.text.trim(),
        rawTranscript: activeTranscript,
        chatMessages: _messages,
        llmProvider: settings.llmProvider.displayName,
        llmModel: settings.llmModel.isNotEmpty ? settings.llmModel : (_detectedModel ?? ''),
      );
      setState(() {
        _loadedRecordTitle = titleController.text.trim();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Enregistré avec succès dans la base IA !'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _openSearchKnowledgeDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AiKnowledgeDialog(
        onRestoreToChat: (record) {
          setState(() {
            _activeTranscriptOverride = record.rawTranscript;
            _loadedRecordTitle = record.title;
            _messages.clear();
            _messages.addAll(record.chatMessages);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Fiche "${record.title}" chargée dans l\'Assistant IA.'),
              duration: const Duration(seconds: 2),
            ),
          );
        },
      ),
    );
  }

  void _copyFullChatToClipboard() {
    if (_messages.isEmpty) return;
    final sb = StringBuffer();
    for (final m in _messages) {
      final sender = m.role == 'user' ? '👤 Vous' : '🤖 Assistant IA';
      sb.writeln('### $sender :');
      sb.writeln(m.content);
      sb.writeln();
    }
    Clipboard.setData(
        ClipboardData(text: AiTextDisclosure.forSummary(sb.toString().trim())));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Discussion complète copiée dans le presse-papier !'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _openFullscreenChat() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: const Text('🤖 Assistant Audio (Plein écran)', style: TextStyle(fontSize: 16)),
            actions: [
              IconButton(
                icon: const Icon(Icons.search_rounded),
                tooltip: 'Rechercher dans la base IA',
                onPressed: _openSearchKnowledgeDialog,
              ),
              IconButton(
                icon: const Icon(Icons.save_outlined),
                tooltip: 'Enregistrer dans la base IA',
                onPressed: _openSaveRecordDialog,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Configuration LLM',
                onPressed: _showSettingsDialog,
              ),
            ],
          ),
          body: SafeArea(
            child: LlmChatWidget(
              transcript: _activeTranscriptOverride ?? widget.transcript,
              isFullscreen: true,
              enableReadAloud: widget.enableReadAloud,
            ),
          ),
        ),
      ),
    );
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
    final theme = Theme.of(context);
    final activeTranscript = _activeTranscriptOverride ?? widget.transcript;
    final hasTranscript = activeTranscript.trim().isNotEmpty;
    final settings = ref.watch(settingsServiceProvider);

    return Column(
      children: [
        // Top Toolbar Status
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.isFullscreen) ...[
                  IconButton.filledTonal(
                    icon: const Icon(Icons.open_in_full, size: 16, color: Colors.blueAccent),
                    tooltip: 'Maximiser en plein écran',
                    visualDensity: VisualDensity.compact,
                    onPressed: _openFullscreenChat,
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
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.blueGrey.shade900.withValues(alpha: 0.8)
                          : Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isConnected || settings.llmProvider == LlmProvider.liteRtAndroid || settings.llmProvider == LlmProvider.liteRtWindows
                                ? Colors.greenAccent
                                : Colors.orangeAccent,
                          ),
                        ),
                        const SizedBox(width: 6),
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

                if (_loadedRecordTitle != null) ...[
                  Text(
                    '📂 $_loadedRecordTitle',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 6),
                ],

                IconButton(
                  icon: const Icon(Icons.search_rounded, size: 18),
                  tooltip: 'Rechercher dans la base IA',
                  onPressed: _openSearchKnowledgeDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.save_outlined, size: 18),
                  tooltip: 'Enregistrer dans la base IA',
                  onPressed: _openSaveRecordDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  tooltip: 'Configuration LLM / Modèles',
                  onPressed: _showSettingsDialog,
                ),
                if (_messages.isNotEmpty) ...[
                  IconButton(
                    icon: const Icon(Icons.copy_all_rounded, size: 18),
                    tooltip: 'Copier toute la discussion',
                    onPressed: _copyFullChatToClipboard,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Effacer la discussion',
                    onPressed: () => setState(() {
                      _messages.clear();
                      _loadedRecordTitle = null;
                      _activeTranscriptOverride = null;
                      _findMatches = []; _findIdx = -1;
                    }),
                  ),
                  // 🔍 Recherche dans la conversation
                  IconButton(
                    icon: Icon(_showFind ? Icons.search_off : Icons.search, size: 18),
                    tooltip: _showFind ? 'Fermer la recherche' : 'Rechercher dans la discussion',
                    onPressed: () => setState(() {
                      _showFind = !_showFind;
                      if (!_showFind) { _findQuery = ''; _findCtrl.clear(); _findMatches = []; _findIdx = -1; }
                    }),
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Barre de recherche dans la conversation ──────────────────────
        if (_showFind) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: const Color(0xFF1A1A2E),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _findCtrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'Rechercher dans la discussion…',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    suffixIcon: _findQuery.isNotEmpty
                        ? IconButton(icon: const Icon(Icons.clear, size: 14),
                            onPressed: () { _findCtrl.clear(); setState(() { _findQuery = ''; _findMatches = []; _findIdx = -1; }); })
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) { setState(() => _findQuery = v); _rebuildFind(); },
                  onSubmitted: (_) => _navigateFind(_findIdx + 1),
                ),
              ),
              const SizedBox(width: 6),
              if (_findMatches.isNotEmpty) ...[
                Text('${_findIdx + 1}/${_findMatches.length}',
                    style: const TextStyle(fontSize: 11, color: Colors.white60)),
                const SizedBox(width: 4),
              ] else if (_findQuery.isNotEmpty)
                const Text('0 résultat', style: TextStyle(fontSize: 11, color: Colors.white38)),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                onPressed: _findIdx > 0 ? () => _navigateFind(_findIdx - 1) : null,
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                onPressed: _findIdx < _findMatches.length - 1 ? () => _navigateFind(_findIdx + 1) : null,
              ),
            ]),
          ),
        ],

        // Chat Body
        Expanded(
          child: _messages.isEmpty && _currentStreamingText.isEmpty
              ? _buildEmptyState(hasTranscript)
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length + (_isStreaming ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index < _messages.length) {
                      final bool isActive = _findIdx >= 0 && _findIdx < _findMatches.length &&
                          _findMatches[_findIdx].messageIndex == index;
                      return _buildMessageBubble(
                        _messages[index],
                        key: isActive ? _findKey : null,
                        findQuery: _findQuery,
                        activeStart: isActive ? _findMatches[_findIdx].charStart : null,
                        activeEnd:   isActive ? _findMatches[_findIdx].charEnd   : null,
                      );
                    } else {
                      return _buildStreamingBubble();
                    }
                  },
                ),
        ),

        // Quick suggestions bar
        if (hasTranscript && !_isStreaming)
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildQuickActionChip('🪄 Résumé synthétique', 'Fais-moi un résumé clair et synthétique de cette transcription.'),
                _buildQuickActionChip('📋 Points clés & Décisions', 'Quels sont les points clés et les décisions majeures mentionnés dans cette transcription ?'),
                _buildQuickActionChip('📌 Plan d\'action (To-Do)', 'Extrais la liste des tâches concrètes et des actions à mener d\'après cet enregistrement.'),
                _buildQuickActionChip('🔍 Analyse du ton', 'Analyse le ton, le style et l\'intention du locuteur dans cet enregistrement.'),
              ],
            ),
          ),

        // Input Field
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputController,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: hasTranscript
                        ? 'Posez une question sur cette transcription...'
                        : 'Aucun texte transcrit. Enregistrez ou importez un audio.',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (val) => _sendPrompt(val),
                ),
              ),
              const SizedBox(width: 4),
              AutoTtsToggleButton(
                isAudioPlaying: _isPlayingAudio,
                isSynthesizing: _isSynthesizing,
                onStopRequested: _stopReadingAloud,
              ),
              const SizedBox(width: 2),
              VoiceDictationButton(
                controller: _inputController,
                enabled: !_isStreaming,
                onRecordingStarted: _stopReadingAloud,
                onBusyChanged: (busy) {
                  if (busy) _stopReadingAloud();
                  if (mounted) setState(() => _isVoiceDictationBusy = busy);
                },
              ),
              const SizedBox(width: 4),
              if (_isStreaming)
                IconButton.filled(
                  icon: const Icon(Icons.stop),
                  color: Colors.white,
                  style: IconButton.styleFrom(backgroundColor: Colors.redAccent),
                  onPressed: () {
                    _streamSub?.cancel();
                    setState(() {
                      _isStreaming = false;
                      if (_currentStreamingText.isNotEmpty) {
                        _messages.add(LlmChatMessage(
                          role: 'assistant',
                          content: _currentStreamingText,
                        ));
                        _currentStreamingText = '';
                      }
                    });
                  },
                )
              else
                IconButton.filled(
                  icon: const Icon(Icons.send_rounded),
                  onPressed: _isVoiceDictationBusy
                      ? null
                      : () => _sendPrompt(_inputController.text),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(bool hasTranscript) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              'Assistant IA & Analyse Locale',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              hasTranscript
                  ? 'Interrogez et résumez directement votre enregistrement avec LM Studio ou Ollama.'
                  : 'Commencez par enregistrer ou transcrire un fichier audio pour l\'analyser ici.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            if (hasTranscript) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.summarize_outlined, size: 16),
                    label: const Text('🪄 Résumé de l\'audio'),
                    onPressed: () => _sendPrompt('Fais un résumé clair et structuré de cette transcription.'),
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.checklist, size: 16),
                    label: const Text('📋 Extraire les actions'),
                    onPressed: () => _sendPrompt('Extrais la liste des actions à mener et des points à retenir.'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionChip(String label, String prompt) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        onPressed: () => _sendPrompt(prompt),
      ),
    );
  }

  // ── Lecture audio TTS (AUA-004 / VOICE I/O R1E) ───────────────────────────
  Future<void> _readAloud(String messageId, String rawText) async {
    if (_isSynthesizing) return;
    if (_isPlayingAudio && _readingMessageId == messageId) {
      await _stopAndCleanup();
      if (mounted) {
        setState(() {
          _isPlayingAudio = false;
          _readingMessageId = null;
        });
      }
      return;
    }

    if (_isPlayingAudio) {
      await _stopAndCleanup();
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
        _readingMessageId = messageId;
        _isSynthesizing = true;
      });

      try {
        final savedConfig = settings.getSpeakerVoiceConfig('narrator');
        AudiobookSpeaker narratorSpeaker;
        if (savedConfig.isNotEmpty) {
          narratorSpeaker = AudiobookSpeaker.fromJson(savedConfig);
          if (settings.defaultNarratorVoice.isNotEmpty &&
              narratorSpeaker.voiceModelName != settings.defaultNarratorVoice) {
            narratorSpeaker =
                narratorSpeaker.copyWith(voiceModelName: settings.defaultNarratorVoice);
          }
        } else {
          narratorSpeaker = AudiobookSpeaker(
            id: 'narrator',
            name: 'Narrateur',
            voiceModelName: settings.defaultNarratorVoice,
          );
        }

        final dummyLine = AudiobookLine(
          id: 'msg_${messageId}_${DateTime.now().millisecondsSinceEpoch}',
          speakerId: 'narrator',
          speakerName: 'Narrateur',
          text: cleanText,
        );

        final svc = ref.read(audiobookServiceProvider);
        final wavBytes = await svc.synthesizeLinesToMemory(
          lines: [dummyLine],
          speakers: {'narrator': narratorSpeaker},
        );

        final tempDir = AppPaths.tmpDir;
        final previewFile = File(p.join(tempDir.path, 'assistant_read_aloud.wav'));
        await previewFile.writeAsBytes(wavBytes);

        if (!mounted) return;
        setState(() {
          _isSynthesizing = false;
        });

        await _audioPlayer.setFilePath(previewFile.path);
        await _audioPlayer.play();
      } catch (e) {
        _cleanupTempWavFile();
        if (mounted) {
          setState(() {
            _isSynthesizing = false;
            _readingMessageId = null;
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
      _readingMessageId = messageId;
      _isSynthesizing = true;
    });

    final currentGen = ++_readAloudGen;

    try {
      final voiceSvc = ref.read(assistantVoiceServiceProvider);
      final res = await voiceSvc.synthesize(
        text: cleanText,
        mode: settings.voiceIoMode,
        onlineVoiceId: settings.voiceIoOnlineVoice,
        offlineVoiceId: settings.voiceIoOfflineVoice,
        allowOnline: settings.voiceIoOnlineConsent == true,
      );

      if (!mounted || currentGen != _readAloudGen) {
        if (res.filePath != null) {
          try {
            File(res.filePath!).deleteSync();
          } catch (_) {}
        }
        return;
      }

      setState(() {
        _isSynthesizing = false;
      });

      if (!res.isSuccess || res.filePath == null) {
        if (mounted) {
          setState(() => _readingMessageId = null);
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

      _currentAudioFilePath = res.filePath;
      await _audioPlayer.setFilePath(res.filePath!);
      await _audioPlayer.play();
    } catch (e) {
      _cleanupTempAudioFile();
      if (mounted) {
        setState(() {
          _isSynthesizing = false;
          _readingMessageId = null;
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

  Widget _buildMessageBubble(LlmChatMessage msg, {
    Key? key,
    String findQuery = '',
    int? activeStart,
    int? activeEnd,
  }) {
    final isUser = msg.role == 'user';
    final theme = Theme.of(context);

    return Align(
      key: key,
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * (widget.isFullscreen ? 0.96 : 0.90),
        ),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isUser ? 'Vous' : 'Assistant IA',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isUser
                        ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.9)
                        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(width: 8),
                if (!isUser && widget.enableReadAloud) ...[
                  InkWell(
                    onTap: () {
                      final msgId = '${msg.timestamp.millisecondsSinceEpoch}_${msg.content.hashCode}';
                      _readAloud(msgId, msg.content);
                    },
                    child: _isSynthesizing && _readingMessageId == '${msg.timestamp.millisecondsSinceEpoch}_${msg.content.hashCode}'
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _isPlayingAudio && _readingMessageId == '${msg.timestamp.millisecondsSinceEpoch}_${msg.content.hashCode}'
                                ? Icons.stop_rounded
                                : Icons.volume_up_rounded,
                            size: 15,
                            color: _isPlayingAudio && _readingMessageId == '${msg.timestamp.millisecondsSinceEpoch}_${msg.content.hashCode}'
                                ? theme.colorScheme.primary
                                : Colors.grey,
                          ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (!isUser)
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(
                          text: AiTextDisclosure.forSummary(msg.content)));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Texte copié dans le presse-papier'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    child: const Icon(Icons.copy, size: 14, color: Colors.grey),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            findQuery.isEmpty
                ? SelectableText(
                    msg.content,
                    style: TextStyle(
                      fontSize: 14.5, height: 1.45,
                      color: isUser
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : SelectableText.rich(
                    _buildFindSpan(msg.content, findQuery,
                        activeStart: activeStart, activeEnd: activeEnd),
                    style: TextStyle(
                      fontSize: 14.5, height: 1.45,
                      color: isUser
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  // ── Méthodes de recherche ─────────────────────────────────────────────────

  void _rebuildFind() {
    if (_findQuery.isEmpty || _messages.isEmpty) {
      setState(() { _findMatches = []; _findIdx = -1; });
      return;
    }
    final regex = _chatSearchRegex(_findQuery);
    final found = <_ChatMatch>[];
    for (int i = 0; i < _messages.length; i++) {
      for (final m in regex.allMatches(_messages[i].content)) {
        found.add(_ChatMatch(messageIndex: i, charStart: m.start, charEnd: m.end));
      }
    }
    setState(() { _findMatches = found; _findIdx = found.isEmpty ? -1 : 0; });
    if (found.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFind());
    }
  }

  void _navigateFind(int newIdx) {
    if (_findMatches.isEmpty) return;
    setState(() => _findIdx = newIdx.clamp(0, _findMatches.length - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFind());
  }

  void _scrollToFind() {
    if (!_scrollController.hasClients || _findMatches.isEmpty || _findIdx < 0) return;
    final ctx = _findKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0.3,
          duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
      return;
    }
    final msgIdx = _findMatches[_findIdx].messageIndex;
    final fraction = _messages.length <= 1 ? 0.0 : msgIdx / (_messages.length - 1);
    final target = (_scrollController.position.maxScrollExtent * fraction)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController
        .animateTo(target,
            duration: const Duration(milliseconds: 250), curve: Curves.easeInOut)
        .then((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx2 = _findKey.currentContext;
        if (ctx2 != null) {
          Scrollable.ensureVisible(ctx2, alignment: 0.3,
              duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
        }
      });
    });
  }

  static RegExp _chatSearchRegex(String q) {
    if (q.contains('*') || q.contains('?')) {
      final buf = StringBuffer();
      for (final c in q.split('')) {
        if (c == '*') {
          buf.write('.*');
        } else if (c == '?') {
          buf.write('.');
        } else {
          buf.write(RegExp.escape(c));
        }
      }
      return RegExp(buf.toString(), caseSensitive: false);
    }
    return RegExp(RegExp.escape(q), caseSensitive: false);
  }

  static TextSpan _buildFindSpan(String text, String query,
      {int? activeStart, int? activeEnd}) {
    if (query.isEmpty) return TextSpan(text: text);
    final regex = _chatSearchRegex(query);
    final matches = regex.allMatches(text).toList();
    if (matches.isEmpty) return TextSpan(text: text);
    const passiveStyle = TextStyle(backgroundColor: Color(0xFFFFD54F), color: Colors.black87, fontWeight: FontWeight.bold);
    const activeStyle  = TextStyle(backgroundColor: Color(0xFFFF6D00), color: Colors.white,   fontWeight: FontWeight.bold);
    final spans = <TextSpan>[];
    int cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) spans.add(TextSpan(text: text.substring(cursor, m.start)));
      final isActive = activeStart != null && m.start == activeStart && m.end == activeEnd;
      spans.add(TextSpan(text: text.substring(m.start, m.end), style: isActive ? activeStyle : passiveStyle));
      cursor = m.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(children: spans);
  }

  Widget _buildStreamingBubble() {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * (widget.isFullscreen ? 0.96 : 0.90),
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Assistant IA (en cours d\'écriture...)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                ),
                SizedBox(width: 8),
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              _currentStreamingText.isNotEmpty ? _currentStreamingText : 'Génération de la réponse...',
              style: TextStyle(fontSize: 14.5, height: 1.45, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMatch {
  final int messageIndex, charStart, charEnd;
  const _ChatMatch({required this.messageIndex, required this.charStart, required this.charEnd});
}
