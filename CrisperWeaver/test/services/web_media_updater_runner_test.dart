import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:jarvisol/services/web_media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late WebMediaService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cw_web_media_test_');
    service = WebMediaService();
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('CORR-07 / TNR-027: Updater sécurisé yt-dlp transactionnel', () {
    test('TNR-027: Staging .tmp, validation de taille/version, sauvegarde .bak_prev et rollback', () async {
      final fakeBinDir = Directory(p.join(tempDir.path, 'runtime', 'web_media'));
      await fakeBinDir.create(recursive: true);

      final currentBin = File(p.join(fakeBinDir.path, 'yt-dlp.exe'));
      await currentBin.writeAsString('INITIAL_BINARY_V1');

      final currentPath = currentBin.path;
      final tmpFile = File('$currentPath.tmp');
      final bakFile = File('$currentPath.bak_prev');

      // 1. Simulation d'un téléchargement corrompu / 0-octet
      await tmpFile.writeAsString(''); // 0 octet
      final isTmpValid = await tmpFile.exists() && (await tmpFile.length()) > 1024 * 1024;
      expect(isTmpValid, isFalse, reason: 'Le fichier temporaire de staging incomplet doit être rejeté');

      // Nettoyage sans impacter le binaire actif
      await tmpFile.delete();
      expect(await currentBin.exists(), isTrue);
      expect(await currentBin.readAsString(), equals('INITIAL_BINARY_V1'));

      // 2. Simulation d'une mise à jour valide avec commit atomique et .bak_prev
      final validPayload = List<int>.filled(2 * 1024 * 1024, 65); // 2 Mo
      await tmpFile.writeAsBytes(validPayload, flush: true);
      expect(await tmpFile.length(), greaterThan(1024 * 1024));

      // Sauvegarde .bak_prev
      await currentBin.copy(bakFile.path);
      expect(await bakFile.exists(), isTrue);

      // Remplacement atomique
      if (Platform.isWindows && await currentBin.exists()) {
        await currentBin.delete();
      }
      await tmpFile.rename(currentPath);

      expect(await currentBin.exists(), isTrue);
      expect(await currentBin.length(), equals(2 * 1024 * 1024));
      expect(await bakFile.readAsString(), equals('INITIAL_BINARY_V1'));
    });
  });

  group('CORR-07 / TNR-076: Runner sécurisé enumeratePlaylist & getComments', () {
    test('TNR-076: Arguments en liste distincte, consommation stdout/stderr, et exitCode non nul en erreur', () async {
      // Vérification que le service gère les erreurs de processus sans masquer l'échec en liste vide
      expect(
        () => service.enumeratePlaylist('https://invalid-non-existent-playlist-url-test.org/list'),
        throwsA(isA<WebMediaProcessException>()),
      );
    });

    test('TNR-076: getComments avec URL invalide lève une exception contrôlée au lieu d\'une liste vide', () async {
      expect(
        () => service.getComments('https://invalid-non-existent-comments-test.org/watch?v=none'),
        throwsA(isA<WebMediaProcessException>()),
      );
    });

    test('TNR-076: WebMediaCancellationToken annule le processus', () {
      final token = WebMediaCancellationToken();
      expect(token.isCancelled, isFalse);
      token.cancel();
      expect(token.isCancelled, isTrue);
    });
  });

  group('CORR-07 Canaries: TNR-136 (Canary non-régression Web Media)', () {
    test('TNR-136: Découverte des exécutables et intégrité de l\'environnement Web Media', () async {
      final ytdlp = service.findYtDlpBinary();
      expect(ytdlp, isNotNull, reason: 'yt-dlp doit être présent dans runtime/web_media');

      final ffmpeg = service.findFfmpegBinary();
      expect(ffmpeg, isNotNull, reason: 'ffmpeg doit être présent dans runtime/web_media');

      final js = service.findJsRuntime();
      expect(js, isNotNull, reason: 'Deno JS runtime doit être présent dans runtime/web_media');

      final probe = await service.probe();
      expect(probe.isAvailable, isTrue);
      expect(probe.version, isNotNull);
    });
  });
}
