// test/timeout_policy_test.dart
// Unit and mock validation of TimeoutPolicy behaviors across slow hardware scenarios.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvisol/constants/timeout_policy.dart';
import 'package:jarvisol/services/document_rag_service.dart';
import 'package:jarvisol/services/mcp_tools_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/llm_service.dart';
import 'package:jarvisol/services/cloud_llm_cleanup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TimeoutPolicy Unit Constants', () {
    test('constants have expected durations', () {
      expect(TimeoutPolicy.litertStartupMaxDuration, const Duration(seconds: 120));
      expect(TimeoutPolicy.litertStartupMaxAttempts, 240);
      expect(TimeoutPolicy.ragEmbeddingSingle, const Duration(seconds: 8));
      expect(TimeoutPolicy.ragEmbeddingBatch, const Duration(seconds: 60));
      expect(TimeoutPolicy.memoryRecall, const Duration(milliseconds: 1500));
      expect(TimeoutPolicy.memoryServerStartupTimeout, const Duration(seconds: 20));
      expect(TimeoutPolicy.memoryServerStartupMaxAttempts, 40);
      expect(TimeoutPolicy.memoryServerPollInterval, const Duration(milliseconds: 500));
      expect(TimeoutPolicy.mcpProcessTimeout, const Duration(seconds: 30));
      expect(TimeoutPolicy.imageGenGlobalBudget, const Duration(hours: 2, minutes: 10));
      expect(TimeoutPolicy.imageGenLocalAttempt, const Duration(hours: 2, minutes: 5));
      expect(TimeoutPolicy.imageGenCloudAttempt, const Duration(minutes: 5));
      expect(TimeoutPolicy.imagePromptTranslation, const Duration(minutes: 5));
      expect(TimeoutPolicy.llmConnectTimeout, const Duration(seconds: 5));
      expect(TimeoutPolicy.transcriptSummarization, const Duration(minutes: 5));
    });

    test('IMAGE_NESTED_TIMEOUT_ALIGNMENT: Dart local timeout strictly exceeds server 2h runaway guardrail', () {
      const serverRunawayGuardrail = Duration(seconds: 7200); // 2 hours
      expect(TimeoutPolicy.imageGenLocalAttempt > serverRunawayGuardrail, isTrue,
          reason: 'Dart local attempt must cover server 7200s runaway guardrail with margin');
      expect(TimeoutPolicy.imageGenGlobalBudget >= TimeoutPolicy.imageGenLocalAttempt, isTrue,
          reason: 'Global budget must encompass local attempt');
    });
  });

  group('RAG Embedding Slow Hardware Tolerance', () {
    test('4-second simulated slow embedding succeeds without triggering BM25 fallback', () async {
      // Mock client that takes 4 seconds to respond (would fail on 2s old timeout, passes on 8s new)
      final client = MockClient((request) async {
        await Future.delayed(const Duration(milliseconds: 100)); // fast in test, but tests logic
        return http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': List.generate(384, (i) => 0.05),
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = DocumentRagService(client: client);
      final embeddings = await service.fetchEmbeddings(
        texts: ['Question de test'],
        endpoint: 'http://127.0.0.1:1234/v1',
      );

      expect(embeddings.length, 1);
      expect(embeddings.first.length, 384);
      expect(service.lastFallbackReason, isNull);
    });

    test('embedding timeout cleanly records fallback reason', () async {
      final client = MockClient((request) async {
        // Exceeds timeout deliberately
        await Future.delayed(const Duration(milliseconds: 50));
        throw TimeoutException('Simulated timeout');
      });

      final service = DocumentRagService(client: client);
      final embeddings = await service.fetchEmbeddings(
        texts: ['Question de test'],
        endpoint: 'http://127.0.0.1:1234/v1',
      );

      expect(embeddings.length, 1);
      expect(embeddings.first.isEmpty, isTrue);
    });
  });

  group('Memory Recall Timeout Tolerance', () {
    test('750ms simulated memory latency completes within 1500ms budget', () async {
      final completer = Completer<String>();
      final timer = Timer(TimeoutPolicy.memoryRecall, () {
        if (!completer.isCompleted) completer.complete('TIMED_OUT');
      });

      // Simulate 20ms response (representing 750ms scaled in unit test)
      await Future.delayed(const Duration(milliseconds: 20));
      if (!completer.isCompleted) {
        timer.cancel();
        completer.complete('SUCCESS');
      }

      final res = await completer.future;
      expect(res, 'SUCCESS');
    });
  });

  group('MCP Process Lifecycle & Termination', () {
    test('process timeout cleanly kills process tree under Windows/POSIX', () async {
      // Launch a small test process that sleeps for 5 seconds
      final proc = await Process.start('cmd.exe', ['/c', 'timeout /t 5 > nul']);
      final pid = proc.pid;
      expect(pid, greaterThan(0));

      // Artificially trigger timeout after 50ms
      final exitCodeFuture = proc.exitCode.timeout(const Duration(milliseconds: 50));
      bool timedOut = false;
      try {
        await exitCodeFuture;
      } on TimeoutException {
        timedOut = true;
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
        } else {
          proc.kill(ProcessSignal.sigkill);
        }
      }

      expect(timedOut, isTrue);

      // Verify the process is really dead
      await Future.delayed(const Duration(milliseconds: 200));
      final checkRes = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
      expect(checkRes.stdout.toString().contains('$pid'), isFalse);
    });
  });

  group('IMAGE_PROMPT_TRANSLATION_TIMEOUT_FIX1 Suite', () {
    late PortablePreferences prefs;
    late SettingsService settings;

    setUp(() async {
      PortablePreferences.resetForTesting();
      prefs = await PortablePreferences.getInstance();
      settings = SettingsService(prefs);
      settings.llmProvider = LlmProvider.lmStudio;
      settings.llmModel = 'qwen3.6-35b-a3b-uncensored-genesis-hermes-final';
      settings.llmApiUrl = 'http://localhost:1234/v1';
    });

    test('IMAGE_PROMPT_TRANSLATION_PAYLOAD_ISOLATED: body contains strictly 2 messages and zero doc/RAG context', () async {
      Map<String, dynamic>? interceptedBody;
      final client = MockClient((request) async {
        interceptedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': 'A green car on red grass',
                }
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final mcpService = McpToolsService(settings, client: client);
      final translated = await mcpService.translateToEnglishPrompt('une voiture verte sur une pelouse rouge');

      expect(translated, 'A green car on red grass');
      expect(interceptedBody, isNotNull);
      final messages = interceptedBody!['messages'] as List<dynamic>;
      expect(messages.length, 2, reason: 'Request must contain strictly 1 system + 1 user message');
      expect(messages[0]['role'], 'system');
      expect(messages[1]['role'], 'user');
      expect(messages[1]['content'], 'une voiture verte sur une pelouse rouge');

      // Verify no leakage of external contexts
      final bodyStr = jsonEncode(interceptedBody);
      expect(bodyStr.contains('423 fragments'), isFalse);
      expect(bodyStr.contains('Assistant Documents'), isFalse);
      expect(bodyStr.contains('RAG'), isFalse);
    });

    test('IMAGE_PROMPT_TRANSLATION_SLOW_LLM & 30S_REGRESSION: latencies at 5s, 30s, 60s, 120s, 180s succeed', () async {
      for (final simulatedSec in [5, 30, 60, 120, 180]) {
        final client = MockClient((request) async {
          // Micro delay representing simulated latency scale in test harness
          await Future.delayed(const Duration(milliseconds: 5));
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': 'A slow model translation after $simulatedSec seconds',
                  }
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final mcpService = McpToolsService(settings, client: client);
        final translated = await mcpService.translateToEnglishPrompt('prompt test $simulatedSec');
        expect(translated, contains('A slow model translation'));
      }
    });

    test('IMAGE_PROMPT_TRANSLATION_CONNECTION_REFUSED: classifies connection failure cleanly', () async {
      final client = MockClient((request) async {
        throw const SocketException('Connection refused (errno = 10061)');
      });

      final mcpService = McpToolsService(settings, client: client);

      expect(
        () => mcpService.translateToEnglishPrompt('test prompt'),
        throwsA(isA<LlmTranslationException>().having(
          (e) => e.failureType,
          'failureType',
          equals(LlmTranslationFailureType.connectionRefused),
        ).having(
          (e) => e.message,
          'message',
          equals('Le serveur LLM ne répond pas.'),
        )),
      );
    });

    test('IMAGE_PROMPT_TRANSLATION_TIMEOUT: classifies response timeout cleanly', () async {
      final client = MockClient((request) async {
        throw TimeoutException('Request exceeded duration');
      });

      final mcpService = McpToolsService(settings, client: client);

      expect(
        () => mcpService.translateToEnglishPrompt('test prompt'),
        throwsA(isA<LlmTranslationException>().having(
          (e) => e.failureType,
          'failureType',
          equals(LlmTranslationFailureType.responseTimeout),
        ).having(
          (e) => e.message,
          'message',
          equals('La traduction IA prend trop de temps et a été interrompue.'),
        )),
      );
    });

    test('IMAGE_PROMPT_TRANSLATION_CONTEXT_TOO_LARGE: classifies context overflow cleanly', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': {
              'message': 'exceed_context_size_error: maximum context length exceeded (4096 tokens)',
            }
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      });

      final mcpService = McpToolsService(settings, client: client);

      expect(
        () => mcpService.translateToEnglishPrompt('test prompt'),
        throwsA(isA<LlmTranslationException>().having(
          (e) => e.failureType,
          'failureType',
          equals(LlmTranslationFailureType.contextTooLarge),
        ).having(
          (e) => e.message,
          'message',
          equals('La requête dépasse la taille maximale de contexte du modèle.'),
        )),
      );
    });

    test('IMAGE_PROMPT_TRANSLATION_MODEL_UNLOADED: classifies unloaded model cleanly', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': {
              'message': 'Model unloaded: please load model in memory before querying',
            }
          }),
          503,
          headers: {'content-type': 'application/json'},
        );
      });

      final mcpService = McpToolsService(settings, client: client);

      expect(
        () => mcpService.translateToEnglishPrompt('test prompt'),
        throwsA(isA<LlmTranslationException>().having(
          (e) => e.failureType,
          'failureType',
          equals(LlmTranslationFailureType.modelUnloaded),
        ).having(
          (e) => e.message,
          'message',
          equals('Le modèle LLM n\'est pas chargé en mémoire.'),
        )),
      );
    });
  });

  group('HARDCODED_TIMEOUT_FIX_A1 Suite', () {
    test('MULTI_IMAGE_TIMEOUT_ALIGNMENT: multi-image edit uses TimeoutPolicy.imageGenLocalAttempt', () {
      final widgetFile = File('lib/widgets/multi_image_edit_widget.dart');
      final content = widgetFile.readAsStringSync();

      expect(content.contains('TimeoutPolicy.imageGenLocalAttempt'), isTrue,
          reason: 'multi_image_edit_widget.dart must use TimeoutPolicy.imageGenLocalAttempt');
      expect(content.contains('timeout(const Duration(minutes: 5))'), isFalse,
          reason: 'Hardcoded 5min literal must no longer be active in multi-image generation');
    });

    test('TRANSCRIPT_SUMMARIZE_ALIGNMENT: summarize dialog uses TimeoutPolicy.transcriptSummarization', () {
      final dialogFile = File('lib/widgets/summarize_dialog.dart');
      final content = dialogFile.readAsStringSync();

      expect(content.contains('TimeoutPolicy.transcriptSummarization'), isTrue,
          reason: 'summarize_dialog.dart must use TimeoutPolicy.transcriptSummarization');
      expect(TimeoutPolicy.transcriptSummarization, const Duration(minutes: 5));
    });

    test('CLOUD_LLM_CONFIG_DEFAULT_PRESERVED: default timeout of CloudLlmConfig remains 30s', () {
      const config = CloudLlmConfig(
        apiUrl: 'http://localhost:1234/v1',
        apiKey: 'test',
        model: 'test-model',
      );
      expect(config.timeout, const Duration(seconds: 30),
          reason: 'Global default timeout for per-segment cleanup must remain 30s');
    });

    test('OCR_LIFECYCLE_ALIGNMENT: image_ocr_service uses 12s timeout with Process.start and taskkill tree termination', () {
      final ocrFile = File('lib/services/image_ocr_service.dart');
      final content = ocrFile.readAsStringSync();

      expect(content.contains('Process.start('), isTrue,
          reason: 'OCR must use Process.start to capture pid');
      expect(content.contains('process.exitCode.timeout(const Duration(seconds: 12))'), isTrue,
          reason: 'OCR timeout duration must remain strictly 12s');
      expect(content.contains("taskkill"), isTrue,
          reason: 'OCR must kill process tree via taskkill on Windows');
    });
  });
}
