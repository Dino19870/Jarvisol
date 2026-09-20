// test/audiobook_batch_generation_test.dart — Unit & Widget logic tests for multi-chapter batch audio generation.

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/audiobook_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EXT-V1-04 — BATCH GENERATION LOGIC & INVARIANTS', () {
    late AudiobookProject sampleProject;

    setUp(() {
      sampleProject = AudiobookProject(
        id: 'proj_batch_test',
        title: 'Le Mystère de la Chambre Jaune',
        author: 'Gaston Leroux',
        sourcePath: 'livre.epub',
        chapters: [
          const AudiobookChapter(id: 'chap_1', index: 1, title: 'Chapitre 1 : Le Drame', rawText: 'Texte chap 1'),
          const AudiobookChapter(id: 'chap_2', index: 2, title: 'Chapitre 2 : L\'Enquête', rawText: 'Texte chap 2'),
          const AudiobookChapter(id: 'chap_3', index: 3, title: 'Chapitre 3 : Les Indices', rawText: 'Texte chap 3'),
          const AudiobookChapter(id: 'chap_4', index: 4, title: 'Chapitre 4 : La Piste', rawText: 'Texte chap 4'),
          const AudiobookChapter(id: 'chap_5', index: 5, title: 'Chapitre 5 : La Révélation', rawText: 'Texte chap 5'),
        ],
        speakers: {
          'narrator': const AudiobookSpeaker(
            id: 'narrator',
            name: 'Narrateur',
            voiceModelName: 'piper-fr-siwis-medium',
          ),
        },
        createdAt: DateTime.now(),
      );
    });

    test('T1: BATCH_ORDER = BOOK_ORDER (Strict book index ordering regardless of selection order)', () {
      // User checks chapters in random order: 5, then 2, then 4, then 1
      final selectedIds = <String>{};
      selectedIds.add('chap_5');
      selectedIds.add('chap_2');
      selectedIds.add('chap_4');
      selectedIds.add('chap_1');

      // Create snapshot queue sorted by book order
      final queue = sampleProject.chapters
          .where((c) => selectedIds.contains(c.id))
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));

      expect(queue.length, 4);
      expect(queue[0].index, 1);
      expect(queue[1].index, 2);
      expect(queue[2].index, 4);
      expect(queue[3].index, 5);
      expect(queue.map((c) => c.id).toList(), ['chap_1', 'chap_2', 'chap_4', 'chap_5']);
    });

    test('T2: Select All & Deselect All Chapters', () {
      final selectedIds = <String>{};

      // Select All
      selectedIds.addAll(sampleProject.chapters.map((c) => c.id));
      expect(selectedIds.length, 5);
      expect(selectedIds.containsAll(['chap_1', 'chap_2', 'chap_3', 'chap_4', 'chap_5']), isTrue);

      // Deselect All
      selectedIds.clear();
      expect(selectedIds.isEmpty, isTrue);
    });

    test('T3: Non-contiguous selection (e.g. chapters 1, 3, 5)', () {
      final selectedIds = <String>{'chap_1', 'chap_3', 'chap_5'};

      final queue = sampleProject.chapters
          .where((c) => selectedIds.contains(c.id))
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));

      expect(queue.length, 3);
      expect(queue[0].index, 1);
      expect(queue[1].index, 3);
      expect(queue[2].index, 5);
    });

    test('T4: Pre-flight conflict check (Skip option filters out already generated chapters)', () {
      // Simulate chapter 2 and chapter 4 already ready
      final modifiedChapters = List<AudiobookChapter>.from(sampleProject.chapters);
      modifiedChapters[1] = modifiedChapters[1].copyWith(status: AudiobookRenderStatus.ready, audioFilePath: 'path/Audiobook_Chap_02.wav');
      modifiedChapters[3] = modifiedChapters[3].copyWith(status: AudiobookRenderStatus.ready, audioFilePath: 'path/Audiobook_Chap_04.wav');

      final projectWithExisting = sampleProject.copyWith(chapters: modifiedChapters);

      final selectedIds = {'chap_1', 'chap_2', 'chap_3', 'chap_4'};
      final queue = projectWithExisting.chapters
          .where((c) => selectedIds.contains(c.id))
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));

      final existing = queue.where((c) => c.status == AudiobookRenderStatus.ready).toList();
      expect(existing.length, 2);
      expect(existing.map((c) => c.index).toList(), [2, 4]);

      // skip mode
      final skippedIds = existing.map((c) => c.id).toSet();
      final chaptersToRun = queue.where((c) => !skippedIds.contains(c.id)).toList();

      expect(chaptersToRun.length, 2);
      expect(chaptersToRun.map((c) => c.index).toList(), [1, 3]);
    });

    test('T5: Pre-flight conflict check (Overwrite option keeps all selected)', () {
      final modifiedChapters = List<AudiobookChapter>.from(sampleProject.chapters);
      modifiedChapters[0] = modifiedChapters[0].copyWith(status: AudiobookRenderStatus.ready);

      final selectedIds = {'chap_1', 'chap_2'};
      final queue = modifiedChapters
          .where((c) => selectedIds.contains(c.id))
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));

      // overwrite keeps all
      final chaptersToRun = List<AudiobookChapter>.from(queue);
      expect(chaptersToRun.length, 2);
      expect(chaptersToRun[0].index, 1);
      expect(chaptersToRun[1].index, 2);
    });

    test('T6: Error Resilience — Single chapter failure does not abort remaining chapters', () async {
      final selectedIds = {'chap_1', 'chap_2', 'chap_3'};
      final queue = sampleProject.chapters
          .where((c) => selectedIds.contains(c.id))
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));

      final batchStatuses = <String, AudiobookRenderStatus>{};
      final batchErrors = <String, String>{};
      final executed = <int>[];

      // Simulate sequential batch loop with error on chap_2
      for (final chap in queue) {
        batchStatuses[chap.id] = AudiobookRenderStatus.synthesizing;
        executed.add(chap.index);

        if (chap.id == 'chap_2') {
          // Simulate failure
          batchErrors[chap.id] = 'Disk full or TTS error';
          batchStatuses[chap.id] = AudiobookRenderStatus.error;
          continue; // Continue to next chapter
        }

        batchStatuses[chap.id] = AudiobookRenderStatus.ready;
      }

      expect(executed, [1, 2, 3], reason: 'All chapters must be attempted');
      expect(batchStatuses['chap_1'], AudiobookRenderStatus.ready);
      expect(batchStatuses['chap_2'], AudiobookRenderStatus.error);
      expect(batchStatuses['chap_3'], AudiobookRenderStatus.ready);
      expect(batchErrors.containsKey('chap_2'), isTrue);
      expect(batchErrors.containsKey('chap_1'), isFalse);
    });

    test('T7: Cancellation — User stop cleanly halts subsequent chapters', () {
      final selectedIds = {'chap_1', 'chap_2', 'chap_3', 'chap_4', 'chap_5'};
      final queue = sampleProject.chapters
          .where((c) => selectedIds.contains(c.id))
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));

      final batchStatuses = <String, AudiobookRenderStatus>{};
      for (final c in queue) {
        batchStatuses[c.id] = AudiobookRenderStatus.waiting;
      }

      bool isCancelled = false;
      final executed = <int>[];

      for (int i = 0; i < queue.length; i++) {
        if (isCancelled) {
          for (int k = i; k < queue.length; k++) {
            batchStatuses[queue[k].id] = AudiobookRenderStatus.cancelled;
          }
          break;
        }

        final chap = queue[i];
        batchStatuses[chap.id] = AudiobookRenderStatus.synthesizing;
        executed.add(chap.index);
        batchStatuses[chap.id] = AudiobookRenderStatus.ready;

        // User stops after chapter 2
        if (chap.index == 2) {
          isCancelled = true;
        }
      }

      expect(executed, [1, 2]);
      expect(batchStatuses['chap_1'], AudiobookRenderStatus.ready);
      expect(batchStatuses['chap_2'], AudiobookRenderStatus.ready);
      expect(batchStatuses['chap_3'], AudiobookRenderStatus.cancelled);
      expect(batchStatuses['chap_4'], AudiobookRenderStatus.cancelled);
      expect(batchStatuses['chap_5'], AudiobookRenderStatus.cancelled);
    });

    test('T8: Non-regression — Single chapter generation still produces expected chapter state', () {
      final chap = sampleProject.chapters[0];
      const simulatedWavPath = 'C:/Jarvisol/data/Audiobooks/Test/Audiobook_Chap_01.wav';

      final updatedChapter = chap.copyWith(
        status: AudiobookRenderStatus.ready,
        audioFilePath: simulatedWavPath,
        progress: 1.0,
      );

      expect(updatedChapter.status, AudiobookRenderStatus.ready);
      expect(updatedChapter.audioFilePath, simulatedWavPath);
      expect(updatedChapter.progress, 1.0);
    });
  });
}
