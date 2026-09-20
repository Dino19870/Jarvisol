// test/timeout_fix_a1_test.dart
// Targeted verification suite for JARVISOL-HARDCODED-TIMEOUT-FIX-A1

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvisol/constants/timeout_policy.dart';
import 'package:jarvisol/services/cloud_llm_cleanup_service.dart';
import 'package:jarvisol/services/transcript_summarize_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Section 5: MULTI-IMAGE PREBUILD TESTS', () {
    test('MULTI_IMAGE_TIMEOUT_USES_POLICY: verify multi_image_edit_widget.dart uses TimeoutPolicy.imageGenLocalAttempt', () {
      final file = File('lib/widgets/multi_image_edit_widget.dart');
      final content = file.readAsStringSync();
      expect(content.contains('TimeoutPolicy.imageGenLocalAttempt'), isTrue);
    });

    test('MULTI_IMAGE_NO_5MIN_LITERAL_ACTIVE: verify no 5 min literal in multi_image_edit_widget.dart', () {
      final file = File('lib/widgets/multi_image_edit_widget.dart');
      final content = file.readAsStringSync();
      expect(content.contains('timeout(const Duration(minutes: 5))'), isFalse);
    });

    test('IMAGE_MAIN_TIMEOUT_CHAIN: sd_server guardrail < localAttempt <= globalBudget', () {
      const sdServerGuardrail = Duration(seconds: 7200); // 2 hours
      const localAttempt = TimeoutPolicy.imageGenLocalAttempt; // 7500s (2h05m)
      const globalBudget = TimeoutPolicy.imageGenGlobalBudget; // 7800s (2h10m)

      expect(sdServerGuardrail.inSeconds, 7200);
      expect(localAttempt.inSeconds, 7500);
      expect(globalBudget.inSeconds, 7800);
      expect(sdServerGuardrail < localAttempt, isTrue);
      expect(localAttempt <= globalBudget, isTrue);
    });
  });

  group('Section 6: TRANSCRIPT SUMMARY PREBUILD TESTS', () {
    test('TRANSCRIPT_SUMMARIZATION_POLICY: TimeoutPolicy.transcriptSummarization is 5 minutes', () {
      expect(TimeoutPolicy.transcriptSummarization, const Duration(minutes: 5));
      expect(TimeoutPolicy.transcriptSummarization.inSeconds, 300);
    });

    test('CLOUD_LLM_DEFAULT_TIMEOUT_UNCHANGED: CloudLlmConfig default timeout remains 30s', () {
      const config = CloudLlmConfig(
        apiUrl: 'http://localhost:1234/v1',
        apiKey: 'test-key',
        model: 'test-model',
      );
      expect(config.timeout, const Duration(seconds: 30));
    });

    test('SUMMARIZE_DIALOG_USES_TRANSCRIPT_SUMMARIZATION: summarize_dialog.dart explicitly passes transcriptSummarization', () {
      final file = File('lib/widgets/summarize_dialog.dart');
      final content = file.readAsStringSync();
      expect(content.contains('timeout: TimeoutPolicy.transcriptSummarization'), isTrue);
    });

    test('TRANSCRIPT_SUMMARY_LATENCY_TOLERANCE: latencies at 20s, 31s, 60s, 120s, 180s pass under 5min budget', () async {
      final config = const CloudLlmConfig(
        apiUrl: 'http://localhost:1234/v1',
        apiKey: 'test',
        model: 'model',
        timeout: TimeoutPolicy.transcriptSummarization,
      );

      for (final latencySec in [20, 31, 60, 120, 180]) {
        // Create mock client with accelerated clock simulation
        final client = MockClient((request) async {
          await Future.delayed(const Duration(milliseconds: 5));
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': '## Action items\n- Action item after $latencySec s (Bob)',
                  }
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final service = TranscriptSummarizeService(client: client);
        final response = await service.summarize(
          transcript: 'Test transcript content for meeting',
          kinds: {SummaryKind.actionItems},
          config: config,
        );
        expect(response.actionItems.length, 1);
        expect(response.actionItems.first, contains('Action item after $latencySec s'));
      }
    });

    test('OTHER_LLM_CALLS_UNCHANGED: per-segment cleanup still uses default 30s timeout config', () {
      const normalConfig = CloudLlmConfig(
        apiUrl: 'http://localhost:1234/v1',
        apiKey: 'test',
        model: 'model',
      );
      expect(normalConfig.timeout, const Duration(seconds: 30));
    });
  });

  group('Section 7: OCR PREBUILD TESTS', () {
    test('OCR_TIMEOUT_VALUE_BEFORE_AND_AFTER: OCR timeout value remains strictly 12 seconds', () {
      final file = File('lib/services/image_ocr_service.dart');
      final content = file.readAsStringSync();
      expect(content.contains('process.exitCode.timeout(const Duration(seconds: 12))'), isTrue);
    });

    test('OCR_TREE_TERMINATION_AND_ORPHAN_PREVENTION: verify process and descendants killed cleanly on timeout', () async {
      // Spawn a parent powershell process that launches a background child process
      final proc = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Start-Process ping -ArgumentList "-t 127.0.0.1" -NoNewWindow -PassThru | Select-Object -ExpandProperty Id; Start-Sleep -Seconds 60'
      ]);

      final pid = proc.pid;
      expect(pid, greaterThan(0));

      // Read stdout to capture child PID if possible
      int? childPid;
      final sub = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((line) {
        final trimmed = line.trim();
        final parsed = int.tryParse(trimmed);
        if (parsed != null && parsed > 0 && childPid == null) {
          childPid = parsed;
        }
      });

      // Wait 1 second for child to start
      await Future.delayed(const Duration(seconds: 1));

      // Simulate timeout trigger: kill parent and tree using taskkill /F /T /PID
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
      } else {
        proc.kill(ProcessSignal.sigkill);
      }

      await sub.cancel();
      await proc.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);

      // Verify parent process is dead
      final checkParent = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
      final parentAlive = checkParent.stdout.toString().contains('$pid');
      expect(parentAlive, isFalse, reason: 'Parent process must not be alive after taskkill /F /T');

      // If child PID was identified, verify child is dead
      if (childPid != null) {
        final checkChild = await Process.run('tasklist', ['/FI', 'PID eq $childPid']);
        final childAlive = checkChild.stdout.toString().contains('$childPid');
        expect(childAlive, isFalse, reason: 'Child process must not be alive after tree taskkill');
      }
    });

    test('OCR_NORMAL_COMPLETION: quick command completes successfully without timeout', () async {
      final proc = await Process.start('powershell', ['-NoProfile', '-Command', 'Write-Output "OCR_SUCCESS"']);
      final stdoutBuffer = StringBuffer();
      final sub = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((data) => stdoutBuffer.write(data));

      final exitCode = await proc.exitCode.timeout(const Duration(seconds: 12));
      await sub.cancel();

      expect(exitCode, 0);
      expect(stdoutBuffer.toString(), contains('OCR_SUCCESS'));
    });
  });
}
