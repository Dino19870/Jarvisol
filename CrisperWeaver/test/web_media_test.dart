import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/web_media_service.dart';

void main() {
  group('WebMediaModels Unit Tests', () {
    test('WebMediaChapter parsing and serialization', () {
      final json = {
        'title': 'Introduction',
        'start_time': 0.0,
        'end_time': 45.5,
      };

      final chapter = WebMediaChapter.fromJson(json);
      expect(chapter.title, 'Introduction');
      expect(chapter.startTime, 0.0);
      expect(chapter.endTime, 45.5);

      final outJson = chapter.toJson();
      expect(outJson['title'], 'Introduction');
      expect(outJson['start_time'], 0.0);
      expect(outJson['end_time'], 45.5);
    });

    test('WebMediaSubtitleTrack manual vs automatic detection', () {
      final manualJson = {
        'name': 'Français (officiel)',
        'ext': 'vtt',
        'url': 'https://example.com/fr.vtt',
      };
      final manualTrack = WebMediaSubtitleTrack.fromJson('fr', manualJson, isAuto: false);
      expect(manualTrack.langCode, 'fr');
      expect(manualTrack.langName, 'Français (officiel)');
      expect(manualTrack.isAuto, false);
      expect(manualTrack.ext, 'vtt');

      final autoJson = {
        'name': 'Anglais (généré automatiquement)',
        'ext': 'ttml',
        'url': 'https://example.com/en-auto.ttml',
      };
      final autoTrack = WebMediaSubtitleTrack.fromJson('en', autoJson, isAuto: true);
      expect(autoTrack.langCode, 'en');
      expect(autoTrack.isAuto, true);
    });

    test('WebMediaFormat audio-only vs video format distinction', () {
      final audioOnlyJson = {
        'format_id': '251',
        'ext': 'webm',
        'vcodec': 'none',
        'acodec': 'opus',
        'tbr': 128.5,
        'filesize': 5432100,
      };
      final audioFormat = WebMediaFormat.fromJson(audioOnlyJson);
      expect(audioFormat.isAudioOnly, isTrue);
      expect(audioFormat.hasVideo, isFalse);
      expect(audioFormat.acodec, 'opus');

      final videoJson = {
        'format_id': '137',
        'ext': 'mp4',
        'vcodec': 'avc1.640028',
        'acodec': 'none',
        'resolution': '1920x1080',
        'filesize': 50000000,
      };
      final videoFormat = WebMediaFormat.fromJson(videoJson);
      expect(videoFormat.isAudioOnly, isFalse);
      expect(videoFormat.hasVideo, isTrue);
      expect(videoFormat.resolution, '1920x1080');
    });

    test('WebMediaPlaylistItem selection and structure', () {
      final item = WebMediaPlaylistItem(
        id: 'dQw4w9WgXcQ',
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        title: 'Rick Astley - Never Gonna Give You Up',
        duration: 213.0,
        uploader: 'RickAstleyVEVO',
      );

      expect(item.id, 'dQw4w9WgXcQ');
      expect(item.isSelected, isTrue);
      item.isSelected = false;
      expect(item.isSelected, isFalse);

      final fromJson = WebMediaPlaylistItem.fromJson({
        'id': 'abc1234',
        'title': 'Test Item',
        'duration': 120,
        'uploader': 'Test Channel',
      });
      expect(fromJson.url, 'https://www.youtube.com/watch?v=abc1234');
      expect(fromJson.duration, 120.0);
    });

    test('WebMediaMetadata full parsing, allSubtitleTracks and selectPreferredSubtitleTrack', () {
      final mockJson = {
        'id': 'vid_999',
        'title': 'Test Conférence Audio & Deep Learning',
        'extractor': 'youtube',
        'description': 'Une conférence passionnante sur le traitement de signal vocal.',
        'uploader': 'Labo Acoustique',
        'uploader_id': 'lab_acoustique',
        'channel': 'Science & Voix',
        'upload_date': '20260901',
        'duration': 1800,
        'thumbnail': 'https://example.com/thumb.jpg',
        'live_status': 'not_live',
        'chapters': [
          {'title': 'Partie 1', 'start_time': 0, 'end_time': 600},
          {'title': 'Partie 2', 'start_time': 600, 'end_time': 1800},
        ],
        'subtitles': {
          'en': [
            {'name': 'English (official)', 'ext': 'vtt', 'url': 'https://example.com/en.vtt'}
          ]
        },
        'automatic_captions': {
          'fr': [
            {'name': 'Français (auto)', 'ext': 'vtt', 'url': 'https://example.com/fr.vtt'}
          ],
          'es': [
            {'name': 'Español (auto)', 'ext': 'vtt', 'url': 'https://example.com/es.vtt'}
          ]
        },
        'formats': [
          {'format_id': '140', 'ext': 'm4a', 'vcodec': 'none', 'acodec': 'mp4a.40.2', 'tbr': 128},
        ],
      };

      final meta = WebMediaMetadata.fromJson('https://example.com/watch?v=vid_999', mockJson);
      expect(meta.id, 'vid_999');
      expect(meta.allSubtitleTracks.length, 3);
      expect(meta.subtitles.length, 1);
      expect(meta.automaticCaptions.length, 2);

      // Preferred language French: human en exists, but if we prioritize human, it returns human en
      final preferred = meta.selectPreferredSubtitleTrack(preferredLang: 'fr');
      expect(preferred, isNotNull);
      // Because human en exists, it picks human en over auto fr per priority (human first)
      expect(preferred!.langCode, 'en');
      expect(preferred.isAuto, isFalse);

      // If video has human fr, it picks human fr
      final metaWithFrHuman = WebMediaMetadata.fromJson('https://example.com/watch?v=vid_999', {
        ...mockJson,
        'subtitles': {
          'fr': [{'name': 'Français', 'ext': 'vtt', 'url': 'https://example.com/fr.vtt'}],
          'en': [{'name': 'English', 'ext': 'vtt', 'url': 'https://example.com/en.vtt'}],
        }
      });
      final preferredFr = metaWithFrHuman.selectPreferredSubtitleTrack(preferredLang: 'fr');
      expect(preferredFr!.langCode, 'fr');
      expect(preferredFr.isAuto, isFalse);

      // If video only has auto subtitles, it picks auto fr
      final metaOnlyAuto = WebMediaMetadata.fromJson('https://example.com/watch?v=vid_999', {
        ...mockJson,
        'subtitles': {},
      });
      final preferredAutoFr = metaOnlyAuto.selectPreferredSubtitleTrack(preferredLang: 'fr');
      expect(preferredAutoFr!.langCode, 'fr');
      expect(preferredAutoFr.isAuto, isTrue);
    });
  });

  group('WebMediaService Architecture & Fail-safe Tests', () {
    test('WebMediaCancellationToken cancel and process attach', () {
      final token = WebMediaCancellationToken();
      expect(token.isCancelled, isFalse);

      token.cancel();
      expect(token.isCancelled, isTrue);
    });

    test('WebMediaDisabledException toString message', () {
      final exc = WebMediaDisabledException('Test désactivation');
      expect(exc.toString(), contains('Test désactivation'));
    });

    test('WebMediaProcessException formatting', () {
      final exc = WebMediaProcessException('Erreur yt-dlp', exitCode: 2, stderr: 'Video unavailable');
      expect(exc.toString(), contains('code: 2'));
      expect(exc.toString(), contains('Video unavailable'));
    });

    test('Binary discovery finds local candidates safely without crashing', () {
      final service = WebMediaService.instance;
      final ytdlpPath = service.findYtDlpBinary();
      final ffmpegPath = service.findFfmpegBinary();
      final jsPath = service.findJsRuntime();

      expect(ytdlpPath != null, isTrue);
      expect(ffmpegPath != null, isTrue);
      expect(jsPath != null, isTrue);
    });
  });
}
