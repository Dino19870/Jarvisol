import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/voice_pack_inspector.dart';

void main() {
  group('VoicePackInspector', () {
    test('D-01 / D-05: Inspect Chatterbox Voice Pack', () {
      final path = r'D:\Antigravity\AgentFolder\VoiceBake\output\C2_Chatterbox_Test.gguf';
      if (!File(path).existsSync()) return;
      final res = VoicePackInspector.inspect(path);
      print('ERR: ' + (res.errorMessage ?? '')); expect(res.isValid, isTrue);
      expect(res.family, equals(VoicePackFamily.chatterbox));
      expect(res.compatibleBackend, equals('chatterbox'));
      expect(res.voiceNames, contains('C2_Chatterbox_Test'));
      expect(res.tensorCount, equals(5));
    });

    test('D-02 / D-06: Inspect Qwen3 Voice Pack', () {
      final path = r'D:\Antigravity\AgentFolder\VoiceBake\output\C2_Qwen3_Test.gguf';
      if (!File(path).existsSync()) return;
      final res = VoicePackInspector.inspect(path);
      print('ERR: ' + (res.errorMessage ?? '')); expect(res.isValid, isTrue);
      expect(res.family, equals(VoicePackFamily.qwen3));
      expect(res.compatibleBackend, equals('qwen3-tts'));
      expect(res.voiceNames, contains('C2_Qwen3_Test'));
      expect(res.tensorCount, equals(2));
    });

    test('D-03: Reject main model GGUF (non-voicepack)', () {
      final path = r'D:\Antigravity\AgentFolder\candidate_release_c85_ext02_p4_nomodels\data\models\whisper_cpp\chatterbox-t3-q8_0.gguf';
      if (!File(path).existsSync()) return;
      final res = VoicePackInspector.inspect(path);
      expect(res.isValid, isFalse);
      expect(res.errorMessage, contains('Architecture GGUF non reconnue comme Voice Pack'));
    });

    test('D-04: Reject corrupt / non-GGUF file', () {
      final tmp = File('test_corrupt.gguf');
      tmp.writeAsBytesSync([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      try {
        final res = VoicePackInspector.inspect(tmp.path);
        expect(res.isValid, isFalse);
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });
  });
}

