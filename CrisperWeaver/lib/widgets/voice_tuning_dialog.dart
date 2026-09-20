import 'dart:io';
import '../utils/app_paths.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import '../main.dart' show modelServiceProvider;
import '../models/audiobook_models.dart';
import '../screens/model_management_screen.dart';
import '../services/audiobook_service.dart';
import '../services/imported_voice_service.dart';
import '../services/model_service.dart' show ModelKind;
import '../services/settings_service.dart';
import '../services/voice_pack_inspector.dart';
import '../utils/file_picker_util.dart' show pickFilesRobust;

class VoiceTuningDialog extends ConsumerStatefulWidget {
  final AudiobookSpeaker speaker;
  final String? initialSampleText;
  final Map<String, String> availableVoices;

  const VoiceTuningDialog({
    super.key,
    required this.speaker,
    this.initialSampleText,
    required this.availableVoices,
  });

  static Future<AudiobookSpeaker?> show(
    BuildContext context, {
    required AudiobookSpeaker speaker,
    String? initialSampleText,
    required Map<String, String> availableVoices,
  }) {
    return showDialog<AudiobookSpeaker>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => VoiceTuningDialog(
        speaker: speaker,
        initialSampleText: initialSampleText,
        availableVoices: availableVoices,
      ),
    );
  }

  @override
  ConsumerState<VoiceTuningDialog> createState() => _VoiceTuningDialogState();
}

class _VoiceTuningDialogState extends ConsumerState<VoiceTuningDialog> {
  late String _selectedVoiceModel;
  late double _speed;
  late double _pitch;
  late double _volume;
  String? _selectedPresetId;
  String? _customVoiceWavPath;

  late TextEditingController _sampleTextController;
  late TextEditingController _customVoiceRefTextController;
  late TextEditingController _clonedVoiceNameController;
  final AudioPlayer _player = AudioPlayer();
  bool _isSynthesizing = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _selectedVoiceModel = widget.speaker.voiceModelName;
    _speed = widget.speaker.speed;
    _pitch = widget.speaker.pitch;
    _volume = widget.speaker.volume;
    _customVoiceWavPath = widget.speaker.customVoiceWavPath;

    final defaultText = widget.initialSampleText != null && widget.initialSampleText!.trim().isNotEmpty
        ? widget.initialSampleText!.trim()
        : 'La nuit était tombée sur la ville brumeuse lorsque John s\'approcha de la fenêtre du bureau. Il regarda la rue déserte et soupira.';
    _sampleTextController = TextEditingController(text: defaultText);

    final initialRefText = widget.speaker.customVoiceRefText ?? 'Bonjour, je suis votre voix de référence en français.';
    _customVoiceRefTextController = TextEditingController(text: initialRefText);

    String initialCloneName = 'Ma Voix';
    final settings = ref.read(settingsServiceProvider);
    if (widget.speaker.voiceModelName.startsWith('clone_')) {
      final pid = widget.speaker.voiceModelName.replaceFirst('clone_', '');
      final match = settings.customClonedVoices.where((c) => c.id == pid).toList();
      if (match.isNotEmpty) {
        initialCloneName = match.first.name;
      }
    } else if (widget.speaker.name.isNotEmpty && widget.speaker.name != 'Narrateur') {
      initialCloneName = 'Voix ${widget.speaker.name}';
    }
    _clonedVoiceNameController = TextEditingController(text: initialCloneName);

