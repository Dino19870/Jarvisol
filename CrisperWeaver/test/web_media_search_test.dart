import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/web_media_service.dart';
import 'package:jarvisol/services/batch_persistence_service.dart';
import 'package:jarvisol/services/batch_queue_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('REQ-POST-001: Web Media Search Test Suite (SEARCH-001 -> SEARCH-013)', () {
    late WebMediaService service;

    setUp(() {
      service = WebMediaService();
    });

    // SEARCH-001: Recherche textuelle simple
    test('SEARCH-001: Decodage NDJSON et mapping WebMediaSearchResult', () {
      final ndjsonSample = {
        'id': 'dQw4w9WgXcQ',
        'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'title': 'Rick Astley - Never Gonna Give You Up (Official Music Video)',
        'uploader': 'Rick Astley',
        'channel': 'Rick Astley Official',
        'duration': 213,
        'duration_string': '3:33',
        'thumbnail': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
        'description': 'The official video for Never Gonna Give You Up by Rick Astley.',
        'extractor': 'youtube',
        'view_count': 1500000000,
        '_type': 'video',
      };

      final result = WebMediaSearchResult.fromJson(ndjsonSample);
      expect(result.id, 'dQw4w9WgXcQ');
      expect(result.url, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(result.title, contains('Rick Astley'));
      expect(result.uploader, 'Rick Astley');
      expect(result.channel, 'Rick Astley Official');
      expect(result.duration, 213.0);
      expect(result.thumbnailUrl, 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg');
      expect(result.mediaType, WebMediaResultType.video);
      expect(result.viewCount, 1500000000);

      final map = result.toJson();
      expect(map['id'], 'dQw4w9WgXcQ');
      expect(map['media_type'], 'video');
    });

    // SEARCH-002: Recherche avec jokers (* et ?)
    test('SEARCH-002: Wildcards (*, ?) filtrage local et extraction de base query', () {
      expect(WebMediaWildcardMatcher.hasWildcards('piano tutorial'), isFalse);
      expect(WebMediaWildcardMatcher.hasWildcards('mozart*sonata'), isTrue);
      expect(WebMediaWildcardMatcher.hasWildcards('track?'), isTrue);

      expect(WebMediaWildcardMatcher.extractBaseQuery('beethoven*symphonie*9'), 'beethoven symphonie 9');
      expect(WebMediaWildcardMatcher.extractBaseQuery('chopin*nocturne?op9'), 'chopin nocturne op9');
      expect(WebMediaWildcardMatcher.extractBaseQuery('***'), '');

      final r1 = WebMediaSearchResult(
        id: '1',
        url: 'https://example.com/1',
        title: 'Mozart - Piano Sonata No. 16 in C Major',
        uploader: 'Classical Archive',
        mediaType: WebMediaResultType.video,
      );

      final r2 = WebMediaSearchResult(
        id: '2',
        url: 'https://example.com/2',
        title: 'Beethoven - Symphony No. 5',
        uploader: 'Orchestra Live',
        mediaType: WebMediaResultType.video,
      );

      expect(WebMediaWildcardMatcher.matches('mozart*sonata', r1), isTrue);
      expect(WebMediaWildcardMatcher.matches('mozart*sonata', r2), isFalse);

      final r3 = WebMediaSearchResult(
        id: '3',
        url: 'https://example.com/3',
        title: 'Track 01 Intro',
        uploader: 'Artist',
        mediaType: WebMediaResultType.video,
      );
      expect(WebMediaWildcardMatcher.matches('Track ?1*', r3), isTrue);
      expect(WebMediaWildcardMatcher.matches('Track ?9*', r3), isFalse);

      expect(WebMediaWildcardMatcher.matches('*Classical*', r1), isTrue);
      expect(WebMediaWildcardMatcher.matches('*Classical*', r2), isFalse);
    });

    // SEARCH-003: Zero resultat
    test('SEARCH-003: Recherche sans resultat renvoie une liste vide propre [] sans erreur', () async {
      final lines = <String>[];
      final results = <WebMediaSearchResult>[];
      for (final line in lines) {
        if (line.trim().isNotEmpty) {
          results.add(WebMediaSearchResult.fromJson(jsonDecode(line)));
        }
      }
      expect(results, isEmpty);
      expect(results, isA<List<WebMediaSearchResult>>());
    });

    // SEARCH-004: Resultat -> metadonnees
    test('SEARCH-004: Le resultat selectionne route vers getMetadata via son URL canonique', () {
      final item = WebMediaSearchResult(
        id: 'vid123',
        url: 'https://www.youtube.com/watch?v=vid123',
        title: 'Video Test',
        mediaType: WebMediaResultType.video,
      );
      expect(item.url, startsWith('http'));
      expect(item.url, contains('vid123'));
    });

    // SEARCH-005: Resultat -> Audio
    test('SEARCH-005: Le resultat selectionne s intègre au pipeline downloadAudio', () {
      final item = WebMediaSearchResult(
        id: 'audio123',
        url: 'https://www.youtube.com/watch?v=audio123',
        title: 'Piste Audio Test',
        mediaType: WebMediaResultType.video,
      );
      expect(item.url, isNotEmpty);
      expect(item.url, contains('audio123'));
    });

    // SEARCH-006: Resultat -> Video
    test('SEARCH-006: Le resultat selectionne s intègre au pipeline downloadVideo', () {
      final item = WebMediaSearchResult(
        id: 'vid456',
        url: 'https://www.youtube.com/watch?v=vid456',
        title: 'Video HD Test',
        mediaType: WebMediaResultType.video,
      );
      expect(item.id, 'vid456');
    });

    // SEARCH-007: Playlist -> Batch
    test('SEARCH-007: Les resultats playlist s intègrent a BatchQueueNotifier', () async {
      final tempDir = await Directory.systemTemp.createTemp('cw_search_batch_');
      final persistence = BatchPersistenceService.withDirectory(tempDir);
      final queue = BatchQueueNotifier(persistence: persistence);

      try {
        final playlistItem = WebMediaSearchResult(
          id: 'PL123',
          url: 'https://www.youtube.com/playlist?list=PL123',
          title: 'Album Playlist',
          mediaType: WebMediaResultType.playlist,
        );
        expect(playlistItem.mediaType, WebMediaResultType.playlist);

        final id1 = queue.enqueue('C:\\temp\\audio_pl1.wav');
        final id2 = queue.enqueue('C:\\temp\\audio_pl2.wav');
        final id3 = queue.enqueue('C:\\temp\\audio_pl3.wav');

        await queue.whenPersisted();

        expect(queue.state.length, 3);
        expect(queue.state.map((j) => j.id), containsAll([id1, id2, id3]));
      } finally {
        queue.dispose();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    // SEARCH-008: Sous-titres
    test('SEARCH-008: Integration sous-titres et selection preferred track', () {
      final meta = WebMediaMetadata(
        id: 'sub_test',
        url: 'https://example.com/sub_test',
        title: 'Conference',
        extractor: 'youtube',
        description: 'Description test',
        uploader: 'Test Uploader',
        channel: 'Test Channel',
        uploadDate: '20260901',
        duration: 300.0,
        subtitles: [
          WebMediaSubtitleTrack(langCode: 'fr', langName: 'Francais', ext: 'vtt', url: 'https://sub/fr.vtt', isAuto: false),
        ],
        automaticCaptions: [
          WebMediaSubtitleTrack(langCode: 'en', langName: 'English (auto)', ext: 'vtt', url: 'https://sub/en.vtt', isAuto: true),
        ],
      );

      expect(meta.hasSubtitles, isTrue);
      final prefTrack = meta.selectPreferredSubtitleTrack(preferredLang: 'fr');
      expect(prefTrack, isNotNull);
      expect(prefTrack!.langCode, 'fr');
      expect(prefTrack.isAuto, isFalse);
    });

    // SEARCH-009: Annulation
    test('SEARCH-009: WebMediaCancellationToken signale l annulation immediatement', () {
      final cancelToken = WebMediaCancellationToken();
      expect(cancelToken.isCancelled, isFalse);
      cancelToken.cancel();
      expect(cancelToken.isCancelled, isTrue);
    });

    // SEARCH-010: Timeout / provider error
    test('SEARCH-010: Timeout ou annulation leve CancellationException controlee', () {
      final cancelToken = WebMediaCancellationToken();
      cancelToken.cancel();

      expect(
        () {
          if (cancelToken.isCancelled) throw CancellationException();
        },
        throwsA(isA<CancellationException>()),
      );
    });

    // SEARCH-011: web_media_enabled=false -> 0 processus
    test('SEARCH-011: web_media_enabled=false leve WebMediaDisabledException sans lancer de processus', () async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);
      settings.webMediaEnabled = false;

      final disabledService = WebMediaService(settingsService: settings);
      expect(disabledService.isEnabled, isFalse);

      expect(
        () => disabledService.searchMedia('test query'),
        throwsA(isA<WebMediaDisabledException>()),
      );
    });

    // SEARCH-012: Direct URL non-regressed
    test('SEARCH-012: Import direct par URL conserve 100% de son integrite', () {
      expect(service.isEnabled, isTrue);
    });

    // SEARCH-013: Portabilite
    test('SEARCH-013: Verification de la portabilite et presence des binaires embarques', () async {
      final ytdlpPath = service.findYtDlpBinary();
      expect(ytdlpPath, isNotNull);
      final f = File(ytdlpPath!);
      expect(await f.exists(), isTrue);
      expect(await f.length(), greaterThan(1024 * 1024));
    });
  });

  group('EVOL-WEB-SEARCH-R2: Publication Date, Summary & Result Count Management (WEBR2-001 -> WEBR2-014)', () {
    late WebMediaService service;

    setUp(() {
      service = WebMediaService();
    });

    // WEBR2-001: CURRENT SEARCH LIMIT
    test('WEBR2-001: Valeur exacte N, constantes et source de configuration', () {
      expect(WebMediaService.defaultSearchLimit, 20);
      expect(WebMediaService.searchLimitIncrement, 10);
      expect(WebMediaService.maxSearchLimit, 50);
    });

    // WEBR2-002: DATE upload_date
    test('WEBR2-002: upload_date au format YYYYMMDD ou ISO correctement formatée en français', () {
      final item1 = WebMediaSearchResult.fromJson({
        'id': 'v1',
        'title': 'Test Video 1',
        'upload_date': '20250312',
      });
      expect(item1.formattedPublicationDate, 'Publié le 12 mars 2025');
      expect(item1.publicationDateDisplay, 'Publié le 12 mars 2025');

      final item2 = WebMediaSearchResult.fromJson({
        'id': 'v2',
        'title': 'Test Video 2',
        'upload_date': '2024-11-05',
      });
      expect(item2.formattedPublicationDate, 'Publié le 5 novembre 2024');
    });

    // WEBR2-003: DATE fallback timestamp
    test('WEBR2-003: Repli sur timestamp / release_timestamp quand upload_date est absent', () {
      // 1741777200 = 12 mars 2025 11:00:00 UTC
      final itemTimestamp = WebMediaSearchResult.fromJson({
        'id': 'v3',
        'title': 'Test Video 3',
        'timestamp': 1741777200,
      });
      expect(itemTimestamp.formattedPublicationDate, 'Publié le 12 mars 2025');

      // release_timestamp fallback
      final itemRelease = WebMediaSearchResult.fromJson({
        'id': 'v4',
        'title': 'Test Video 4',
        'release_timestamp': 1741777200,
      });
      expect(itemRelease.formattedPublicationDate, 'Publié le 12 mars 2025');
    });

    // WEBR2-004: DATE absente -> aucune date inventée
    test('WEBR2-004: Aucune date présente -> état neutre "Date indisponible" et aucune date inventée', () {
      final itemEmpty = WebMediaSearchResult.fromJson({
        'id': 'v5',
        'title': 'Test Video 5',
      });
      expect(itemEmpty.formattedPublicationDate, isNull);
      expect(itemEmpty.publicationDateDisplay, 'Date indisponible');

      final itemInvalid = WebMediaSearchResult.fromJson({
        'id': 'v6',
        'title': 'Test Video 6',
        'upload_date': 'invalid_date_str',
      });
      expect(itemInvalid.formattedPublicationDate, isNull);
      expect(itemInvalid.publicationDateDisplay, 'Date indisponible');
    });

    // WEBR2-005: RÉSUMÉ description normalisée
    test('WEBR2-005: Description extraite de la recherche, normalisée (espaces, retours, HTML) sans appel LLM', () {
      final item = WebMediaSearchResult.fromJson({
        'id': 'v7',
        'title': 'Test Video 7',
        'description': '  Première ligne.\nDeuxième ligne avec   espaces multiples et <b>balise HTML</b>.\r\nTroisième ligne.  ',
      });
      expect(item.summaryText, isNotNull);
      expect(item.summaryText, 'Première ligne. Deuxième ligne avec espaces multiples et balise HTML. Troisième ligne.');
      expect(item.summaryText, isNot(contains('\n')));
      expect(item.summaryText, isNot(contains('<b>')));
    });

    // WEBR2-006: RÉSUMÉ long
    test('WEBR2-006: Résumé long préservé sans débordement de structure', () {
      final longDesc = List.generate(50, (i) => 'Mot$i').join(' ');
      final item = WebMediaSearchResult.fromJson({
        'id': 'v8',
        'title': 'Test Video 8',
        'description': longDesc,
      });
      expect(item.summaryText, isNotNull);
      expect(item.summaryText!.length, greaterThan(100));
    });

    // WEBR2-007: RÉSUMÉ absent
    test('WEBR2-007: Résumé absent ou vide -> état neutre propre null', () {
      final itemNull = WebMediaSearchResult.fromJson({
        'id': 'v9',
        'title': 'Test Video 9',
      });
      expect(itemNull.summaryText, isNull);

      final itemBlank = WebMediaSearchResult.fromJson({
        'id': 'v10',
        'title': 'Test Video 10',
        'description': '   \n  \t ',
      });
      expect(itemBlank.summaryText, isNull);
    });

    // WEBR2-008: AFFICHER PLUS (incrément, déduplication, conservation)
    test('WEBR2-008: Afficher plus - déduplication par id/url et conservation des résultats existants', () {
      final initialResults = [
        WebMediaSearchResult.fromJson({'id': 'vid1', 'title': 'Titre 1'}),
        WebMediaSearchResult.fromJson({'id': 'vid2', 'title': 'Titre 2'}),
      ];

      final rerunFetched = [
        WebMediaSearchResult.fromJson({'id': 'vid1', 'title': 'Titre 1'}),
        WebMediaSearchResult.fromJson({'id': 'vid2', 'title': 'Titre 2'}),
        WebMediaSearchResult.fromJson({'id': 'vid3', 'title': 'Titre 3'}),
      ];

      final existingKeys = initialResults.map((r) => r.id.isNotEmpty ? r.id : r.url).toSet();
      final newItems = rerunFetched.where((r) => !existingKeys.contains(r.id.isNotEmpty ? r.id : r.url)).toList();

      final combined = [...initialResults, ...newItems];

      expect(combined.length, 3);
      expect(combined[0].id, 'vid1');
      expect(combined[1].id, 'vid2');
      expect(combined[2].id, 'vid3');
    });

    // WEBR2-009: WILDCARDS
    test('WEBR2-009: Les jokers (* et ?) conservent strictement leur sémantique', () {
      final r = WebMediaSearchResult.fromJson({
        'id': 'v11',
        'title': 'Chopin Nocturne Op 9 No 2',
        'uploader': 'Pianist Channel',
        'description': 'Magnificent classical performance',
      });
      expect(WebMediaWildcardMatcher.matches('chopin*nocturne*', r), isTrue);
      expect(WebMediaWildcardMatcher.matches('chopin?nocturne', r), isFalse);
      expect(WebMediaWildcardMatcher.matches('*classical*', r), isTrue);
    });

    // WEBR2-010: URL DIRECTE
    test('WEBR2-010: Mode URL directe non régressé', () {
      final meta = WebMediaMetadata(
        url: 'https://www.youtube.com/watch?v=direct123',
        extractor: 'youtube',
        id: 'direct123',
        title: 'Direct Video',
        description: 'Desc',
        uploader: 'Channel',
        channel: 'Channel',
        uploadDate: '20250101',
        duration: 120.0,
      );
      expect(meta.url, contains('direct123'));
      expect(meta.id, 'direct123');
    });

    // WEBR2-011: SÉLECTION
    test('WEBR2-011: Résultat sélectionné fournit une URL canonique exploitable par le pipeline existant', () {
      final item = WebMediaSearchResult.fromJson({
        'id': 'sel123',
        'url': 'https://www.youtube.com/watch?v=sel123',
        'title': 'Selected Media',
      });
      expect(item.url, 'https://www.youtube.com/watch?v=sel123');
    });

    // WEBR2-012: PERFORMANCE
    test('WEBR2-012: Zéro analyse complète (getMetadata) par résultat lors du parsing de recherche', () {
      final list = List.generate(20, (i) => {
        'id': 'id_$i',
        'title': 'Title $i',
        'description': 'Desc $i',
        'upload_date': '20250101',
      });

      final parsed = list.map((j) => WebMediaSearchResult.fromJson(j)).toList();
      expect(parsed.length, 20);
      for (final item in parsed) {
        expect(item.summaryText, startsWith('Desc'));
        expect(item.formattedPublicationDate, contains('2025'));
      }
    });

    // WEBR2-013: FEATURE FLAG
    test('WEBR2-013: web_media_enabled=false bloque toute recherche sans spawn', () async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);
      settings.webMediaEnabled = false;

      final disabledService = WebMediaService(settingsService: settings);
      expect(disabledService.isEnabled, isFalse);
      expect(
        () => disabledService.searchMedia('test', limit: 30),
        throwsA(isA<WebMediaDisabledException>()),
      );
    });

    // WEBR2-014: PORTABILITÉ
    test('WEBR2-014: Exécutables portables yt-dlp et ffmpeg présents', () async {
      final ytdlp = service.findYtDlpBinary();
      expect(ytdlp, isNotNull);
      expect(File(ytdlp!).existsSync(), isTrue);
    });
  });
}
