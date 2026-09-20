// lib/services/audiobook_service.dart — orchestrates multi-voice casting, chapter segmentation, and batch TTS synthesis.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:crispasr/crispasr.dart' as crispasr;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../utils/app_paths.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/audiobook_models.dart';
import '../models/audiobook_rules.dart';
import 'document_rag_service.dart';
import 'document_source_service.dart';
import 'imported_voice_service.dart';
import 'log_service.dart';
import 'tts_service.dart';
import 'voice_pack_inspector.dart' show VoicePackFamily;

final audiobookServiceProvider = Provider<AudiobookService>((ref) {
  final tts = ref.watch(ttsServiceProvider);
  final imported = ref.watch(importedVoiceServiceProvider.notifier);
  return AudiobookService(tts, imported);
});

class AudiobookService {
  final TtsService _ttsService;
  final ImportedVoiceService _importedVoiceService;

  AudiobookService(this._ttsService, [ImportedVoiceService? importedVoiceService])
      : _importedVoiceService = importedVoiceService ?? ImportedVoiceService();

  static const Map<String, String> qwenSpeakerMap = {
    // Current official IDs
    'qwen3-uncle_fu': 'uncle_fu',
    'qwen3-ryan': 'ryan',
    'qwen3-eric': 'eric',
    'qwen3-aiden': 'aiden',
    'qwen3-dylan': 'dylan',
    'qwen3-vivian': 'vivian',
    'qwen3-serena': 'serena',
    'qwen3-ono_anna': 'ono_anna',
    'qwen3-sohee': 'sohee',

    // Legacy IDs mapped to closest matching voice
    'qwen3-ethan': 'ryan',
    'qwen3-martin': 'uncle_fu',
    'qwen3-chelsie': 'ono_anna',
    'uncle_martin': 'uncle_fu',
    'ethan': 'ryan',
    'chelsie': 'ono_anna',
  };

  /// Default French voices for casting roles.
  static const Map<String, String> defaultVoiceRoles = {
    'narrator': 'qwen3-uncle_fu',
    'male_main': 'qwen3-ryan',
    'female_main': 'qwen3-vivian',
  };

  /// Creates a new audiobook project from an EPUB, PDF, DOCX or TXT file with a specific rules profile.
  Future<AudiobookProject> createProjectFromFile(
    String filePath, {
    AudiobookRuleProfile? profile,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw Exception('Fichier introuvable: $filePath');
    }

    final activeProfile = profile ?? AudiobookRuleProfile.standard;
    final title = p.basenameWithoutExtension(filePath);
    final now = DateTime.now();

    final docItem = await DocumentSourceService().parseFile(filePath);
    final cleanedText = activeProfile.applyCleaning(docItem.textContent);
    final rawChapters = _splitTextIntoChapters(cleanedText, title, profile: activeProfile);

    final defaultSpeakers = <String, AudiobookSpeaker>{
      'narrator': const AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: 'kokoro-voice-ff_siwis',
        role: 'narrator',
      ),
      'male_main': const AudiobookSpeaker(
        id: 'male_main',
        name: 'Personnage Principal (H)',
        voiceModelName: 'qwen3-ryan',
        role: 'male',
      ),
      'female_main': const AudiobookSpeaker(
        id: 'female_main',
        name: 'Personnage Principal (F)',
        voiceModelName: 'kokoro-voice-ff_siwis',
        role: 'female',
      ),
    };

    // Pre-segment lines for all chapters
    final chapters = rawChapters.map((chap) {
      final lines = castChapterLinesSync(
        chapter: chap,
        speakers: defaultSpeakers,
        profile: activeProfile,
      );
      return chap.copyWith(lines: lines);
    }).toList();

