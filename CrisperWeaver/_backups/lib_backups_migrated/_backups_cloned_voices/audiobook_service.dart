// lib/services/audiobook_service.dart — orchestrates multi-voice casting, chapter segmentation, and batch TTS synthesis.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:crispasr/crispasr.dart' as crispasr;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/audiobook_models.dart';
import '../models/audiobook_rules.dart';
import 'document_rag_service.dart';
import 'document_source_service.dart';
import 'llm_service.dart';
import 'log_service.dart';
import 'tts_service.dart';

final audiobookServiceProvider = Provider<AudiobookService>((ref) {
  final tts = ref.watch(ttsServiceProvider);
  return AudiobookService(tts);
});

class AudiobookService {
  final TtsService _ttsService;

  AudiobookService(this._ttsService);

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
        voiceModelName: 'qwen3-ethan',
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
        voiceModelName: 'qwen3-ethan',
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

        final tempDir = await getTemporaryDirectory();
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

  Future<TtsLoadStatus> _prepareSpeaker(AudiobookSpeaker speaker) async {
    if (speaker.customVoiceWavPath != null && speaker.customVoiceWavPath!.isNotEmpty) {
      final safeWavPath = await ensure24kHzWav(speaker.customVoiceWavPath!);
      final refText = (speaker.customVoiceRefText != null && speaker.customVoiceRefText!.trim().isNotEmpty)
          ? speaker.customVoiceRefText!.trim()
          : 'Bonjour, je suis votre voix de référence en français.';
      return await _ttsService.prepare(
        modelName: 'qwen3-tts-12hz-0.6b-base',
        codecName: 'qwen3-tts-tokenizer-12hz',
        voiceWavPath: safeWavPath,
        refText: refText,
      );
    } else if (speaker.voiceModelName.startsWith('vibevoice')) {
      return await _ttsService.prepare(
        modelName: 'vibevoice-1.5b-tts-q4_k',
        voiceName: speaker.voiceModelName,
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
        await _prepareSpeaker(speaker);
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
      throw Exception('La synthèse audio a échoué: aucun échantillon produit.');
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
        await _prepareSpeaker(speaker);
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

    final fontTitle = PdfStandardFont(PdfFontFamily.helvetica, 18, style: PdfFontStyle.bold);
    final fontHeading = PdfStandardFont(PdfFontFamily.helvetica, 14, style: PdfFontStyle.bold);
    final fontSpeaker = PdfStandardFont(PdfFontFamily.helvetica, 10, style: PdfFontStyle.bold);
    final fontBody = PdfStandardFont(PdfFontFamily.helvetica, 10);

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
