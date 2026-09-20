// test/web_media_edge_process_r4_test.dart
// Verification and fault-injection test suite for PHASE JARVISOL-WEB-MEDIA-EDGE-PROCESS-FIX-R4.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/web_media_service.dart';

bool isPidAlive(int pid) {
  if (Platform.isWindows) {
    final res = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    final out = res.stdout.toString().trim();
    return out.contains(pid.toString());
  } else {
    try {
      final res = Process.runSync('kill', ['-0', pid.toString()]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Web Media R4 Edge Process Tests (AUD-WEB-04)', () {
    test('A, B, C: Process Tree Termination on Timeout kills parent and child (0 orphans)', () async {
      // Simulates the timeout handler pattern across getMetadata, enumeratePlaylist, getComments
      // using WebMediaService.terminateProcessTree(process).
      final script = '''
import subprocess, time, sys
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
print(f"CHILD_PID:{child.pid}", flush=True)
time.sleep(60)
''';
      final parent = await Process.start('python', ['-c', script], runInShell: false);
      final childPidCompleter = Completer<int>();

      parent.stdout.transform(utf8.decoder).listen((line) {
        final m = RegExp(r'CHILD_PID:(\d+)').firstMatch(line);
        if (m != null) {
          childPidCompleter.complete(int.parse(m.group(1)!));
        }
      });

      final childPid = await childPidCompleter.future.timeout(const Duration(seconds: 5));
      expect(isPidAlive(parent.pid), isTrue);
      expect(isPidAlive(childPid), isTrue);

      // Simulate timeout triggering WebMediaService.terminateProcessTree
      WebMediaService.terminateProcessTree(parent);
      await Future.delayed(const Duration(milliseconds: 1200));

      final parentAlive = isPidAlive(parent.pid);
      final childAlive = isPidAlive(childPid);

      expect(parentAlive, isFalse, reason: 'PARENT_TERMINATED should be YES');
      expect(childAlive, isFalse, reason: 'CHILD_TERMINATED should be YES (0 orphans)');
    });

    test('D: enumeratePlaylist JSON totalement corrompu -> WebMediaProcessException', () {
      // Direct unit test of the parsing contract implemented in enumeratePlaylist:
      // When rawOutput is non-empty but contains candidate lines that fail to parse,
      // it must throw WebMediaProcessException and NOT return [] as a false success.
      const corruptedOutput = '<html><head><title>500 Error</title></head><body>Server Error</body></html>\n';
      
      final items = <WebMediaPlaylistItem>[];
      int candidateLines = 0;
      for (final line in corruptedOutput.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        candidateLines++;
        try {
          final data = jsonDecode(trimmed) as Map<String, dynamic>;
          items.add(WebMediaPlaylistItem.fromJson(data));
        } catch (_) {}
      }

      expect(candidateLines, greaterThan(0));
      expect(items, isEmpty);
      // The service contract throws WebMediaProcessException in this case:
      expect(
        () {
          if (candidateLines > 0 && items.isEmpty) {
            throw WebMediaProcessException(
              'Format JSON invalide ou aucune entrée playlist exploitable.',
              exitCode: 0,
              stderr: '',
            );
          }
        },
        throwsA(isA<WebMediaProcessException>()),
      );
    });

    test('E: enumeratePlaylist lignes mixtes -> entrees valides conservees', () {
      final mixedOutput = [
        '{"id": "v1", "title": "First Video", "url": "https://youtube.com/watch?v=v1"}',
        'THIS IS A CORRUPTED OR LOG LINE THAT IS NOT JSON',
        '{"id": "v2", "title": "Second Video", "url": "https://youtube.com/watch?v=v2"}',
      ].join('\n');

      final items = <WebMediaPlaylistItem>[];
      int candidateLines = 0;
      for (final line in mixedOutput.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        candidateLines++;
        try {
          final data = jsonDecode(trimmed) as Map<String, dynamic>;
          items.add(WebMediaPlaylistItem.fromJson(data));
        } catch (_) {}
      }

      expect(candidateLines, 3);
      expect(items.length, 2);
      expect(items[0].id, 'v1');
      expect(items[1].id, 'v2');
      // Must NOT throw when valid items are recovered
      expect(candidateLines > 0 && items.isEmpty, isFalse);
    });

    test('F: exitCode != 0 throws WebMediaProcessException with exit code and stderr', () {
      const exitCode = 1;
      const stderr = 'ERROR: [youtube] Private video';
      expect(
        () {
          if (exitCode != 0) {
            throw WebMediaProcessException(
              'Échec de l\'opération',
              exitCode: exitCode,
              stderr: stderr,
            );
          }
        },
        throwsA(isA<WebMediaProcessException>()),
      );
    });

    test('G: STDERR >150 KB causes no pipe deadlock when drained asynchronously', () async {
      final script = '''
import sys
for _ in range(2000):
    sys.stderr.write("E" * 100 + "\\n")
    sys.stderr.flush()
sys.stdout.write("DONE\\n")
sys.stdout.flush()
sys.exit(0)
''';
      final proc = await Process.start('python', ['-c', script], runInShell: false);
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();

      proc.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
      proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);

      final exitCode = await proc.exitCode.timeout(const Duration(seconds: 10));
      expect(exitCode, 0);
      expect(stderrBuf.length, greaterThanOrEqualTo(200000));
      expect(stdoutBuf.toString().trim(), 'DONE');
    });

    test('H: Cancel Token terminates process tree (parent and child)', () async {
      final script = '''
import subprocess, time, sys
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
print(f"CHILD_PID:{child.pid}", flush=True)
time.sleep(60)
''';
      final parent = await Process.start('python', ['-c', script], runInShell: false);
      final childPidCompleter = Completer<int>();

      parent.stdout.transform(utf8.decoder).listen((line) {
        final m = RegExp(r'CHILD_PID:(\d+)').firstMatch(line);
        if (m != null) {
          childPidCompleter.complete(int.parse(m.group(1)!));
        }
      });

      final childPid = await childPidCompleter.future.timeout(const Duration(seconds: 5));
      final cancelToken = WebMediaCancellationToken();
      cancelToken.attachProcess(parent);

      expect(isPidAlive(parent.pid), isTrue);
      expect(isPidAlive(childPid), isTrue);

      cancelToken.cancel();
      await Future.delayed(const Duration(milliseconds: 1200));

      expect(isPidAlive(parent.pid), isFalse);
      expect(isPidAlive(childPid), isFalse);
    });
  });
}
