// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/model_service.dart';
import 'package:jarvisol/services/tts_service.dart';
import 'package:jarvisol/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('INVESTIGATE TTS VOICES', () async {
    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    final settings = SettingsService(prefs);
    final modelService = ModelService(settings);
    await modelService.initialize();
    final tts = TtsService(modelService);

    // Test Kokoro
    final kokoroStatus = await tts.prepare(
      modelName: 'kokoro-82m-q8_0',
      voiceName: 'kokoro-voice-ff_siwis',
    );
    print(
        'Kokoro status: ready=${kokoroStatus.ready}, missingModel=${kokoroStatus.missingModelName}, missingVoice=${kokoroStatus.missingVoiceName}');

    // Test Qwen3
    final qwenStatus = await tts.prepare(
      modelName: 'qwen3-tts-12hz-0.6b-customvoice-q8_0',
      codecName: 'qwen3-tts-tokenizer-12hz',
      speakerName: 'Ethan',
    );
    print(
        'Qwen3 status: ready=${qwenStatus.ready}, missingModel=${qwenStatus.missingModelName}, missingCodec=${qwenStatus.missingCodecName}');

    // Test VibeVoice
    final vibevoiceStatus = await tts.prepare(
      modelName: 'vibevoice-1.5b-tts-q4_k',
      voiceName: 'vibevoice-voice-fr-Spk0_man',
    );
    print(
        'VibeVoice status: ready=${vibevoiceStatus.ready}, missingModel=${vibevoiceStatus.missingModelName}, missingVoice=${vibevoiceStatus.missingVoiceName}');

    // Test path lookup
    final qwenModelPath = await modelService
        .getWhisperCppModelPath('qwen3-tts-12hz-0.6b-customvoice-q8_0');
    final qwenCodecPath =
        await modelService.getWhisperCppModelPath('qwen3-tts-tokenizer-12hz');
    final vvModelPath =
        await modelService.getWhisperCppModelPath('vibevoice-1.5b-tts-q4_k');
    final vvVoicePath = await modelService
        .getWhisperCppModelPath('vibevoice-voice-fr-Spk0_man');
    print('Paths on disk:');
    print(' - qwenModel: $qwenModelPath');
    print(' - qwenCodec: $qwenCodecPath');
    print(' - vvModel: $vvModelPath');
    print(' - vvVoice: $vvVoicePath');
  });
}
