import 'dart:convert';
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
  });

  group('LM Studio Provider Integration & Non-regression', () {
    test('LMS-DISC-06: fetchModelsForEndpoint returns chatModels only for lmStudio provider', () async {
      final prefs = await PortablePreferences.getInstance();
      await prefs.setString('llm_provider', 'lmstudio');
      await prefs.setString('llm_api_url', 'http://localhost:1234/v1');
      final settings = SettingsService(prefs);

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/v0/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'mistralai/devstral-small-2-2512', 'type': 'vlm'},
                {'id': 'text-embedding-qwen3-embedding-4b', 'type': 'embeddings'},
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not found', 404);
      });

      final llm = LlmService(settings, client: mockClient);
      final models = await llm.fetchModelsForEndpoint('http://localhost:1234/v1');

      expect(models, contains('mistralai/devstral-small-2-2512'));
      expect(models, isNot(contains('text-embedding-qwen3-embedding-4b')));
      expect(models.length, equals(1));
    });

    test('LMS-DISC-07: getAvailableModels returns chatModels only for lmStudio provider', () async {
      final prefs = await PortablePreferences.getInstance();
      await prefs.setString('llm_provider', 'lmstudio');
      await prefs.setString('llm_api_url', 'http://localhost:1234/v1');
      final settings = SettingsService(prefs);

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/v0/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'google/gemma-4-26b-a4b-qat', 'type': 'llm'},
                {'id': 'text-embedding-nomic-embed-text-v1.5', 'type': 'embeddings'},
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not found', 404);
      });

      final llm = LlmService(settings, client: mockClient);
      final models = await llm.getAvailableModels();

      expect(models, contains('google/gemma-4-26b-a4b-qat'));
      expect(models, isNot(contains('text-embedding-nomic-embed-text-v1.5')));
      expect(models.length, equals(1));
    });
  });
}
