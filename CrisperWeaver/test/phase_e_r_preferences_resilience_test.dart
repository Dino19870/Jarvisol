import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';

void main() {
  setUp(() {
    PortablePreferences.resetForTesting();
  });

  Future<SettingsService> createServiceWithRawJson(Map<String, dynamic> data) async {
    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    for (final entry in data.entries) {
      if (entry.value is String) {
        await prefs.setString(entry.key, entry.value as String);
      } else if (entry.value is bool) {
        await prefs.setBool(entry.key, entry.value as bool);
      } else if (entry.value is int) {
        await prefs.setInt(entry.key, entry.value as int);
      } else if (entry.value is double) {
        await prefs.setDouble(entry.key, entry.value as double);
      } else {
        await prefs.setRaw(entry.key, entry.value);
      }
    }
    return SettingsService(prefs);
  }

  group('Phase E-R: Preferences Resilience & Anti-Regression', () {
    test('E-R-01: custom_cloned_voices as native List [] does not crash getString or customClonedVoices', () async {
      final svc = await createServiceWithRawJson({
        'custom_cloned_voices': [],
      });
      final prefs = await PortablePreferences.getInstance();

      expect(prefs.getString('custom_cloned_voices'), isNull);
      final voices = svc.customClonedVoices;
      expect(voices, isEmpty);
    });

    test('E-R-02: custom_cloned_voices as stringified JSON returns empty list', () async {
      final svc = await createServiceWithRawJson({
        'custom_cloned_voices': '[]',
      });
      final prefs = await PortablePreferences.getInstance();

      expect(prefs.getString('custom_cloned_voices'), '[]');
      final voices = svc.customClonedVoices;
      expect(voices, isEmpty);
    });

    test('E-R-03: custom_cloned_voices with items under both native List and stringified JSON', () async {
      final sampleItem = {
        'id': 'voice_alice',
        'name': 'Alice Cloned',
        'speaker': 'alice',
        'wavPath': 'voices/alice.wav',
        'createdAt': '2026-09-10T12:00:00.000Z',
      };

      // Form 1: Native List
      final svcN = await createServiceWithRawJson({
        'custom_cloned_voices': [sampleItem],
      });
      final voicesN = svcN.customClonedVoices;
      expect(voicesN.length, 1);
      expect(voicesN.first.id, 'voice_alice');
      expect(voicesN.first.name, 'Alice Cloned');

      // Form 2: Stringified JSON
      final svcS = await createServiceWithRawJson({
        'custom_cloned_voices': jsonEncode([sampleItem]),
      });
      final voicesS = svcS.customClonedVoices;
      expect(voicesS.length, 1);
      expect(voicesS.first.id, 'voice_alice');
      expect(voicesS.first.name, 'Alice Cloned');
    });

    test('E-R-04: custom_cloned_voices absent returns empty list without error', () async {
      final svc = await createServiceWithRawJson({});
      expect(svc.customClonedVoices, isEmpty);
    });

    test('E-R-05: custom_cloned_voices corrupted string or unexpected type falls back safely', () async {
      final svcC = await createServiceWithRawJson({
        'custom_cloned_voices': '{this is not valid json',
      });
      expect(svcC.customClonedVoices, isEmpty);

      final svcI = await createServiceWithRawJson({
        'custom_cloned_voices': 42,
      });
      expect(svcI.customClonedVoices, isEmpty);
    });

    test('E-R-06: custom_voice_presets native list and stringified JSON', () async {
      final presetItem = {
        'id': 'custom_p1',
        'name': 'Custom Preset 1',
        'voice': 'custom_voice',
        'temperature': 0.8,
      };

      final svcN = await createServiceWithRawJson({
        'custom_voice_presets': [presetItem],
      });
      final listN = svcN.customVoicePresets;
      expect(listN.any((p) => p.id == 'custom_p1'), isTrue);

      final svcS = await createServiceWithRawJson({
        'custom_voice_presets': jsonEncode([presetItem]),
      });
      final listS = svcS.customVoicePresets;
      expect(listS.any((p) => p.id == 'custom_p1'), isTrue);
    });

    test('E-R-06b: custom_cloud_llm_providers native list and stringified JSON', () async {
      final providerItem = {
        'id': 'prov_deepseek',
        'name': 'DeepSeek Cloud',
        'apiUrl': 'https://api.deepseek.com/v1',
        'apiKey': 'sk-test',
        'selectedModel': 'deepseek-chat',
        'availableModels': ['deepseek-chat', 'deepseek-reasoner'],
      };

      final svcN = await createServiceWithRawJson({
        'custom_cloud_llm_providers': [providerItem],
      });
      final listN = svcN.customCloudProviders;
      expect(listN.length, 1);
      expect(listN.first.id, 'prov_deepseek');

      final svcS = await createServiceWithRawJson({
        'custom_cloud_llm_providers': jsonEncode([providerItem]),
      });
      final listS = svcS.customCloudProviders;
      expect(listS.length, 1);
      expect(listS.first.id, 'prov_deepseek');
    });

    test('E-R-06c: custom_system_prompt_presets native list and stringified JSON', () async {
      final promptItem = {
        'id': 'custom_prompt_1',
        'name': 'Code Reviewer',
        'prompt': 'Review this code carefully.',
      };

      final svcN = await createServiceWithRawJson({
        'custom_system_prompt_presets': [promptItem],
      });
      expect(svcN.systemPromptPresets.any((p) => p.id == 'custom_prompt_1'), isTrue);

      final svcS = await createServiceWithRawJson({
        'custom_system_prompt_presets': jsonEncode([promptItem]),
      });
      expect(svcS.systemPromptPresets.any((p) => p.id == 'custom_prompt_1'), isTrue);
    });

    test('E-R-06d: audiobook_rule_profiles native list and stringified JSON', () async {
      final ruleItem = {
        'id': 'rule_profile_1',
        'name': 'Custom Rule Profile',
        'isBuiltin': false,
        'rules': [],
      };

      final svcN = await createServiceWithRawJson({
        'audiobook_rule_profiles': [ruleItem],
      });
      expect(svcN.audiobookRuleProfiles.any((p) => p.id == 'rule_profile_1'), isTrue);

      final svcS = await createServiceWithRawJson({
        'audiobook_rule_profiles': jsonEncode([ruleItem]),
      });
      expect(svcS.audiobookRuleProfiles.any((p) => p.id == 'rule_profile_1'), isTrue);
    });

    test('E-R-06e: hf_user_repos native list and stringified JSON', () async {
      final repoItem = {
        'repoId': 'user/my-whisper-model',
        'backend': 'whisper',
      };

      final svcN = await createServiceWithRawJson({
        'hf_user_repos': [repoItem],
      });
      expect(svcN.hfUserRepos.length, 1);
      expect(svcN.hfUserRepos.first['repoId'], 'user/my-whisper-model');

      final svcS = await createServiceWithRawJson({
        'hf_user_repos': jsonEncode([repoItem]),
      });
      expect(svcS.hfUserRepos.length, 1);
      expect(svcS.hfUserRepos.first['repoId'], 'user/my-whisper-model');
    });

    test('E-R-06f: llm_per_model_configs native Map and stringified JSON', () async {
      final configMap = {
        'gemma-3n-e4b-it': {
          'temperature': 0.4,
          'maxContextTokens': 4096,
        }
      };

      final svcN = await createServiceWithRawJson({
        'llm_per_model_configs': configMap,
      });
      expect(svcN.getModelTemperature('gemma-3n-e4b-it'), 0.4);

      final svcS = await createServiceWithRawJson({
        'llm_per_model_configs': jsonEncode(configMap),
      });
      expect(svcS.getModelTemperature('gemma-3n-e4b-it'), 0.4);
    });
  });
}
