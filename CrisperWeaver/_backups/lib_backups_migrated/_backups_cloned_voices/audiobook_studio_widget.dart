import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../main.dart' show modelServiceProvider, settingsServiceProvider;
import '../models/audiobook_models.dart';
import '../models/audiobook_rules.dart';
import '../services/audiobook_service.dart';
import '../services/document_rag_service.dart';
import '../services/log_service.dart';
import '../services/settings_service.dart';
import '../services/tts_service.dart';
import '../utils/file_picker_util.dart' show pickFilesRobust;
import 'audiobook_export_dialog.dart';
import 'audiobook_import_dialog.dart';
import 'audiobook_rules_dialog.dart';
import 'llm_settings_dialog.dart';
import 'rag_library_dialog.dart';
import 'voice_tuning_dialog.dart';

class AudiobookStudioWidget extends ConsumerStatefulWidget {
  const AudiobookStudioWidget({super.key});

  @override
  ConsumerState<AudiobookStudioWidget> createState() => _AudiobookStudioWidgetState();
}

class _AudiobookStudioWidgetState extends ConsumerState<AudiobookStudioWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static AudiobookProject? _persistedStudioProject;
  static int _persistedChapterIndex = 0;

  AudiobookProject? _project;
  int _selectedChapterIndex = 0;
  bool _isSynthesizing = false;
  double _renderProgress = 0.0;
  AudiobookRuleProfile _activeProfile = AudiobookRuleProfile.standard;

  // Search State
  bool _isSearchVisible = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // Batch Line Selection State
  final Set<String> _selectedLineIds = {};

  // Active bubbles in raw edit mode (others in clean WYSIWYG view)
  final Set<String> _editingBubbleIds = {};

  // Controllers per line for selection-aware formatting
  final Map<String, TextEditingController> _lineControllers = {};

  final AudioPlayer _player = AudioPlayer();
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  bool _isPlaying = false;

  final Map<String, String> _availableFrenchVoices = {
    // 1. Qwen3-TTS (Neural 0.6B CustomVoice - 9 Voix Officielles Prêtes sur votre SSD)
    'qwen3-uncle_fu': '👨 Oncle Fu (Qwen3-TTS — Voix Narrative & Mûre)',
    'qwen3-ryan': '👨 Ryan (Qwen3-TTS — Voix Masculine Dynamique & Vivante)',
    'qwen3-eric': '👨 Eric (Qwen3-TTS — Voix Masculine Posée & Profonde)',
    'qwen3-aiden': '👨 Aiden (Qwen3-TTS — Voix Masculine Jeune & Claire)',
    'qwen3-dylan': '👨 Dylan (Qwen3-TTS — Voix Masculine Naturelle)',
    'qwen3-vivian': '👩 Vivian (Qwen3-TTS — Voix Féminine Expressive & Vivante)',
    'qwen3-serena': '👩 Serena (Qwen3-TTS — Voix Féminine Douce & Posée)',
    'qwen3-ono_anna': '👩 Anna (Qwen3-TTS — Voix Féminine Chaleureuse)',
    'qwen3-sohee': '👩 Sohee (Qwen3-TTS — Voix Féminine Claire)',

    // 2. Clonage Vocal Personnalisé (Votre Propre Voix .wav / Acteur)
    'custom-clone': '🎙️ [Clonage Vocal] Échantillon Audio Personnalisé (.wav)',

    // 3. VibeVoice (Microsoft) & Kokoro
    'vibevoice-voice-fr-Spk0_man': '👨 VibeVoice (Homme Français — Voix Naturelle)',
    'vibevoice-voice-fr-Spk1_woman': '👩 VibeVoice (Femme Française — Voix Naturelle)',
    'kokoro-voice-ff_siwis': '👩 Siwis (Kokoro 82M — Voix Rapide)',
  };

  @override
  void initState() {
    super.initState();
    // Load last saved profile
    final savedProfileId = ref.read(settingsServiceProvider).lastAudiobookProfileId;
    final matchedProfile = AudiobookRuleProfile.defaultProfiles.firstWhere(
      (p) => p.id == savedProfileId,
      orElse: () => AudiobookRuleProfile.standard,
    );
    _activeProfile = matchedProfile;

    if (_persistedStudioProject != null) {
      _project = _persistedStudioProject;
      _selectedChapterIndex = _persistedChapterIndex.clamp(0, (_persistedStudioProject!.chapters.length - 1).clamp(0, 9999));
    } else {
      _initSampleProject();
    }

    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _currentPosition = pos);
    });
    _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _totalDuration = dur);
    });
    _player.playerStateStream.listen((state) {
      if (mounted) setState(() => _isPlaying = state.playing);
    });
  }

  @override
  void dispose() {
    for (final c in _lineControllers.values) {
      c.dispose();
    }
    _lineControllers.clear();
    _searchController.dispose();
    _player.dispose();
    try {
      getTemporaryDirectory().then((tempDir) {
        final f1 = File('${tempDir.path}/audiobook_single_preview.wav');
        final f2 = File('${tempDir.path}/audiobook_batch_preview.wav');
        if (f1.existsSync()) f1.deleteSync();
        if (f2.existsSync()) f2.deleteSync();
      });
    } catch (_) {}
    super.dispose();
  }

  TextEditingController _getControllerForLine(String lineId, String initialText) {
    if (!_lineControllers.containsKey(lineId)) {
      _lineControllers[lineId] = RichStyleTextEditingController(text: initialText);
    } else if (_lineControllers[lineId]!.text != initialText &&
        !_lineControllers[lineId]!.selection.isValid) {
      _lineControllers[lineId]!.text = initialText;
    }
    return _lineControllers[lineId]!;
  }

  void _initSampleProject() {
    final settings = ref.read(settingsServiceProvider);
    final defaultSpeakers = <String, AudiobookSpeaker>{
      'narrator': AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: settings.defaultNarratorVoice,
        role: 'narrator',
      ),
      'male_main': AudiobookSpeaker(
        id: 'male_main',
        name: 'Personnage Principal (H)',
        voiceModelName: settings.defaultMaleVoice,
        role: 'male',
      ),
      'female_main': AudiobookSpeaker(
        id: 'female_main',
        name: 'Personnage Principal (F)',
        voiceModelName: settings.defaultFemaleVoice,
        role: 'female',
      ),
    };

    final sampleChapters = [
      AudiobookChapter(
        id: 'chap_1',
        index: 1,
        title: 'Chapitre 1 : L\'Ouverture',
        rawText: '''La nuit était tombée sur la ville brumeuse lorsque John s'approcha de la fenêtre du bureau. Il regarda la rue déserte et soupira.
— Nous n'avons plus beaucoup de temps avant l'aube, déclara-t-il sans se retourner.
Sarah leva les yeux de ses notes et posa sa tasse de café.
— Je sais, répondit-elle d'une voix calme. Mais nous devons nous assurer que tous les documents sont en sécurité.
Le silence retomba un instant dans la pièce, troublé seulement par le tic-tac régulier de l'horloge murale.''',
        lines: [
          const AudiobookLine(
            id: 'l1',
            speakerId: 'narrator',
            speakerName: 'Narrateur',
            text: 'La nuit était tombée sur la ville brumeuse lorsque John s\'approcha de la fenêtre du bureau. Il regarda la rue déserte et soupira.',
          ),
          const AudiobookLine(
            id: 'l2',
            speakerId: 'male_main',
            speakerName: 'John (Personnage H)',
            text: 'Nous n\'avons plus beaucoup de temps avant l\'aube, déclara-t-il sans se retourner.',
          ),
          const AudiobookLine(
            id: 'l3',
            speakerId: 'female_main',
            speakerName: 'Sarah (Personnage F)',
            text: 'Je sais, répondit-elle d\'une voix calme. Mais nous devons nous assurer que tous les documents sont en sécurité.',
          ),
          const AudiobookLine(
            id: 'l4',
            speakerId: 'narrator',
            speakerName: 'Narrateur',
            text: 'Le silence retomba un instant dans la pièce, troublé seulement par le tic-tac régulier de l\'horloge murale.',
          ),
        ],
      ),
      const AudiobookChapter(
        id: 'chap_2',
        index: 2,
        title: 'Chapitre 2 : La Révélation',
        rawText: '''À six heures précises, une voiture noire s'arrêta devant le bâtiment. Un homme en manteau sombre en descendit et franchit la grille.
— Le voici, chuchota Sarah en éteignant la lampe de table.
— Reste derrière moi, ordonna John en avançant vers la porte.''',
      ),
    ];

    _project = AudiobookProject(
      id: 'proj_sample',
      title: 'L\'Ombre sur la Cité (Exemple)',
      author: 'Roman Dramatique',
      sourcePath: 'sample.epub',
      chapters: sampleChapters,
      speakers: defaultSpeakers,
      createdAt: DateTime.now(),
    );
  }

  Future<void> _pickEpubFile() async {
    final pick = await pickFilesRobust(
      dialogTitle: 'Sélectionner un livre EPUB, PDF ou TXT',
      allowedExtensions: ['epub', 'txt', 'pdf', 'docx'],
    );
    if (pick.localPaths.isNotEmpty) {
      final path = pick.localPaths.first;
      if (!mounted) return;

      final choice = await AudiobookImportDialog.show(
        context,
        filePath: path,
        initialProfile: _activeProfile,
      );

      if (choice == null) return;
      _activeProfile = choice.profile;
      ref.read(settingsServiceProvider).lastAudiobookProfileId = _activeProfile.id;

      final svc = ref.read(audiobookServiceProvider);
      try {
        AudiobookProject project;
        if (choice.shouldIndexInRag) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('⏳ Indexation du livre dans la Bibliothèque RAG...')),
            );
          }
          final ragService = ref.read(documentRagServiceProvider);
          final settings = ref.read(settingsServiceProvider);
          final cachedEntry = await ragService.indexFile(path, settings: settings);
          project = await svc.createProjectFromCachedDoc(cachedEntry, profile: _activeProfile);
        } else {
          project = await svc.createProjectFromFile(path, profile: _activeProfile);
        }

        setState(() {
          _project = project;
          _selectedChapterIndex = 0;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Livre "${project.title}" chargé (${project.chapters.length} chapitres, profil: ${_activeProfile.name})')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erreur d\'ouverture : $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _openRagLibrary() async {
    final selectedDocs = await RagLibraryDialog.show(context);
    if (selectedDocs != null && selectedDocs.isNotEmpty) {
      final doc = selectedDocs.first;
      final svc = ref.read(audiobookServiceProvider);
      try {
        final project = await svc.createProjectFromCachedDoc(doc, profile: _activeProfile);
        setState(() {
          _project = project;
          _selectedChapterIndex = 0;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Livre "${project.title}" chargé (${project.chapters.length} chapitres)')),
          );
        }
      } catch (e) {
        Log.instance.w('audiobook', 'Erreur chargement RAG: $e');
      }
    }
  }

  Future<void> _openRulesDialog() async {
    final updated = await AudiobookRulesDialog.show(
      context,
      currentProfile: _activeProfile,
    );
    if (updated != null) {
      setState(() {
        _activeProfile = updated;
      });
      ref.read(settingsServiceProvider).lastAudiobookProfileId = _activeProfile.id;
      // Re-apply immediately in memory to all chapters
      if (_project != null) {
        final svc = ref.read(audiobookServiceProvider);
        final updatedChapters = _project!.chapters.map((chap) {
          final cleanText = _activeProfile.applyCleaning(chap.rawText);
          final cleanChap = chap.copyWith(rawText: cleanText);
          final lines = svc.castChapterLinesSync(
            chapter: cleanChap,
            speakers: _project!.speakers,
            profile: _activeProfile,
          );
          return cleanChap.copyWith(lines: lines);
        }).toList();

        setState(() {
          _project = _project!.copyWith(chapters: updatedChapters);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ Profil "${_activeProfile.name}" appliqué à tous les chapitres !')),
          );
        }
      }
    }
  }

  Widget _buildSearchResultsBadge() {
    if (_project == null || _searchQuery.isEmpty) return const SizedBox.shrink();
    int matchCount = 0;
    final List<Map<String, dynamic>> results = [];

    for (int c = 0; c < _project!.chapters.length; c++) {
      final chap = _project!.chapters[c];
      for (int l = 0; l < chap.lines.length; l++) {
        final line = chap.lines[l];
        if (line.text.toLowerCase().contains(_searchQuery)) {
          matchCount++;
          if (results.length < 25) {
            results.add({
              'chapterIndex': c,
              'chapterTitle': chap.title,
              'lineIndex': l,
              'text': line.text,
              'speaker': line.speakerName,
            });
          }
        }
      }
    }

    return PopupMenuButton<Map<String, dynamic>>(
      tooltip: 'Voir les occurrences trouvées',
      onSelected: (item) {
        setState(() {
          _selectedChapterIndex = item['chapterIndex'] as int;
        });
      },
      itemBuilder: (ctx) => results.map((res) {
        return PopupMenuItem(
          value: res,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${res['chapterTitle']} • ${res['speaker']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              Text(
                res['text'] as String,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$matchCount résultat${matchCount > 1 ? 's' : ''}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 14),
          ],
        ),
      ),
    );
  }

  // --- Project Save & Open & Export Actions ---

  Future<void> _saveProjectAs() async {
    if (_project == null) return;
    try {
      final defaultName = '${_project!.title.replaceAll(RegExp(r'[^\w\s\-]'), '_')}.cwproject';
      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Sauvegarder le Projet Audio (.cwproject)',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: ['cwproject', 'json'],
        bytes: Uint8List(0),
      );
      if (savePath != null) {
        final svc = ref.read(audiobookServiceProvider);
        await svc.saveProjectToFile(_project!, savePath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('💾 Projet sauvegardé sans perte : $savePath'), backgroundColor: Colors.green.shade800),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _openSavedProject() async {
    try {
      final result = await pickFilesRobust(
        type: FileType.custom,
        allowedExtensions: ['cwproject', 'json'],
      );
      if (result.isNotEmpty && result.localPaths.isNotEmpty) {
        final path = result.localPaths.first;
        final svc = ref.read(audiobookServiceProvider);
        final project = await svc.loadProjectFromFile(path);
        setState(() {
          _project = project;
          _selectedChapterIndex = 0;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('📂 Projet "${project.title}" ouvert (${project.chapters.length} chapitres, ${project.totalWords} mots)')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur d\'ouverture : $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _exportProject() {
    if (_project == null) return;
    AudiobookExportDialog.show(context, _project!);
  }

  // --- Line Editing & Formatting Operations ---

  void _updateLineText(int chapterIdx, int lineIdx, String newText) {
    if (_project == null || chapterIdx >= _project!.chapters.length) return;
    final chap = _project!.chapters[chapterIdx];
    if (lineIdx >= chap.lines.length) return;

    final updatedLines = List<AudiobookLine>.from(chap.lines);
    updatedLines[lineIdx] = updatedLines[lineIdx].copyWith(text: newText);
    final updatedChap = chap.copyWith(lines: updatedLines);

    final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
    updatedChapters[chapterIdx] = updatedChap;
    setState(() => _project = _project!.copyWith(chapters: updatedChapters));
  }

  void _changeLineSpeaker(int chapterIdx, int lineIdx, String speakerId, String speakerName) {
    if (_project == null || chapterIdx >= _project!.chapters.length) return;
    final chap = _project!.chapters[chapterIdx];
    if (lineIdx >= chap.lines.length) return;

    final updatedLines = List<AudiobookLine>.from(chap.lines);
    updatedLines[lineIdx] = updatedLines[lineIdx].copyWith(speakerId: speakerId, speakerName: speakerName);
    final updatedChap = chap.copyWith(lines: updatedLines);

    final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
    updatedChapters[chapterIdx] = updatedChap;
    setState(() => _project = _project!.copyWith(chapters: updatedChapters));
  }

  void _changeLineColor(int chapterIdx, int lineIdx, String? colorHex) {
    if (_project == null || chapterIdx >= _project!.chapters.length) return;
    final chap = _project!.chapters[chapterIdx];
    if (lineIdx >= chap.lines.length) return;

    final updatedLines = List<AudiobookLine>.from(chap.lines);
    updatedLines[lineIdx] = updatedLines[lineIdx].copyWith(colorHex: colorHex);
    final updatedChap = chap.copyWith(lines: updatedLines);

    final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
    updatedChapters[chapterIdx] = updatedChap;
    setState(() => _project = _project!.copyWith(chapters: updatedChapters));
  }

  void _changeLineHighlight(int chapterIdx, int lineIdx, String? highlightHex) {
    if (_project == null || chapterIdx >= _project!.chapters.length) return;
    final chap = _project!.chapters[chapterIdx];
    if (lineIdx >= chap.lines.length) return;

    final updatedLines = List<AudiobookLine>.from(chap.lines);
    updatedLines[lineIdx] = updatedLines[lineIdx].copyWith(highlightHex: highlightHex);
    final updatedChap = chap.copyWith(lines: updatedLines);

    final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
    updatedChapters[chapterIdx] = updatedChap;
    setState(() => _project = _project!.copyWith(chapters: updatedChapters));
  }

  void _applyStyleToSelectionOrLine({
    required int chapterIdx,
    required int lineIdx,
    required AudiobookLine line,
    String? colorHex,
    String? highlightHex,
    bool isBold = false,
    bool isItalic = false,
  }) {
    final ctrl = _lineControllers[line.id];
    if (ctrl != null && ctrl.selection.isValid && !ctrl.selection.isCollapsed) {
      final sel = ctrl.selection;
      final cleanText = ctrl.text;
      final start = sel.start.clamp(0, cleanText.length);
      final end = sel.end.clamp(0, cleanText.length);
      if (start >= end) return;

      // Update styleSpans: split and replace any overlapping span in the selected range
      final updatedSpans = <AudiobookStyleSpan>[];
      for (final s in line.styleSpans) {
        if (s.end <= start || s.start >= end) {
          updatedSpans.add(s);
        } else {
          if (s.start < start) {
            updatedSpans.add(s.copyWith(end: start));
          }
          if (s.end > end) {
            updatedSpans.add(s.copyWith(start: end));
          }
        }
      }

      updatedSpans.add(AudiobookStyleSpan(
        start: start,
        end: end,
        colorHex: colorHex,
        highlightHex: highlightHex,
        isBold: isBold,
        isItalic: isItalic,
      ));

      final updatedLine = line.copyWith(
        text: cleanText,
        styleSpans: updatedSpans,
      );

      final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
      final currentChapter = updatedChapters[chapterIdx];
      final updatedLines = List<AudiobookLine>.from(currentChapter.lines);
      updatedLines[lineIdx] = updatedLine;
      updatedChapters[chapterIdx] = currentChapter.copyWith(lines: updatedLines);

      setState(() {
        _project = _project!.copyWith(chapters: updatedChapters);
        _editingBubbleIds.remove(line.id);
      });
    } else {
      if (colorHex != null) _changeLineColor(chapterIdx, lineIdx, colorHex);
      if (highlightHex != null) _changeLineHighlight(chapterIdx, lineIdx, highlightHex);
    }
  }

  void _toggleSelectAllCurrentChapter() {
    if (_project == null || _selectedChapterIndex >= _project!.chapters.length) return;
    final chap = _project!.chapters[_selectedChapterIndex];
    final allIds = chap.lines.map((l) => l.id).toSet();
    setState(() {
      if (_selectedLineIds.containsAll(allIds)) {
        _selectedLineIds.removeAll(allIds);
      } else {
        _selectedLineIds.addAll(allIds);
      }
    });
  }

  Future<void> _synthesizeSelectedBatch() async {
    if (_project == null || _selectedChapterIndex >= _project!.chapters.length || _selectedLineIds.isEmpty || _isSynthesizing) return;
    final chap = _project!.chapters[_selectedChapterIndex];
    final selectedLines = chap.lines.where((l) => _selectedLineIds.contains(l.id)).toList();
    if (selectedLines.isEmpty) return;

    setState(() {
      _isSynthesizing = true;
      _renderProgress = 0.0;
    });

    for (final spk in _project!.speakers.values) {
      final ok = await _ensureVoiceDownloaded(spk.voiceModelName);
      if (!ok) {
        setState(() => _isSynthesizing = false);
        return;
      }
    }

    final svc = ref.read(audiobookServiceProvider);

    try {
      final wavBytes = await svc.synthesizeLinesToMemory(
        lines: selectedLines,
        speakers: _project!.speakers,
        onProgress: (p) => setState(() => _renderProgress = p),
      );

      setState(() {
        _isSynthesizing = false;
      });

      final tempDir = await getTemporaryDirectory();
      final previewFile = File('${tempDir.path}/audiobook_batch_preview.wav');
      await previewFile.writeAsBytes(wavBytes);

      await _player.setFilePath(previewFile.path);
      await _player.play();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('▶️ Lot de ${selectedLines.length} répliques en lecture !'),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      setState(() => _isSynthesizing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur synthèse par lots: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _synthesizeSingleLine(AudiobookLine line) async {
    if (_project == null || _isSynthesizing) return;
    setState(() {
      _isSynthesizing = true;
      _renderProgress = 0.0;
    });

    final spk = _project!.speakers[line.speakerId] ?? _project!.speakers['narrator'];
    if (spk != null) {
      final ok = await _ensureVoiceDownloaded(spk.voiceModelName);
      if (!ok) {
        setState(() => _isSynthesizing = false);
        return;
      }
    }

    final svc = ref.read(audiobookServiceProvider);

    try {
      final wavBytes = await svc.synthesizeLinesToMemory(
        lines: [line],
        speakers: _project!.speakers,
        onProgress: (p) => setState(() => _renderProgress = p),
      );

      setState(() {
        _isSynthesizing = false;
      });

      final tempDir = await getTemporaryDirectory();
      final previewFile = File('${tempDir.path}/audiobook_single_preview.wav');
      await previewFile.writeAsBytes(wavBytes);

      await _player.setFilePath(previewFile.path);
      await _player.play();
    } catch (e) {
      setState(() => _isSynthesizing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur lecture réplique: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _splitLine(int chapterIdx, int lineIdx) {
    if (_project == null || chapterIdx >= _project!.chapters.length) return;
    final chap = _project!.chapters[chapterIdx];
    if (lineIdx >= chap.lines.length) return;

    final targetLine = chap.lines[lineIdx];
    final text = targetLine.text;
    if (text.length < 4) return;

    final mid = text.length ~/ 2;
    // Find nearest space or punctuation around mid
    var splitPos = text.indexOf(' ', mid);
    if (splitPos == -1) splitPos = mid;

    final part1 = text.substring(0, splitPos).trim();
    final part2 = text.substring(splitPos).trim();

    final updatedLines = List<AudiobookLine>.from(chap.lines);
    updatedLines[lineIdx] = targetLine.copyWith(text: part1);
    updatedLines.insert(
      lineIdx + 1,
      AudiobookLine(
        id: 'line_${chap.index}_${DateTime.now().millisecondsSinceEpoch}',
        speakerId: targetLine.speakerId,
        speakerName: targetLine.speakerName,
        text: part2,
        colorHex: targetLine.colorHex,
        highlightHex: targetLine.highlightHex,
      ),
    );

    final updatedChap = chap.copyWith(lines: updatedLines);
    final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
    updatedChapters[chapterIdx] = updatedChap;
    setState(() => _project = _project!.copyWith(chapters: updatedChapters));
  }

  void _mergeWithNextLine(int chapterIdx, int lineIdx) {
    if (_project == null || chapterIdx >= _project!.chapters.length) return;
    final chap = _project!.chapters[chapterIdx];
    if (lineIdx >= chap.lines.length - 1) return;

    final cur = chap.lines[lineIdx];
    final next = chap.lines[lineIdx + 1];

    final updatedLines = List<AudiobookLine>.from(chap.lines);
    updatedLines[lineIdx] = cur.copyWith(text: '${cur.text} ${next.text}');
    updatedLines.removeAt(lineIdx + 1);

    final updatedChap = chap.copyWith(lines: updatedLines);
    final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
    updatedChapters[chapterIdx] = updatedChap;
    setState(() => _project = _project!.copyWith(chapters: updatedChapters));
  }

  void _insertLineBelow(int chapterIdx, int lineIdx) {
    if (_project == null || chapterIdx >= _project!.chapters.length) return;
    final chap = _project!.chapters[chapterIdx];

    final updatedLines = List<AudiobookLine>.from(chap.lines);
    updatedLines.insert(
      lineIdx + 1,
      AudiobookLine(
        id: 'line_${chap.index}_${DateTime.now().millisecondsSinceEpoch}',
        speakerId: 'narrator',
        speakerName: _project!.speakers['narrator']?.name ?? 'Narrateur',
        text: 'Nouveau texte inséré...',
      ),
    );

    final updatedChap = chap.copyWith(lines: updatedLines);
    final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
    updatedChapters[chapterIdx] = updatedChap;
    setState(() => _project = _project!.copyWith(chapters: updatedChapters));
  }

  void _deleteLine(int chapterIdx, int lineIdx) {
    if (_project == null || chapterIdx >= _project!.chapters.length) return;
    final chap = _project!.chapters[chapterIdx];
    if (chap.lines.length <= 1) return;

    final updatedLines = List<AudiobookLine>.from(chap.lines)..removeAt(lineIdx);
    final updatedChap = chap.copyWith(lines: updatedLines);

    final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
    updatedChapters[chapterIdx] = updatedChap;
    setState(() => _project = _project!.copyWith(chapters: updatedChapters));
  }

  Future<void> _addNewCustomSpeaker() async {
    if (_project == null) return;
    final nameCtrl = TextEditingController();
    String selectedVoice = _availableFrenchVoices.keys.first;

    final created = await showDialog<AudiobookSpeaker>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.person_add, color: Colors.blue),
            SizedBox(width: 8),
            Text('Ajouter un Personnage'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nom du personnage (ex: Jake Brigance, Bullard, Lucy)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: selectedVoice,
              decoration: const InputDecoration(
                labelText: 'Voix TTS assignée',
                border: OutlineInputBorder(),
              ),
              items: _availableFrenchVoices.entries.map((e) {
                return DropdownMenuItem(value: e.key, child: Text(e.value, style: const TextStyle(fontSize: 12)));
              }).toList(),
              onChanged: (v) {
                if (v != null) selectedVoice = v;
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isNotEmpty) {
                final id = 'speaker_${DateTime.now().millisecondsSinceEpoch}';
                Navigator.of(ctx).pop(
                  AudiobookSpeaker(
                    id: id,
                    name: nameCtrl.text.trim(),
                    voiceModelName: selectedVoice,
                    role: 'custom',
                  ),
                );
              }
            },
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );

    if (created != null) {
      final updatedSpeakers = Map<String, AudiobookSpeaker>.from(_project!.speakers);
      updatedSpeakers[created.id] = created;
      setState(() => _project = _project!.copyWith(speakers: updatedSpeakers));
    }
  }

  Future<bool> _ensureVoiceDownloaded(String voiceModelName) async {
    final modelService = ref.read(modelServiceProvider);

    // 1. If custom-clone, ensure Qwen3 Base + tokenizer are downloaded
    if (voiceModelName == 'custom-clone') {
      final baseModel = await modelService.getWhisperCppModelPath('qwen3-tts-12hz-0.6b-base');
      if (baseModel == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⬇️ Téléchargement du moteur de clonage Qwen3 Base (~1.8 Go)...'), duration: Duration(seconds: 5)),
          );
        }
        await modelService.downloadWhisperCppModel('qwen3-tts-12hz-0.6b-base');
      }
      final codecModel = await modelService.getWhisperCppModelPath('qwen3-tts-tokenizer-12hz');
      if (codecModel == null) {
        await modelService.downloadWhisperCppModel('qwen3-tts-tokenizer-12hz');
      }
      return true;
    }

    // 2. If kokoro voicepack, ensure base kokoro model is downloaded
    if (voiceModelName.startsWith('kokoro')) {
      final baseModelPath = await modelService.getWhisperCppModelPath('kokoro-82m-q8_0');
      if (baseModelPath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⬇️ Téléchargement du moteur Kokoro 82M (~82 Mo)...'), duration: Duration(seconds: 4)),
          );
        }
        await modelService.downloadWhisperCppModel('kokoro-82m-q8_0');
      }
    } else if (voiceModelName.startsWith('vibevoice')) {
      // 3. If VibeVoice, ensure 1.5B model is downloaded
      final mainModel = await modelService.getWhisperCppModelPath('vibevoice-1.5b-tts-q4_k');
      if (mainModel == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⬇️ Téléchargement de VibeVoice 1.5B (~1.9 Go)...'), duration: Duration(seconds: 5)),
          );
        }
        await modelService.downloadWhisperCppModel('vibevoice-1.5b-tts-q4_k');
      }
    } else if (voiceModelName.startsWith('qwen3')) {
      // 4. If Qwen3-TTS, ensure both 0.6B model and tokenizer are downloaded
      final mainModel = await modelService.getWhisperCppModelPath('qwen3-tts-12hz-0.6b-customvoice-q8_0');
      if (mainModel == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⬇️ Téléchargement de Qwen3-TTS 0.6B (~960 Mo)...'), duration: Duration(seconds: 5)),
          );
        }
        await modelService.downloadWhisperCppModel('qwen3-tts-12hz-0.6b-customvoice-q8_0');
      }

      final codecModel = await modelService.getWhisperCppModelPath('qwen3-tts-tokenizer-12hz');
      if (codecModel == null) {
        await modelService.downloadWhisperCppModel('qwen3-tts-tokenizer-12hz');
      }
      return true;
    }

    final modelPath = await modelService.getWhisperCppModelPath(voiceModelName);
    if (modelPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⬇️ Téléchargement de la voix "$voiceModelName"...'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      try {
        await modelService.downloadWhisperCppModel(
          voiceModelName,
          onProgress: (p) => Log.instance.d('audiobook', 'Téléchargement voix $voiceModelName: ${(p * 100).toInt()}%'),
        );
        return true;
      } catch (e) {
        Log.instance.w('audiobook', 'Erreur téléchargement voix $voiceModelName: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Impossible de télécharger la voix $voiceModelName: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return false;
      }
    }
    return true;
  }

  Future<void> _testVoice(String voiceModelName, {AudiobookSpeaker? speaker}) async {
    final ok = await _ensureVoiceDownloaded(voiceModelName);
    if (!ok) return;

    final tts = ref.read(ttsServiceProvider);
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🔊 Test de la voix en cours...'), duration: Duration(seconds: 2)),
        );
      }
      if (voiceModelName == 'custom-clone' || (speaker != null && speaker.customVoiceWavPath != null && speaker.customVoiceWavPath!.isNotEmpty)) {
        await tts.prepare(
          modelName: 'qwen3-tts-12hz-0.6b-base',
          codecName: 'qwen3-tts-tokenizer-12hz',
          voiceWavPath: speaker?.customVoiceWavPath,
        );
      } else if (voiceModelName.startsWith('vibevoice')) {
        await tts.prepare(
          modelName: 'vibevoice-1.5b-tts-q4_k',
          voiceName: voiceModelName,
        );
      } else if (voiceModelName.startsWith('kokoro')) {
        await tts.prepare(
          modelName: 'kokoro-82m-q8_0',
          voiceName: voiceModelName == 'kokoro-82m-q8_0' ? 'kokoro-voice-ff_siwis' : voiceModelName,
        );
      } else if (voiceModelName.startsWith('qwen3')) {
        final mappedSpeaker = AudiobookService.qwenSpeakerMap[voiceModelName] ?? 'uncle_fu';
        await tts.prepare(
          modelName: 'qwen3-tts-12hz-0.6b-customvoice-q8_0',
          codecName: 'qwen3-tts-tokenizer-12hz',
          speakerName: mappedSpeaker,
        );
      } else {
        await tts.prepare(modelName: voiceModelName);
      }
      final audio = await tts.synthesize(
        'Bonjour, voici un extrait de test pour votre livre audio en français.',
      );
      if (audio != null) {
        final tempDir = await getTemporaryDirectory();
        final testFile = File('${tempDir.path}/test_voice.wav');
        final svc = ref.read(audiobookServiceProvider);
        final wavData = svc.createWavHeaderAndData(audio.samples, audio.sampleRate);
        await testFile.writeAsBytes(wavData);
        await _player.setFilePath(testFile.path);
        await _player.play();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur test voix: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _openVoiceTuning(AudiobookSpeaker speaker) async {
    String? currentTextSample;
    if (_project != null && _selectedChapterIndex < _project!.chapters.length) {
      final chap = _project!.chapters[_selectedChapterIndex];
      final matchingLine = chap.lines.firstWhere(
        (l) => l.speakerId == speaker.id,
        orElse: () => chap.lines.isNotEmpty ? chap.lines.first : const AudiobookLine(id: '', speakerId: '', speakerName: '', text: ''),
      );
      if (matchingLine.text.isNotEmpty) {
        currentTextSample = matchingLine.text;
      }
    }

    final tuned = await VoiceTuningDialog.show(
      context,
      speaker: speaker,
      initialSampleText: currentTextSample,
      availableVoices: _availableFrenchVoices,
    );

    if (tuned != null && _project != null) {
      final updatedSpeakers = Map<String, AudiobookSpeaker>.from(_project!.speakers);
      updatedSpeakers[speaker.id] = tuned;
      setState(() {
        _project = _project!.copyWith(speakers: updatedSpeakers);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✨ Réglages appliqués pour ${tuned.name} (${tuned.speed.toStringAsFixed(2)}x, pitch ${tuned.pitch.toStringAsFixed(2)})'),
            backgroundColor: Colors.green.shade800,
          ),
        );
      }
    }
  }

  Future<void> _synthesizeCurrentChapter() async {
    if (_project == null || _isSynthesizing) return;
    final chapter = _project!.chapters[_selectedChapterIndex];

    setState(() {
      _isSynthesizing = true;
      _renderProgress = 0.0;
    });

    // Check that all required character voices are downloaded
    for (final spk in _project!.speakers.values) {
      final ok = await _ensureVoiceDownloaded(spk.voiceModelName);
      if (!ok) {
        setState(() => _isSynthesizing = false);
        return;
      }
    }

    final svc = ref.read(audiobookServiceProvider);
    final appDocsDir = await getApplicationDocumentsDirectory();
    final outDir = '${appDocsDir.path}/Audiobooks/${_project!.title}';

    try {
      final outPath = await svc.synthesizeChapter(
        chapter: chapter,
        speakers: _project!.speakers,
        outputDir: outDir,
        onProgress: (p) => setState(() => _renderProgress = p),
      );

      final updatedChapter = chapter.copyWith(
        status: AudiobookRenderStatus.ready,
        audioFilePath: outPath,
        progress: 1.0,
      );

      final updatedChapters = List<AudiobookChapter>.from(_project!.chapters);
      updatedChapters[_selectedChapterIndex] = updatedChapter;

      setState(() {
        _project = _project!.copyWith(chapters: updatedChapters);
        _isSynthesizing = false;
      });

      await _player.setFilePath(outPath);
      await _player.play();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Chapitre ${chapter.index} généré avec succès !'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _isSynthesizing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur synthèse : $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  InlineSpan _parseFormattedSpan(String text, TextStyle baseStyle) {
    if (text.isEmpty) return const TextSpan(text: '');

    // 1. Check for <color=0x...>(...)</color>
    final colorMatch = RegExp(r'<color=(0x[0-9a-fA-F]{8})>(.*?)</color>', dotAll: true, caseSensitive: false).firstMatch(text);
    if (colorMatch != null) {
      final before = text.substring(0, colorMatch.start);
      final hexStr = colorMatch.group(1)!;
      final inner = colorMatch.group(2)!;
      final after = text.substring(colorMatch.end);

      final color = Color(int.tryParse(hexStr) ?? 0xFFFFFFFF);
      final styledInner = _parseFormattedSpan(inner, baseStyle.copyWith(color: color));

      return TextSpan(
        children: [
          _parseFormattedSpan(before, baseStyle),
          styledInner,
          _parseFormattedSpan(after, baseStyle),
        ],
      );
    }

    // 2. Check for <mark=0x...>(...)</mark>
    final markMatch = RegExp(r'<mark=(0x[0-9a-fA-F]{8})>(.*?)</mark>', dotAll: true, caseSensitive: false).firstMatch(text);
    if (markMatch != null) {
      final before = text.substring(0, markMatch.start);
      final hexStr = markMatch.group(1)!;
      final inner = markMatch.group(2)!;
      final after = text.substring(markMatch.end);

      final bg = Color(int.tryParse(hexStr) ?? 0x33FBBF24);
      final styledInner = _parseFormattedSpan(inner, baseStyle.copyWith(backgroundColor: bg));

      return TextSpan(
        children: [
          _parseFormattedSpan(before, baseStyle),
          styledInner,
          _parseFormattedSpan(after, baseStyle),
        ],
      );
    }

    // 3. Check for **bold**
    final boldMatch = RegExp(r'\*\*(.*?)\*\*', dotAll: true).firstMatch(text);
    if (boldMatch != null) {
      final before = text.substring(0, boldMatch.start);
      final inner = boldMatch.group(1)!;
      final after = text.substring(boldMatch.end);

      final styledInner = _parseFormattedSpan(inner, baseStyle.copyWith(fontWeight: FontWeight.bold));

      return TextSpan(
        children: [
          _parseFormattedSpan(before, baseStyle),
          styledInner,
          _parseFormattedSpan(after, baseStyle),
        ],
      );
    }

    // 4. Check for *italic*
    final italicMatch = RegExp(r'\*(.*?)\*', dotAll: true).firstMatch(text);
    if (italicMatch != null) {
      final before = text.substring(0, italicMatch.start);
      final inner = italicMatch.group(1)!;
      final after = text.substring(italicMatch.end);

      final styledInner = _parseFormattedSpan(inner, baseStyle.copyWith(fontStyle: FontStyle.italic));

      return TextSpan(
        children: [
          _parseFormattedSpan(before, baseStyle),
          styledInner,
          _parseFormattedSpan(after, baseStyle),
        ],
      );
    }

    // Strip any remaining unclosed or malformed tags so raw tags NEVER leak to screen!
    final clean = text
        .replaceAll(RegExp(r'</?(color|mark)(=[^>]+)?>', caseSensitive: false), '')
        .replaceAll('**', '')
        .replaceAll('*', '');

    return TextSpan(text: clean, style: baseStyle);
  }

  Widget _buildFormattedText({
    required AudiobookLine line,
    required TextStyle baseStyle,
    Color? defaultTextColor,
    Color? defaultHighlightColor,
  }) {
    final effectiveStyle = baseStyle.copyWith(
      color: defaultTextColor,
      backgroundColor: defaultHighlightColor,
    );

    if (line.styleSpans.isNotEmpty) {
      final text = line.text;
      final boundaries = <int>{0, text.length};
      for (final s in line.styleSpans) {
        boundaries.add(s.start.clamp(0, text.length));
        boundaries.add(s.end.clamp(0, text.length));
      }
      final sorted = boundaries.toList()..sort();

      final children = <InlineSpan>[];
      for (int i = 0; i < sorted.length - 1; i++) {
        final start = sorted[i];
        final end = sorted[i + 1];
        if (start >= end) continue;

        final chunk = text.substring(start, end);

        Color? chunkColor = defaultTextColor;
        Color? chunkBg = defaultHighlightColor;
        bool isBold = false;
        bool isItalic = false;

        for (final s in line.styleSpans) {
          if (start >= s.start && end <= s.end) {
            if (s.colorHex != null) {
              chunkColor = Color(int.tryParse(s.colorHex!) ?? 0xFFFFFFFF);
            }
            if (s.highlightHex != null) {
              chunkBg = Color(int.tryParse(s.highlightHex!) ?? 0x33FBBF24);
            }
            if (s.isBold) isBold = true;
            if (s.isItalic) isItalic = true;
          }
        }

        var style = effectiveStyle.copyWith(
          color: chunkColor,
          backgroundColor: chunkBg,
        );
        if (isBold) style = style.copyWith(fontWeight: FontWeight.bold);
        if (isItalic) style = style.copyWith(fontStyle: FontStyle.italic);

        children.add(TextSpan(text: chunk, style: style));
      }

      return RichText(text: TextSpan(children: children));
    }

    return RichText(
      text: _parseFormattedSpan(line.text, effectiveStyle),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _persistedStudioProject = _project;
    _persistedChapterIndex = _selectedChapterIndex;

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final currentChapter = _project != null && _project!.chapters.isNotEmpty
        ? _project!.chapters[_selectedChapterIndex.clamp(0, _project!.chapters.length - 1)]
        : null;

    return Scaffold(
      body: Column(
        children: [
          // Toolbar Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4))),
            ),
            child: Row(
              children: [
                Icon(Icons.headphones, color: cs.primary, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Studio Livre Audio Multi-Voix',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                // Search Toggle
                IconButton.outlined(
                  tooltip: 'Recherche globale dans tout le livre',
                  icon: Icon(_isSearchVisible ? Icons.search_off : Icons.search, size: 18),
                  onPressed: () => setState(() => _isSearchVisible = !_isSearchVisible),
                ),
                const SizedBox(width: 6),
                // Save Project
                IconButton.outlined(
                  tooltip: 'Sauvegarder le Projet Complet (.cwproject)',
                  icon: const Icon(Icons.save, size: 18),
                  onPressed: _project != null ? _saveProjectAs : null,
                ),
                const SizedBox(width: 6),
                // Open Project
                IconButton.outlined(
                  tooltip: 'Ouvrir un Projet Existant (.cwproject / .json)',
                  icon: const Icon(Icons.folder_open, size: 18),
                  onPressed: _openSavedProject,
                ),
                const SizedBox(width: 6),
                // Export Document
                FilledButton.icon(
                  onPressed: _project != null ? _exportProject : null,
                  icon: const Icon(Icons.file_download, size: 18),
                  label: const Text('Exporter'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton.tonalIcon(
                  onPressed: _openRagLibrary,
                  icon: const Icon(Icons.menu_book, size: 18),
                  label: const Text('Bibliothèque RAG'),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: _pickEpubFile,
                  icon: const Icon(Icons.file_open, size: 18),
                  label: const Text('Importer EPUB / TXT'),
                ),
                const SizedBox(width: 6),
                IconButton.outlined(
                  tooltip: 'Règles de Découpage & Nettoyage (${_activeProfile.name})',
                  icon: const Icon(Icons.cleaning_services, size: 18),
                  onPressed: _openRulesDialog,
                ),
                const SizedBox(width: 6),
                IconButton.outlined(
                  tooltip: 'Paramètres LLM (Casting & Détection)',
                  icon: const Icon(Icons.tune, size: 18),
                  onPressed: () => showLlmSettingsDialog(context, ref),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),

          // Search Bar Overlay if toggled
          if (_isSearchVisible && _project != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: cs.surfaceContainerHighest.withValues(alpha: 0.8),
              child: Row(
                children: [
                  const Icon(Icons.search, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Rechercher un mot, un nom ou une phrase dans tout le livre...',
                        isDense: true,
                        border: InputBorder.none,
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                      ),
                      onChanged: (val) => setState(() => _searchQuery = val.trim().toLowerCase()),
                    ),
                  ),
                  if (_searchQuery.isNotEmpty) ...[
                    _buildSearchResultsBadge(),
                  ],
                ],
              ),
            ),

          // Main Studio Content
          Expanded(
            child: _project == null
                ? const Center(child: Text('Veuillez charger un livre EPUB pour commencer.'))
                : Row(
                    children: [
                      // Left Sidebar: TOC & Voice Casting
                      SizedBox(
                        width: 360,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(right: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.3))),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Book Header Card
                              Container(
                                padding: const EdgeInsets.all(12),
                                color: cs.primaryContainer.withValues(alpha: 0.3),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _project!.title,
                                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${_project!.chapters.length} chapitres • ~${_project!.totalWords} mots (${_project!.totalEstimatedMinutes} min)',
                                      style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),

                              // Chapters Tab Header
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                                child: Text('TABLE DES MATIÈRES', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                              ),

                              // Chapter List
                              Expanded(
                                flex: 3,
                                child: ListView.builder(
                                  itemCount: _project!.chapters.length,
                                  itemBuilder: (ctx, i) {
                                    final chap = _project!.chapters[i];
                                    final isSelected = i == _selectedChapterIndex;
                                    return ListTile(
                                      selected: isSelected,
                                      selectedTileColor: cs.primary.withValues(alpha: 0.12),
                                      dense: true,
                                      leading: CircleAvatar(
                                        radius: 12,
                                        backgroundColor: chap.status == AudiobookRenderStatus.ready
                                            ? Colors.green
                                            : cs.surfaceContainerHighest,
                                        child: Text(
                                          '${chap.index}',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: chap.status == AudiobookRenderStatus.ready ? Colors.white : cs.onSurface,
                                          ),
                                        ),
                                      ),
                                      title: Text(chap.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                      subtitle: Text('${chap.wordCount} mots • ~${chap.estimatedDurationMinutes} min'),
                                      trailing: chap.status == AudiobookRenderStatus.ready
                                          ? const Icon(Icons.check_circle, size: 16, color: Colors.green)
                                          : null,
                                      onTap: () => setState(() => _selectedChapterIndex = i),
                                    );
                                  },
                                ),
                              ),

                              const Divider(height: 1),

                              // Voice Casting Section
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                                child: Row(
                                  children: [
                                    const Icon(Icons.record_voice_over, size: 16),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'DISTRIBUTION DES VOIX',
                                        style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 1.1),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.person_add, size: 16),
                                      tooltip: 'Ajouter un personnage',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: _addNewCustomSpeaker,
                                    ),
                                  ],
                                ),
                              ),

                              // Speakers List
                              Expanded(
                                flex: 2,
                                child: ListView(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  children: _project!.speakers.entries.map((e) {
                                    final spk = e.value;
                                    return Card(
                                      margin: const EdgeInsets.only(bottom: 6),
                                      elevation: 0,
                                      color: cs.surfaceContainerLow,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Icon(
                                                  spk.id == 'narrator'
                                                      ? Icons.menu_book
                                                      : (spk.role == 'female' ? Icons.face_3 : Icons.face),
                                                  size: 14,
                                                  color: cs.primary,
                                                ),
                                                const SizedBox(width: 6),
                                                Expanded(
                                                  child: Text(
                                                    spk.name,
                                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                IconButton(
                                                  icon: const Icon(Icons.tune, size: 14),
                                                  tooltip: 'Régler la voix (Vitesse, Pitch, Volume, Presets)',
                                                  visualDensity: VisualDensity.compact,
                                                  onPressed: () => _openVoiceTuning(spk),
                                                ),
                                                IconButton(
                                                  icon: const Icon(Icons.volume_up, size: 14),
                                                  tooltip: 'Tester la voix',
                                                  visualDensity: VisualDensity.compact,
                                                  onPressed: () => _testVoice(spk.voiceModelName, speaker: spk),
                                                ),
                                              ],
                                            ),
                                            DropdownButtonFormField<String>(
                                              isDense: true,
                                              isExpanded: true,
                                              value: _availableFrenchVoices.containsKey(spk.voiceModelName)
                                                  ? spk.voiceModelName
                                                  : _availableFrenchVoices.keys.first,
                                              items: _availableFrenchVoices.entries.map((voice) {
                                                return DropdownMenuItem(
                                                  value: voice.key,
                                                  child: Text(voice.value, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
                                                );
                                              }).toList(),
                                              onChanged: (newVoice) {
                                                if (newVoice != null) {
                                                  if (newVoice == 'custom-clone' && (spk.customVoiceWavPath == null || spk.customVoiceWavPath!.isEmpty)) {
                                                    _openVoiceTuning(spk);
                                                    return;
                                                  }
                                                  final updated = Map<String, AudiobookSpeaker>.from(_project!.speakers);
                                                  final updatedSpk = spk.copyWith(voiceModelName: newVoice);
                                                  updated[e.key] = updatedSpk;

                                                  final settings = ref.read(settingsServiceProvider);
                                                  if (spk.id == 'narrator') {
                                                    settings.defaultNarratorVoice = newVoice;
                                                  } else if (spk.role == 'male') {
                                                    settings.defaultMaleVoice = newVoice;
                                                  } else if (spk.role == 'female') {
                                                    settings.defaultFemaleVoice = newVoice;
                                                  }
                                                  settings.saveSpeakerVoiceConfig(spk.id, updatedSpk.toJson());

                                                  setState(() => _project = _project!.copyWith(speakers: updated));
                                                }
                                              },
                                              decoration: const InputDecoration(
                                                isDense: true,
                                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                border: OutlineInputBorder(),
                                              ),
                                            ),
                                            if (spk.speed != 1.0 || spk.pitch != 1.0 || spk.volume != 1.0) ...[
                                              const SizedBox(height: 4),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: cs.primaryContainer.withValues(alpha: 0.5),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  '⚡ ${spk.speed.toStringAsFixed(2)}x  •  🎵 ${(spk.pitch < 0.96 ? "Grave" : (spk.pitch > 1.04 ? "Aigu" : "Neutre"))}  •  🔊 ${(spk.volume * 100).toInt()}%',
                                                  style: TextStyle(fontSize: 10, color: cs.onPrimaryContainer, fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Right Main Area: Interactive Script & Audio Player
                      Expanded(
                        child: currentChapter == null
                            ? const Center(child: Text('Sélectionnez un chapitre'))
                            : Column(
                                children: [
                                  // Chapter Action Bar
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                    color: cs.surfaceContainerLow,
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                currentChapter.title,
                                                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                '${currentChapter.wordCount} mots • ${currentChapter.lines.length} répliques segmentées',
                                                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(
                                          flex: 0,
                                          child: Wrap(
                                            spacing: 8,
                                            runSpacing: 4,
                                            crossAxisAlignment: WrapCrossAlignment.center,
                                            children: [
                                              OutlinedButton.icon(
                                                onPressed: _toggleSelectAllCurrentChapter,
                                                icon: Icon(
                                                  currentChapter.lines.isNotEmpty &&
                                                          _selectedLineIds.containsAll(currentChapter.lines.map((l) => l.id))
                                                      ? Icons.check_box
                                                      : Icons.check_box_outline_blank,
                                                  size: 16,
                                                ),
                                                label: Text(
                                                  currentChapter.lines.isNotEmpty &&
                                                          _selectedLineIds.containsAll(currentChapter.lines.map((l) => l.id))
                                                      ? 'Désélectionner'
                                                      : 'Tout sélectionner',
                                                  style: const TextStyle(fontSize: 12),
                                                ),
                                              ),
                                              if (_selectedLineIds.isNotEmpty)
                                                FilledButton.tonalIcon(
                                                  onPressed: _isSynthesizing ? null : _synthesizeSelectedBatch,
                                                  icon: const Icon(Icons.record_voice_over, size: 16),
                                                  label: Text('Générer Sélection (${currentChapter.lines.where((l) => _selectedLineIds.contains(l.id)).length})'),
                                                ),
                                              if (_isSynthesizing)
                                                SizedBox(
                                                  width: 130,
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      LinearProgressIndicator(value: _renderProgress),
                                                      const SizedBox(height: 2),
                                                      Text('${(_renderProgress * 100).toInt()}%', style: const TextStyle(fontSize: 10)),
                                                    ],
                                                  ),
                                                )
                                              else
                                                FilledButton.icon(
                                                  onPressed: _synthesizeCurrentChapter,
                                                  icon: const Icon(Icons.play_circle_filled, size: 18),
                                                  label: const Text('Générer Tout le Chapitre'),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Script Area with Editable Bubbles
                                  Expanded(
                                    child: ListView.builder(
                                      padding: const EdgeInsets.all(16),
                                      itemCount: currentChapter.lines.isNotEmpty ? currentChapter.lines.length : 1,
                                      itemBuilder: (ctx, i) {
                                        if (currentChapter.lines.isEmpty) {
                                          return SelectableText(
                                            currentChapter.rawText,
                                            style: const TextStyle(fontSize: 14, height: 1.6),
                                          );
                                        }

                                        final line = currentChapter.lines[i];
                                        final isNarrator = line.speakerId == 'narrator';
                                        final isFemale = line.speakerId == 'female_main' ||
                                            (_project!.speakers[line.speakerId]?.role == 'female');

                                        final bubbleColor = isNarrator
                                            ? cs.surfaceContainerHighest.withValues(alpha: 0.35)
                                            : (isFemale
                                                ? Colors.pink.withValues(alpha: 0.12)
                                                : cs.primaryContainer.withValues(alpha: 0.35));

                                        Color? customTextColor;
                                        if (line.colorHex != null) {
                                          customTextColor = Color(int.tryParse(line.colorHex!) ?? 0xFFFFFFFF);
                                        }

                                        Color? customHighlightColor;
                                        if (line.highlightHex != null) {
                                          customHighlightColor = Color(int.tryParse(line.highlightHex!) ?? 0x00000000);
                                        }

                                        final hasFormattingTags = line.text.contains('<color=') ||
                                            line.text.contains('<mark=') ||
                                            line.text.contains('**') ||
                                            line.text.contains('*');

                                        final isSelectedForBatch = _selectedLineIds.contains(line.id);

                                        return Container(
                                          margin: const EdgeInsets.only(bottom: 8),
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: customHighlightColor ?? bubbleColor,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: isSelectedForBatch
                                                  ? cs.primary
                                                  : (isNarrator
                                                      ? cs.outlineVariant.withValues(alpha: 0.4)
                                                      : (isFemale
                                                          ? Colors.pink.withValues(alpha: 0.4)
                                                          : cs.primary.withValues(alpha: 0.4))),
                                              width: isSelectedForBatch ? 2 : 1,
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              // Bubble Top Bar: Batch Checkbox, Speaker Selector & Formatting Tools
                                              Row(
                                                children: [
                                                  // Batch Checkbox
                                                  SizedBox(
                                                    width: 24,
                                                    height: 24,
                                                    child: Checkbox(
                                                      value: isSelectedForBatch,
                                                      visualDensity: VisualDensity.compact,
                                                      onChanged: (val) {
                                                        setState(() {
                                                          if (val == true) {
                                                            _selectedLineIds.add(line.id);
                                                          } else {
                                                            _selectedLineIds.remove(line.id);
                                                          }
                                                        });
                                                      },
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),

                                                  // Speaker Badge Dropdown
                                                  PopupMenuButton<String>(
                                                    tooltip: 'Changer le locuteur',
                                                    onSelected: (speakerId) {
                                                      if (speakerId == '__add_new__') {
                                                        _addNewCustomSpeaker();
                                                      } else {
                                                        final spk = _project!.speakers[speakerId];
                                                        if (spk != null) {
                                                          _changeLineSpeaker(_selectedChapterIndex, i, spk.id, spk.name);
                                                        }
                                                      }
                                                    },
                                                    itemBuilder: (ctx) => [
                                                      ..._project!.speakers.values.map(
                                                        (spk) => PopupMenuItem(
                                                          value: spk.id,
                                                          child: Row(
                                                            children: [
                                                              Icon(
                                                                spk.id == 'narrator'
                                                                    ? Icons.menu_book
                                                                    : (spk.role == 'female' ? Icons.face_3 : Icons.face),
                                                                size: 16,
                                                              ),
                                                              const SizedBox(width: 8),
                                                              Text(spk.name),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                      const PopupMenuDivider(),
                                                      const PopupMenuItem(
                                                        value: '__add_new__',
                                                        child: Row(
                                                          children: [
                                                            Icon(Icons.person_add, color: Colors.blue, size: 16),
                                                            SizedBox(width: 8),
                                                            Text('➕ Nouveau Personnage...'),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                    child: Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                      decoration: BoxDecoration(
                                                        color: isNarrator
                                                            ? Colors.grey.shade300
                                                            : (isFemale
                                                                ? const Color(0xFFFFD1DC)
                                                                : const Color(0xFFBBDEFB)),
                                                        borderRadius: BorderRadius.circular(5),
                                                        border: Border.all(
                                                          color: isNarrator
                                                              ? Colors.grey.shade600
                                                              : (isFemale
                                                                  ? const Color(0xFFE91E63)
                                                                  : const Color(0xFF1E88E5)),
                                                          width: 1,
                                                        ),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          Text(
                                                            line.speakerName,
                                                            style: const TextStyle(
                                                              color: Colors.black87,
                                                              fontSize: 11,
                                                              fontWeight: FontWeight.bold,
                                                            ),
                                                          ),
                                                          const SizedBox(width: 4),
                                                          const Icon(Icons.arrow_drop_down, size: 14, color: Colors.black87),
                                                        ],
                                                      ),
                                                    ),
                                                  ),

                                                  const Spacer(),

                                                  // Synthesize / Play Single Line
                                                  IconButton(
                                                    icon: const Icon(Icons.play_circle_outline, size: 16),
                                                    tooltip: 'Synthétiser / Écouter cette réplique seule',
                                                    visualDensity: VisualDensity.compact,
                                                    onPressed: () => _synthesizeSingleLine(line),
                                                  ),

                                                  // Bold selection
                                                  IconButton(
                                                    icon: const Icon(Icons.format_bold, size: 16),
                                                    tooltip: 'Mettre la sélection en gras (**texte**)',
                                                    visualDensity: VisualDensity.compact,
                                                    onPressed: () => _applyStyleToSelectionOrLine(
                                                      chapterIdx: _selectedChapterIndex,
                                                      lineIdx: i,
                                                      line: line,
                                                      isBold: true,
                                                    ),
                                                  ),

                                                  // Italic selection
                                                  IconButton(
                                                    icon: const Icon(Icons.format_italic, size: 16),
                                                    tooltip: 'Mettre la sélection en italique (*texte*)',
                                                    visualDensity: VisualDensity.compact,
                                                    onPressed: () => _applyStyleToSelectionOrLine(
                                                      chapterIdx: _selectedChapterIndex,
                                                      lineIdx: i,
                                                      line: line,
                                                      isItalic: true,
                                                    ),
                                                  ),

                                                  // Font Color Menu (selection-aware)
                                                  PopupMenuButton<String?>(
                                                    tooltip: 'Couleur de police (sur sélection ou réplique)',
                                                    icon: const Icon(Icons.format_color_text, size: 16),
                                                    onSelected: (colorHex) => _applyStyleToSelectionOrLine(
                                                      chapterIdx: _selectedChapterIndex,
                                                      lineIdx: i,
                                                      line: line,
                                                      colorHex: colorHex,
                                                    ),
                                                    itemBuilder: (ctx) => [
                                                      const PopupMenuItem(value: null, child: Text('Couleur par défaut')),
                                                      const PopupMenuItem(value: '0xFF38BDF8', child: Text('🔵 Bleu Ciel', style: TextStyle(color: Colors.lightBlueAccent))),
                                                      const PopupMenuItem(value: '0xFF4ADE80', child: Text('🟢 Vert Menthe', style: TextStyle(color: Colors.greenAccent))),
                                                      const PopupMenuItem(value: '0xFFF87171', child: Text('🔴 Rouge Corail', style: TextStyle(color: Colors.redAccent))),
                                                      const PopupMenuItem(value: '0xFFC084FC', child: Text('🟣 Violet Améthyste', style: TextStyle(color: Colors.purpleAccent))),
                                                      const PopupMenuItem(value: '0xFFFBBF24', child: Text('🟡 Ambre Doré', style: TextStyle(color: Colors.amberAccent))),
                                                    ],
                                                  ),

                                                  // Highlight Color Menu (selection-aware)
                                                  PopupMenuButton<String?>(
                                                    tooltip: 'Surlignage (sur sélection ou réplique)',
                                                    icon: const Icon(Icons.highlight, size: 16),
                                                    onSelected: (hlHex) => _applyStyleToSelectionOrLine(
                                                      chapterIdx: _selectedChapterIndex,
                                                      lineIdx: i,
                                                      line: line,
                                                      highlightHex: hlHex,
                                                    ),
                                                    itemBuilder: (ctx) => [
                                                      const PopupMenuItem(value: null, child: Text('Aucun surlignage')),
                                                      const PopupMenuItem(value: '0x33FBBF24', child: Text('🟨 Surlignage Jaune')),
                                                      const PopupMenuItem(value: '0x3338BDF8', child: Text('🟦 Surlignage Cyan')),
                                                      const PopupMenuItem(value: '0x33F472B6', child: Text('🟥 Surlignage Rose')),
                                                      const PopupMenuItem(value: '0x334ADE80', child: Text('🟩 Surlignage Vert')),
                                                    ],
                                                  ),

                                                   // Toggle Edit / WYSIWYG view
                                                   IconButton(
                                                     icon: Icon(_editingBubbleIds.contains(line.id) ? Icons.check_circle_outline : Icons.edit_outlined, size: 16),
                                                     tooltip: _editingBubbleIds.contains(line.id) ? 'Valider et afficher la mise en forme claire' : 'Modifier le texte',
                                                     color: _editingBubbleIds.contains(line.id) ? Colors.greenAccent : null,
                                                     visualDensity: VisualDensity.compact,
                                                     onPressed: () {
                                                       setState(() {
                                                         if (_editingBubbleIds.contains(line.id)) {
                                                           _editingBubbleIds.remove(line.id);
                                                         } else {
                                                           _editingBubbleIds.add(line.id);
                                                         }
                                                       });
                                                     },
                                                   ),

                                                  // Split Line
                                                  IconButton(
                                                    icon: const Icon(Icons.call_split, size: 16),
                                                    tooltip: 'Scinder la réplique en deux',
                                                    visualDensity: VisualDensity.compact,
                                                    onPressed: () => _splitLine(_selectedChapterIndex, i),
                                                  ),

                                                  // Merge Line
                                                  if (i < currentChapter.lines.length - 1)
                                                    IconButton(
                                                      icon: const Icon(Icons.merge, size: 16),
                                                      tooltip: 'Fusionner avec la réplique suivante',
                                                      visualDensity: VisualDensity.compact,
                                                      onPressed: () => _mergeWithNextLine(_selectedChapterIndex, i),
                                                    ),

                                                  // Insert Below
                                                  IconButton(
                                                    icon: const Icon(Icons.add_circle_outline, size: 16),
                                                    tooltip: 'Insérer une réplique en dessous',
                                                    visualDensity: VisualDensity.compact,
                                                    onPressed: () => _insertLineBelow(_selectedChapterIndex, i),
                                                  ),

                                                  // Delete Line
                                                  IconButton(
                                                    icon: const Icon(Icons.delete_outline, size: 16),
                                                    tooltip: 'Supprimer cette réplique',
                                                    visualDensity: VisualDensity.compact,
                                                    onPressed: () => _deleteLine(_selectedChapterIndex, i),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),

                                              if (_editingBubbleIds.contains(line.id)) ...[
                                                // Editable Text Field connected to line controller
                                                TextField(
                                                  controller: _getControllerForLine(line.id, line.text),
                                                  maxLines: null,
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    color: customTextColor ?? cs.onSurface,
                                                    fontStyle: isNarrator ? FontStyle.italic : FontStyle.normal,
                                                    height: 1.5,
                                                  ),
                                                  decoration: const InputDecoration(
                                                    isDense: true,
                                                    border: InputBorder.none,
                                                    contentPadding: EdgeInsets.zero,
                                                    hintText: 'Saisissez ou modifiez votre texte...',
                                                  ),
                                                  onChanged: (newVal) => _updateLineText(_selectedChapterIndex, i, newVal),
                                                ),
                                              ] else ...[
                                                // Clean WYSIWYG Formatted Display (Zero raw tags visible!)
                                                InkWell(
                                                  onTap: () => setState(() => _editingBubbleIds.add(line.id)),
                                                  borderRadius: BorderRadius.circular(4),
                                                  child: Container(
                                                    width: double.infinity,
                                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                                    child: _buildFormattedText(
                                                      line: line,
                                                      baseStyle: TextStyle(
                                                        fontSize: 14,
                                                        fontStyle: isNarrator ? FontStyle.italic : FontStyle.normal,
                                                        height: 1.5,
                                                      ),
                                                      defaultTextColor: customTextColor ?? cs.onSurface,
                                                      defaultHighlightColor: customHighlightColor,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ),

                                  // Audio Player Bar
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                                      border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4))),
                                    ),
                                    child: Row(
                                      children: [
                                        IconButton.filled(
                                          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                                          onPressed: () {
                                            if (_isPlaying) {
                                              _player.pause();
                                            } else {
                                              _player.play();
                                            }
                                          },
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          '${_currentPosition.inMinutes}:${(_currentPosition.inSeconds % 60).toString().padLeft(2, '0')}',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                        ),
                                        Expanded(
                                          child: Slider(
                                            value: _currentPosition.inSeconds.toDouble().clamp(
                                                  0.0,
                                                  _totalDuration.inSeconds > 0 ? _totalDuration.inSeconds.toDouble() : 1.0,
                                                ),
                                            max: _totalDuration.inSeconds > 0 ? _totalDuration.inSeconds.toDouble() : 1.0,
                                            onChanged: (val) {
                                              _player.seek(Duration(seconds: val.toInt()));
                                            },
                                          ),
                                        ),
                                        Text(
                                          '${_totalDuration.inMinutes}:${(_totalDuration.inSeconds % 60).toString().padLeft(2, '0')}',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Custom TextEditingController rendering styled TextSpans (colors, highlights, bold, italic)
/// without printing raw markup tags on screen.
class RichStyleTextEditingController extends TextEditingController {
  RichStyleTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final effectiveStyle = style ?? const TextStyle();
    return _parseRichControllerSpans(text, effectiveStyle);
  }

  static TextSpan _parseRichControllerSpans(String text, TextStyle baseStyle) {
    if (text.isEmpty) return const TextSpan(text: '');

    // 1. Color tag
    final colorMatch = RegExp(r'<color=(0x[0-9a-fA-F]{8})>(.*?)</color>', dotAll: true, caseSensitive: false).firstMatch(text);
    if (colorMatch != null) {
      final before = text.substring(0, colorMatch.start);
      final hexStr = colorMatch.group(1)!;
      final inner = colorMatch.group(2)!;
      final after = text.substring(colorMatch.end);

      final color = Color(int.tryParse(hexStr) ?? 0xFFFFFFFF);
      final styledInner = _parseRichControllerSpans(inner, baseStyle.copyWith(color: color));

      return TextSpan(
        children: [
          _parseRichControllerSpans(before, baseStyle),
          styledInner,
          _parseRichControllerSpans(after, baseStyle),
        ],
      );
    }

    // 2. Mark / Highlight tag
    final markMatch = RegExp(r'<mark=(0x[0-9a-fA-F]{8})>(.*?)</mark>', dotAll: true, caseSensitive: false).firstMatch(text);
    if (markMatch != null) {
      final before = text.substring(0, markMatch.start);
      final hexStr = markMatch.group(1)!;
      final inner = markMatch.group(2)!;
      final after = text.substring(markMatch.end);

      final bg = Color(int.tryParse(hexStr) ?? 0x33FBBF24);
      final styledInner = _parseRichControllerSpans(inner, baseStyle.copyWith(backgroundColor: bg));

      return TextSpan(
        children: [
          _parseRichControllerSpans(before, baseStyle),
          styledInner,
          _parseRichControllerSpans(after, baseStyle),
        ],
      );
    }

    // 3. Bold tag
    final boldMatch = RegExp(r'\*\*(.*?)\*\*', dotAll: true).firstMatch(text);
    if (boldMatch != null) {
      final before = text.substring(0, boldMatch.start);
      final inner = boldMatch.group(1)!;
      final after = text.substring(boldMatch.end);

      final styledInner = _parseRichControllerSpans(inner, baseStyle.copyWith(fontWeight: FontWeight.bold));

      return TextSpan(
        children: [
          _parseRichControllerSpans(before, baseStyle),
          styledInner,
          _parseRichControllerSpans(after, baseStyle),
        ],
      );
    }

    // 4. Italic tag
    final italicMatch = RegExp(r'\*(.*?)\*', dotAll: true).firstMatch(text);
    if (italicMatch != null) {
      final before = text.substring(0, italicMatch.start);
      final inner = italicMatch.group(1)!;
      final after = text.substring(italicMatch.end);

      final styledInner = _parseRichControllerSpans(inner, baseStyle.copyWith(fontStyle: FontStyle.italic));

      return TextSpan(
        children: [
          _parseRichControllerSpans(before, baseStyle),
          styledInner,
          _parseRichControllerSpans(after, baseStyle),
        ],
      );
    }

    // Strip unclosed tags
    final clean = text
        .replaceAll(RegExp(r'</?(color|mark)(=[^>]+)?>', caseSensitive: false), '')
        .replaceAll('**', '')
        .replaceAll('*', '');

    return TextSpan(text: clean, style: baseStyle);
  }
}
