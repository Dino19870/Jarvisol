import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Vérification AudioPlayer sur Windows', () async {
    final player = AudioPlayer();
    const testWavPath = r'D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST\data\tmp\assistant_read_aloud_diag.wav';
    print('WAV File exists: ${File(testWavPath).existsSync()}');
    if (File(testWavPath).existsSync()) {
      print('WAV Size: ${File(testWavPath).lengthSync()} octets');
      try {
        final duration = await player.setFilePath(testWavPath);
        print('setFilePath succeeded! Duration: $duration');
        print('ProcessingState: ${player.processingState}');
        print('AudioPlayer test PASS');
      } catch (e) {
        print('AudioPlayer setFilePath FAILED: $e');
      } finally {
        await player.dispose();
      }
    }
  });
}