    _player.playerStateStream.listen((state) {
      if (mounted) {
        final isReallyPlaying = state.playing &&
            state.processingState != ProcessingState.completed &&
            state.processingState != ProcessingState.idle;
        setState(() => _isPlaying = isReallyPlaying);
      }
    });
  }

  @override
  void dispose() {
    _sampleTextController.dispose();
    _customVoiceRefTextController.dispose();
    _clonedVoiceNameController.dispose();
    _player.dispose();
    super.dispose();
  }

  void _applyPreset(VoicePreset preset) {
    setState(() {
      _selectedPresetId = preset.id;
      _selectedVoiceModel = widget.availableVoices.containsKey(preset.voiceModelName)
          ? preset.voiceModelName
          : _selectedVoiceModel;
      _speed = preset.speed;
      _pitch = preset.pitch;
      _volume = preset.volume;
    });
  }

  Future<void> _saveCurrentAsNewPreset() async {
    final nameCtrl = TextEditingController(
      text: 'Preset ${_speed.toStringAsFixed(2)}x - ${widget.speaker.name}',
    );

    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enregistrer le Preset Vocal'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Nom du Preset',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      final newPreset = VoicePreset(
        id: 'preset_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        voiceModelName: _selectedVoiceModel,
        speed: _speed,
        pitch: _pitch,
        volume: _volume,
      );

      final settings = ref.read(settingsServiceProvider);
      await settings.saveCustomVoicePreset(newPreset);
      setState(() {
        _selectedPresetId = newPreset.id;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('💾 Preset "$name" mémorisé avec succès !'), backgroundColor: Colors.green.shade800),
        );
      }
    }
  }

  Future<void> _pickCustomVoiceWav() async {
    final result = await pickFilesRobust(
      dialogTitle: 'Sélectionner un extrait vocal de référence (.wav, .mp3, .flac)',
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'flac', 'ogg', 'm4a'],
    );

    if (result.localPaths.isNotEmpty) {
      setState(() {
        _customVoiceWavPath = result.localPaths.first;
        _selectedVoiceModel = 'custom-clone';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🎙️ Échantillon pour clonage sélectionné : ${p.basename(_customVoiceWavPath!)}'),
            backgroundColor: Colors.green.shade800,
          ),
        );
      }
    }
  }

    Future<void> _importVoicePackInDialog() async {
    final pick = await pickFilesRobust(
      type: FileType.custom,
      allowedExtensions: ['gguf'],
      dialogTitle: 'Importer un Voice Pack (.gguf)',
    );
    if (pick.localPaths.isEmpty) return;
    try {
      final path = pick.localPaths.first;
      final pack = await ref.read(importedVoiceServiceProvider.notifier).importVoicePack(path);
      setState(() {
        if (pack.family == VoicePackFamily.chatterbox) {
          _selectedVoiceModel = 'imported_chatterbox:${pack.fileName}';
        } else if (pack.family == VoicePackFamily.qwen3) {
          final spk = pack.presetSpeakers.isNotEmpty ? pack.presetSpeakers.first : null;
          _selectedVoiceModel = spk != null
              ? 'imported_qwen3:${pack.fileName}#$spk'
              : 'imported_qwen3:${pack.fileName}';
        }
        _selectedPresetId = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Voice Pack "${pack.id}" importé et assigné avec succès !'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur import Voice Pack : $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<bool> _ensureVoiceDownloaded(String voiceModelName) async {
    final modelService = ref.read(modelServiceProvider);
    String primaryModel = 'kokoro-82m-q8_0';
    String? voicepackToDownload;
    if (voiceModelName.startsWith('imported_chatterbox')) {
      primaryModel = 'chatterbox-t3-q8_0';
      voicepackToDownload = 'chatterbox-s3gen-q8_0';
    } else if (voiceModelName.startsWith('imported_qwen3')) {
      primaryModel = 'qwen3-tts-12hz-0.6b-base';
      voicepackToDownload = 'qwen3-tts-tokenizer-12hz';
    } else if (voiceModelName == 'custom-clone' || voiceModelName == 'custom-clone-new' || voiceModelName.startsWith('clone_')) {
      primaryModel = 'qwen3-tts-12hz-0.6b-base';
      voicepackToDownload = 'qwen3-tts-tokenizer-12hz';
    } else if (voiceModelName.startsWith('vibevoice-voice-') ||
        voiceModelName == 'vibevoice-fr-Spk0_man' ||
        voiceModelName == 'vibevoice-fr-Spk1_woman') {
      primaryModel = 'vibevoice-realtime-0.5b-tts-f16';
      voicepackToDownload = (voiceModelName == 'vibevoice-fr-Spk0_man')
          ? 'vibevoice-voice-fr-Spk0_man'
          : (voiceModelName == 'vibevoice-fr-Spk1_woman')
              ? 'vibevoice-voice-fr-Spk1_woman'
              : voiceModelName;
    } else if (voiceModelName.startsWith('vibevoice')) {
      primaryModel = 'vibevoice-1.5b-tts-q4_k';
    } else if (voiceModelName.startsWith('qwen3')) {
      primaryModel = 'qwen3-tts-12hz-0.6b-customvoice-q8_0';
      voicepackToDownload = 'qwen3-tts-tokenizer-12hz';
    } else if (voiceModelName.startsWith('kokoro')) {
      primaryModel = 'kokoro-82m-q8_0';
      if (voiceModelName != 'kokoro-82m-q8_0') {
        voicepackToDownload = voiceModelName;
      }
    }

    final mainModelPath = await modelService.getWhisperCppModelPath(primaryModel);
    final voicepackPath = voicepackToDownload != null ? await modelService.getWhisperCppModelPath(voicepackToDownload) : 'dummy';

    if (mainModelPath == null || voicepackPath == null) {
      if (!mounted) return false;
      final missingNames = [
        if (mainModelPath == null) primaryModel,
        if (voicepackPath == null && voicepackToDownload != null) voicepackToDownload,
      ].join(', ');

      final shouldDownload = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Modèle vocal non téléchargé'),
          content: Text(
            'Pour tester cette voix ($voiceModelName), le(s) composant(s) ($missingNames) doive(nt) être téléchargé(s).\n\nSouhaitez-vous le(s) télécharger maintenant ?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.download),
              onPressed: () => Navigator.pop(ctx, true),
              label: const Text('Télécharger'),
            ),
          ],
        ),
      );

      if (shouldDownload == true) {
        try {
          if (mainModelPath == null) {
            await modelService.downloadWhisperCppModel(primaryModel);
          }
          if (voicepackPath == null && voicepackToDownload != null) {
            await modelService.downloadWhisperCppModel(voicepackToDownload);
          }
          return true;
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Échec du téléchargement du modèle: $e'), backgroundColor: Colors.red),
            );
          }
          return false;
        }
      }
      return false;
    }
    return true;
  }

  Future<void> _testVoiceSample() async {
    if (_isSynthesizing) return;
    if (_isPlaying) {
      await _player.stop();
      return;
    }

    final text = _sampleTextController.text.trim();
    if (text.isEmpty) return;

    final ok = await _ensureVoiceDownloaded(_selectedVoiceModel);
    if (!ok) return;

    setState(() => _isSynthesizing = true);

    try {
      final dummyLine = AudiobookLine(
        id: 'test_sample',
        speakerId: widget.speaker.id,
        speakerName: widget.speaker.name,
        text: text,
      );

      final tunedSpeaker = widget.speaker.copyWith(
        voiceModelName: _selectedVoiceModel,
        speed: _speed,
        pitch: _pitch,
        volume: _volume,
        customVoiceWavPath: _customVoiceWavPath,
        customVoiceRefText: _customVoiceRefTextController.text.trim().isNotEmpty
            ? _customVoiceRefTextController.text.trim()
            : 'Bonjour, je suis votre voix de référence en français.',
      );

      final svc = ref.read(audiobookServiceProvider);
      final wavBytes = await svc.synthesizeLinesToMemory(
        lines: [dummyLine],
        speakers: {widget.speaker.id: tunedSpeaker},
      );

      final tempDir = AppPaths.tmpDir;
      final previewFile = File('${tempDir.path}/audiobook_tuning_sample.wav');
      await previewFile.writeAsBytes(wavBytes);

      setState(() => _isSynthesizing = false);

      await _player.setFilePath(previewFile.path);
      await _player.play();
    } catch (e) {
      setState(() => _isSynthesizing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur de test vocal: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = ref.watch(settingsServiceProvider);
    final customPresets = settings.customVoicePresets;
    final importedPacks = ref.watch(importedVoiceServiceProvider);

    final Map<String, String> activeVoices = Map<String, String>.from(widget.availableVoices);
    for (final pack in importedPacks) {
      if (!pack.fileExists) continue;
      if (pack.family == VoicePackFamily.chatterbox) {
        activeVoices['imported_chatterbox:${pack.fileName}'] = '📦 ${pack.id} (Chatterbox — Importée)';
      } else if (pack.family == VoicePackFamily.qwen3) {
        if (pack.presetSpeakers.length > 1) {
          for (final spk in pack.presetSpeakers) {
            activeVoices['imported_qwen3:${pack.fileName}#$spk'] = '📦 ${pack.id} — $spk (Qwen3 — Importée)';
          }
        } else {
          final spkName = pack.presetSpeakers.isNotEmpty ? pack.presetSpeakers.first : null;
          final key = spkName != null ? 'imported_qwen3:${pack.fileName}#$spkName' : 'imported_qwen3:${pack.fileName}';
          final name = spkName != null ? '${pack.id} — $spkName' : pack.id;
          activeVoices[key] = '📦 $name (Qwen3 — Importée)';
        }
      }
    }
    if (!activeVoices.containsKey('imported-pack-new')) {
      activeVoices['imported-pack-new'] = '📦 [ + Importer un Voice Pack (.gguf)... ]';
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 720,
        constraints: const BoxConstraints(maxHeight: 760),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.tune, color: cs.onPrimaryContainer, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Atelier de Paramétrage Vocal',
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Personnage : ${widget.speaker.name} (${widget.speaker.role})',
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.cloud_download_outlined, size: 20),
                  tooltip: 'Télécharger d\'autres modèles vocaux (Gestionnaire de modèles)',
                  onPressed: () {
                    Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const ModelManagementScreen(initialKindFilter: ModelKind.voice),
                      ),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(height: 24),

            // Content Area (Scrollable)
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Presets Bar
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.bookmarks, size: 18),
                          const SizedBox(width: 8),
                          const Text('Presets :', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isDense: true,
                                isExpanded: true,
                                value: _selectedPresetId,
                                hint: const Text('Sélectionner un profil pré-réglé...', style: TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                                items: customPresets.map((p) {
                                  return DropdownMenuItem<String>(
                                    value: p.id,
                                    child: Text(p.name, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    final match = customPresets.firstWhere((p) => p.id == val);
                                    _applyPreset(match);
                                  }
                                },
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.save_as, size: 18),
                            tooltip: 'Sauvegarder les réglages actuels en nouveau preset',
                            onPressed: _saveCurrentAsNewPreset,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Voice Model Selector
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Modèle de Voix Assigné', style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold)),
                        TextButton.icon(
                          onPressed: () {
                            Navigator.push<void>(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => const ModelManagementScreen(initialKindFilter: ModelKind.voice),
                              ),
                            );
                          },
                          icon: const Icon(Icons.download, size: 14),
                          label: const Text('Gérer les téléchargements', style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      key: ValueKey('tuning_voice_${activeVoices.length}_$_selectedVoiceModel'),
                      isDense: true,
                      isExpanded: true,
                      initialValue: activeVoices.containsKey(_selectedVoiceModel)
                          ? _selectedVoiceModel
                          : activeVoices.keys.first,
                      items: activeVoices.entries.map((e) {
                        return DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (v) {
                        if (v != null) {
                          if (v == 'imported-pack-new') {
                            _importVoicePackInDialog();
                            return;
                          }
                          setState(() {
                            _selectedVoiceModel = v;
                            _selectedPresetId = null;
                          });
                        }
                      },
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),

                    // Custom Voice Cloning Card
                    if (_selectedVoiceModel.startsWith('clone_') || _selectedVoiceModel == 'custom-clone' || _selectedVoiceModel == 'custom-clone-new' || _customVoiceWavPath != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: cs.primary.withValues(alpha: 0.5)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.mic, size: 16),
                                const SizedBox(width: 6),
                                const Text('Clonage Vocal & Banque de Voix', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                const Spacer(),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.folder_open, size: 14),
                                  label: Text(_customVoiceWavPath == null ? 'Importer un extrait (.wav/.mp3)' : 'Changer'),
                                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                                  onPressed: _pickCustomVoiceWav,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _clonedVoiceNameController,
                              style: const TextStyle(fontSize: 12),
                              decoration: const InputDecoration(
                                labelText: 'Nom de la voix (visible dans le sélecteur)',
                                hintText: 'Ex: Ma Voix, Voix Marc, Voix Sophie...',
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              ),
                            ),
                            if (_customVoiceWavPath != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: cs.surface,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.audiotrack, size: 16, color: Colors.green),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        p.basename(_customVoiceWavPath!),
                                        style: TextStyle(fontSize: 12, color: cs.onSurface, fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.play_circle_fill, size: 20, color: Colors.blue),
                                      tooltip: 'Écouter l\'extrait source',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () async {
                                        await _player.setFilePath(_customVoiceWavPath!);
                                        await _player.play();
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.close, size: 18, color: Colors.red),
                                      tooltip: 'Retirer l\'extrait',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () {
                                        setState(() {
                                          _customVoiceWavPath = null;
                                          _selectedVoiceModel = 'qwen3-uncle_fu';
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: _customVoiceRefTextController,
                                style: const TextStyle(fontSize: 11),
                                decoration: const InputDecoration(
                                  labelText: 'Transcription de référence',
                                  helperText: 'Required for Qwen3-TTS Base and VibeVoice 1.5B when cloning from a WAV.',
                                  helperMaxLines: 2,
                                  hintText: 'Ex: Bonjour, je teste ma voix pour le livre audio...',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                ),
                              ),
                            ] else ...[
                              const SizedBox(height: 6),
                              const Text(
                                '💡 Pour un résultat optimal : utilisez un fichier audio de 5 à 15 secondes parlant clairement en français, sans musique de fond.',
                                style: TextStyle(fontSize: 11, color: Colors.grey),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),

                    // Sliders Section
                    Row(
                      children: [
                        // Speed Slider
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Vitesse de diction', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                  Text('${_speed.toStringAsFixed(2)}x', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              Slider(
                                value: _speed,
                                min: 0.6,
                                max: 1.6,
                                divisions: 20,
                                label: '${_speed.toStringAsFixed(2)}x',
                                onChanged: (v) {
                                  setState(() {
                                    _speed = v;
                                    _selectedPresetId = null;
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 20),
                        // Pitch / Tone Slider
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Tonalité / Pitch', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                  Text(
                                    _pitch < 0.96 ? 'Grave (${_pitch.toStringAsFixed(2)})' : (_pitch > 1.04 ? 'Aigu (${_pitch.toStringAsFixed(2)})' : 'Neutre'),
                                    style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              Slider(
                                value: _pitch,
                                min: 0.7,
                                max: 1.4,
                                divisions: 14,
                                label: _pitch.toStringAsFixed(2),
                                onChanged: (v) {
                                  setState(() {
                                    _pitch = v;
                                    _selectedPresetId = null;
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Volume Slider
                    Row(
                      children: [
                        const Text('Volume sonore :', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(width: 8),
                        Text('${(_volume * 100).toInt()}%', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
                        Expanded(
                          child: Slider(
                            value: _volume,
                            min: 0.5,
                            max: 1.5,
                            divisions: 10,
                            label: '${(_volume * 100).toInt()}%',
                            onChanged: (v) {
                              setState(() {
                                _volume = v;
                                _selectedPresetId = null;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Test Sample Section
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.record_voice_over, size: 16),
                              const SizedBox(width: 6),
                              const Text('Extrait de test en direct :', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              const Spacer(),
                              if (_isSynthesizing)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              else
                                FilledButton.tonalIcon(
                                  onPressed: _testVoiceSample,
                                  icon: Icon(_isPlaying ? Icons.stop : Icons.volume_up, size: 16),
                                  label: Text(_isPlaying ? 'Stopper' : 'Écouter le rendu'),
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _sampleTextController,
                            maxLines: 2,
                            style: const TextStyle(fontSize: 12),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              hintText: 'Saisissez ou collez du texte pour tester vos réglages...',
                              contentPadding: EdgeInsets.all(8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 24),

            // Dialog Footer
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annuler'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Appliquer au Personnage'),
                  onPressed: () {
                    final settings = ref.read(settingsServiceProvider);
                    final nav = Navigator.of(context);
                    String effectiveVoiceModel = _selectedVoiceModel;
                    ClonedVoiceProfile? profileToSave;

                    if (_customVoiceWavPath != null && _customVoiceWavPath!.isNotEmpty) {
                      final profileId = _selectedVoiceModel.startsWith('clone_')
                          ? _selectedVoiceModel.replaceFirst('clone_', '')
                          : '${DateTime.now().millisecondsSinceEpoch}';
                      final cloneName = _clonedVoiceNameController.text.trim().isNotEmpty
                          ? _clonedVoiceNameController.text.trim()
                          : (widget.speaker.name.isNotEmpty ? 'Voix de ${widget.speaker.name}' : 'Ma Voix');

                      profileToSave = ClonedVoiceProfile(
                        id: profileId,
                        name: cloneName,
                        wavPath: _customVoiceWavPath!,
                        refText: _customVoiceRefTextController.text.trim().isNotEmpty
                            ? _customVoiceRefTextController.text.trim()
                            : 'Bonjour, je suis votre voix de référence en français.',
                        defaultSpeed: _speed,
                        defaultPitch: _pitch,
                        defaultVolume: _volume,
                        createdAt: DateTime.now(),
                      );
                      effectiveVoiceModel = 'clone_$profileId';
                    }

                    final updatedSpeaker = widget.speaker.copyWith(
                      voiceModelName: effectiveVoiceModel,
                      speed: _speed,
                      pitch: _pitch,
                      volume: _volume,
                      presetName: _selectedPresetId,
                      customVoiceWavPath: _customVoiceWavPath,
                      customVoiceRefText: _customVoiceRefTextController.text.trim().isNotEmpty
                          ? _customVoiceRefTextController.text.trim()
                          : 'Bonjour, je suis votre voix de référence en français.',
                    );

                    // Persist voice defaults in SettingsService (synchronous in-memory update)
                    if (widget.speaker.id == 'narrator') {
                      settings.defaultNarratorVoice = effectiveVoiceModel;
                    } else if (widget.speaker.role == 'male') {
                      settings.defaultMaleVoice = effectiveVoiceModel;
                    } else if (widget.speaker.role == 'female') {
                      settings.defaultFemaleVoice = effectiveVoiceModel;
                    }
                    settings.saveSpeakerVoiceConfig(widget.speaker.id, updatedSpeaker.toJson());

                    // Fermer immédiatement (pas d'attente I/O) puis sauvegarder en arrière-plan
                    nav.pop(updatedSpeaker);
                    if (profileToSave != null) {
                      settings.saveClonedVoice(profileToSave);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
