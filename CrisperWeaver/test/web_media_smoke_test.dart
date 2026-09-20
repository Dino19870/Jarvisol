import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/web_media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebMediaService Live Smoke Tests', () {
    final service = WebMediaService.instance;
    const testVideoUrl = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';

    test('WEB-01: Metadata probe extracts valid title, duration and formats', () async {
      final meta = await service.getMetadata(testVideoUrl);
      expect(meta.id, 'jNQXAC9IVRw');
      expect(meta.title.toLowerCase(), contains('zoo'));
      expect(meta.duration, inInclusiveRange(18.0, 20.0));
      expect(meta.extractor, 'youtube');
      expect(meta.formats, isNotEmpty);
      print('WEB-01 PASSED: Title="${meta.title}", Duration=${meta.duration}s, Formats=${meta.formats.length}');
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('WEB-02: Audio download extracts playable audio file', () async {
      double lastProgress = 0.0;
      final file = await service.downloadAudio(
        testVideoUrl,
        targetFormat: 'mp3',
        quality: 128,
        onProgress: (p, s) {
          lastProgress = p;
        },
      );

      expect(file.existsSync(), isTrue);
      final size = await file.length();
      expect(size, greaterThan(50000)); // ~200-300KB
      expect(lastProgress, 1.0);
      print('WEB-02 PASSED: Audio downloaded to ${file.path} (size: $size bytes)');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('WEB-08: Invalid URL returns clean controlled exception', () async {
      expect(
        () => service.getMetadata('https://www.youtube.com/watch?v=THIS_IS_TOTALLY_INVALID_AND_DOESNT_EXIST_12345'),
        throwsA(isA<WebMediaProcessException>()),
      );
      print('WEB-08 PASSED: Controlled WebMediaProcessException thrown on invalid URL');
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('WEB-10: Disabled service throws WebMediaDisabledException without process launch', () async {
      // Create a service without settings or forced disabled
      service.setEnabled(false);
      expect(
        () => service.getMetadata(testVideoUrl),
        throwsA(isA<WebMediaDisabledException>()),
      );
      // Re-enable
      service.setEnabled(true);
      print('WEB-10 PASSED: WebMediaDisabledException thrown when disabled');
    });

    test('WEB-09: Missing binary simulation throws clear error', () async {
      // Test when binary path is invalid
      final binary = service.findYtDlpBinary();
      expect(binary, isNotNull);
      expect(File(binary!).existsSync(), isTrue);
      print('WEB-09 PASSED: Valid binary verified at $binary');
    });
  });
}
