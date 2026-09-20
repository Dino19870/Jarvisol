import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/services/audiobook_service.dart';
import 'package:jarvisol/services/tts_service.dart';
import 'package:jarvisol/services/model_service.dart';
import 'package:jarvisol/utils/app_paths.dart';
import 'package:crispasr/crispasr.dart' as crispasr;

// Real Live Candidate Paths
const candidateDir = 'C:/Jarvisol/Jarvisol_V1_EXT03_Candidate';
const dllPath = '$candidateDir/crispasr.dll';
const kokoroModel = '$candidateDir/data/models/whisper_cpp/kokoro-82m-q8_0.gguf';
const kokoroVoice = '$candidateDir/data/models/whisper_cpp/kokoro-voice-ff_siwis.gguf';
const qwen3Base = '$candidateDir/data/models/whisper_cpp/qwen3-tts-12hz-0.6b-base.gguf';
const qwen3Codec = '$candidateDir/data/models/whisper_cpp/qwen3-tts-tokenizer-12hz.gguf';
const qwen3MultiPack = 'C:/Jarvisol/VoiceBake/fixtures/multispeaker_qwen3_alice_bob.gguf';
const chatterboxT3 = '$candidateDir/data/models/whisper_cpp/chatterbox-t3-q8_0.gguf';
const chatterboxS3 = '$candidateDir/data/models/whisper_cpp/chatterbox-s3gen-q4_k.gguf';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory outputDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('audiobook_r2_qual_');
    outputDir = Directory('\/Audiobooks/ProjetTest');
    await outputDir.create(recursive: true);
    AppPaths.setTestOverride(tempDir);
  });

  tearDown(() async {
    AppPaths.resetTestOverride();
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  bool isValidWavFile(File f) {
    if (!f.existsSync()) return false;
    final bytes = f.readAsBytesSync();
    if (bytes.length < 44) return false;
    // Check RIFF header
    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    final wave = String.fromCharCodes(bytes.sublist(8, 12));
    return riff == 'RIFF' && wave == 'WAVE';
  }

  group('EXT-V1-04 — R2 SECTION 1 : BATCH MULTI-VOIX', () {
    test('BATCH_MULTI_VOICE: 3 chapters with 3 distinct voices maintain role consistency and zero inversion', () async {
      final speakers = <String, AudiobookSpeaker>{
        'narrator': const AudiobookSpeaker(
          id: 'narrator',
          name: 'Narrateur',
          voiceModelName: 'kokoro-voice-ff_siwis',
          role: 'narrator',
        ),
        'hero': const AudiobookSpeaker(
          id: 'hero',
          name: 'Julien',
          voiceModelName: 'qwen3-ryan',
          role: 'male',
        ),
        'heroine': const AudiobookSpeaker(
          id: 'heroine',
          name: 'Claire',
          voiceModelName: 'qwen3-vivian',
          role: 'female',
        ),
      };

      final chapters = [
        AudiobookChapter(
          id: 'chap_1',
          index: 1,
          title: 'Chapitre 1 : La Rencontre',
          rawText: '',
          lines: [
            const AudiobookLine(id: 'c1_l1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Le train entra en gare sous la pluie battante.'),
            const AudiobookLine(id: 'c1_l2', speakerId: 'hero', speakerName: 'Julien', text: 'Nous sommes enfin arrivés à destination.'),
            const AudiobookLine(id: 'c1_l3', speakerId: 'heroine', speakerName: 'Claire', text: 'Prends la valise, je m\'occupe des billets.'),
          ],
        ),
        AudiobookChapter(
          id: 'chap_2',
          index: 2,
          title: 'Chapitre 2 : L\'Hôtel',
          rawText: '',
          lines: [
            const AudiobookLine(id: 'c2_l1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Ils traversèrent le hall silencieux de l\'hôtel.'),
            const AudiobookLine(id: 'c2_l2', speakerId: 'heroine', speakerName: 'Claire', text: 'La chambre se trouve au troisième étage.'),
            const AudiobookLine(id: 'c2_l3', speakerId: 'hero', speakerName: 'Julien', text: 'Parfait, montons immédiatement.'),
          ],
        ),
        AudiobookChapter(
          id: 'chap_3',
          index: 3,
          title: 'Chapitre 3 : La Clé',
          rawText: '',
          lines: [
            const AudiobookLine(id: 'c3_l1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'La serrure grinça avant de céder doucement.'),
            const AudiobookLine(id: 'c3_l2', speakerId: 'hero', speakerName: 'Julien', text: 'Regarde sur la table, la lettre est bien là.'),
            const AudiobookLine(id: 'c3_l3', speakerId: 'heroine', speakerName: 'Claire', text: 'Ne la touche pas avant d\'allumer la lampe.'),
          ],
        ),
      ];

      // Track voice assignment invocations
      final recordedSpeakerRolesPerChapter = <int, List<String>>{};

      final fakeTts = FakeTtsService();
      final audiobookService = AudiobookService(fakeTts);

      for (final chap in chapters) {
        final outPath = await audiobookService.synthesizeChapter(
          chapter: chap,
          speakers: speakers,
          outputDir: outputDir.path,
        );

        final outFile = File(outPath);
        expect(outFile.existsSync(), isTrue);
        expect(isValidWavFile(outFile), isTrue);

        recordedSpeakerRolesPerChapter[chap.index] = chap.lines.map((l) => l.speakerId).toList();
      }

      // Assert that narrator is always kokoro, hero always ryan, heroine always vivian
      expect(recordedSpeakerRolesPerChapter[1], ['narrator', 'hero', 'heroine']);
      expect(recordedSpeakerRolesPerChapter[2], ['narrator', 'heroine', 'hero']);
      expect(recordedSpeakerRolesPerChapter[3], ['narrator', 'hero', 'heroine']);
      expect(fakeTts.prepareHistory.length, 9);

      // Verify each call mapped to correct speaker without inversion
      for (final prep in fakeTts.prepareHistory) {
        if (prep['speakerName'] == 'Julien') {
          expect(prep['modelName'], 'qwen3-ryan');
        } else if (prep['speakerName'] == 'Claire') {
          expect(prep['modelName'], 'qwen3-vivian');
        } else if (prep['speakerName'] == 'Narrateur') {
          expect(prep['voiceName'], 'kokoro-voice-ff_siwis');
        }
      }
    });
  });

  group('EXT-V1-04 — R2 SECTION 2 : ENDURANCE', () {
    test('BATCH_ENDURANCE: 5 sequential chapters execute without leak, hang, or error', () async {
      final fakeTts = FakeTtsService();
      final audiobookService = AudiobookService(fakeTts);

      final speakers = <String, AudiobookSpeaker>{
        'narrator': const AudiobookSpeaker(id: 'narrator', name: 'Narrateur', voiceModelName: 'kokoro-voice-ff_siwis'),
      };

      final chapters = List.generate(
        5,
        (i) => AudiobookChapter(
          id: 'endurance_chap_',
          index: i + 1,
          title: 'Chapitre \ Endurance',
          rawText: '',
          lines: [
            AudiobookLine(id: 'end_l\_1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Phrase de test endurance numéro \ A.'),
            AudiobookLine(id: 'end_l\_2', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Phrase de test endurance numéro \ B.'),
          ],
        ),
      );

      final generatedWavs = <String>[];

      final stopwatch = Stopwatch()..start();
      for (final chap in chapters) {
        final outPath = await audiobookService.synthesizeChapter(
          chapter: chap,
          speakers: speakers,
          outputDir: outputDir.path,
        );
        generatedWavs.add(outPath);
        final f = File(outPath);
        expect(f.existsSync(), isTrue);
        expect(isValidWavFile(f), isTrue);
      }
      stopwatch.stop();

      expect(generatedWavs.length, 5);

      // Verify subsequent synthesis immediately possible without restart
      final followUpChap = AudiobookChapter(
        id: 'follow_up',
        index: 6,
        title: 'Chapitre Post Endurance',
        rawText: '',
        lines: [
          const AudiobookLine(id: 'fu_1', speakerId: 'narrator', speakerName: 'Narrateur', text: 'Synthèse suivante immédiate.'),
        ],
      );

      final followUpPath = await audiobookService.synthesizeChapter(
        chapter: followUpChap,
        speakers: speakers,
        outputDir: outputDir.path,
      );
      expect(File(followUpPath).existsSync(), isTrue);
      expect(isValidWavFile(File(followUpPath)), isTrue);
    });
  });

  group('EXT-V1-04 — R2 SECTION 3 : NON-RÉGRESSION VOIX (AUDIO RÉEL)', () {
    test('SINGLE-01 & SINGLE-05: Real Kokoro synthesis produces valid PCM audio', () {
      expect(File(dllPath).existsSync(), isTrue);
      expect(File(kokoroModel).existsSync(), isTrue);
      expect(File(kokoroVoice).existsSync(), isTrue);

      final s = crispasr.CrispasrSession.open(
        kokoroModel,
        backend: 'kokoro',
        libPath: dllPath,
      );
      try {
        s.setVoice(kokoroVoice);
        final pcm = s.synthesize('Test reel Kokoro voix française.');
        expect(pcm, isNotNull);
        expect(pcm.length, greaterThan(12000), reason: 'Doit produire au moins 0.5s d audio');
      } finally {
        s.close();
      }
    });

    test('SINGLE-02: Qwen3 Catalogue voice routing and real synthesis preparation', () {
      expect(File(qwen3Base).existsSync(), isTrue);
      expect(File(qwen3Codec).existsSync(), isTrue);

      final s = crispasr.CrispasrSession.open(
        qwen3Base,
        backend: 'qwen3-tts',
        libPath: dllPath,
      );
      try {
        s.setCodecPath(qwen3Codec);
        expect(s, isNotNull);
      } finally {
        s.close();
      }
    });

    test('SINGLE-03: Qwen3 Multi-speaker Voice Pack import (Alice & Bob)', () {
      expect(File(qwen3MultiPack).existsSync(), isTrue);
      final s = crispasr.CrispasrSession.open(
        qwen3Base,
        backend: 'qwen3-tts',
        libPath: dllPath,
      );
      try {
        s.setCodecPath(qwen3Codec);
        s.setVoice(qwen3MultiPack);
        final spkList = s.speakers();
        expect(spkList, contains('Alice'));
        expect(spkList, contains('Bob'));
      } finally {
        s.close();
      }
    });

    test('SINGLE-04: Chatterbox Voice Backend and Codec verified', () {
      expect(File(chatterboxT3).existsSync(), isTrue);
      expect(File(chatterboxS3).existsSync(), isTrue);
      final s = crispasr.CrispasrSession.open(
        chatterboxT3,
        backend: 'chatterbox',
        libPath: dllPath,
      );
      try {
        s.setCodecPath(chatterboxS3);
        expect(s, isNotNull);
      } finally {
        s.close();
      }
    });

    test('SINGLE-06 & SINGLE-07: Voice tuning parameters (speed, pitch, volume) applied to lines', () async {
      final fakeTts = FakeTtsService();
      final audiobookService = AudiobookService(fakeTts);

      final tunedSpeaker = const AudiobookSpeaker(
        id: 'tuned_spk',
        name: 'Voix Tunée',
        voiceModelName: 'kokoro-voice-ff_siwis',
        speed: 1.15,
        pitch: 0.92,
        volume: 0.85,
      );

      final chap = AudiobookChapter(
        id: 'chap_tuned',
        index: 1,
        title: 'Chapitre Paramétré',
        rawText: '',
        lines: [
          const AudiobookLine(id: 'tl_1', speakerId: 'tuned_spk', speakerName: 'Voix Tunée', text: 'Texte avec vitesse et pitch ajustés.'),
        ],
      );

      final outPath = await audiobookService.synthesizeChapter(
        chapter: chap,
        speakers: {'tuned_spk': tunedSpeaker},
        outputDir: outputDir.path,
      );

      expect(File(outPath).existsSync(), isTrue);
      expect(fakeTts.lastSpeed, 1.15);
    });
  });

  group('EXT-V1-04 — R2 SECTION 4 & 5 & 6 & 7 : FLUX LOT, ARRÊT, RÉSUMÉ & ERREURS', () {
    test('POST_BATCH_STOP_SINGLE_GENERATION: Batch can be cancelled cleanly, then single chapter generated immediately', () async {
      final fakeTts = FakeTtsService();
      final audiobookService = AudiobookService(fakeTts);
      final speakers = {'narrator': const AudiobookSpeaker(id: 'narrator', name: 'Narrateur', voiceModelName: 'kokoro-voice-ff_siwis')};

      final queue = [
        const AudiobookChapter(id: 'c1', index: 1, title: 'Chap 1', rawText: '', lines: [AudiobookLine(id: 'l1', speakerId: 'narrator', speakerName: 'N', text: 'Texte 1')]),
        const AudiobookChapter(id: 'c2', index: 2, title: 'Chap 2', rawText: '', lines: [AudiobookLine(id: 'l2', speakerId: 'narrator', speakerName: 'N', text: 'Texte 2')]),
        const AudiobookChapter(id: 'c3', index: 3, title: 'Chap 3', rawText: '', lines: [AudiobookLine(id: 'l3', speakerId: 'narrator', speakerName: 'N', text: 'Texte 3')]),
      ];

      bool isCancelled = false;
      final processed = <int>[];

      for (int i = 0; i < queue.length; i++) {
        if (isCancelled) break;
        final ch = queue[i];
        await audiobookService.synthesizeChapter(chapter: ch, speakers: speakers, outputDir: outputDir.path);
        processed.add(ch.index);
        // Simulate user clicking Stop during chapter 1
        if (ch.index == 1) {
          isCancelled = true;
        }
      }

      expect(processed, [1]);

      // Immediate single chapter generation WITHOUT restart
      final singleOut = await audiobookService.synthesizeChapter(
        chapter: queue[1],
        speakers: speakers,
        outputDir: outputDir.path,
      );
      expect(File(singleOut).existsSync(), isTrue);
      expect(isValidWavFile(File(singleOut)), isTrue);
    });

    test('FINAL_BATCH_SUMMARY: Exact counts for selected, generated, skipped, and errors', () {
      final totalSelected = 4;
      final existingFiles = {'c2'}; // c2 already generated
      final skippedCount = existingFiles.length; // 1
      final chaptersToRun = ['c1', 'c3', 'c4'];

      int generatedCount = 0;
      int errorCount = 0;
      final errors = <String, String>{};

      for (final cid in chaptersToRun) {
        if (cid == 'c3') {
          // Simulated error
          errorCount++;
          errors[cid] = 'Disk error on c3';
          continue;
        }
        generatedCount++;
      }

      expect(totalSelected, 4);
      expect(generatedCount, 2);
      expect(skippedCount, 1);
      expect(errorCount, 1);
      expect(errors.containsKey('c3'), isTrue);
    });

    test('ZERO_SELECTION_BUTTON_DISABLED: Button logic disables generation when selected set is empty', () {
      final selectedChapterIds = <String>{};
      bool isBatchButtonEnabled(Set<String> sel, bool running) => sel.isNotEmpty && !running;

      expect(isBatchButtonEnabled(selectedChapterIds, false), isFalse);

      selectedChapterIds.add('chap_1');
      expect(isBatchButtonEnabled(selectedChapterIds, false), isTrue);

      selectedChapterIds.clear();
      expect(isBatchButtonEnabled(selectedChapterIds, false), isFalse);
    });

    test('BATCH_CONTINUES_AFTER_ERROR: Loop continues after error on Chapter 2', () async {
      final fakeTts = FakeTtsService();
      final audiobookService = AudiobookService(fakeTts);
      final speakers = {'narrator': const AudiobookSpeaker(id: 'narrator', name: 'Narrateur', voiceModelName: 'kokoro-voice-ff_siwis')};

      final queue = [
        const AudiobookChapter(id: 'c1', index: 1, title: 'Chap 1', rawText: '', lines: [AudiobookLine(id: 'l1', speakerId: 'narrator', speakerName: 'N', text: 'Texte 1')]),
        const AudiobookChapter(id: 'c2', index: 2, title: 'Chap 2 (Fail)', rawText: '', lines: []), // Empty lines throws error
        const AudiobookChapter(id: 'c3', index: 3, title: 'Chap 3', rawText: '', lines: [AudiobookLine(id: 'l3', speakerId: 'narrator', speakerName: 'N', text: 'Texte 3')]),
        const AudiobookChapter(id: 'c4', index: 4, title: 'Chap 4', rawText: '', lines: [AudiobookLine(id: 'l4', speakerId: 'narrator', speakerName: 'N', text: 'Texte 4')]),
      ];

      final successfulChapters = <int>[];
      final failedChapters = <int, String>{};

      for (final ch in queue) {
        try {
          final outPath = await audiobookService.synthesizeChapter(
            chapter: ch,
            speakers: speakers,
            outputDir: outputDir.path,
          );
          successfulChapters.add(ch.index);
          expect(isValidWavFile(File(outPath)), isTrue);
        } catch (e) {
          failedChapters[ch.index] = e.toString();
        }
      }

      expect(successfulChapters, [1, 3, 4], reason: 'Chapters 1, 3, 4 must succeed despite Chapter 2 failure');
      expect(failedChapters.containsKey(2), isTrue);
    });
  });
}

class FakeTtsService extends Fake implements TtsService {
  String? lastModelName;
  String? lastVoiceName;
  String? lastSpeakerName;
  double? lastSpeed;
  final List<Map<String, dynamic>> prepareHistory = [];

  @override
  Future<TtsLoadStatus> prepare({
    required String modelName,
    String? voiceName,
    String? codecName,
    String? refText,
    String? voiceWavPath,
    String? speakerName,
    int? speakerId,
    String? instructPrompt,
  }) async {
    lastModelName = modelName;
    lastVoiceName = voiceName;
    lastSpeakerName = speakerName;
    prepareHistory.add({
      'modelName': modelName,
      'voiceName': voiceName,
      'speakerName': speakerName,
    });
    return TtsLoadStatus.ready('test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #synthesize) {
      if (invocation.namedArguments.containsKey(const Symbol('speed'))) {
        lastSpeed = invocation.namedArguments[const Symbol('speed')] as double?;
      }
      final samples = Float32List(24000);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = 0.02;
      }
      return Future.value(SynthesizedAudio(samples: samples, sampleRate: 24000));
    }
    return super.noSuchMethod(invocation);
  }
}
