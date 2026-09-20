// test/cloud_llm_providers_test.dart — Comprehensive tests for multi-cloud LLM providers, API keys, and manual model ID entry.

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/models/cloud_llm_provider_profile.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AUDIT CLOUD LLM PROVIDERS : Modèles & Persistance', () {
    test('1.1 CloudLlmProviderProfile serialization, presets, and copyWith',
        () {
      final profile = CloudLlmProviderProfile(
        id: 'prov_custom_1',
        name: 'Mon Serveur Mistral',
        endpoint: 'https://api.mistral.ai/v1',
        apiKey: 'sk-mistral-secret-key-123',
        defaultModel: 'mistral-large-latest',
        cachedModels: ['mistral-large-latest', 'codestral-latest'],
        temperature: 0.65,
        maxTokens: 32000,
        createdAt: DateTime(2026, 8, 23, 14, 0),
      );

      final json = profile.toJson();
      expect(json['id'], 'prov_custom_1');
      expect(json['name'], 'Mon Serveur Mistral');
      expect(json['apiKey'], 'sk-mistral-secret-key-123');
      expect(json['defaultModel'], 'mistral-large-latest');
      expect(json['temperature'], 0.65);
      expect(json['maxTokens'], 32000);

      final deserialized = CloudLlmProviderProfile.fromJson(json);
      expect(deserialized.id, 'prov_custom_1');
      expect(deserialized.name, 'Mon Serveur Mistral');
      expect(deserialized.apiKey, 'sk-mistral-secret-key-123');
      expect(deserialized.cachedModels.length, 2);

      final copied = profile.copyWith(
          name: 'Mistral Production', defaultModel: 'pixtral-large-latest');
      expect(copied.name, 'Mistral Production');
      expect(copied.defaultModel, 'pixtral-large-latest');
      expect(copied.apiKey, 'sk-mistral-secret-key-123');

      // Presets
      expect(CloudLlmProviderProfile.presets.length, greaterThanOrEqualTo(5));
      expect(
          CloudLlmProviderProfile.presets.any((p) => p.name.contains('OpenAI')),
          isTrue);
      expect(
          CloudLlmProviderProfile.presets.any((p) => p.name.contains('Groq')),
          isTrue);
      expect(
          CloudLlmProviderProfile.presets
              .any((p) => p.name.contains('DeepSeek')),
          isTrue);
    });

    test('1.2 SettingsService save, list, and delete custom cloud providers',
        () async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);

      expect(settings.customCloudProviders, isEmpty);

      final p1 = CloudLlmProviderProfile(
        id: 'p1',
        name: 'OpenAI Dev',
        endpoint: 'https://api.openai.com/v1',
        apiKey: 'sk-proj-abc',
        defaultModel: 'gpt-4o',
        createdAt: DateTime.now(),
      );

      final p2 = CloudLlmProviderProfile(
        id: 'p2',
        name: 'Groq Cloud',
        endpoint: 'https://api.groq.com/openai/v1',
        apiKey: 'gsk-xyz',
        defaultModel: 'llama-3.3-70b-versatile',
        createdAt: DateTime.now(),
      );

      await settings.saveCloudProvider(p1);
      await settings.saveCloudProvider(p2);

      expect(settings.customCloudProviders.length, 2);
      expect(settings.customCloudProviders.first.name, 'OpenAI Dev');
      expect(settings.customCloudProviders.last.name, 'Groq Cloud');

      // Update p1
      final updatedP1 =
          p1.copyWith(name: 'OpenAI Prod', defaultModel: 'gpt-4o-mini');
      await settings.saveCloudProvider(updatedP1);
      expect(settings.customCloudProviders.length, 2);
      expect(settings.customCloudProviders.first.name, 'OpenAI Prod');
      expect(settings.customCloudProviders.first.defaultModel, 'gpt-4o-mini');

      // Delete p2
      await settings.deleteCloudProvider('p2');
      expect(settings.customCloudProviders.length, 1);
      expect(settings.customCloudProviders.first.id, 'p1');
    });
  });

  group('AUDIT CLOUD LLM PROVIDERS : Dialogue & Actions Utilisateur', () {
    late SettingsService settingsService;

    setUp(() async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      settingsService = SettingsService(prefs);
    });

    test('2.1 saveCloudProvider persists active profile on first add',
        () async {
      final profile = CloudLlmProviderProfile(
        id: 'prov_new_cloud_123',
        name: 'OpenAI Dev',
        endpoint: 'https://api.openai.com/v1',
        apiKey: 'sk-proj-test-openai',
        defaultModel: 'gpt-4o',
        cachedModels: ['gpt-4o', 'gpt-4o-mini'],
        createdAt: DateTime.now(),
      );

      await settingsService.saveCloudProvider(profile);
      settingsService.activeCloudProviderId = profile.id;
      settingsService.llmProvider = LlmProvider.custom;
      settingsService.llmApiUrl = profile.endpoint;
      settingsService.llmApiKey = profile.apiKey;
      settingsService.llmModel = profile.defaultModel;

      expect(settingsService.llmProvider, LlmProvider.custom);
      expect(settingsService.llmApiKey, 'sk-proj-test-openai');
      expect(settingsService.llmModel, 'gpt-4o');
      expect(settingsService.activeCloudProviderId, 'prov_new_cloud_123');
      expect(settingsService.customCloudProviders.length, 1);
      expect(settingsService.customCloudProviders.first.name, 'OpenAI Dev');
      expect(settingsService.customCloudProviders.first.cachedModels,
          ['gpt-4o', 'gpt-4o-mini']);
    });

    test('2.2 switching to local provider clears activeCloudProviderId',
        () async {
      // Simulate cloud provider configured first
      final profile = CloudLlmProviderProfile(
        id: 'prov_groq',
        name: 'Groq',
        endpoint: 'https://api.groq.com/openai/v1',
        apiKey: 'gsk-groq-key',
        defaultModel: 'llama-3.3-70b-versatile',
        createdAt: DateTime.now(),
      );
      await settingsService.saveCloudProvider(profile);
      settingsService.activeCloudProviderId = 'prov_groq';
      settingsService.llmProvider = LlmProvider.custom;

      // Now switch to local LM Studio
      settingsService.activeCloudProviderId = '';
      settingsService.llmProvider = LlmProvider.lmStudio;
      settingsService.llmApiUrl = LlmProvider.lmStudio.defaultEndpoint;
      settingsService.llmApiKey = '';

      expect(settingsService.activeCloudProviderId, '');
      expect(settingsService.llmProvider, LlmProvider.lmStudio);
      // Cloud provider persisted in list (not deleted)
      expect(settingsService.customCloudProviders.length, 1);
    });

    test('2.3 CloudLlmProviderProfile presets cover all major providers', () {
      final presets = CloudLlmProviderProfile.presets;
      expect(presets.length, greaterThanOrEqualTo(5));
      expect(presets.any((p) => p.endpoint.contains('openai.com')), isTrue,
          reason: 'OpenAI preset manquant');
      expect(presets.any((p) => p.endpoint.contains('groq.com')), isTrue,
          reason: 'Groq preset manquant');
      expect(presets.any((p) => p.endpoint.contains('mistral.ai')), isTrue,
          reason: 'Mistral preset manquant');
      expect(presets.any((p) => p.endpoint.contains('deepseek.com')), isTrue,
          reason: 'DeepSeek preset manquant');
      expect(presets.any((p) => p.endpoint.contains('openrouter.ai')), isTrue,
          reason: 'OpenRouter preset manquant');

      // All presets have a non-empty defaultModel
      for (final preset in presets) {
        expect(preset.defaultModel.isNotEmpty, isTrue,
            reason: 'Preset "${preset.name}" sans defaultModel');
        expect(preset.cachedModels.isNotEmpty, isTrue,
            reason: 'Preset "${preset.name}" sans cachedModels');
      }
    });

    test(
        '2.4 Manual model ID entry — profile saves with user-supplied model string',
        () async {
      const manualModelId = 'my-finetuned-mistral-8x7b:custom';

      final profile = CloudLlmProviderProfile(
        id: 'prov_manual',
        name: 'Serveur Custom',
        endpoint: 'https://my-server.example.com/v1',
        apiKey: 'secret-key-abc',
        defaultModel: manualModelId,
        cachedModels: [], // Pas de modèles listés automatiquement
        createdAt: DateTime.now(),
      );

      await settingsService.saveCloudProvider(profile);

      final saved = settingsService.customCloudProviders
          .firstWhere((p) => p.id == 'prov_manual');
      expect(saved.defaultModel, manualModelId);
      expect(saved.cachedModels, isEmpty);
      expect(saved.endpoint, 'https://my-server.example.com/v1');
    });
  });
}
