import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvisol/services/llm_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PortablePreferences.resetForTesting();
    LlmService.lastLmStudioDiscovery = null;
  });

  group('EXT-V1-06 Vision LM Studio Capability Matrix', () {
    test('VISION-VLM-01: Native VLM model (type "vlm") is recognized as supporting Vision', () async {
      final prefs = await PortablePreferences.getInstance();
      await prefs.setString('llm_provider', 'lmstudio');
      await prefs.setString('llm_model', 'qwen3.6-35b-a3b-uncensored-genesis-hermes-final');
      await prefs.setString('llm_api_url', 'http://localhost:1234/v1');
      final settings = SettingsService(prefs);

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/v0/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'qwen3.6-35b-a3b-uncensored-genesis-hermes-final',
                  'type': 'vlm',
                },
                {
                  'id': 'google/gemma-4-26b-a4b-qat',
                  'type': 'vlm',
                },
                {
                  'id': 'lfm2.5-2.6b',
                  'type': 'llm',
                },
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not found', 404);
      });

      final llm = LlmService(settings, client: mockClient);

      // 1. Check active model (qwen3.6...)
      final resultActive = await llm.checkVisionCapability();
      expect(resultActive.isSupported, isTrue);
      expect(resultActive.activeModelId, equals('qwen3.6-35b-a3b-uncensored-genesis-hermes-final'));
      expect(resultActive.reason, isNull);

      // 2. Check override model (google/gemma-4-26b-a4b-qat)
      final resultGemma = await llm.checkVisionCapability(modelOverride: 'google/gemma-4-26b-a4b-qat');
      expect(resultGemma.isSupported, isTrue);
      expect(resultGemma.activeModelId, equals('google/gemma-4-26b-a4b-qat'));
      expect(resultGemma.reason, isNull);
    });

    test('VISION-TEXT-01: Pure LLM model (type "llm") is refused with its EXACT model name in message', () async {
      final prefs = await PortablePreferences.getInstance();
      await prefs.setString('llm_provider', 'lmstudio');
      await prefs.setString('llm_model', 'qwen3.6-35b-a3b-uncensored-genesis-hermes-final');
      await prefs.setString('llm_api_url', 'http://localhost:1234/v1');
      final settings = SettingsService(prefs);

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/v0/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'lfm2.5-2.6b', 'type': 'llm'},
                {'id': 'google/gemma-4-26b-a4b-qat', 'type': 'vlm'},
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not found', 404);
      });

      final llm = LlmService(settings, client: mockClient);

      final result = await llm.checkVisionCapability(modelOverride: 'lfm2.5-2.6b');
      expect(result.isSupported, isFalse);
      expect(result.activeModelId, equals('lfm2.5-2.6b'));
      expect(result.reason, contains('lfm2.5-2.6b'));
      expect(result.reason, isNot(contains('qwen-2.5-1.5b-instruct')));
    });

    test('VISION-GHOST-FREE: Active LM Studio model is never mutated to qwen-2.5-1.5b-instruct', () async {
      final prefs = await PortablePreferences.getInstance();
      await prefs.setString('llm_provider', 'lmstudio');
      await prefs.setString('llm_model', 'qwen3.6-35b-a3b-uncensored-genesis-hermes-final');
      await prefs.setString('llm_api_url', 'http://localhost:1234/v1');
      final settings = SettingsService(prefs);

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/v0/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'qwen3.6-35b-a3b-uncensored-genesis-hermes-final', 'type': 'vlm'},
                {'id': 'qwen2.5-vl-7b-instruct', 'type': 'vlm'},
                {'id': 'qwen2.5-coder-32b-instruct', 'type': 'llm'},
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not found', 404);
      });

      final llm = LlmService(settings, client: mockClient);

      // Verify active model
      final res1 = await llm.checkVisionCapability();
      expect(res1.activeModelId, equals('qwen3.6-35b-a3b-uncensored-genesis-hermes-final'));
      expect(res1.activeModelId, isNot(equals('qwen-2.5-1.5b-instruct')));

      // Verify coder model
      final res2 = await llm.checkVisionCapability(modelOverride: 'qwen2.5-coder-32b-instruct');
      expect(res2.activeModelId, equals('qwen2.5-coder-32b-instruct'));
      expect(res2.activeModelId, isNot(equals('qwen-2.5-1.5b-instruct')));
      expect(res2.isSupported, isFalse);
      expect(res2.reason, contains('qwen2.5-coder-32b-instruct'));
      expect(res2.reason, isNot(contains('qwen-2.5-1.5b-instruct')));
    });

    test('VISION-OFFLINE: Returns isSupported=false and server unavailable message', () async {
      final prefs = await PortablePreferences.getInstance();
      await prefs.setString('llm_provider', 'lmstudio');
      await prefs.setString('llm_model', 'qwen3.6-35b-a3b-uncensored-genesis-hermes-final');
      await prefs.setString('llm_api_url', 'http://localhost:1234/v1');
      final settings = SettingsService(prefs);

      final mockClient = MockClient((request) async {
        throw const SocketException('Connection refused');
      });

      final llm = LlmService(settings, client: mockClient);
      final res = await llm.checkVisionCapability();

      expect(res.isSupported, isFalse);
      expect(res.reason, contains('indisponible'));
    });
  });
}
