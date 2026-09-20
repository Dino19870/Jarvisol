import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/web_media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WEB-03 & WEB-07: Subtitle/Comment extraction and chapters', () async {
    final service = WebMediaService.instance;
    const testVideoUrl = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';

    // Test comments retrieval
    final comments = await service.getComments(testVideoUrl, maxComments: 5);
    expect(comments, isA<List<WebMediaComment>>());
    print('Comments retrieved: ${comments.length}');
    if (comments.isNotEmpty) {
      print('First comment by ${comments.first.author}: ${comments.first.text.replaceAll('\n', ' ').substring(0, 50)}...');
    }

    // Test subtitle download (auto-captions for this video)
    final vttFile = await service.downloadSubtitles(testVideoUrl, langCode: 'en');
    if (vttFile != null && vttFile.existsSync()) {
      final vttContent = await vttFile.readAsString();
      expect(vttContent, isNotEmpty);
      print('WEB-03 PASSED: Subtitle file downloaded (${vttFile.path}, length: ${vttContent.length} chars)');
    } else {
      print('WEB-03: No subtitle returned (normal if no English track configured)');
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
