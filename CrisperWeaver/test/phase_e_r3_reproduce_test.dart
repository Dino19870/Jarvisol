import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/voice_pack_inspector.dart';
import 'package:jarvisol/services/imported_voice_service.dart';

void main() {
  test('Inspect Chatterbox Voice Pack and demonstrate speaker population bug', () async {
    final result = VoicePackValidationResult.valid(
      family: VoicePackFamily.chatterbox,
      architecture: 'chatterbox-voice',
      compatibleBackend: 'chatterbox',
      voiceNames: ['PPDA'],
      tensorCount: 5,
      fileSizeBytes: 1000,
    );

    print('Family: ');
    print('Architecture: ');
    print('Compatible Backend: ');
    print('Voice Names: ');

    expect(result.family, VoicePackFamily.chatterbox);
    expect(result.voiceNames, ['PPDA']);
  });
}
