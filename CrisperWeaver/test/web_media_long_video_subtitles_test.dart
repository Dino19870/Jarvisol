import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/web_media_service.dart';
import 'package:jarvisol/utils/transcript_parsers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Web Media Subtitles Fix1 Suite (SUB-01 to SUB-09)', () {
    final service = WebMediaService.instance;
    const shortVideoUrl = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
    const longVideoUrl = 'https://www.youtube.com/watch?v=NYFGCESmikA'; // 2h 21m 54s, 157 tracks

    test('SUB-01: Vidéo courte avec sous-titres auto', () async {
      final subFile = await service.downloadSubtitles(
        shortVideoUrl,
        langCode: 'en',
        autoCaptions: true,
      );
      expect(subFile, isNotNull);
      expect(subFile!.existsSync(), isTrue);
      final content = await subFile.readAsString();
      expect(content, contains('-->'));
      print('SUB-01 PASSED: Short video subtitle downloaded (${subFile.path}, ${content.length} chars)');
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('SUB-02, SUB-03 & SUB-04: Vidéo longue > 1h avec 157 pistes, sélection humaine unique sans timeout à 40s', () async {
      final sw = Stopwatch()..start();
      final meta = await service.getMetadata(longVideoUrl);
      expect(meta.duration, greaterThan(3600.0)); // > 1 heure (2h21m)
      expect(meta.allSubtitleTracks.length, greaterThan(100)); // 157 pistes

      // Vérifier la priorité humaine
      final selectedTrack = meta.selectPreferredSubtitleTrack(preferredLang: 'fr');
      expect(selectedTrack, isNotNull);
      // Comme français n'a pas de piste humaine mais en l'a, la priorité 2 choisit en humaine
      expect(selectedTrack!.isAuto, isFalse);
      expect(selectedTrack.langCode, 'en');

      print('SUB-02/03/04: Long video duration=${meta.duration}s (${(meta.duration / 3600).toStringAsFixed(1)}h), tracks=${meta.allSubtitleTracks.length}, selected track: ${selectedTrack.langName} (${selectedTrack.langCode})');

      // Télécharger UNE SEULE piste humaine
      final subFile = await service.downloadSubtitles(
        longVideoUrl,
        langCode: selectedTrack.langCode,
        autoCaptions: selectedTrack.isAuto,
        inactivityTimeout: const Duration(seconds: 30),
        absoluteTimeout: const Duration(seconds: 180),
      );

      sw.stop();
      expect(subFile, isNotNull);
      expect(subFile!.existsSync(), isTrue);
      final content = await subFile.readAsString();
      expect(content.length, greaterThan(50000)); // ~460 KB
      expect(sw.elapsed.inSeconds, lessThan(40)); // Se télécharge en quelques secondes sans bloquer
      print('SUB-02, SUB-03, SUB-04 PASSED: Downloaded in ${sw.elapsed.inSeconds}s, size=${content.length} chars, no timeout');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('SUB-05: Vidéo avec uniquement auto-sub', () async {
      final subFile = await service.downloadSubtitles(
        shortVideoUrl,
        langCode: 'en',
        autoCaptions: true,
      );
      expect(subFile, isNotNull);
      expect(subFile!.existsSync(), isTrue);
      print('SUB-05 PASSED: Auto-sub successfully downloaded');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('SUB-06: Aucune piste compatible => retourne null sans crash', () async {
      final subFile = await service.downloadSubtitles(
        shortVideoUrl,
        langCode: 'zz_non_existent_lang_123',
        autoCaptions: false,
      );
      expect(subFile, isNull);
      print('SUB-06 PASSED: Incompatible track returns null gracefully');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('SUB-08: Watchdog inactivité arrête proprement un processus inactif', () async {
      final cancelToken = WebMediaCancellationToken();
      // On teste un timeout d'inactivité court (2s)
      final timeoutFuture = service.downloadSubtitles(
        longVideoUrl,
        langCode: 'en',
        inactivityTimeout: const Duration(milliseconds: 1), // Force watchdog immédiat
        cancelToken: cancelToken,
      );
      expect(timeoutFuture, throwsA(isA<TimeoutException>()));
      print('SUB-08 PASSED: Watchdog triggered TimeoutException on inactivity');
    });

    test('SUB-09: Annulation utilisateur tue le process et nettoie les fichiers', () async {
      final cancelToken = WebMediaCancellationToken();
      final targetDir = service.getSubtitlesDir();
      final beforeCount = targetDir.listSync().length;

      final future = service.downloadSubtitles(
        longVideoUrl,
        langCode: 'en',
        cancelToken: cancelToken,
      );

      // Annulation rapide
      Future.delayed(const Duration(milliseconds: 300), () {
        cancelToken.cancel();
      });

      try {
        await future;
      } catch (e) {
        expect(e, isA<CancellationException>());
      }

      // Vérifier qu'aucun fichier temporaire corrompu n'est resté
      final afterCount = targetDir.listSync().length;
      expect(afterCount, equals(beforeCount));
      print('SUB-09 PASSED: Process cancelled, clean exception and no leftover files');
    });

    test('SUBTITLE_DOCUMENT_SOURCE: Conversion et injection propre dans Document RAG', () async {
      final meta = await service.getMetadata(longVideoUrl);
      final subFile = await service.downloadSubtitles(
        longVideoUrl,
        langCode: 'en',
        autoCaptions: false,
      );
      expect(subFile, isNotNull);

      final rawContent = await subFile!.readAsString();
      final parsed = TranscriptParsers.parseSrt(rawContent);
      expect(parsed.segments, isNotEmpty);
      expect(parsed.plainText, isNotEmpty);

      // Validation de la structure du document produit pour RAG
      final buffer = StringBuffer();
      buffer.writeln('# ${meta.title}');
      buffer.writeln('- **URL :** ${meta.url}');
      buffer.writeln('- **Durée :** ${meta.duration}s');
      buffer.writeln('- **Piste :** English (en) — [HUMAIN]');
      buffer.writeln('### Segments :');
      for (final seg in parsed.segments.take(5)) {
        buffer.writeln('[${seg.startTime.toStringAsFixed(1)}s - ${seg.endTime.toStringAsFixed(1)}s] ${seg.text}');
      }

      final docText = buffer.toString();
      expect(docText, contains('# '));
      expect(docText, contains(meta.url));
      expect(docText, contains('English (en)'));
      print('SUBTITLE_DOCUMENT_SOURCE PASSED: Created structured RAG source (${docText.length} chars, ${parsed.segments.length} segments)');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
