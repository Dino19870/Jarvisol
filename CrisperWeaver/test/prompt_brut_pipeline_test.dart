import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/mcp_tools_service.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  late PortablePreferences prefs;
  late SettingsService settings;
  late Directory tempDir;

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);

    tempDir = await Directory.systemTemp.createTemp('cw_prompt_brut_test_');
    AppPaths.setTestOverride(tempDir);
  });

  tearDown(() async {
    AppPaths.resetTestOverride();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Prompt Brut & Image Pipeline — Oracle strict & Non-régression', () {
    test('REQ-1 : Oracle strict du Prompt brut — aucun appel LLM et prompt français brut envoyé à T2I', () async {
      settings.activeImageModel = 'flux1-schnell-Q4_K_S.gguf';
      settings.imageGenApiUrl = 'http://127.0.0.1:7860/v1';
      settings.imageGenIsCloud = false;

      const dummyB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

      final requestsMade = <http.Request>[];

      final mockClient = MockClient((request) async {
        requestsMade.add(request as http.Request);
        if (request.url.path.contains('/sdapi/v1/txt2img')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['prompt'], 'voiture verte devant une maison sous la neige');
          expect(body['model'], 'flux1-schnell-Q4_K_S.gguf');
          return http.Response(
            jsonEncode({
              'images': [dummyB64]
            }),
            200,
          );
        }
        return http.Response('Unexpected call: ${request.url}', 500);
      });

      final mcpService = McpToolsService(settings, client: mockClient);

      final result = await mcpService.generateImage(
        'voiture verte devant une maison sous la neige',
        allowLlmTranslation: false,
      );

      expect(result, contains('🎨 **Image générée avec succès :**'));
      expect(result, contains('voiture verte devant une maison sous la neige'));
      expect(result, isNot(contains('Green car')));

      expect(requestsMade.length, 1);
      expect(requestsMade.first.url.path, '/sdapi/v1/txt2img');
    });

    test('REQ-2 : Test A/B complet — Étape A (Traduction IA) vs Étape B (Prompt brut)', () async {
      settings.activeImageModel = 'flux1-schnell-Q4_K_S.gguf';
      settings.imageGenApiUrl = 'http://127.0.0.1:7860/v1';
      settings.imageGenIsCloud = false;
      settings.llmProvider = LlmProvider.liteRtWindows;

      const dummyB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

      final receivedT2iPrompts = <String>[];

      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/sdapi/v1/txt2img')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          receivedT2iPrompts.add(body['prompt'] as String);
          return http.Response(
            jsonEncode({
              'images': [dummyB64]
            }),
            200,
          );
        } else if (request.url.path.contains('/chat/completions')) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Green car in front of a house under the snow'}
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final llmService = LlmService(settings, client: mockClient);
      final mcpService = McpToolsService(settings, client: mockClient);

      const rawFrenchPrompt = 'voiture verte devant une maison sous la neige';

      // --- ÉTAPE A : Traduction IA ---
      final translatedPrompt = await mcpService.translateToEnglishPrompt(
        rawFrenchPrompt,
        allowLlm: true,
        llmService: llmService,
      );
      expect(translatedPrompt, 'Green car in front of a house under the snow');

      final resultA = await mcpService.generateImage(translatedPrompt, allowLlmTranslation: false);
      expect(resultA, contains('🎨 **Image générée avec succès :**'));
      expect(resultA, contains('Green car in front of a house under the snow'));

      // --- ÉTAPE B : Prompt brut ---
      final resultB = await mcpService.generateImage(rawFrenchPrompt, allowLlmTranslation: false);
      expect(resultB, contains('🎨 **Image générée avec succès :**'));
      expect(resultB, contains('voiture verte devant une maison sous la neige'));

      expect(receivedT2iPrompts.length, 2);
      expect(receivedT2iPrompts[0], 'Green car in front of a house under the snow');
      expect(receivedT2iPrompts[1], 'voiture verte devant une maison sous la neige');
    });

    test('REQ-3 : Faux succès interdit — Si T2I échoue, erreur claire sans inventer d\'image', () async {
      settings.activeImageModel = 'flux1-schnell-Q4_K_S.gguf';
      settings.imageGenApiUrl = 'http://127.0.0.1:7860/v1';
      settings.imageGenIsCloud = false;

      final mockClient = MockClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final mcpService = McpToolsService(settings, client: mockClient);

      final result = await mcpService.generateImage('voiture verte', allowLlmTranslation: false);

      expect(result, contains('⚠️ **Serveur de Génération d\'Images Injoignable ou Erreur**'));
      expect(result, isNot(contains('🎨 **Image générée avec succès :**')));
    });

    test('REQ-4 : Robustesse de détection visuelle — support des variantes avec typos (énère, genere)', () {
      final mcpService = McpToolsService(settings);

      expect(mcpService.isImageGenerationRequest("génère l'image d'une voiture verte devant une maison"), isTrue);
      expect(mcpService.extractImagePrompt("génère l'image d'une voiture verte devant une maison"), 'voiture verte devant une maison');

      expect(mcpService.isImageGenerationRequest("énère l'image d'une voiture verte devant une maison sous la neige"), isTrue);
      expect(mcpService.extractImagePrompt("énère l'image d'une voiture verte devant une maison sous la neige"), 'voiture verte devant une maison sous la neige');

      expect(mcpService.isImageGenerationRequest("enere l'image d'une voiture"), isTrue);
    });

    test('REQ-5 : Isolation historique du chat textuel — les images générées sont exclues de validHistory', () {
      final messages = [
        LlmChatMessage(role: 'user', content: 'bonjour', timestamp: DateTime.now()),
        LlmChatMessage(role: 'assistant', content: 'Bonjour ! Comment puis-je vous aider ?', timestamp: DateTime.now()),
        LlmChatMessage(
          role: 'assistant',
          content: '🎨 **Image générée avec succès :**\n\n![Green car](file:///D:/path/img.png)',
          timestamp: DateTime.now(),
        ),
        LlmChatMessage(
          role: 'assistant',
          content: '🎨 **Détection d\'intention visuelle**\n\nVotre message décrit une scène visuelle.',
          timestamp: DateTime.now(),
        ),
        LlmChatMessage(role: 'user', content: 'énère l\'image d\'une voiture', timestamp: DateTime.now()),
      ];

      final validHistory = messages
          .where((m) =>
              !m.content.startsWith('❌ Erreur') &&
              !m.content.startsWith('⚠️ Aucune') &&
              !m.content.startsWith('⚠️') &&
              !m.content.contains('🎨 **Image générée avec succès') &&
              !m.content.contains('🎨 **Détection d\'intention visuelle'))
          .toList();

      expect(validHistory.length, 3);
      expect(validHistory[0].content, 'bonjour');
      expect(validHistory[1].content, 'Bonjour ! Comment puis-je vous aider ?');
      expect(validHistory[2].content, 'énère l\'image d\'une voiture');
      expect(validHistory.any((m) => m.content.contains('Image générée avec succès')), isFalse);
    });

    test('REQ-6 : Sauvegarde résiliente — résolution des URI et fallback vers AppPaths.imagesDir', () async {
      final imagesDir = AppPaths.imagesDir;
      final testFile = File(p.join(imagesDir.path, 'gen_image_test_9999.png'));
      await testFile.writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));

      final fileUri = Uri.file(testFile.path).toString();
      String resolvedPath = Uri.decodeComponent(fileUri.trim());
      if (resolvedPath.startsWith('file:///')) {
        resolvedPath = Uri.parse(resolvedPath).toFilePath(windows: Platform.isWindows);
      }
      File sourceFile = File(resolvedPath);
      if (!sourceFile.existsSync()) {
        final fallbackPath = p.join(AppPaths.imagesDir.path, p.basename(resolvedPath));
        final fallbackFile = File(fallbackPath);
        if (fallbackFile.existsSync()) {
          sourceFile = fallbackFile;
          resolvedPath = fallbackPath;
        }
      }
      expect(sourceFile.existsSync(), isTrue);

      const justBasename = 'gen_image_test_9999.png';
      String fallbackResolved = justBasename;
      File fallbackSource = File(fallbackResolved);
      if (!fallbackSource.existsSync()) {
        final fallbackPath = p.join(AppPaths.imagesDir.path, p.basename(fallbackResolved));
        final fallbackFile = File(fallbackPath);
        if (fallbackFile.existsSync()) {
          fallbackSource = fallbackFile;
          fallbackResolved = fallbackPath;
        }
      }
      expect(fallbackSource.existsSync(), isTrue);
      expect(fallbackResolved, testFile.path);
    });
  });
}
