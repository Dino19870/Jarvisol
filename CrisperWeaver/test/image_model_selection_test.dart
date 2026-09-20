import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/mcp_tools_service.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  late PortablePreferences prefs;
  late SettingsService settings;

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
  });

  group('T2I Model Selection — Exclusion inpainting & format filtering', () {
    test('excludes files containing inpaint from text-to-image candidates', () {
      final sampleFiles = [
        'flux1-schnell-Q4_K_S.gguf',
        'Realistic_Vision_V6.0_NV_B1_inpainting.safetensors',
        'stable-diffusion-v1-5-inpainting-Q4_0.gguf',
        'sd1.5-Q4_0.gguf',
        'sd_turbo.safetensors',
        'ae.safetensors',
        'clip_g.safetensors',
      ];

      final t2iModels = sampleFiles.where((f) {
        final lower = f.toLowerCase();
        if (lower.startsWith('ae.') || lower.startsWith('clip_') || lower.startsWith('t5xxl')) {
          return false;
        }
        if (lower.contains('inpaint')) {
          return false; // Inpainting formellement exclu
        }
        return lower.endsWith('.safetensors') || lower.endsWith('.gguf') || lower.endsWith('.ckpt');
      }).toList();

      expect(t2iModels, contains('flux1-schnell-Q4_K_S.gguf'));
      expect(t2iModels, contains('sd1.5-Q4_0.gguf'));
      expect(t2iModels, contains('sd_turbo.safetensors'));
      expect(t2iModels, isNot(contains('Realistic_Vision_V6.0_NV_B1_inpainting.safetensors')));
      expect(t2iModels, isNot(contains('stable-diffusion-v1-5-inpainting-Q4_0.gguf')));
      expect(t2iModels.length, 3);
    });

    test('excludes is_inpainting == true from /v1/models/image response', () {
      final mockServerList = [
        {'name': 'sd1.5-Q4_0.gguf', 'is_inpainting': false},
        {'name': 'sd_turbo.safetensors', 'is_inpainting': false},
        {'name': 'Realistic_Vision_V6.0_inpainting.safetensors', 'is_inpainting': true},
      ];

      final discovered = <String>[];
      for (final item in mockServerList) {
        final name = item['name'] as String;
        final isInpainting = item['is_inpainting'] as bool;
        if (name.isNotEmpty && !isInpainting) {
          discovered.add(name);
        }
      }

      expect(discovered, contains('sd1.5-Q4_0.gguf'));
      expect(discovered, contains('sd_turbo.safetensors'));
      expect(discovered, isNot(contains('Realistic_Vision_V6.0_inpainting.safetensors')));
      expect(discovered.length, 2);
    });
  });

  group('T2I Model Selection — UI Mode Determination', () {
    String determineUiMode(List<String>? models) {
      if (models != null && models.length > 1) return 'dropdown';
      if (models != null && models.length == 1) return 'label_simple';
      if (models != null && models.isEmpty) return 'aucun_modele';
      return 'loading_or_fallback';
    }

    test('determines dropdown mode when multiple compatible models are available', () {
      expect(determineUiMode(['modelA.gguf', 'modelB.safetensors']), 'dropdown');
    });

    test('determines simple label mode when exactly one model is available', () {
      expect(determineUiMode(['sd1.5-Q4_0.gguf']), 'label_simple');
    });

    test('determines explicit no-model message when 0 model is available', () {
      expect(determineUiMode([]), 'aucun_modele');
    });

    test('determines fallback/loading mode when models is null', () {
      expect(determineUiMode(null), 'loading_or_fallback');
    });
  });

  group('T1 à T5 — Tests rigoureux de traduction et génération d\'image', () {
    test('T1 Traduction ON : raw francais -> traduction LLM mockee -> prompt anglais', () async {
      const rawPrompt = 'une voiture verte sous la neige';
      const englishTranslation = 'a green car in the snow';

      final mockClient = MockClient((request) async {
        expect(request.url.path, endsWith('/chat/completions'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>;
        expect(messages.last['content'], rawPrompt);

        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': englishTranslation}
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      settings.llmProvider = LlmProvider.liteRtWindows;
      final mcpService = McpToolsService(settings, client: mockClient);

      final translated = await mcpService.translateToEnglishPrompt(rawPrompt, allowLlm: true);
      expect(translated, englishTranslation);

      // Simulation du payload transmis à generateImage
      settings.activeImageModel = 'flux1-schnell-Q4_K_S.gguf';
      final payload = jsonEncode({
        'prompt': translated,
        'model': settings.activeImageModel,
      });

      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      expect(decoded['prompt'], 'a green car in the snow');
      expect(decoded['model'], 'flux1-schnell-Q4_K_S.gguf');
    });

    test('T2 Traduction OFF : raw francais -> aucun LLM appele -> prompt brut francais', () async {
      const rawPrompt = 'voiture verte devant une maison sous la neige';
      bool llmCalled = false;

      final mockClient = MockClient((request) async {
        llmCalled = true;
        return http.Response('{}', 200);
      });

      final mcpService = McpToolsService(settings, client: mockClient);

      final result = await mcpService.translateToEnglishPrompt(rawPrompt, allowLlm: false);

      expect(llmCalled, isFalse, reason: 'Le LLM ne doit pas être contacté quand allowLlm=false');
      expect(result, rawPrompt);
    });

    test('T3 Traduction echoue : erreur HTTP 400 No models loaded -> LlmTranslationException levee', () async {
      const rawPrompt = 'voiture verte devant une maison sous la neige';

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': {
              'message': "No models loaded. Please load a model in the developer page or use the 'lms load' command.",
              'type': 'invalid_request_error',
            }
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      });

      settings.llmProvider = LlmProvider.lmStudio;
      final mcpService = McpToolsService(settings, client: mockClient);

      expect(
        () => mcpService.translateToEnglishPrompt(rawPrompt, allowLlm: true),
        throwsA(isA<LlmTranslationException>().having(
          (e) => e.message,
          'message',
          contains('No models loaded'),
        )),
        reason: 'Une exception explicite doit être levée sans fallback silencieux vers le français',
      );
    });

    test('T4 Modele image : activeImageModel est inchange dans les deux parcours', () async {
      settings.activeImageModel = 'flux1-schnell-Q4_K_S.gguf';

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'a red car'}
              }
            ]
          }),
          200,
        );
      });

      final mcpService = McpToolsService(settings, client: mockClient);

      // Parcours 1 : avec traduction
      await mcpService.translateToEnglishPrompt('une voiture rouge', allowLlm: true);
      expect(settings.activeImageModel, 'flux1-schnell-Q4_K_S.gguf');

      // Parcours 2 : sans traduction
      await mcpService.translateToEnglishPrompt('une voiture rouge', allowLlm: false);
      expect(settings.activeImageModel, 'flux1-schnell-Q4_K_S.gguf');
    });

    test('T5 Inpainting : activeInpaintModel reste inchange lors des operations T2I', () async {
      settings.activeImageModel = 'flux1-schnell-Q4_K_S.gguf';
      settings.activeInpaintModel = 'Realistic_Vision_V6.0_NV_B1_inpainting.safetensors';

      // Modification du modèle T2I
      settings.activeImageModel = 'sd1.5-Q4_0.gguf';

      expect(settings.activeImageModel, 'sd1.5-Q4_0.gguf');
      expect(settings.activeInpaintModel, 'Realistic_Vision_V6.0_NV_B1_inpainting.safetensors');
    });

    test('T6 Routage dynamique via LlmService : utilise le provider et l''endpoint exacts du service', () async {
      settings.llmProvider = LlmProvider.liteRtWindows;
      settings.llmModel = 'gemma-3n-e2b-it';

      final mockClient = MockClient((request) async {
        expect(request.url.host, '127.0.0.1');
        expect(request.url.port, 9379);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'a blue sports car'}
              }
            ]
          }),
          200,
        );
      });

      final llmService = LlmService(settings, client: mockClient);
      final mcpService = McpToolsService(settings);

      final result = await mcpService.translateToEnglishPrompt(
        'une voiture de sport bleue',
        allowLlm: true,
        llmService: llmService,
      );

      expect(result, 'a blue sports car');
    });
  });
}
