import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/web_media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WEB-04 & WEB-05: Playlist enumeration and batch item selection', () async {
    final service = WebMediaService.instance;
    const playlistUrl = 'https://www.youtube.com/playlist?list=PLrAXtmErZgOdP_8GztsuKi9nrraNbKKp4';

    final items = await service.enumeratePlaylist(playlistUrl, maxItems: 5);
    expect(items, isNotEmpty);
    expect(items.length, inInclusiveRange(1, 5));
    for (final item in items) {
      expect(item.id, isNotEmpty);
      expect(item.title, isNotEmpty);
      expect(item.url, contains('watch?v='));
      expect(item.isSelected, isTrue);
    }
    print('WEB-04 & WEB-05 PASSED: Enumerated ${items.length} items from playlist. First item: "${items.first.title}" (${items.first.url})');
  }, timeout: const Timeout(Duration(seconds: 45)));
}
