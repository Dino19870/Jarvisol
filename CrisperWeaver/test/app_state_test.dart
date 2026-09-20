// AppStateNotifier — speaker rename + transcription lifecycle.
// Uses a ProviderContainer since Notifier requires ref.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jarvisol/engines/transcription_engine.dart';
import 'package:jarvisol/main.dart'
    show AppState, AppStateNotifier, appStateProvider;

void main() {
  late ProviderContainer container;
  late AppStateNotifier n;

  AppState readState() => container.read(appStateProvider);

  setUp(() {
    container = ProviderContainer();
    // Eagerly read the state so the notifier is built.
    container.read(appStateProvider);
    n = container.read(appStateProvider.notifier);
  });

  tearDown(() => container.dispose());

  group('AppStateNotifier.renameSpeaker', () {
    test('starts with no overrides', () {
      expect(readState().speakerNames, isEmpty);
    });

    test('sets and overrides a name', () {
      n.renameSpeaker('Speaker 1', 'Alice');
      expect(readState().speakerNames, {'Speaker 1': 'Alice'});

      n.renameSpeaker('Speaker 1', 'Alicia');
      expect(readState().speakerNames, {'Speaker 1': 'Alicia'});
    });

    test('keeps multiple overrides in parallel', () {
      n.renameSpeaker('Speaker 1', 'Alice');
      n.renameSpeaker('Speaker 2', 'Bob');
      expect(readState().speakerNames, {
        'Speaker 1': 'Alice',
        'Speaker 2': 'Bob',
      });
    });

    test('trims surrounding whitespace from the new name', () {
      n.renameSpeaker('Speaker 1', '   Alice   ');
      expect(readState().speakerNames['Speaker 1'], 'Alice');
    });

    test('whitespace-only new name removes the override', () {
      n.renameSpeaker('Speaker 1', 'Alice');
      n.renameSpeaker('Speaker 1', '   ');
      expect(readState().speakerNames.containsKey('Speaker 1'), isFalse);
    });

    test('empty new name removes the override (reset)', () {
      n.renameSpeaker('Speaker 1', 'Alice');
      n.renameSpeaker('Speaker 1', '');
      expect(readState().speakerNames.containsKey('Speaker 1'), isFalse);
    });

    test('empty original is a no-op', () {
      n.renameSpeaker('Speaker 1', 'Alice');
      n.renameSpeaker('', 'Charlie');
      expect(readState().speakerNames, {'Speaker 1': 'Alice'});
    });

    test('startTranscription wipes the rename map', () {
      n.renameSpeaker('Speaker 1', 'Alice');
      n.startTranscription();
      expect(readState().speakerNames, isEmpty);
      expect(readState().isTranscribing, isTrue);
      expect(readState().segments, isEmpty);
    });
  });

  group('AppStateNotifier transcription lifecycle', () {
    TranscriptionSegment seg(String t, double start, double end) =>
        TranscriptionSegment(
            text: t, startTime: start, endTime: end, confidence: 1.0);

    test('updateProgress clamps to [0, 1]', () {
      n.updateProgress(0.5);
      expect(readState().progress, 0.5);
      n.updateProgress(1.5);
      expect(readState().progress, 1.0);
      n.updateProgress(-0.2);
      expect(readState().progress, 0.0);
    });

    test('addSegment appends and rebuilds the joined transcription text',
        () {
      n.addSegment(seg('Hello.', 0.0, 1.0));
      expect(readState().segments.length, 1);
      expect(readState().currentTranscription, 'Hello.');

      n.addSegment(seg('World.', 1.0, 2.0));
      expect(readState().segments.length, 2);
      expect(readState().currentTranscription, 'Hello. World.');
    });

    test('completeTranscription sets isTranscribing=false + progress=1', () {
      n.startTranscription();
      n.completeTranscription([seg('a', 0, 1), seg('b', 1, 2)]);
      expect(readState().isTranscribing, isFalse);
      expect(readState().progress, 1.0);
      expect(readState().currentTranscription, 'a b');
      expect(readState().errorMessage, isNull);
    });

    test('setError clears isTranscribing and stores the message', () {
      n.startTranscription();
      n.setError('boom');
      expect(readState().isTranscribing, isFalse);
      expect(readState().errorMessage, 'boom');
    });

    test('clearTranscription resets to a fresh AppState', () {
      n.addSegment(seg('a', 0, 1));
      n.renameSpeaker('Speaker 1', 'Alice');
      n.clearTranscription();
      expect(readState().segments, isEmpty);
      expect(readState().currentTranscription, isNull);
      expect(readState().speakerNames, isEmpty);
    });

    test(
        'replaceLiveStreamingText: full streaming cycle clears prior segments '
        'then sets a live segment', () {
      // Simulate a prior transcription session with finalised segments.
      n.addSegment(seg('prior session segment', 0.0, 1.0));
      expect(readState().segments.length, 1);

      // In every real call site (mic-stream L447 + system-audio L557),
      // startTranscription() is always called before replaceLiveStreamingText.
      // It rebuilds AppState from scratch, clearing segments and speaker names.
      n.startTranscription();
      expect(readState().segments, isEmpty,
          reason: 'startTranscription() must clear all prior segments so '
              'the UI does not mix finalized and live text');
      expect(readState().isTranscribing, isTrue);

      // Engine emits rolling 10-s window commits — each overwrites in-place
      // to avoid duplicate text as the window slides forward.
      n.replaceLiveStreamingText('rolling decode latest');

      // currentTranscription holds the latest rolling window text.
      expect(readState().currentTranscription, 'rolling decode latest');

      // Exactly one live segment is present so the segment-list UI can
      // display the rolling text in the same widget as finalised segments.
      expect(readState().segments.length, 1);
      final live = readState().segments.single;
      expect(live.text, 'rolling decode latest');
      expect(live.metadata['streaming'], isTrue,
          reason: 'the streaming flag lets the UI distinguish a transient '
              'rolling-window segment from a permanent finalised one');
    });

    test('editSegment replaces text + flags edited in metadata', () {
      n.addSegment(seg('original text', 0, 1));
      n.editSegment(0, 'corrected text');
      expect(readState().segments[0].text, 'corrected text');
      expect(readState().segments[0].metadata['edited'], isTrue);
      expect(readState().currentTranscription, 'corrected text');
    });

    test('editSegment with out-of-range index is a no-op', () {
      n.addSegment(seg('original', 0, 1));
      n.editSegment(5, 'should not happen');
      expect(readState().segments[0].text, 'original');
      n.editSegment(-1, 'should not happen');
      expect(readState().segments[0].text, 'original');
    });
  });
}
