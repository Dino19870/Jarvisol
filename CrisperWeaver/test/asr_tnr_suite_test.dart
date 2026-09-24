// test/asr_tnr_suite_test.dart
//
// Tests de non-régression (TNR) obligatoires ASR (Section 5) :
// - fichier audio court (jfk-2s.wav)
// - fichier audio long (jfk.wav)
// - cold start worker
// - warm reuse
// - pool multi-workers (count: 2)
// - streaming / onSegment
// - modèle absent / erreur worker
// - fermeture propre du pool
// - annulation / dispatch post-shutdown

import 'dart:io';
import 'package:crispasr/crispasr.dart' as crispasr;
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/engines/transcription_engine.dart';
import 'package:jarvisol/services/transcription_worker_pool.dart';

void main() {
  final baseModelFile = File(r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2\data\models\whisper_cpp\ggml-base.bin');
  final whisperDllFile = File(r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2\whisper.dll');
  final shortWav = File('test/jfk-2s.wav');
  final longWav = File('test/jfk.wav');

  final skipReason = (!baseModelFile.existsSync() || !whisperDllFile.existsSync())
      ? 'Modèle ou DLL CrispASR introuvable'
      : null;

  group('ASR TNR Suite (Section 5)', () {
    test('TNR: cold start, multi-worker pool, short audio, warm reuse, streaming, and clean shutdown', () async {
      final libPath = whisperDllFile.path;
      final modelPath = baseModelFile.path;

      // Décodage des fixtures audio
      final shortDecoded = crispasr.decodeAudioFile(shortWav.path, libPath: libPath);
      final longDecoded = crispasr.decodeAudioFile(longWav.path, libPath: libPath);
      expect(shortDecoded.samples.length, greaterThan(20000));
      expect(longDecoded.samples.length, greaterThan(50000));

      // 1. Cold start multi-workers pool (count: 2)
      final pool = await TranscriptionWorkerPool.spawn(
        count: 2,
        modelPath: modelPath,
        backend: 'whisper',
        libName: libPath,
      );
      expect(pool.size, 2);
      expect(pool.aliveCount, 2);

      // 2. Fichier court + streaming onSegment
      final streamedSegsShort = <TranscriptionSegment>[];
      final resShort = await pool.dispatch(
        samples: shortDecoded.samples,
        language: 'en',
        onSegment: (s) => streamedSegsShort.add(s),
      );
      expect(resShort, isNotEmpty);
      expect(streamedSegsShort, isNotEmpty);
      final shortText = resShort.map((s) => s.text).join(' ').toLowerCase();
      expect(shortText.contains('america') || shortText.contains('fellow') || shortText.contains('and so'), isTrue);

      // 3. Warm reuse sur le même pool avec fichier long
      final streamedSegsLong = <TranscriptionSegment>[];
      final resLong = await pool.dispatch(
        samples: longDecoded.samples,
        language: 'en',
        onSegment: (s) => streamedSegsLong.add(s),
      );
      expect(resLong, isNotEmpty);
      expect(streamedSegsLong, isNotEmpty);

      // 4. Fermeture propre du pool
      await pool.shutdown();
      expect(pool.isShutdown, isTrue);

      // 5. Annulation / rejet sur pool fermé
      expect(
        () async => await pool.dispatch(samples: shortDecoded.samples),
        throwsA(isA<TranscriptionWorkerException>()),
      );
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

    test('TNR: modèle absent -> erreur worker gérée proprement', () async {
      final libPath = whisperDllFile.path;
      try {
        await TranscriptionWorkerPool.spawn(
          count: 1,
          modelPath: 'C:/invalid_path/model_absent.bin',
          backend: 'whisper',
          libName: libPath,
          initTimeout: const Duration(seconds: 5),
        );
        fail('Devrait échouer car modèle absent');
      } catch (e) {
        expect(e, isA<TranscriptionWorkerException>());
      }
    }, skip: skipReason);
  });
}
