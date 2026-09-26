import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart' show transcriptionServiceProvider;
import '../services/audio_service.dart';
import '../services/settings_service.dart';
import 'assistant_voice_settings_dialog.dart';

/// Compact microphone control shared by Assistant Audio and Assistant Documents.
///
/// Design goals for Voice I/O R1:
/// - reuse Jarvisol's existing microphone + transcription stack;
/// - never alter the active ASR model or the global transcription settings;
/// - force French for prompt dictation;
/// - never auto-send a prompt: the transcript is inserted in the text field;
/// - keep temporary microphone recordings out of user history by deleting them
///   after transcription;
/// - refuse concurrent use while another transcription/recording is active.
class VoiceDictationButton extends ConsumerStatefulWidget {
  const VoiceDictationButton({
    super.key,
    required this.controller,
    this.enabled = true,
    this.onBusyChanged,
    this.onRecordingStarted,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<bool>? onBusyChanged;
  final VoidCallback? onRecordingStarted;

  @override
  ConsumerState<VoiceDictationButton> createState() =>
      _VoiceDictationButtonState();
}

class _VoiceDictationButtonState extends ConsumerState<VoiceDictationButton> {
  bool _isRecording = false;
  bool _isTranscribing = false;
  String? _recordingPath;
  bool _wasBusy = false;

  void _notifyBusy(bool busy) {
    if (_wasBusy != busy) {
      _wasBusy = busy;
      widget.onBusyChanged?.call(busy);
    }
  }

  @override
  void dispose() {
    _notifyBusy(false);
    final currentRecording = _recordingPath;
    _recordingPath = null;
    if (_isRecording) {
      _isRecording = false;
      unawaited(() async {
        try {
          final stoppedPath =
              await ref.read(audioServiceProvider).stopRecording();
          final pathToClean = stoppedPath ?? currentRecording;
          if (pathToClean != null && pathToClean.isNotEmpty) {
            _deleteTemporaryRecording(pathToClean);
          }
        } catch (_) {
          if (currentRecording != null && currentRecording.isNotEmpty) {
            _deleteTemporaryRecording(currentRecording);
          }
        }
      }());
    } else if (currentRecording != null && currentRecording.isNotEmpty) {
      _deleteTemporaryRecording(currentRecording);
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isTranscribing) return;
    if (_isRecording) {
      await _stopAndTranscribe();
    } else if (widget.enabled) {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final audio = ref.read(audioServiceProvider);
    final transcription = ref.read(transcriptionServiceProvider);

    if (audio.isRecording) {
      _showMessage('Le microphone est déjà utilisé par Jarvisol.');
      return;
    }
    if (transcription.isTranscribing ||
        (transcription.currentEngine?.isProcessing ?? false)) {
      _showMessage('Une transcription est déjà en cours.');
      return;
    }
    final engine = transcription.currentEngine;
    if (engine == null || engine.currentModelId == null) {
      _showMessage(
        'Aucun modèle de transcription n’est chargé. Chargez un modèle ASR puis réessayez.',
      );
      return;
    }

    final settings = ref.read(settingsServiceProvider);
    widget.onRecordingStarted?.call();
    final path = await audio.startRecording(settingsService: settings);
    if (!mounted) return;
    if (path == null) {
      _notifyBusy(false);
      _showMessage('Impossible d’accéder au microphone.');
      return;
    }

    setState(() {
      _recordingPath = path;
      _isRecording = true;
    });
    _notifyBusy(true);
  }

  Future<void> _stopAndTranscribe() async {
    final audio = ref.read(audioServiceProvider);
    final transcription = ref.read(transcriptionServiceProvider);

    String? path;
    try {
      final stoppedPath = await audio.stopRecording();
      path = stoppedPath ?? _recordingPath;
    } catch (_) {
      path = _recordingPath;
    }

    if (!mounted) {
      if (path != null && path.isNotEmpty) {
        _deleteTemporaryRecording(path);
      }
      return;
    }

    setState(() {
      _isRecording = false;
      _isTranscribing = true;
    });
    _notifyBusy(true);

    if (path == null || path.isEmpty) {
      setState(() => _isTranscribing = false);
      _notifyBusy(false);
      _showMessage('L’enregistrement vocal n’a pas pu être récupéré.');
      return;
    }

    try {
      final segments = await transcription.transcribeFile(
        File(path),
        language: 'fr',
        enableDiarization: false,
        enableWordTimestamps: false,
        translate: false,
        beamSearch: false,
        vad: false,
        restorePunctuation: false,
        temperature: 0.0,
        bestOf: 1,
      );
      final text = segments
          .map((segment) => segment.text.trim())
          .where((part) => part.isNotEmpty)
          .join(' ')
          .trim();

      if (!mounted) return;
      if (text.isEmpty) {
        _showMessage('Aucune parole exploitable n’a été reconnue.');
        return;
      }
      _insertAtSelection(text);
    } catch (e) {
      if (mounted) {
        _showMessage('Erreur de dictée vocale : $e');
      }
    } finally {
      _deleteTemporaryRecording(path);
      _recordingPath = null;
      if (mounted) {
        setState(() => _isTranscribing = false);
      }
      _notifyBusy(false);
    }
  }

  void _insertAtSelection(String transcript) {
    final controller = widget.controller;
    final original = controller.text;
    final selection = controller.selection;

    var start = selection.isValid ? selection.start : original.length;
    var end = selection.isValid ? selection.end : original.length;
    start = start.clamp(0, original.length).toInt();
    end = end.clamp(start, original.length).toInt();

    final before = original.substring(0, start);
    final after = original.substring(end);
    final needsLeadingSpace =
        before.isNotEmpty && !RegExp(r'\s$').hasMatch(before);
    final needsTrailingSpace = after.isNotEmpty &&
        !RegExp(r'^\s').hasMatch(after) &&
        !RegExp(r'^[,.;:!?\)\]\}]').hasMatch(after);

    final insertion =
        '${needsLeadingSpace ? ' ' : ''}$transcript${needsTrailingSpace ? ' ' : ''}';
    final updated = before + insertion + after;
    final caret = (before + insertion).length;

    controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  void _deleteTemporaryRecording(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Dictation must remain usable even if Windows briefly keeps the WAV open.
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        try {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {}
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isTranscribing) {
      return const Padding(
        padding: EdgeInsets.all(10),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final canClick = (_isRecording || widget.enabled) && !_isTranscribing;

    return IconButton(
      tooltip: _isRecording
          ? 'Arrêter et transcrire la dictée'
          : 'Dicter le prompt en français',
      onPressed: canClick ? _toggle : null,
      icon: Icon(
        _isRecording ? Icons.stop_circle_rounded : Icons.mic_none_rounded,
      ),
      color: _isRecording ? Colors.redAccent : null,
    );
  }
}

/// Commande compacte synchronisée "🔊 Réponse vocale auto" (AUA-004 / DOC-VOICE-R1B).
/// OFF par défaut. Synchronisée globalement entre Assistant Audio et Assistant Documents.
/// Permet aussi d'interrompre immédiatement la lecture en cours (Stop).
class AutoTtsToggleButton extends ConsumerWidget {
  const AutoTtsToggleButton({
    super.key,
    this.isAudioPlaying = false,
    this.isSynthesizing = false,
    this.onStopRequested,
    this.showSettingsButton = true,
  });

  final bool isAudioPlaying;
  final bool isSynthesizing;
  final VoidCallback? onStopRequested;
  final bool showSettingsButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autoTts = ref.watch(autoTtsResponseEnabledProvider);
    final theme = Theme.of(context);
    final isBusy = isAudioPlaying || isSynthesizing;

    Widget mainPill;
    // Si une lecture ou synthèse est en cours, afficher un bouton Stop immédiat
    if (isBusy && onStopRequested != null) {
      mainPill = IconButton(
        visualDensity: VisualDensity.compact,
        icon: isSynthesizing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.orangeAccent),
                ),
              )
            : const Icon(Icons.stop_circle_rounded, color: Colors.redAccent, size: 20),
        tooltip: isSynthesizing
            ? 'Synthèse vocale en cours... (cliquer pour annuler)'
            : 'Arrêter la lecture vocale en cours',
        onPressed: onStopRequested,
      );
    } else {
      final activeColor = theme.colorScheme.primary;
      mainPill = Tooltip(
        message: autoTts
            ? 'Réponse vocale auto : ACTIVÉE (cliquer pour désactiver)'
            : 'Réponse vocale auto : DÉSACTIVÉE (cliquer pour activer)',
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            ref.read(autoTtsResponseEnabledProvider.notifier).toggle();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: autoTts
                  ? activeColor.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: autoTts
                    ? activeColor.withValues(alpha: 0.6)
                    : Colors.grey.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  autoTts ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                  size: 15,
                  color: autoTts ? activeColor : Colors.grey,
                ),
                const SizedBox(width: 4),
                Text(
                  'Auto',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: autoTts ? FontWeight.w600 : FontWeight.normal,
                    color: autoTts ? activeColor : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!showSettingsButton) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: mainPill,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          mainPill,
          const SizedBox(width: 2),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 17,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            icon: Icon(
              Icons.tune_rounded,
              size: 17,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
            tooltip: 'Réglages de la voix de l’assistant',
            onPressed: () => AssistantVoiceSettingsDialog.show(context),
          ),
        ],
      ),
    );
  }
}

