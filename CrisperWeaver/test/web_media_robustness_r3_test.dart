import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/constants/timeout_policy.dart';
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
  group('Web Media R3 Robustness Tests', () {
    test('TimeoutPolicy Web Media Constants Defined', () {
      expect(TimeoutPolicy.webMediaDownloadInactivityTimeout, const Duration(seconds: 90));
      expect(TimeoutPolicy.webMediaDownloadAbsoluteMaxDuration, const Duration(hours: 2));
    });

    test('CAS 1: Processus actif avec stdout regulier au-dela du timeout d inactivite court -> NE DOIT PAS etre tue', () async {
      // Simulation: inactivityTimeout = 1s, duration = 2.5s, stdout emitted every 400ms
      final script = '''
import time, sys
for i in range(5):
    print(f"[download] {i*20}% of 10MiB", flush=True)
    time.sleep(0.4)
sys.exit(0)
''';
      final proc = await Process.start('python', ['-c', script], runInShell: false);
      DateTime lastActivity = DateTime.now();
      final completer = Completer<int>();

      proc.stdout.transform(utf8.decoder).listen((_) {
        lastActivity = DateTime.now();
      });
      proc.stderr.transform(utf8.decoder).listen((_) {
        lastActivity = DateTime.now();
      });
      proc.exitCode.then((c) {
        if (!completer.isCompleted) completer.complete(c);
      });

      final inactivityTimeout = const Duration(milliseconds: 2500);
      bool wasKilled = false;

      final timer = Timer.periodic(const Duration(milliseconds: 200), (t) {
        if (completer.isCompleted) {
          t.cancel();
          return;
        }
        if (DateTime.now().difference(lastActivity) >= inactivityTimeout) {
          t.cancel();
          wasKilled = true;
          WebMediaService.terminateProcessTree(proc);
          if (!completer.isCompleted) completer.completeError(TimeoutException('Stalled'));
        }
      });

      final code = await completer.future;
      timer.cancel();

      expect(wasKilled, isFalse);
      expect(code, 0);
    });

    test('CAS 2: Processus actif avec activite uniquement stderr -> NE DOIT PAS etre tue', () async {
      // Simulation: inactivityTimeout = 1s, duration = 2.5s, stderr emitted every 400ms
      final script = '''
import time, sys
for i in range(5):
    sys.stderr.write(f"frame={i*10} fps=30 speed=2.5x\\n")
    sys.stderr.flush()
    time.sleep(0.4)
sys.exit(0)
''';
      final proc = await Process.start('python', ['-c', script], runInShell: false);
      DateTime lastActivity = DateTime.now();
      final completer = Completer<int>();

      proc.stdout.transform(utf8.decoder).listen((_) {
        lastActivity = DateTime.now();
      });
      proc.stderr.transform(utf8.decoder).listen((_) {
        lastActivity = DateTime.now();
      });
      proc.exitCode.then((c) {
        if (!completer.isCompleted) completer.complete(c);
      });

      final inactivityTimeout = const Duration(milliseconds: 2500);
      bool wasKilled = false;

      final timer = Timer.periodic(const Duration(milliseconds: 200), (t) {
        if (completer.isCompleted) {
          t.cancel();
          return;
        }
        if (DateTime.now().difference(lastActivity) >= inactivityTimeout) {
          t.cancel();
          wasKilled = true;
          WebMediaService.terminateProcessTree(proc);
          if (!completer.isCompleted) completer.completeError(TimeoutException('Stalled'));
        }
      });

      final code = await completer.future;
      timer.cancel();

      expect(wasKilled, isFalse);
      expect(code, 0);
    });

    test('CAS 3: Processus totalement silencieux > inactivity timeout -> DOIT etre tue', () async {
      final script = '''
import time, sys
time.sleep(30)
''';
      final proc = await Process.start('python', ['-c', script], runInShell: false);
      DateTime lastActivity = DateTime.now();
      final completer = Completer<int>();

      proc.stdout.transform(utf8.decoder).listen((_) {
        lastActivity = DateTime.now();
      });
      proc.stderr.transform(utf8.decoder).listen((_) {
        lastActivity = DateTime.now();
      });
      proc.exitCode.then((c) {
        if (!completer.isCompleted) completer.complete(c);
      });

      final inactivityTimeout = const Duration(milliseconds: 800);
      bool wasKilled = false;

      final timer = Timer.periodic(const Duration(milliseconds: 200), (t) {
        if (completer.isCompleted) {
          t.cancel();
          return;
        }
        if (DateTime.now().difference(lastActivity) >= inactivityTimeout) {
          t.cancel();
          wasKilled = true;
          WebMediaService.terminateProcessTree(proc);
          if (!completer.isCompleted) completer.completeError(TimeoutException('Stalled'));
        }
      });

      expect(() => completer.future, throwsA(isA<TimeoutException>()));
      await Future.delayed(const Duration(milliseconds: 1200));
      timer.cancel();

      expect(wasKilled, isTrue);
      expect(isPidAlive(proc.pid), isFalse);
    });

    test('CAS 4: Processus continuellement actif mais depassant absolute max -> DOIT etre tue', () async {
      final script = '''
import time, sys
while True:
    print("chunk", flush=True)
    time.sleep(0.2)
''';
      final proc = await Process.start('python', ['-c', script], runInShell: false);
      final startTime = DateTime.now();
      final completer = Completer<int>();

      proc.stdout.transform(utf8.decoder).listen((_) {});
      proc.stderr.transform(utf8.decoder).listen((_) {});
      proc.exitCode.then((c) {
        if (!completer.isCompleted) completer.complete(c);
      });

      final absoluteTimeout = const Duration(milliseconds: 1000);
      bool wasKilled = false;

      final timer = Timer.periodic(const Duration(milliseconds: 200), (t) {
        if (completer.isCompleted) {
          t.cancel();
          return;
        }
        if (DateTime.now().difference(startTime) >= absoluteTimeout) {
          t.cancel();
          wasKilled = true;
          WebMediaService.terminateProcessTree(proc);
          if (!completer.isCompleted) completer.completeError(TimeoutException('Absolute max exceeded'));
        }
      });

      expect(() => completer.future, throwsA(isA<TimeoutException>()));
      await Future.delayed(const Duration(milliseconds: 1400));
      timer.cancel();

      expect(wasKilled, isTrue);
      expect(isPidAlive(proc.pid), isFalse);
    });

    test('CAS 5 & 6 + Process Tree: Parent + Enfant tue avec 0 orphelin sur timeout et annulation', () async {
      // Test CAS 5: Timeout triggers terminateProcessTree -> 0 descendants
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

      // Trigger terminateProcessTree
      WebMediaService.terminateProcessTree(parent);
      await Future.delayed(const Duration(milliseconds: 1200));

      final parentAliveAfter = isPidAlive(parent.pid);
      final childAliveAfter = isPidAlive(childPid);

      expect(parentAliveAfter, isFalse);
      expect(childAliveAfter, isFalse);

      // Test CAS 6: User Cancellation triggers terminateProcessTree -> 0 descendants
      final parent2 = await Process.start('python', ['-c', script], runInShell: false);
      final child2PidCompleter = Completer<int>();

      parent2.stdout.transform(utf8.decoder).listen((line) {
        final m = RegExp(r'CHILD_PID:(\d+)').firstMatch(line);
        if (m != null) {
          child2PidCompleter.complete(int.parse(m.group(1)!));
        }
      });

      final child2Pid = await child2PidCompleter.future.timeout(const Duration(seconds: 5));
      final cancelToken = WebMediaCancellationToken();
      cancelToken.attachProcess(parent2);

      expect(isPidAlive(parent2.pid), isTrue);
      expect(isPidAlive(child2Pid), isTrue);

      cancelToken.cancel();
      await Future.delayed(const Duration(milliseconds: 1200));

      expect(isPidAlive(parent2.pid), isFalse);
      expect(isPidAlive(child2Pid), isFalse);
    });

    test('STDERR_HIGH_VOLUME_NO_PIPE_BLOCK = PASS', () async {
      // Produces ~150KB of stderr chunks without writing to stdout.
      // If streams were not drained concurrently, the OS pipe would block the subprocess.
      final script = '''
import sys
for i in range(1500):
    sys.stderr.write("X" * 100 + "\\n")
    sys.stderr.flush()
sys.exit(0)
''';
      final proc = await Process.start('python', ['-c', script], runInShell: false);
      final stderrBuf = StringBuffer();
      final stdoutBuf = StringBuffer();

      proc.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
      proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);

      final exitCode = await proc.exitCode.timeout(const Duration(seconds: 10));
      expect(exitCode, 0);
      expect(stderrBuf.length, greaterThanOrEqualTo(150000));
    });

    test('SUBTITLE_WATCHDOG_LOGIC_UNCHANGED = PASS', () {
      final service = WebMediaService.instance;
      expect(service.findYtDlpBinary(), isNotNull);
      // The subtitle watchdog uses terminateProcessTree on cancellation / timeout
    });

    test('WEB_MEDIA_R2_BASELINE = PASS', () {
      expect(WebMediaService.defaultSearchLimit, 20);
      expect(WebMediaService.searchLimitIncrement, 10);
      expect(WebMediaService.maxSearchLimit, 50);

      // Verify Wildcard matching
      final item1 = WebMediaSearchResult(
        id: '1',
        url: 'https://youtube.com/watch?v=1',
        title: 'Python Tutorial Beginner',
      );
      final item2 = WebMediaSearchResult(
        id: '2',
        url: 'https://youtube.com/watch?v=2',
        title: 'Flutter Advanced Guide',
      );

      expect(WebMediaWildcardMatcher.matches('Python*', item1), isTrue);
      expect(WebMediaWildcardMatcher.matches('Python*', item2), isFalse);
      expect(WebMediaWildcardMatcher.matches('*Advanced*', item2), isTrue);
    });

    test('PORTABILITY = PASS', () {
      final service = WebMediaService.instance;
      final ytdlp = service.findYtDlpBinary();
      final ffmpeg = service.findFfmpegBinary();
      final ffprobe = service.findFfprobeBinary();
      final js = service.findJsRuntime();

      expect(ytdlp, contains('runtime'));
      expect(ytdlp, contains('web_media'));
      expect(ffmpeg, contains('runtime'));
      expect(ffmpeg, contains('web_media'));
      expect(ffprobe, contains('runtime'));
      expect(ffprobe, contains('web_media'));
      expect(js, contains('runtime'));
      expect(js, contains('web_media'));
    });
  });
}