    return AudiobookProject(
      id: 'proj_${now.millisecondsSinceEpoch}',
      title: title,
      author: 'Auteur',
      sourcePath: filePath,
      chapters: chapters,
      speakers: defaultSpeakers,
      createdAt: now,
    );
  }

  /// Creates an audiobook project directly from a cached RAG document entry with a specific rules profile.
  Future<AudiobookProject> createProjectFromCachedDoc(
    CachedDocumentEntry doc, {
    AudiobookRuleProfile? profile,
  }) async {
    final activeProfile = profile ?? AudiobookRuleProfile.standard;
    final cleanedText = activeProfile.applyCleaning(doc.reconstructedText);

    List<AudiobookChapter> rawChapters = [];

    // 1. Check if RAG chunks already contain distinct structured chapter titles
    final chunkTitles = doc.chunks
        .map((c) => c.chapterTitle?.trim())
        .where((t) => t != null && t.isNotEmpty && t != 'Général' && t != doc.sourceName)
        .toSet();

    if (chunkTitles.length > 1) {
      final grouped = <String, StringBuffer>{};
      for (final c in doc.chunks) {
        final title = (c.chapterTitle != null && c.chapterTitle!.trim().isNotEmpty)
            ? c.chapterTitle!.trim()
            : 'Section';
        final cleanChunk = activeProfile.applyCleaning(c.text);
        grouped.putIfAbsent(title, () => StringBuffer()).writeln(cleanChunk);
      }

      int idx = 1;
      for (final entry in grouped.entries) {
        rawChapters.add(AudiobookChapter(
          id: 'chap_$idx',
          index: idx,
          title: entry.key,
          rawText: entry.value.toString().trim(),
        ));
        idx++;
      }
    }

    // 2. Fallback to robust textual segmentation on the reconstructed text
    if (rawChapters.length <= 1) {
      rawChapters = _splitTextIntoChapters(cleanedText, doc.sourceName, profile: activeProfile);
    }

    final defaultSpeakers = <String, AudiobookSpeaker>{
      'narrator': const AudiobookSpeaker(
        id: 'narrator',
        name: 'Narrateur',
        voiceModelName: 'kokoro-voice-ff_siwis',
        role: 'narrator',
      ),
      'male_main': const AudiobookSpeaker(
        id: 'male_main',
        name: 'Personnage Principal (H)',
        voiceModelName: 'qwen3-ryan',
        role: 'male',
      ),
      'female_main': const AudiobookSpeaker(
        id: 'female_main',
        name: 'Personnage Principal (F)',
        voiceModelName: 'kokoro-voice-ff_siwis',
        role: 'female',
      ),
    };

    // Pre-segment lines for all chapters
    final chapters = rawChapters.map((chap) {
      final lines = castChapterLinesSync(
        chapter: chap,
        speakers: defaultSpeakers,
        profile: activeProfile,
      );
      return chap.copyWith(lines: lines);
    }).toList();

    return AudiobookProject(
      id: 'proj_${DateTime.now().millisecondsSinceEpoch}',
      title: doc.sourceName,
      author: 'Auteur',
      sourcePath: doc.fileName,
      chapters: chapters,
      speakers: defaultSpeakers,
      createdAt: DateTime.now(),
    );
  }

  /// Robust chapter segmentation for French/English novels, essays, and documents.
  List<AudiobookChapter> _splitTextIntoChapters(
    String fullText,
    String defaultTitle, {
    AudiobookRuleProfile? profile,
  }) {
    final activeProfile = profile ?? AudiobookRuleProfile.standard;
    final lines = fullText.split('\n');
    final rawChapters = <AudiobookChapter>[];

    final chapterRegex = RegExp(
      activeProfile.chapterRegex,
      caseSensitive: false,
    );

    var currentTitle = 'Introduction';
    var currentBuffer = StringBuffer();
    var chapIndex = 1;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // Heading candidate: short line (< 80 chars) matching the chapter regex
      final isHeadingCandidate = trimmed.isNotEmpty &&
          trimmed.length < 80 &&
          chapterRegex.hasMatch(trimmed);

      if (isHeadingCandidate) {
        if (currentBuffer.isNotEmpty) {
          final content = currentBuffer.toString().trim();
          if (content.isNotEmpty) {
            String displayTitle = _cleanChapterTitle(currentTitle);
            rawChapters.add(AudiobookChapter(
              id: 'chap_$chapIndex',
              index: chapIndex,
              title: displayTitle,
              rawText: content,
            ));
            chapIndex++;
          }
          currentBuffer = StringBuffer();
        }
        currentTitle = trimmed;
      } else {
        currentBuffer.writeln(line);
      }
    }

    if (currentBuffer.isNotEmpty) {
      final content = currentBuffer.toString().trim();
      if (content.isNotEmpty) {
        String displayTitle = _cleanChapterTitle(currentTitle);
        rawChapters.add(AudiobookChapter(
          id: 'chap_$chapIndex',
          index: chapIndex,
          title: displayTitle,
          rawText: content,
        ));
      }
    }

    if (rawChapters.isEmpty) {
      rawChapters.add(AudiobookChapter(
        id: 'chap_1',
        index: 1,
        title: defaultTitle,
        rawText: fullText.trim(),
      ));
    }

    // 3. Post-process: Subdivide excessively large chapters (> 3500 words) into manageable sub-parts
    final finalChapters = <AudiobookChapter>[];
    int finalIndex = 1;

    for (final chap in rawChapters) {
      if (chap.wordCount > 3500) {
        final subParts = _subdivideLargeChapter(chap, maxWordsPerPart: 2500);
        for (final sub in subParts) {
          finalChapters.add(sub.copyWith(
            id: 'chap_$finalIndex',
            index: finalIndex,
          ));
          finalIndex++;
        }
      } else {
        finalChapters.add(chap.copyWith(
          id: 'chap_$finalIndex',
          index: finalIndex,
        ));
        finalIndex++;
      }
    }

    return finalChapters;
  }

  String _cleanChapterTitle(String rawTitle) {
    var title = rawTitle.trim();

    // Clean RAG marker: "--- Chapitre / Section 18 ---" -> "Chapitre 18"
    final ragMatch = RegExp(r'^---\s*(?:chapitre\s*/\s*section|section|chapitre|chapter)\s*(\d+|[ivxldcm]+|[a-zÀ-ÿ\-]+)\s*---$', caseSensitive: false).firstMatch(title);
    if (ragMatch != null) {
      return 'Chapitre ${ragMatch.group(1)}';
    }

    // Clean pure number "18" -> "Chapitre 18"
    if (RegExp(r'^\d+$').hasMatch(title)) {
      return 'Chapitre $title';
    }

    // Clean pure Roman "XVIII" -> "Chapitre XVIII"
    if (RegExp(r'^[IVXLCDM]+$', caseSensitive: false).hasMatch(title)) {
      return 'Chapitre $title';
    }

    // Clean Markdown "### Chapitre 1" -> "Chapitre 1"
    title = title.replaceAll(RegExp(r'^#+\s*'), '');

    return title;
  }

  /// Subdivides a very large chapter at scene breaks or paragraph boundaries.
  List<AudiobookChapter> _subdivideLargeChapter(AudiobookChapter chapter, {int maxWordsPerPart = 2500}) {
    final paragraphs = chapter.rawText.split(RegExp(r'\n{2,}'));
    final parts = <AudiobookChapter>[];
    var currentBuf = StringBuffer();
    var currentWordCount = 0;
    var partNum = 1;

    for (final p in paragraphs) {
      final pTrim = p.trim();
      if (pTrim.isEmpty) continue;

      final wordsInP = pTrim.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

      if (currentWordCount + wordsInP > maxWordsPerPart && currentBuf.isNotEmpty) {
        parts.add(AudiobookChapter(
          id: '${chapter.id}_part$partNum',
          index: partNum,
          title: '${chapter.title} (Partie $partNum)',
          rawText: currentBuf.toString().trim(),
        ));
        partNum++;
        currentBuf = StringBuffer();
        currentWordCount = 0;
      }

      currentBuf.writeln(pTrim);
      currentBuf.writeln();
      currentWordCount += wordsInP;
    }

    if (currentBuf.isNotEmpty) {
      parts.add(AudiobookChapter(
        id: '${chapter.id}_part$partNum',
        index: partNum,
        title: parts.isEmpty ? chapter.title : '${chapter.title} (Partie $partNum)',
        rawText: currentBuf.toString().trim(),
      ));
    }

    return parts;
  }

  /// Synchronous casting and dialogue diarization with robust French dialogue extraction.
  List<AudiobookLine> castChapterLinesSync({
    required AudiobookChapter chapter,
    required Map<String, AudiobookSpeaker> speakers,
    AudiobookRuleProfile? profile,
  }) {
    final text = chapter.rawText.trim();
    if (text.isEmpty) return [];

    final activeProfile = profile ?? AudiobookRuleProfile.standard;
    final List<AudiobookLine> parsedLines = [];
    final rawParagraphs = text.split(RegExp(r'\n+'));

    final dialogueRegex = RegExp(activeProfile.dialogueMarkerRegex);
    final femaleRegex = RegExp(activeProfile.femaleKeywordsRegex, caseSensitive: false);

    int lineCounter = 1;

    for (final para in rawParagraphs) {
      final p = para.trim();
      if (p.isEmpty) continue;

      // Only split on true dialogue markers
      if (dialogueRegex.hasMatch(p)) {
        final parts = p.split(dialogueRegex);
        final startsWithMarker = p.startsWith('—') || p.startsWith('–') || p.startsWith('-');

        if (startsWithMarker) {
          for (final part in parts) {
            final clean = part.trim();
            if (clean.isEmpty) continue;
            final isFemale = femaleRegex.hasMatch(clean);

            final speakerId = isFemale ? 'female_main' : 'male_main';
            final speakerName = speakers[speakerId]?.name ?? (isFemale ? 'Personnage F' : 'Personnage H');

            parsedLines.add(AudiobookLine(
              id: 'line_${chapter.index}_$lineCounter',
              speakerId: speakerId,
              speakerName: speakerName,
              text: clean,
            ));
            lineCounter++;
          }
        } else {
          // First part before the marker is narration
          if (parts.isNotEmpty && parts[0].trim().isNotEmpty) {
            parsedLines.add(AudiobookLine(
              id: 'line_${chapter.index}_$lineCounter',
              speakerId: 'narrator',
              speakerName: speakers['narrator']?.name ?? 'Narrateur',
              text: parts[0].trim(),
            ));
            lineCounter++;
          }

          // Following parts are dialogues
          for (int idx = 1; idx < parts.length; idx++) {
            final clean = parts[idx].trim();
            if (clean.isEmpty) continue;
            final isFemale = femaleRegex.hasMatch(clean);

            final speakerId = isFemale ? 'female_main' : 'male_main';
            final speakerName = speakers[speakerId]?.name ?? (isFemale ? 'Personnage F' : 'Personnage H');

            parsedLines.add(AudiobookLine(
              id: 'line_${chapter.index}_$lineCounter',
              speakerId: speakerId,
              speakerName: speakerName,
              text: clean,
            ));
            lineCounter++;
          }
        }
      } else {
        // Pure narrative paragraph
        parsedLines.add(AudiobookLine(
          id: 'line_${chapter.index}_$lineCounter',
          speakerId: 'narrator',
          speakerName: speakers['narrator']?.name ?? 'Narrateur',
          text: p,
        ));
        lineCounter++;
      }
    }

    return parsedLines;
  }

  /// Async wrapper for compatibility.
  Future<List<AudiobookLine>> castChapterLines({
    required AudiobookChapter chapter,
    required Map<String, AudiobookSpeaker> speakers,
    AudiobookRuleProfile? profile,
  }) async {
    return castChapterLinesSync(chapter: chapter, speakers: speakers, profile: profile);
  }

  /// Synthesizes a full chapter into a single audio file with multi-voice staging.
  /// Converts/resamples any input audio (WhatsApp, MP3, 44.1k, 48k, etc.) to 24kHz mono 16-bit WAV for TTS engines.
  Future<String> ensure24kHzWav(String audioPath) async {
    final file = File(audioPath);
    if (!await file.exists()) return audioPath;

    // Fast check: if already standard 24kHz mono 16-bit PCM WAV, return path as is
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > 44 &&
          bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && // RIFF
          bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 && bytes[11] == 0x45) { // WAVE
        final sr = bytes[24] | (bytes[25] << 8) | (bytes[26] << 16) | (bytes[27] << 24);
        final ch = bytes[22] | (bytes[23] << 8);
        final bps = bytes[34] | (bytes[35] << 8);
        if (sr == 24000 && ch == 1 && bps == 16) {
          return audioPath;
        }
      }
    } catch (_) {}

    try {
      final decoded = crispasr.decodeAudioFile(audioPath);
      if (decoded.samples.isNotEmpty) {
        final samples = decoded.samples;
        final inSr = decoded.sampleRate > 0 ? decoded.sampleRate : 16000;
        List<double> outSamples;
        if (inSr == 24000) {
          outSamples = samples.map((e) => e.toDouble()).toList();
        } else {
          final ratio = inSr / 24000.0;
          final outLen = (samples.length / ratio).round();
          outSamples = List<double>.filled(outLen, 0.0);
          for (int i = 0; i < outLen; i++) {
            final inPos = i * ratio;
            final idx0 = inPos.floor();
            final idx1 = (idx0 + 1 < samples.length) ? idx0 + 1 : idx0;
            final frac = inPos - idx0;
            outSamples[i] = (samples[idx0] * (1.0 - frac) + samples[idx1] * frac).toDouble();
          }
        }

        final tempDir = AppPaths.tmpDir;
        final outWavPath = '${tempDir.path}/cloned_ref_24k_${DateTime.now().millisecondsSinceEpoch}.wav';
        final wavBytes = createWavHeaderAndData(Float32List.fromList(outSamples), 24000);
        await File(outWavPath).writeAsBytes(wavBytes);
        return outWavPath;
      }
    } catch (e) {
      Log.instance.w('audiobook', 'ensure24kHzWav fallback: $e');
    }
    return audioPath;
  }

  final List<String> _tempResampledPaths = [];

  void _cleanTempResampledPaths() {
    _tempResampledPaths.removeWhere((p) {
      try {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      return true;
    });
  }

  /// Visible for testing to verify speaker resolution and routing.
  Future<TtsLoadStatus> prepareSpeakerForTest(AudiobookSpeaker speaker) => _prepareSpeaker(speaker);

  Future<TtsLoadStatus> _prepareSpeaker(AudiobookSpeaker speaker) async {
    if (speaker.customVoiceWavPath != null && speaker.customVoiceWavPath!.isNotEmpty) {
      if (speaker.customVoiceRefText == null || speaker.customVoiceRefText!.trim().isEmpty) {
        return TtsLoadStatus.error(
          'Texte de référence (refText) obligatoire pour le clonage vocal de "${speaker.name}".',
        );
      }
      final safeWavPath = await ensure24kHzWav(speaker.customVoiceWavPath!);
      if (safeWavPath != speaker.customVoiceWavPath && !_tempResampledPaths.contains(safeWavPath)) {
        _tempResampledPaths.add(safeWavPath);
      }
      final refText = speaker.customVoiceRefText!.trim();

      if (speaker.voiceModelName.startsWith('vibevoice')) {
        return await _ttsService.prepare(
          modelName: 'vibevoice-1.5b-tts-q4_k',
          voiceWavPath: safeWavPath,
          refText: refText,
        );
      } else {
        return await _ttsService.prepare(
          modelName: 'qwen3-tts-12hz-0.6b-base',
          codecName: 'qwen3-tts-tokenizer-12hz',
          voiceWavPath: safeWavPath,
          refText: refText,
        );
      }
    } else if (speaker.voiceModelName.startsWith('clone_') || speaker.voiceModelName == 'custom-clone') {
      // Guard : voix clone sans WAV de référence — configuration incomplète
      return TtsLoadStatus.error(
        'Fichier audio de référence manquant pour "${speaker.name}" '
        '(${speaker.voiceModelName}). Reconfigurer la voix dans le panel Distribution.',
      );
    } else if (speaker.voiceModelName.startsWith('imported_')) {
      // Voice Pack importé (.gguf)
      String fileName;
      String? speakerName;
      bool isChatterbox = false;

      if (speaker.voiceModelName.startsWith('imported_chatterbox:')) {
        fileName = speaker.voiceModelName.substring('imported_chatterbox:'.length);
        isChatterbox = true;
      } else if (speaker.voiceModelName.startsWith('imported_qwen3:')) {
        final rest = speaker.voiceModelName.substring('imported_qwen3:'.length);
        final splitIdx = rest.indexOf('#');
        if (splitIdx != -1) {
          fileName = rest.substring(0, splitIdx);
          speakerName = rest.substring(splitIdx + 1);
        } else {
          fileName = rest;
        }
        isChatterbox = false;
      } else {
        // Format générique de secours: imported_<fileName>
        fileName = speaker.voiceModelName.replaceFirst('imported_', '');
        final packs = await _importedVoiceService.loadAll();
        final match = packs.where((p) => p.fileName == fileName || p.id == fileName).toList();
        if (match.isNotEmpty) {
          isChatterbox = match.first.family == VoicePackFamily.chatterbox;
          if (!isChatterbox && match.first.presetSpeakers.isNotEmpty) {
            speakerName = match.first.presetSpeakers.first;
          }
        }
      }

      final packFile = File(p.join(AppPaths.importedVoicesDir.path, fileName));
      if (!packFile.existsSync()) {
        Log.instance.w('audiobook', 'Voice pack introuvable pour ${speaker.name}: $fileName');
        return TtsLoadStatus.error(
          'Le Voice Pack "$fileName" est introuvable ou a été supprimé. '
          'Veuillez réassigner une voix pour "${speaker.name}" dans le panel Distribution.',
        );
      }

      if (isChatterbox) {
        Log.instance.i('audiobook', 'Préparation voix Chatterbox importée: $fileName pour ${speaker.name}');
        return await _ttsService.prepare(
          modelName: 'chatterbox-en-q8_0',
          codecName: 'chatterbox-s3gen-q8_0',
          voiceName: fileName,
          speakerName: null, // JAMAIS de speaker name pour Chatterbox
        );
      } else {
        Log.instance.i('audiobook', 'Préparation voix Qwen3 importée: $fileName (speaker: $speakerName) pour ${speaker.name}');
        return await _ttsService.prepare(
          modelName: 'qwen3-tts-12hz-0.6b-base',
          codecName: 'qwen3-tts-tokenizer-12hz',
          voiceName: fileName,
          speakerName: speakerName,
        );
      }
    } else if (speaker.voiceModelName.startsWith('vibevoice-voice-') ||
        speaker.voiceModelName == 'vibevoice-fr-Spk0_man' ||
        speaker.voiceModelName == 'vibevoice-fr-Spk1_woman') {
      final canonical = (speaker.voiceModelName == 'vibevoice-fr-Spk0_man')
          ? 'vibevoice-voice-fr-Spk0_man'
          : (speaker.voiceModelName == 'vibevoice-fr-Spk1_woman')
              ? 'vibevoice-voice-fr-Spk1_woman'
              : speaker.voiceModelName;

      // Priorité à vibevoice-realtime-0.5b-q4_k, fallback sur vibevoice-realtime-0.5b-tts-f16
      String realtimeModel = 'vibevoice-realtime-0.5b-q4_k';
      if (await _ttsService.resolvePath(realtimeModel) == null) {
        realtimeModel = 'vibevoice-realtime-0.5b-tts-f16';
        if (await _ttsService.resolvePath(realtimeModel) == null) {
          return TtsLoadStatus.error(
            'Aucun modèle VibeVoice Realtime (0.5B) disponible pour "${speaker.name}". '
            'Veuillez installer vibevoice-realtime-0.5b-q4_k.',
          );
        }
      }

      return await _ttsService.prepare(
        modelName: realtimeModel,
        voiceName: canonical,
      );
    } else if (speaker.voiceModelName.startsWith('vibevoice')) {
      return TtsLoadStatus.error(
        'Le modèle VibeVoice "${speaker.voiceModelName}" nécessite un fichier audio de référence (WAV) '
        'et son texte de référence pour "${speaker.name}".',
      );
    } else if (speaker.voiceModelName.startsWith('kokoro')) {
      return await _ttsService.prepare(
        modelName: 'kokoro-82m-q8_0',
        voiceName: speaker.voiceModelName == 'kokoro-82m-q8_0' ? 'kokoro-voice-ff_siwis' : speaker.voiceModelName,
      );
    } else if (speaker.voiceModelName.startsWith('qwen3')) {
      final mappedSpeaker = qwenSpeakerMap[speaker.voiceModelName] ?? 'uncle_fu';
      return await _ttsService.prepare(
        modelName: 'qwen3-tts-12hz-0.6b-customvoice-q8_0',
        codecName: 'qwen3-tts-tokenizer-12hz',
        speakerName: mappedSpeaker,
      );
    } else {
      return await _ttsService.prepare(modelName: speaker.voiceModelName);
    }
  }

  /// Synthesizes a single chapter into a standalone WAV file with style rules applied.
  Future<String> synthesizeChapter({
    required AudiobookChapter chapter,
    required Map<String, AudiobookSpeaker> speakers,
    required String outputDir,
    AudiobookRuleProfile? profile,
    void Function(double progress)? onProgress,
  }) async {
    final lines = chapter.lines.isNotEmpty
        ? chapter.lines
        : castChapterLinesSync(
            chapter: chapter,
            speakers: speakers,
            profile: profile,
          );

    if (lines.isEmpty) {
      throw Exception('Aucune ligne de texte à synthétiser dans ce chapitre.');
    }

    final outDirectory = Directory(outputDir);
    if (!outDirectory.existsSync()) {
      outDirectory.createSync(recursive: true);
    }

    final outFilePath = p.join(
      outputDir,
      'Audiobook_Chap_${chapter.index.toString().padLeft(2, '0')}.wav',
    );

    final allPcmSamples = <double>[];
    const targetSampleRate = 24000;
    // 350ms pause between sentences
    final silenceSamples = List<double>.filled((targetSampleRate * 0.35).round(), 0.0);
    String? lastError;

    try {
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final speaker = speakers[line.speakerId] ??
            speakers['narrator'] ??
            const AudiobookSpeaker(
              id: 'narrator',
              name: 'Narrateur',
              voiceModelName: 'kokoro-voice-ff_siwis',
            );

        try {
          final loadStatus = await _prepareSpeaker(speaker);
          if (!loadStatus.ready) {
            final missing = loadStatus.missingModelName != null
                ? 'Modèle non téléchargé : ${loadStatus.missingModelName}'
                : (loadStatus.missingCodecName != null
                    ? 'Codec non téléchargé : ${loadStatus.missingCodecName}'
                    : (loadStatus.missingVoiceName != null
                        ? 'Voix non téléchargée : ${loadStatus.missingVoiceName}'
                        : (loadStatus.unsupportedBackend != null
                            ? 'Moteur ${loadStatus.unsupportedBackend} non supporté sur ce système'
                            : (loadStatus.errorMessage ?? 'Moteur TTS non prêt'))));
            throw Exception(missing);
          }
          var audio = await _ttsService.synthesize(
            line.text,
            speed: speaker.speed,
          );

          if (audio == null || audio.samples.isEmpty) {
            Log.instance.w('audiobook', 'Fallback audio synthèse chapitre vers Kokoro Siwis');
            await _ttsService.prepare(
              modelName: 'kokoro-82m-q8_0',
              voiceName: 'kokoro-voice-ff_siwis',
            );
            audio = await _ttsService.synthesize(line.text, speed: speaker.speed);
          }

          if (audio != null && audio.samples.isNotEmpty) {
            allPcmSamples.addAll(audio.samples);
            allPcmSamples.addAll(silenceSamples);
          }
        } catch (e) {
          lastError = e.toString();
          Log.instance.w('audiobook', 'Erreur synthèse ligne ${line.id}: $e');
        }

        final currentProgress = (i + 1) / lines.length;
        onProgress?.call(currentProgress);
      }

      // Write final concatenated WAV
      if (allPcmSamples.isNotEmpty) {
        final wavBytes = createWavHeaderAndData(
          Float32List.fromList(allPcmSamples),
          targetSampleRate,
        );
        await File(outFilePath).writeAsBytes(wavBytes);
        Log.instance.i('audiobook', 'Chapitre ${chapter.index} généré: $outFilePath');
        return outFilePath;
      } else {
        throw Exception(lastError != null ? 'La synthèse audio a échoué: $lastError' : 'La synthèse audio a échoué: aucun échantillon produit.');
      }
    } finally {
      _cleanTempResampledPaths();
    }
  }

  /// Synthesizes a custom batch of lines and returns the generated WAV path.
  Future<String> synthesizeLines({
    required List<AudiobookLine> lines,
    required Map<String, AudiobookSpeaker> speakers,
    required String outputDir,
    String? outputFileName,
    void Function(double progress)? onProgress,
  }) async {
    if (lines.isEmpty) {
      throw Exception('Aucune réplique fournie pour la synthèse.');
    }

    final outDirectory = Directory(outputDir);
    if (!outDirectory.existsSync()) {
      outDirectory.createSync(recursive: true);
    }

    final outFilePath = p.join(
      outputDir,
      outputFileName ?? 'Audiobook_Batch_${DateTime.now().millisecondsSinceEpoch}.wav',
    );

    final allPcmSamples = <double>[];
    const targetSampleRate = 24000;
    final silenceSamples = List<double>.filled((targetSampleRate * 0.35).round(), 0.0);

    try {
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final cleanText = stripStyleTags(line.text);
        if (cleanText.isEmpty) continue;

        final speaker = speakers[line.speakerId] ??
            speakers['narrator'] ??
            const AudiobookSpeaker(
              id: 'narrator',
              name: 'Narrateur',
              voiceModelName: 'kokoro-voice-ff_siwis',
            );

        try {
          final loadStatus = await _prepareSpeaker(speaker);
          if (!loadStatus.ready) {
            final missing = loadStatus.missingModelName != null
                ? 'Modèle non téléchargé : ${loadStatus.missingModelName}'
                : (loadStatus.missingCodecName != null
                    ? 'Codec non téléchargé : ${loadStatus.missingCodecName}'
                    : (loadStatus.missingVoiceName != null
                        ? 'Voix non téléchargée : ${loadStatus.missingVoiceName}'
                        : (loadStatus.unsupportedBackend != null
                            ? 'Moteur ${loadStatus.unsupportedBackend} non supporté sur ce système'
                            : (loadStatus.errorMessage ?? 'Moteur TTS non prêt'))));
            throw Exception(missing);
          }
          var audio = await _ttsService.synthesize(
            cleanText,
            speed: speaker.speed,
          );

          if (audio == null || audio.samples.isEmpty) {
            Log.instance.w('audiobook', 'Fallback audio synthèse batch vers Kokoro Siwis');
            await _ttsService.prepare(
              modelName: 'kokoro-82m-q8_0',
              voiceName: 'kokoro-voice-ff_siwis',
            );
            audio = await _ttsService.synthesize(cleanText, speed: speaker.speed);
          }

          if (audio != null && audio.samples.isNotEmpty) {
            allPcmSamples.addAll(audio.samples);
            allPcmSamples.addAll(silenceSamples);
          }
        } catch (e) {
          Log.instance.w('audiobook', 'Erreur synthèse ligne ${line.id}: $e');
        }

        final currentProgress = (i + 1) / lines.length;
        onProgress?.call(currentProgress);
      }

      if (allPcmSamples.isNotEmpty) {
        final wavBytes = createWavHeaderAndData(
          Float32List.fromList(allPcmSamples),
          targetSampleRate,
        );
        await File(outFilePath).writeAsBytes(wavBytes);
        return outFilePath;
      } else {
        throw Exception('La synthèse audio a échoué: aucun échantillon produit.');
      }
    } finally {
      _cleanTempResampledPaths();
    }
  }

  /// Synthesizes lines directly into in-memory WAV bytes without touching the disk SSD.
  Future<Uint8List> synthesizeLinesToMemory({
    required List<AudiobookLine> lines,
    required Map<String, AudiobookSpeaker> speakers,
    void Function(double progress)? onProgress,
  }) async {
    if (lines.isEmpty) {
      throw Exception('Aucune réplique fournie pour la synthèse.');
    }

    final allPcmSamples = <double>[];
    const targetSampleRate = 24000;
    final silenceSamples = List<double>.filled((targetSampleRate * 0.35).round(), 0.0);

    String? lastError;
    try {
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final cleanText = stripStyleTags(line.text);
        if (cleanText.isEmpty) continue;

        final speaker = speakers[line.speakerId] ??
            speakers['narrator'] ??
            const AudiobookSpeaker(
              id: 'narrator',
              name: 'Narrateur',
              voiceModelName: 'kokoro-voice-ff_siwis',
            );

        try {
          final loadStatus = await _prepareSpeaker(speaker);
          if (!loadStatus.ready) {
            final missing = loadStatus.missingModelName != null
                ? 'Modèle non téléchargé : ${loadStatus.missingModelName}'
                : (loadStatus.missingCodecName != null
                    ? 'Codec non téléchargé : ${loadStatus.missingCodecName}'
                    : (loadStatus.missingVoiceName != null
                        ? 'Voix non téléchargée : ${loadStatus.missingVoiceName}'
                        : (loadStatus.unsupportedBackend != null
                            ? 'Moteur ${loadStatus.unsupportedBackend} non supporté sur ce système'
                            : (loadStatus.errorMessage ?? 'Moteur TTS non prêt'))));
            throw Exception(missing);
          }

          final audio = await _ttsService.synthesize(
            cleanText,
            speed: speaker.speed,
          );

          if (audio != null && audio.samples.isNotEmpty) {
            allPcmSamples.addAll(audio.samples);
            allPcmSamples.addAll(silenceSamples);
          } else {
            throw Exception('La synthèse audio n\'a généré aucun son.');
          }
        } catch (e) {
          lastError = e.toString().replaceFirst('Exception: ', '');
          Log.instance.w('audiobook', 'Erreur synthèse mémoire ligne ${line.id}: $e');
        }

        final currentProgress = (i + 1) / lines.length;
        onProgress?.call(currentProgress);
      }

      if (allPcmSamples.isNotEmpty) {
        final wavBytes = createWavHeaderAndData(
          Float32List.fromList(allPcmSamples),
          targetSampleRate,
        );
        return wavBytes;
      } else {
        throw Exception(lastError ?? 'La synthèse audio a échoué: aucun échantillon produit.');
      }
    } finally {
      _cleanTempResampledPaths();
    }
  }

  /// Utility to clean out formatting tags before sending to TTS engine.
  static String stripStyleTags(String text) {
    var s = text;
    s = s.replaceAll(RegExp(r'<color=[^>]+>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'</color>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<mark=[^>]+>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'</mark>', caseSensitive: false), '');
    s = s.replaceAll('**', '');
    s = s.replaceAll('*', '');
    return s.trim();
  }

  /// Helper to pack Float32 PCM into a valid standard 16-bit PCM WAV container.
  Uint8List createWavHeaderAndData(Float32List samples, int sampleRate) {
    final numChannels = 1;
    final bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    final blockAlign = numChannels * (bitsPerSample ~/ 8);
    final dataSize = samples.length * (bitsPerSample ~/ 8);
    final totalSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);

    // RIFF chunk
    buffer.setUint8(0, 0x52); // 'R'
    buffer.setUint8(1, 0x49); // 'I'
    buffer.setUint8(2, 0x46); // 'F'
    buffer.setUint8(3, 0x46); // 'F'
    buffer.setUint32(4, totalSize, Endian.little);
    buffer.setUint8(8, 0x57); // 'W'
    buffer.setUint8(9, 0x41); // 'A'
    buffer.setUint8(10, 0x56); // 'V'
    buffer.setUint8(11, 0x45); // 'E'

    // fmt chunk
    buffer.setUint8(12, 0x66); // 'f'
    buffer.setUint8(13, 0x6D); // 'm'
    buffer.setUint8(14, 0x74); // 't'
    buffer.setUint8(15, 0x20); // ' '
    buffer.setUint32(16, 16, Endian.little); // chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM format
    buffer.setUint16(22, numChannels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    buffer.setUint8(36, 0x64); // 'd'
    buffer.setUint8(37, 0x61); // 'a'
    buffer.setUint8(38, 0x74); // 't'
    buffer.setUint8(39, 0x61); // 'a'
    buffer.setUint32(40, dataSize, Endian.little);

    // Convert Float32 (-1.0 to 1.0) to Int16
    var offset = 44;
    for (int i = 0; i < samples.length; i++) {
      final s = samples[i].clamp(-1.0, 1.0);
      final int16Val = (s * 32767.0).round().clamp(-32768, 32767);
      buffer.setInt16(offset, int16Val, Endian.little);
      offset += 2;
    }

    return buffer.buffer.asUint8List();
  }

  // --- Project Persistence (.cwproject / .json) ---

  /// Saves the complete audiobook project losslessly to a JSON/.cwproject file.
  Future<void> saveProjectToFile(AudiobookProject project, String targetPath) async {
    final file = File(targetPath);
    final jsonStr = const JsonEncoder.withIndent('  ').convert(project.toJson());
    await file.writeAsString(jsonStr, encoding: utf8);
  }

  /// Loads an audiobook project losslessly from a JSON/.cwproject file.
  Future<AudiobookProject> loadProjectFromFile(String sourcePath) async {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw Exception('Fichier projet introuvable: $sourcePath');
    }
    final content = await file.readAsString(encoding: utf8);
    final map = jsonDecode(content) as Map<String, dynamic>;
    return AudiobookProject.fromJson(map);
  }

  // --- Multi-format Document Export (TXT, Markdown, HTML, PDF, DOCX) ---

  /// Exports project into plain text script scenario.
  String exportProjectToPlainText(AudiobookProject project) {
    final buf = StringBuffer();
    buf.writeln('TITRE : ${project.title}');
    buf.writeln('AUTEUR : ${project.author}');
    buf.writeln('CHAPITRES : ${project.chapters.length}');
    buf.writeln('========================================\n');

    for (final chap in project.chapters) {
      buf.writeln('--- ${chap.title} ---\n');
      if (chap.lines.isNotEmpty) {
        for (final line in chap.lines) {
          final clean = stripStyleTags(line.text);
          buf.writeln('[${line.speakerName.toUpperCase()}] $clean\n');
        }
      } else {
        buf.writeln('${stripStyleTags(chap.rawText)}\n');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// Exports project into structured Markdown.
  String exportProjectToMarkdown(AudiobookProject project) {
    final buf = StringBuffer();
    buf.writeln('# ${project.title}');
    buf.writeln('\n**Auteur :** ${project.author}  ');
    buf.writeln('**Nombre de chapitres :** ${project.chapters.length}  ');
    buf.writeln('**Total mots :** ${project.totalWords}  \n');
    buf.writeln('---\n');

    for (final chap in project.chapters) {
      buf.writeln('## ${chap.title}\n');
      if (chap.lines.isNotEmpty) {
        for (final line in chap.lines) {
          final isNarrator = line.speakerId == 'narrator';
          final badge = isNarrator ? '📖 Narrateur' : '🗣️ **${line.speakerName}**';
          final clean = stripStyleTags(line.text);
          buf.writeln('> $badge : $clean\n');
        }
      } else {
        buf.writeln('${stripStyleTags(chap.rawText)}\n');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// Exports project into stylized HTML with support for rich highlights and font colors.
  String exportProjectToHtml(AudiobookProject project) {
    final buf = StringBuffer();
    buf.writeln('<!DOCTYPE html>');
    buf.writeln('<html lang="fr"><head><meta charset="utf-8">');
    buf.writeln('<title>${project.title} - Script Multi-Voix</title>');
    buf.writeln('<style>');
    buf.writeln('body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.6; max-width: 850px; margin: 40px auto; padding: 0 20px; background: #0f172a; color: #f8fafc; }');
    buf.writeln('h1 { color: #38bdf8; border-bottom: 2px solid #334155; padding-bottom: 10px; }');
    buf.writeln('h2 { color: #818cf8; margin-top: 30px; }');
    buf.writeln('.meta { color: #94a3b8; font-size: 0.9em; margin-bottom: 30px; }');
    buf.writeln('.line { margin-bottom: 12px; padding: 10px 14px; border-radius: 8px; }');
    buf.writeln('.narrator { background: #1e293b; border-left: 4px solid #64748b; }');
    buf.writeln('.male { background: #1e3a8a; border-left: 4px solid #3b82f6; }');
    buf.writeln('.female { background: #831843; border-left: 4px solid #ec4899; }');
    buf.writeln('.badge { font-weight: bold; font-size: 0.8em; text-transform: uppercase; margin-bottom: 4px; display: inline-block; padding: 2px 6px; border-radius: 4px; background: rgba(255,255,255,0.1); }');
    buf.writeln('mark { border-radius: 3px; padding: 1px 3px; color: #ffffff; }');
    buf.writeln('</style></head><body>');
    buf.writeln('<h1>${project.title}</h1>');
    buf.writeln('<div class="meta">Auteur : ${project.author} | ${project.chapters.length} chapitres | ${project.totalWords} mots</div>');

    for (final chap in project.chapters) {
      buf.writeln('<h2>${chap.title}</h2>');
      if (chap.lines.isNotEmpty) {
        for (final line in chap.lines) {
          final isNarrator = line.speakerId == 'narrator';
          final isFemale = line.speakerId == 'female_main';
          final cls = isNarrator ? 'narrator' : (isFemale ? 'female' : 'male');
          final formattedHtml = _convertLineToHtml(line);
          buf.writeln('<div class="line $cls">');
          buf.writeln('<div class="badge">${line.speakerName}</div>');
          buf.writeln('<div>$formattedHtml</div>');
          buf.writeln('</div>');
        }
      } else {
        buf.writeln('<p>${_convertTagsToHtml(chap.rawText)}</p>');
      }
    }
    buf.writeln('</body></html>');
    return buf.toString();
  }

  /// Converts AudiobookLine into styled HTML using styleSpans or legacy tags.
  static String _convertLineToHtml(AudiobookLine line) {
    if (line.styleSpans.isNotEmpty) {
      final text = line.text;
      final boundaries = <int>{0, text.length};
      for (final s in line.styleSpans) {
        boundaries.add(s.start.clamp(0, text.length));
        boundaries.add(s.end.clamp(0, text.length));
      }
      final sorted = boundaries.toList()..sort();

      final buf = StringBuffer();
      for (int i = 0; i < sorted.length - 1; i++) {
        final start = sorted[i];
        final end = sorted[i + 1];
        if (start >= end) continue;

        final chunk = text.substring(start, end);

        String? chunkColor;
        String? chunkBg;
        bool isBold = false;
        bool isItalic = false;

        for (final s in line.styleSpans) {
          if (start >= s.start && end <= s.end) {
            if (s.colorHex != null) {
              final hex = s.colorHex!;
              chunkColor = hex.length == 10 ? hex.substring(4).toLowerCase() : 'ffffff';
            }
            if (s.highlightHex != null) {
              final hex = s.highlightHex!;
              chunkBg = hex.length == 10 ? hex.substring(4).toLowerCase() : 'fbbf24';
            }
            if (s.isBold) isBold = true;
            if (s.isItalic) isItalic = true;
          }
        }

        var chunkHtml = _xmlEscape(chunk);
        if (isBold) chunkHtml = '<b>$chunkHtml</b>';
        if (isItalic) chunkHtml = '<i>$chunkHtml</i>';
        if (chunkBg != null) chunkHtml = '<mark style="background-color:#$chunkBg; color:#000000;">$chunkHtml</mark>';
        if (chunkColor != null) chunkHtml = '<span style="color:#$chunkColor;">$chunkHtml</span>';

        buf.write(chunkHtml);
      }
      return buf.toString();
    }

    return _convertTagsToHtml(line.text);
  }

  /// Helper converting tags into styled HTML.
  static String _convertTagsToHtml(String text) {
    var s = text;
    s = s.replaceAllMapped(RegExp(r'<color=(0x[0-9a-fA-F]{8})>(.*?)</color>', caseSensitive: false), (m) {
      final hex = m.group(1)!;
      final rgb = (hex.length == 10 ? hex.substring(4) : 'ffffff').toLowerCase();
      return '<span style="color:#$rgb;">${m.group(2)}</span>';
    });
    s = s.replaceAllMapped(RegExp(r'<mark=(0x[0-9a-fA-F]{8})>(.*?)</mark>', caseSensitive: false), (m) {
      final hex = m.group(1)!;
      final rgb = (hex.length == 10 ? hex.substring(4) : 'fbbf24').toLowerCase();
      return '<mark style="background-color:#$rgb; color:#000000;">${m.group(2)}</mark>';
    });
    s = s.replaceAllMapped(RegExp(r'\*\*(.*?)\*\*'), (m) => '<b>${m.group(1)}</b>');
    s = s.replaceAllMapped(RegExp(r'\*(.*?)\*'), (m) => '<i>${m.group(1)}</i>');
    return s;
  }

  /// Exports project into PDF document.
  Future<void> exportProjectToPdf(AudiobookProject project, String targetPath) async {
    final pdfDocument = PdfDocument();
    pdfDocument.pageSettings.margins.all = 40;

    final fontTitle = getUnicodePdfFont(18, style: PdfFontStyle.bold);
    final fontHeading = getUnicodePdfFont(14, style: PdfFontStyle.bold);
    final fontBody = getUnicodePdfFont(10);

    // Title Page / Header
    var page = pdfDocument.pages.add();
    var graphics = page.graphics;
    var y = 0.0;

    graphics.drawString('${project.title}\n', fontTitle, bounds: Rect.fromLTWH(0, y, page.getClientSize().width, 30));
    y += 35;
    graphics.drawString('Auteur : ${project.author} | Chapitres : ${project.chapters.length}\n', fontBody, bounds: Rect.fromLTWH(0, y, page.getClientSize().width, 20));
    y += 30;

    for (final chap in project.chapters) {
      if (y > page.getClientSize().height - 80) {
        page = pdfDocument.pages.add();
        graphics = page.graphics;
        y = 0.0;
      }

      graphics.drawString(chap.title, fontHeading, bounds: Rect.fromLTWH(0, y, page.getClientSize().width, 25));
      y += 30;

      for (final line in chap.lines) {
        if (y > page.getClientSize().height - 60) {
          page = pdfDocument.pages.add();
          graphics = page.graphics;
          y = 0.0;
        }

        final speakerText = '[${line.speakerName.toUpperCase()}] ';
        final cleanText = stripStyleTags(line.text);
        final lineText = '$speakerText$cleanText';

        final layoutFormat = PdfLayoutFormat(layoutType: PdfLayoutType.paginate);
        final element = PdfTextElement(text: lineText, font: fontBody);
        final result = element.draw(
          page: page,
          bounds: Rect.fromLTWH(0, y, page.getClientSize().width, 0),
          format: layoutFormat,
        );

        if (result != null) {
          y = result.bounds.bottom + 10;
          page = result.page;
          graphics = page.graphics;
        } else {
          y += 20;
        }
      }
      y += 20;
    }

    final bytes = await pdfDocument.save();
    pdfDocument.dispose();
    await File(targetPath).writeAsBytes(bytes);
  }

  /// Exports project into Word .docx file using standard OpenXML archive with rich styled runs.
  Future<void> exportProjectToDocx(AudiobookProject project, String targetPath) async {
    final archive = Archive();

    // 1. [Content_Types].xml
    const contentTypesXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';
    archive.addFile(ArchiveFile('[Content_Types].xml', contentTypesXml.length, utf8.encode(contentTypesXml)));

    // 2. _rels/.rels
    const relsXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';
    archive.addFile(ArchiveFile('_rels/.rels', relsXml.length, utf8.encode(relsXml)));

    // 3. word/document.xml
    final docBuf = StringBuffer();
    docBuf.writeln('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    docBuf.writeln('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">');
    docBuf.writeln('<w:body>');

    // Title
    docBuf.writeln('<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val="36"/></w:rPr><w:t>${_xmlEscape(project.title)}</w:t></w:r></w:p>');
    docBuf.writeln('<w:p><w:r><w:rPr><w:i/><w:color w:val="666666"/></w:rPr><w:t>Auteur : ${_xmlEscape(project.author)} | ${project.chapters.length} chapitres | ${project.totalWords} mots</w:t></w:r></w:p>');

    for (final chap in project.chapters) {
      docBuf.writeln('<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="2E75B6"/></w:rPr><w:t>${_xmlEscape(chap.title)}</w:t></w:r></w:p>');

      for (final line in chap.lines) {
        final isNarrator = line.speakerId == 'narrator';
        final isFemale = line.speakerId == 'female_main';
        final speakerColor = isNarrator ? '555555' : (isFemale ? 'C00000' : '002060');

        docBuf.writeln('<w:p>');
        docBuf.writeln('<w:r><w:rPr><w:b/><w:color w:val="$speakerColor"/></w:rPr><w:t xml:space="preserve">[${_xmlEscape(line.speakerName.toUpperCase())}] </w:t></w:r>');
        docBuf.write(_buildOpenXmlRunsForLine(line));
        docBuf.writeln('</w:p>');
      }
    }

    docBuf.writeln('</w:body></w:document>');
    final docXml = docBuf.toString();
    archive.addFile(ArchiveFile('word/document.xml', docXml.length, utf8.encode(docXml)));

    final zipEncoder = ZipEncoder();
    final encoded = zipEncoder.encode(archive);
    if (encoded != null) {
      await File(targetPath).writeAsBytes(encoded);
    }
  }

  /// Converts AudiobookLine into OpenXML runs using styleSpans or legacy tags.
  static String _buildOpenXmlRunsForLine(AudiobookLine line) {
    if (line.styleSpans.isNotEmpty) {
      final text = line.text;
      final boundaries = <int>{0, text.length};
      for (final s in line.styleSpans) {
        boundaries.add(s.start.clamp(0, text.length));
        boundaries.add(s.end.clamp(0, text.length));
      }
      final sorted = boundaries.toList()..sort();

      final buf = StringBuffer();
      for (int i = 0; i < sorted.length - 1; i++) {
        final start = sorted[i];
        final end = sorted[i + 1];
        if (start >= end) continue;

        final chunk = text.substring(start, end);

        String? chunkColor;
        String? chunkHighlight;
        bool isBold = false;
        bool isItalic = false;

        for (final s in line.styleSpans) {
          if (start >= s.start && end <= s.end) {
            if (s.colorHex != null) {
              final hex = s.colorHex!;
              chunkColor = hex.length == 10 ? hex.substring(4) : '000000';
            }
            if (s.highlightHex != null) {
              final hex = s.highlightHex!;
              String wordHighlight = 'yellow';
              if (hex.contains('38BDF8')) wordHighlight = 'cyan';
              if (hex.contains('F472B6')) wordHighlight = 'magenta';
              if (hex.contains('4ADE80')) wordHighlight = 'green';
              chunkHighlight = wordHighlight;
            }
            if (s.isBold) isBold = true;
            if (s.isItalic) isItalic = true;
          }
        }

        buf.write('<w:r><w:rPr>');
        if (chunkColor != null) buf.write('<w:color w:val="$chunkColor"/>');
        if (chunkHighlight != null) buf.write('<w:highlight w:val="$chunkHighlight"/>');
        if (isBold) buf.write('<w:b/>');
        if (isItalic) buf.write('<w:i/>');
        buf.write('</w:rPr><w:t xml:space="preserve">${_xmlEscape(chunk)}</w:t></w:r>');
      }
      return buf.toString();
    }

    return _buildOpenXmlRuns(line.text);
  }

  /// Converts formatted text with tags (<color=...>, <mark=...>, **, *) into OpenXML runs.
  static String _buildOpenXmlRuns(String text) {
    final buf = StringBuffer();
    final reg = RegExp(r'(<color=0x[0-9a-fA-F]+>.*?</color>|<mark=0x[0-9a-fA-F]+>.*?</mark>|\*\*.*?\*\*|\*.*?\*)', caseSensitive: false);

    int lastIdx = 0;
    for (final match in reg.allMatches(text)) {
      if (match.start > lastIdx) {
        final plain = text.substring(lastIdx, match.start);
        buf.writeln('<w:r><w:t xml:space="preserve">${_xmlEscape(plain)}</w:t></w:r>');
      }

      final matchedStr = match.group(0)!;
      if (matchedStr.startsWith('<color=') && matchedStr.endsWith('</color>')) {
        final colorEnd = matchedStr.indexOf('>');
        final hexStr = matchedStr.substring(7, colorEnd);
        final inner = matchedStr.substring(colorEnd + 1, matchedStr.length - 8);
        final rgb = hexStr.length == 10 ? hexStr.substring(4) : '000000';
        buf.writeln('<w:r><w:rPr><w:color w:val="$rgb"/></w:rPr><w:t xml:space="preserve">${_xmlEscape(inner)}</w:t></w:r>');
      } else if (matchedStr.startsWith('<mark=') && matchedStr.endsWith('</mark>')) {
        final markEnd = matchedStr.indexOf('>');
        final hexStr = matchedStr.substring(6, markEnd);
        final inner = matchedStr.substring(markEnd + 1, matchedStr.length - 7);
        // Map hex to Word standard highlight color
        String wordHighlight = 'yellow';
        if (hexStr.contains('38BDF8')) wordHighlight = 'cyan';
        if (hexStr.contains('F472B6')) wordHighlight = 'magenta';
        if (hexStr.contains('4ADE80')) wordHighlight = 'green';
        buf.writeln('<w:r><w:rPr><w:highlight w:val="$wordHighlight"/></w:rPr><w:t xml:space="preserve">${_xmlEscape(inner)}</w:t></w:r>');
      } else if (matchedStr.startsWith('**') && matchedStr.endsWith('**')) {
        final inner = matchedStr.substring(2, matchedStr.length - 2);
        buf.writeln('<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(inner)}</w:t></w:r>');
      } else if (matchedStr.startsWith('*') && matchedStr.endsWith('*')) {
        final inner = matchedStr.substring(1, matchedStr.length - 1);
        buf.writeln('<w:r><w:rPr><w:i/></w:rPr><w:t xml:space="preserve">${_xmlEscape(inner)}</w:t></w:r>');
      }
      lastIdx = match.end;
    }

    if (lastIdx < text.length) {
      final plain = text.substring(lastIdx);
      buf.writeln('<w:r><w:t xml:space="preserve">${_xmlEscape(plain)}</w:t></w:r>');
    }

    return buf.toString();
  }

  static String _xmlEscape(String str) {
    return str
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}


// --- Unicode PDF Font Helper (Roboto Apache 2.0) ---
Uint8List? _cachedUnicodeFontBytes;

Uint8List getUnicodeFontBytes() {
  if (_cachedUnicodeFontBytes != null) return _cachedUnicodeFontBytes!;
  _cachedUnicodeFontBytes = Uint8List.fromList(gzip.decode(base64Decode(_kRobotoFontGzipBase64)));
  return _cachedUnicodeFontBytes!;
}

PdfFont getUnicodePdfFont(double size, {PdfFontStyle? style}) {
  try {
    return PdfTrueTypeFont(getUnicodeFontBytes(), size, style: style);
  } catch (e) {
    return PdfStandardFont(PdfFontFamily.helvetica, size, style: style);
  }
}

const String _kRobotoFontGzipBase64 = "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";
