// test/asr_timeout_accelerated_test.dart
//
// Tests accélérés déterministes de l'initialisation du pool de workers ASR (TO-SRV-POOL-01)
// Couvre CAS A, CAS B, CAS C, CAS D sans attendre 90 secondes.

import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/transcription_worker.dart';
import 'package:jarvisol/services/transcription_worker_pool.dart';

// Worker simulant une initialisation lente (300 ms)
void _slowWorkerEntry(TranscriptionWorkerArgs args) async {
  final cmdReceive = ReceivePort();
  args.readySendPort.send(cmdReceive.sendPort);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  args.readySendPort.send(<String, Object?>{
    'type': 'ready',
    'backend': args.backend,
  });
  await for (final raw in cmdReceive) {
    if (raw is Map && raw['type'] == 'shutdown') {
      cmdReceive.close();
      return;
    }
  }
}

// Worker simulant une initialisation rapide (40 ms)
void _fastWorkerEntry(TranscriptionWorkerArgs args) async {
  final cmdReceive = ReceivePort();
  args.readySendPort.send(cmdReceive.sendPort);
  await Future<void>.delayed(const Duration(milliseconds: 40));
  args.readySendPort.send(<String, Object?>{
    'type': 'ready',
    'backend': args.backend,
  });
  await for (final raw in cmdReceive) {
    if (raw is Map && raw['type'] == 'shutdown') {
      cmdReceive.close();
      return;
    }
  }
}

// Worker simulant un échec immédiat (erreur de session)
void _immediateFailWorkerEntry(TranscriptionWorkerArgs args) {
  final cmdReceive = ReceivePort();
  args.readySendPort.send(cmdReceive.sendPort);
  args.readySendPort.send(<String, Object?>{
    'type': 'error',
    'message': 'Simulated immediate session open failure',
  });
  cmdReceive.close();
}

void main() {
  group('ASR Worker Pool Init Accelerated Tests', () {
    test('CAS A: worker sain lent > timeout simulé -> échec contrôlé par timeout', () async {
      final sw = Stopwatch()..start();
      try {
        await TranscriptionWorkerPool.spawn(
          count: 1,
          modelPath: 'dummy.bin',
          backend: 'cpu',
          libName: null,
          initTimeout: const Duration(milliseconds: 100),
          workerEntryPoint: _slowWorkerEntry,
        );
        fail('Le timeout aurait dû interrompre le worker');
      } catch (e) {
        expect(e, isA<TranscriptionWorkerException>());
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(800));
    });

    test('CAS B: worker sain dans la nouvelle fenêtre simulée -> READY', () async {
      final pool = await TranscriptionWorkerPool.spawn(
        count: 1,
        modelPath: 'dummy.bin',
        backend: 'cpu',
        libName: null,
        initTimeout: const Duration(milliseconds: 500),
        workerEntryPoint: _slowWorkerEntry, // prend 300ms, fenêtre 500ms
      );
      expect(pool.size, 1);
      expect(pool.aliveCount, 1);
      await pool.shutdown();
    });

    test('CAS C: worker échoue immédiatement -> fast-fail immédiat sans attendre', () async {
      final sw = Stopwatch()..start();
      try {
        await TranscriptionWorkerPool.spawn(
          count: 1,
          modelPath: 'dummy.bin',
          backend: 'cpu',
          libName: null,
          initTimeout: const Duration(seconds: 10),
          workerEntryPoint: _immediateFailWorkerEntry,
        );
        fail('L\'erreur immédiate aurait dû lever une exception');
      } catch (e) {
        expect(e, isA<TranscriptionWorkerException>());
      }
      sw.stop();
      // Doit échouer en moins de 800ms, sans jamais attendre 10s ni 90s
      expect(sw.elapsedMilliseconds, lessThan(800));
    });

    test('CAS D: pool count=3 -> workers valides correctement constitués', () async {
      final pool = await TranscriptionWorkerPool.spawn(
        count: 3,
        modelPath: 'dummy.bin',
        backend: 'cpu',
        libName: null,
        initTimeout: const Duration(milliseconds: 500),
        workerEntryPoint: _fastWorkerEntry,
      );
      expect(pool.size, 3);
      expect(pool.aliveCount, 3);
      await pool.shutdown();
      expect(pool.isShutdown, isTrue);
    });
  });
}
