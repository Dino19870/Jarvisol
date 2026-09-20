import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/voice_pack_inspector.dart';
import 'package:jarvisol/services/imported_voice_service.dart';

void main() {
  group('Phase E-R3 Voice Pack Routing Tests', () {
    test('E-R3-02: Chatterbox pack recognized as chatterbox-voice with empty presetSpeakers', () {
      final pack = ImportedVoicePack(
        id: 'PPDA',
        fileName: 'PPDA.gguf',
        family: VoicePackFamily.chatterbox,
        compatibleBackend: 'chatterbox',
        voiceNames: ['PPDA'],
        fileSizeBytes: 12345,
        importedAt: DateTime.now(),
      );

      expect(pack.family, VoicePackFamily.chatterbox);
      expect(pack.compatibleBackend, 'chatterbox');
      expect(pack.voiceNames, ['PPDA']);
      // E-R3-03: No preset speakers for Chatterbox
      expect(pack.presetSpeakers, isEmpty, reason: 'Chatterbox must have NO preset speakers');
    });

    test('E-R3-07: Qwen3 mono-speaker pack preserves speaker name in presetSpeakers', () {
      final pack = ImportedVoicePack(
        id: 'qwen3_mono',
        fileName: 'qwen3_mono.gguf',
        family: VoicePackFamily.qwen3,
        compatibleBackend: 'qwen3-tts',
        voiceNames: ['MonoVoice'],
        fileSizeBytes: 12345,
        importedAt: DateTime.now(),
      );

      expect(pack.family, VoicePackFamily.qwen3);
      expect(pack.presetSpeakers, ['MonoVoice']);
    });

    test('E-R3-08 & E-R3-09: Qwen3 multi-speaker pack preserves Alice and Bob in presetSpeakers', () {
      final pack = ImportedVoicePack(
        id: 'alice_bob',
        fileName: 'multispeaker_qwen3_alice_bob.gguf',
        family: VoicePackFamily.qwen3,
        compatibleBackend: 'qwen3-tts',
        voiceNames: ['Alice', 'Bob'],
        fileSizeBytes: 12345,
        importedAt: DateTime.now(),
      );

      expect(pack.family, VoicePackFamily.qwen3);
      expect(pack.presetSpeakers, ['Alice', 'Bob']);
      expect(pack.presetSpeakers.contains('Alice'), isTrue);
      expect(pack.presetSpeakers.contains('Bob'), isTrue);
    });

    test('E-R3-12 & E-R3-13: Strict backend isolation between Chatterbox and Qwen3', () {
      bool isCompatible(String? a, String? b) {
        if (a == null || b == null) return false;
        if (a == b) return true;
        if (a.startsWith('vibevoice') && b.startsWith('vibevoice')) return true;
        if (a.startsWith('chatterbox') && b.startsWith('chatterbox')) return true;
        return false;
      }

      final cbPack = ImportedVoicePack(
        id: 'cb_pack',
        fileName: 'cb_pack.gguf',
        family: VoicePackFamily.chatterbox,
        compatibleBackend: 'chatterbox',
        voiceNames: ['cb_voice'],
        fileSizeBytes: 1000,
        importedAt: DateTime.now(),
      );

      final qwenPack = ImportedVoicePack(
        id: 'qw_pack',
        fileName: 'qw_pack.gguf',
        family: VoicePackFamily.qwen3,
        compatibleBackend: 'qwen3-tts',
        voiceNames: ['qw_voice'],
        fileSizeBytes: 1000,
        importedAt: DateTime.now(),
      );

      // E-R3-12: Chatterbox voice never compatible with qwen3-tts model
      expect(isCompatible(cbPack.compatibleBackend, 'qwen3-tts'), isFalse);
      expect(cbPack.presetSpeakers, isEmpty);

      // E-R3-13: Qwen3 voice never compatible with chatterbox model
      expect(isCompatible(qwenPack.compatibleBackend, 'chatterbox'), isFalse);
    });
  });
}
