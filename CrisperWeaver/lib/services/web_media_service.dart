import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../constants/timeout_policy.dart';
import '../models/web_media_models.dart';
import '../utils/app_paths.dart';
import 'log_service.dart';
import 'settings_service.dart';

class WebMediaCancellationToken {
  bool _isCancelled = false;
  Process? _process;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
    if (_process != null) {
      WebMediaService.terminateProcessTree(_process);
    }
  }

  void attachProcess(Process process) {
    _process = process;
    if (_isCancelled) {
      WebMediaService.terminateProcessTree(process);
    }
  }
}

class WebMediaDisabledException implements Exception {
  final String message;
  WebMediaDisabledException([this.message = 'Le sous-système Web Media est désactivé.']);
  @override
  String toString() => message;
}

class WebMediaProcessException implements Exception {
  final String message;
  final int exitCode;
  final String stderr;
  WebMediaProcessException(this.message, {this.exitCode = -1, this.stderr = ''});
  @override
  String toString() => '$message (code: $exitCode): $stderr';
}

final webMediaServiceProvider = Provider<WebMediaService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  return WebMediaService(settingsService: settings);
});

class WebMediaService {
  static WebMediaService? _instance;
  static WebMediaService get instance => _instance ??= WebMediaService();

  final SettingsService? _settingsService;
  String? _cachedYtdlpPath;
  String? _cachedFfmpegPath;
  String? _cachedFfprobePath;
  String? _cachedJsRuntimePath;

  WebMediaService({SettingsService? settingsService}) : _settingsService = settingsService;

  bool? _overrideEnabled;

  bool get isEnabled => _overrideEnabled ?? _settingsService?.webMediaEnabled ?? true;

  void setEnabled(bool enabled) {
    _overrideEnabled = enabled;
    if (_settingsService != null) {
      _settingsService.webMediaEnabled = enabled;
    }
  }

  // ── Résolution des exécutables ──

  String? findYtDlpBinary() {
    if (_cachedYtdlpPath != null && File(_cachedYtdlpPath!).existsSync()) {
      return _cachedYtdlpPath;
    }

    final candidates = [
      p.join(AppPaths.appDir.path, 'runtime', 'web_media', 'yt-dlp.exe'),
      p.join(Directory.current.path, 'runtime', 'web_media', 'yt-dlp.exe'),
    ];

    for (final c in candidates) {
      if (File(c).existsSync()) {
        _cachedYtdlpPath = c;
        return c;
      }
    }

    return null;
  }

  String? findFfmpegBinary() {
    if (_cachedFfmpegPath != null && File(_cachedFfmpegPath!).existsSync()) {
      return _cachedFfmpegPath;
    }

    final candidates = [
      p.join(AppPaths.appDir.path, 'runtime', 'web_media', 'ffmpeg.exe'),
      p.join(Directory.current.path, 'runtime', 'web_media', 'ffmpeg.exe'),
    ];

    for (final c in candidates) {
      if (File(c).existsSync()) {
        _cachedFfmpegPath = c;
        return c;
      }
    }

    return null;
  }

  String? findFfprobeBinary() {
    if (_cachedFfprobePath != null && File(_cachedFfprobePath!).existsSync()) {
      return _cachedFfprobePath;
    }

    final candidates = [
      p.join(AppPaths.appDir.path, 'runtime', 'web_media', 'ffprobe.exe'),
      p.join(Directory.current.path, 'runtime', 'web_media', 'ffprobe.exe'),
    ];

    for (final c in candidates) {
      if (File(c).existsSync()) {
        _cachedFfprobePath = c;
        return c;
      }
    }

    return null;
  }

  String? findJsRuntime() {
    if (_cachedJsRuntimePath != null && File(_cachedJsRuntimePath!).existsSync()) {
      return _cachedJsRuntimePath;
    }

    final candidates = [
      p.join(AppPaths.appDir.path, 'runtime', 'web_media', 'deno.exe'),
      p.join(Directory.current.path, 'runtime', 'web_media', 'deno.exe'),
    ];

    for (final c in candidates) {
      if (File(c).existsSync()) {
        _cachedJsRuntimePath = c;
        return c;
      }
    }

    return null;
  }

  Directory getTempDir() {
    final dir = Directory(p.join(AppPaths.dataDir.path, 'web_media', 'temp'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Directory getDownloadsDir() {
    final dir = Directory(p.join(AppPaths.dataDir.path, 'web_media', 'downloads'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Directory getSubtitlesDir() {
    final dir = Directory(p.join(AppPaths.dataDir.path, 'web_media', 'subtitles'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // ── Sondage et Version ──

  Future<WebMediaProbeResult> probe() async {
    if (!isEnabled) {
      return const WebMediaProbeResult(
        isAvailable: false,
        errorMessage: 'Fonction Web Media désactivée dans les paramètres.',
      );
    }

    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) {
      return const WebMediaProbeResult(
        isAvailable: false,
        errorMessage: 'Exécutable yt-dlp introuvable dans runtime/web_media.',
      );
    }

    final ffmpeg = findFfmpegBinary();
    if (ffmpeg == null) {
      return WebMediaProbeResult(
        isAvailable: false,
        ytdlpPath: ytdlp,
        errorMessage: 'FFmpeg portable manquant dans runtime/web_media.',
      );
    }

    final jsRuntime = findJsRuntime();
    if (jsRuntime == null) {
      return WebMediaProbeResult(
        isAvailable: false,
        ytdlpPath: ytdlp,
        ffmpegPath: ffmpeg,
        errorMessage: 'Runtime JavaScript Web Media (Deno) manquant dans runtime/web_media.',
      );
    }

    final version = await getVersion();

    return WebMediaProbeResult(
      isAvailable: version != null,
      version: version,
      ytdlpPath: ytdlp,
      ffmpegPath: ffmpeg,
      jsRuntimePath: jsRuntime,
      errorMessage: version == null ? 'Échec d\'exécution de yt-dlp --version.' : null,
    );
  }

  Future<String?> getVersion() async {
    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) return null;

    try {
      final res = await Process.run(ytdlp, ['--version'], runInShell: false);
      if (res.exitCode == 0) {
        return res.stdout.toString().trim();
      }
    } catch (e) {
      Log.instance.w('web_media', 'Erreur lors de la lecture de la version yt-dlp: $e');
    }
    return null;
  }

  // ── Construction des arguments de base sûrs ──

  List<String> _buildBaseArgs() {
    final args = <String>[
      '--no-color',
      '--no-call-home',
    ];

    final ffmpeg = findFfmpegBinary();
    if (ffmpeg != null) {
      args.addAll(['--ffmpeg-location', p.dirname(ffmpeg)]);
    }

    final js = findJsRuntime();
    if (js != null) {
      args.addAll(['--js-runtimes', 'deno:$js']);
    }

    return args;
  }

  // ── Métadonnées et Formats ──

  Future<WebMediaMetadata> getMetadata(
    String url, {
    bool includePlaylist = false,
    Duration timeout = const Duration(seconds: 45),
    WebMediaCancellationToken? cancelToken,
  }) async {
    if (!isEnabled) throw WebMediaDisabledException();

    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) {
      throw WebMediaProcessException('yt-dlp.exe est introuvable.');
    }

    final args = _buildBaseArgs();
    if (!includePlaylist) {
      args.add('--no-playlist');
    } else {
      args.addAll(['--flat-playlist']);
    }
    args.addAll(['--dump-json', url.trim()]);

    final process = await Process.start(ytdlp, args, runInShell: false);
    cancelToken?.attachProcess(process);

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();

    process.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
    process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

    final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
      WebMediaService.terminateProcessTree(process);
      throw TimeoutException('Délai dépassé lors de la récupération des métadonnées ($url)');
    });

    if (cancelToken?.isCancelled ?? false) {
      throw const CancellationException();
    }

    if (exitCode != 0) {
      throw WebMediaProcessException(
        'Échec de l\'analyse du média',
        exitCode: exitCode,
        stderr: stderrBuf.toString().trim(),
      );
    }

    final rawJson = stdoutBuf.toString().trim();
    if (rawJson.isEmpty) {
      throw WebMediaProcessException('yt-dlp n\'a renvoyé aucune donnée JSON.');
    }

    // Si playlist plate, yt-dlp peut sortir un JSON par ligne
    final firstLine = rawJson.split('\n').first.trim();
    try {
      final data = jsonDecode(firstLine) as Map<String, dynamic>;
      return WebMediaMetadata.fromJson(url, data);
    } catch (e) {
      throw WebMediaProcessException('Format JSON invalide renvoyé par yt-dlp: $e');
    }
  }

  // ── Terminaison de processus robuste (Windows / POSIX) ──

  static void terminateProcessTree(Process? proc) {
    if (proc == null) return;
    try {
      if (Platform.isWindows) {
        Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
      } else {
        proc.kill(ProcessSignal.sigkill);
      }
    } catch (_) {
      try {
        proc.kill();
      } catch (_) {}
    }
  }

  // ── Recherche de Médias (REQ-POST-001 & EVOL-WEB-SEARCH-R2) ──

  /// Limite initiale nominale de résultats de recherche.
  static const int defaultSearchLimit = 20;

  /// Incrément lors d'une demande "Afficher plus".
  static const int searchLimitIncrement = 10;

  /// Plafond de sécurité maximal pour une session de recherche.
  static const int maxSearchLimit = 50;

  /// Recherche de médias en ligne via yt-dlp.
  /// Prend en charge les requêtes textuelles simples et les requêtes avec caractères génériques (*, ?).
  Future<List<WebMediaSearchResult>> searchMedia(
    String query, {
    int limit = defaultSearchLimit,
    Duration timeout = const Duration(seconds: 45),
    WebMediaCancellationToken? cancelToken,
  }) async {
    if (!isEnabled) throw WebMediaDisabledException();

    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) {
      throw WebMediaProcessException('yt-dlp.exe est introuvable dans runtime/web_media.');
    }

    final hasWildcards = WebMediaWildcardMatcher.hasWildcards(trimmed);
    final baseQuery = hasWildcards
        ? WebMediaWildcardMatcher.extractBaseQuery(trimmed)
        : trimmed;

    if (baseQuery.isEmpty) return [];

    // Si wildcards, récupérer davantage de résultats pour permettre le filtrage local
    final fetchLimit = hasWildcards ? (limit * 2).clamp(20, 50) : limit.clamp(1, 50);

    final args = _buildBaseArgs();
    args.addAll([
      '--dump-json',
      '--flat-playlist',
      '--skip-download',
      '--no-warnings',
      '--default-search', 'ytsearch',
      'ytsearch$fetchLimit:$baseQuery',
    ]);

    final process = await Process.start(ytdlp, args, runInShell: false);
    cancelToken?.attachProcess(process);

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();

    process.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
    process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

    final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
      terminateProcessTree(process);
      throw TimeoutException('Délai dépassé lors de la recherche ($query)');
    });

    if (cancelToken?.isCancelled ?? false) {
      terminateProcessTree(process);
      throw const CancellationException();
    }

    final rawOutput = stdoutBuf.toString().trim();
    if (rawOutput.isEmpty) {
      if (exitCode != 0) {
        throw WebMediaProcessException(
          'Échec de la recherche de médias',
          exitCode: exitCode,
          stderr: stderrBuf.toString().trim(),
        );
      }
      return [];
    }

    final results = <WebMediaSearchResult>[];
    final lines = rawOutput.split('\n');
    for (final line in lines) {
      final cleanLine = line.trim();
      if (cleanLine.isEmpty) continue;
      try {
        final data = jsonDecode(cleanLine) as Map<String, dynamic>;
        final item = WebMediaSearchResult.fromJson(data);
        if (item.url.isNotEmpty && item.title.isNotEmpty) {
          results.add(item);
        }
      } catch (e) {
        Log.instance.w('web_media', 'Ignoré élément de recherche mal formé: $e');
      }
    }

    // Filtrage local si caractères génériques (*, ?) présents
    if (hasWildcards) {
      final filtered = results
          .where((item) => WebMediaWildcardMatcher.matches(trimmed, item))
          .take(limit)
          .toList();
      return filtered;
    }

    return results.take(limit).toList();
  }

  // ── Téléchargement Audio pour ASR ──

  Future<File> downloadAudio(
    String url, {
    String targetFormat = 'mp3',
    int quality = 192,
    double? startTime,
    double? endTime,
    bool sponsorBlock = false,
    bool keepInDownloads = false,
    void Function(double progress, String status)? onProgress,
    WebMediaCancellationToken? cancelToken,
    Duration inactivityTimeout = TimeoutPolicy.webMediaDownloadInactivityTimeout,
    Duration absoluteTimeout = TimeoutPolicy.webMediaDownloadAbsoluteMaxDuration,
    Duration? timeout,
  }) async {
    if (!isEnabled) throw WebMediaDisabledException();

    if (timeout != null) {
      inactivityTimeout = timeout;
      absoluteTimeout = timeout;
    }

    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) throw WebMediaProcessException('yt-dlp.exe est introuvable dans runtime/web_media.');

    final ffmpeg = findFfmpegBinary();
    if (ffmpeg == null) {
      throw WebMediaProcessException('FFmpeg portable manquant dans runtime/web_media : extraction audio impossible.');
    }

    final targetDir = keepInDownloads ? getDownloadsDir() : getTempDir();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final outTemplate = p.join(targetDir.path, 'web_audio_${ts}_%(id)s.%(ext)s');

    final args = _buildBaseArgs();
    args.addAll([
      '--no-playlist',
      '-x',
      '--audio-format', targetFormat,
      '--audio-quality', '$quality',
      '-o', outTemplate,
    ]);

    if (startTime != null && endTime != null && endTime > startTime) {
      args.addAll(['--download-sections', '*${startTime.toStringAsFixed(1)}-${endTime.toStringAsFixed(1)}']);
    }

    if (sponsorBlock) {
      args.addAll(['--sponsorblock-remove', 'sponsor,selfpromo']);
    }

    args.add(url.trim());

    onProgress?.call(0.05, 'Démarrage du téléchargement audio...');

    final process = await Process.start(ytdlp, args, runInShell: false);
    cancelToken?.attachProcess(process);

    final stderrBuf = StringBuffer();
    String? finalFilePath;
    DateTime lastActivity = DateTime.now();
    final startTimeInstant = DateTime.now();

    process.stdout.transform(utf8.decoder).listen((line) {
      lastActivity = DateTime.now();
      // Analyse du pourcentage [download]  45.0% of ...
      final dlMatch = RegExp(r'\[download\]\s+([0-9.]+)%').firstMatch(line);
      if (dlMatch != null) {
        final pct = double.tryParse(dlMatch.group(1)!) ?? 0.0;
        onProgress?.call(pct / 100.0, 'Téléchargement audio : ${pct.toStringAsFixed(1)}%');
      }

      final destMatch = RegExp(r'Destination:\s*(.+\.(?:mp3|m4a|opus|wav|aac|webm))').firstMatch(line);
      if (destMatch != null) {
        finalFilePath = destMatch.group(1)!.trim();
      }
      final extractMatch = RegExp(r'\[ExtractAudio\] Destination:\s*(.+)').firstMatch(line);
      if (extractMatch != null) {
        finalFilePath = extractMatch.group(1)!.trim();
      }
    });

    process.stderr.transform(utf8.decoder).listen((chunk) {
      lastActivity = DateTime.now();
      stderrBuf.write(chunk);
    });

    final completer = Completer<int>();
    process.exitCode.then((code) {
      if (!completer.isCompleted) completer.complete(code);
    }).catchError((Object err, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(err, st);
    });

    // Watchdog d'inactivité et de plafond absolu avec terminaison complète de l'arbre
    final watchdogTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final inactiveMs = now.difference(lastActivity).inMilliseconds;
      final totalMs = now.difference(startTimeInstant).inMilliseconds;

      if (cancelToken?.isCancelled ?? false) {
        timer.cancel();
        terminateProcessTree(process);
        if (!completer.isCompleted) completer.completeError(const CancellationException());
        return;
      }

      if (inactiveMs >= inactivityTimeout.inMilliseconds) {
        timer.cancel();
        terminateProcessTree(process);
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              'Téléchargement audio interrompu pour inactivité (${(inactiveMs / 1000).toStringAsFixed(1)}s sans flux stdout/stderr).',
            ),
          );
        }
        return;
      }

      if (totalMs >= absoluteTimeout.inMilliseconds) {
        timer.cancel();
        terminateProcessTree(process);
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              'Téléchargement audio interrompu pour dépassement du plafond absolu de sécurité (${(totalMs / 1000).toStringAsFixed(1)}s).',
            ),
          );
        }
        return;
      }
    });

    int exitCode;
    try {
      exitCode = await completer.future;
    } finally {
      watchdogTimer.cancel();
    }

    if (cancelToken?.isCancelled ?? false) {
      throw const CancellationException();
    }

    if (exitCode != 0) {
      throw WebMediaProcessException(
        'Échec de l\'extraction audio',
        exitCode: exitCode,
        stderr: stderrBuf.toString().trim(),
      );
    }

    // Trouver le fichier généré
    if (finalFilePath != null && File(finalFilePath!).existsSync()) {
      onProgress?.call(1.0, 'Audio téléchargé avec succès.');
      return File(finalFilePath!);
    }

    // Recherche de secours par préfixe
    final prefix = 'web_audio_$ts';
    for (final f in targetDir.listSync().whereType<File>()) {
      if (p.basename(f.path).startsWith(prefix)) {
        onProgress?.call(1.0, 'Audio téléchargé avec succès.');
        return f;
      }
    }

    throw WebMediaProcessException('Fichier audio extrait introuvable sur le disque.');
  }

  // ── Téléchargement Vidéo ──

  Future<File> downloadVideo(
    String url, {
    String quality = '1080p',
    void Function(double progress, String status)? onProgress,
    WebMediaCancellationToken? cancelToken,
    Duration inactivityTimeout = TimeoutPolicy.webMediaDownloadInactivityTimeout,
    Duration absoluteTimeout = TimeoutPolicy.webMediaDownloadAbsoluteMaxDuration,
    Duration? timeout,
  }) async {
    if (!isEnabled) throw WebMediaDisabledException();

    if (timeout != null) {
      inactivityTimeout = timeout;
      absoluteTimeout = timeout;
    }

    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) throw WebMediaProcessException('yt-dlp.exe est introuvable dans runtime/web_media.');

    final ffmpeg = findFfmpegBinary();
    if (ffmpeg == null) {
      throw WebMediaProcessException('FFmpeg portable manquant dans runtime/web_media : fusion vidéo/audio impossible.');
    }

    final targetDir = getDownloadsDir();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final outTemplate = p.join(targetDir.path, 'video_${ts}_%(title)s.%(ext)s');

    String formatSelector = 'bestvideo+bestaudio/best';
    if (quality == '720p') {
      formatSelector = 'bestvideo[height<=720]+bestaudio/best[height<=720]/best';
    } else if (quality == '480p') {
      formatSelector = 'bestvideo[height<=480]+bestaudio/best[height<=480]/best';
    } else if (quality == '1080p') {
      formatSelector = 'bestvideo[height<=1080]+bestaudio/best[height<=1080]/best';
    }

    final args = _buildBaseArgs();
    args.addAll([
      '--no-playlist',
      '-f', formatSelector,
      '--merge-output-format', 'mp4',
      '-o', outTemplate,
      url.trim(),
    ]);

    onProgress?.call(0.05, 'Démarrage du téléchargement vidéo ($quality)...');

    final process = await Process.start(ytdlp, args, runInShell: false);
    cancelToken?.attachProcess(process);

    final stderrBuf = StringBuffer();
    String? finalFilePath;
    DateTime lastActivity = DateTime.now();
    final startTimeInstant = DateTime.now();

    process.stdout.transform(utf8.decoder).listen((line) {
      lastActivity = DateTime.now();
      final dlMatch = RegExp(r'\[download\]\s+([0-9.]+)%').firstMatch(line);
      if (dlMatch != null) {
        final pct = double.tryParse(dlMatch.group(1)!) ?? 0.0;
        onProgress?.call(pct / 100.0, 'Téléchargement vidéo : ${pct.toStringAsFixed(1)}%');
      }
      final mergeMatch = RegExp(r'\[Merger\] Merging formats into "([^"]+)"').firstMatch(line);
      if (mergeMatch != null) {
        finalFilePath = mergeMatch.group(1)!.trim();
      }
    });

    process.stderr.transform(utf8.decoder).listen((chunk) {
      lastActivity = DateTime.now();
      stderrBuf.write(chunk);
    });

    final completer = Completer<int>();
    process.exitCode.then((code) {
      if (!completer.isCompleted) completer.complete(code);
    }).catchError((Object err, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(err, st);
    });

    // Watchdog d'inactivité et de plafond absolu avec terminaison complète de l'arbre
    final watchdogTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final inactiveMs = now.difference(lastActivity).inMilliseconds;
      final totalMs = now.difference(startTimeInstant).inMilliseconds;

      if (cancelToken?.isCancelled ?? false) {
        timer.cancel();
        terminateProcessTree(process);
        if (!completer.isCompleted) completer.completeError(const CancellationException());
        return;
      }

      if (inactiveMs >= inactivityTimeout.inMilliseconds) {
        timer.cancel();
        terminateProcessTree(process);
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              'Téléchargement vidéo interrompu pour inactivité (${(inactiveMs / 1000).toStringAsFixed(1)}s sans flux stdout/stderr).',
            ),
          );
        }
        return;
      }

      if (totalMs >= absoluteTimeout.inMilliseconds) {
        timer.cancel();
        terminateProcessTree(process);
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              'Téléchargement vidéo interrompu pour dépassement du plafond absolu de sécurité (${(totalMs / 1000).toStringAsFixed(1)}s).',
            ),
          );
        }
        return;
      }
    });

    int exitCode;
    try {
      exitCode = await completer.future;
    } finally {
      watchdogTimer.cancel();
    }

    if (cancelToken?.isCancelled ?? false) throw const CancellationException();
    if (exitCode != 0) {
      throw WebMediaProcessException('Échec du téléchargement vidéo', exitCode: exitCode, stderr: stderrBuf.toString().trim());
    }

    if (finalFilePath != null && File(finalFilePath!).existsSync()) {
      return File(finalFilePath!);
    }

    final prefix = 'video_$ts';
    for (final f in targetDir.listSync().whereType<File>()) {
      if (p.basename(f.path).startsWith(prefix)) {
        return f;
      }
    }

    throw WebMediaProcessException('Fichier vidéo introuvable après téléchargement.');
  }

  // ── Téléchargement Sous-titres ──

  void _cleanupMatchingFiles(Directory dir, String prefix) {
    try {
      if (dir.existsSync()) {
        for (final f in dir.listSync().whereType<File>()) {
          if (p.basename(f.path).startsWith(prefix)) {
            try {
              f.deleteSync();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Future<File?> downloadSubtitles(
    String url, {
    String langCode = 'fr',
    bool autoCaptions = false,
    String format = 'srt',
    void Function(String status)? onProgress,
    WebMediaCancellationToken? cancelToken,
    Duration absoluteTimeout = const Duration(seconds: 180),
    Duration inactivityTimeout = const Duration(seconds: 30),
  }) async {
    if (!isEnabled) throw WebMediaDisabledException();

    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) throw WebMediaProcessException('yt-dlp.exe est introuvable.');

    final targetDir = getSubtitlesDir();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final prefix = 'sub_$ts';
    final outTemplate = p.join(targetDir.path, '${prefix}_%(id)s.%(ext)s');

    final args = _buildBaseArgs();
    args.addAll([
      '--no-playlist',
      '--skip-download',
    ]);

    // Sélection stricte d'UNE seule piste : soit automatique, soit humaine
    if (autoCaptions) {
      args.add('--write-auto-sub');
    } else {
      args.add('--write-sub');
    }

    args.addAll([
      '--sub-lang', langCode.trim(),
      '--convert-subs', format,
      '-o', outTemplate,
      url.trim(),
    ]);

    final process = await Process.start(ytdlp, args, runInShell: false);
    cancelToken?.attachProcess(process);

    final stderrBuf = StringBuffer();
    final stdoutBuf = StringBuffer();
    DateTime lastActivity = DateTime.now();
    final startTime = DateTime.now();

    process.stdout.transform(utf8.decoder).listen((data) {
      lastActivity = DateTime.now();
      stdoutBuf.write(data);
      final trimmed = data.trim();
      if (trimmed.isNotEmpty) {
        onProgress?.call(trimmed);
      }
    });

    process.stderr.transform(utf8.decoder).listen((data) {
      lastActivity = DateTime.now();
      stderrBuf.write(data);
    });

    final completer = Completer<int>();
    process.exitCode.then((code) {
      if (!completer.isCompleted) completer.complete(code);
    }).catchError((Object err, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(err, st);
    });

    // Watchdog d'inactivité et de timeout absolu
    final watchdogTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final inactiveSec = now.difference(lastActivity).inSeconds;
      final totalSec = now.difference(startTime).inSeconds;

      if (cancelToken?.isCancelled ?? false) {
        timer.cancel();
        try {
          terminateProcessTree(process);
        } catch (_) {}
        _cleanupMatchingFiles(targetDir, prefix);
        if (!completer.isCompleted) completer.completeError(const CancellationException());
        return;
      }

      if (inactiveSec >= inactivityTimeout.inSeconds) {
        timer.cancel();
        try {
          terminateProcessTree(process);
        } catch (_) {}
        _cleanupMatchingFiles(targetDir, prefix);
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              'Inactivité yt-dlp dépassée (${inactiveSec}s sans flux stdout/stderr) lors de la récupération des sous-titres.',
            ),
          );
        }
        return;
      }

      if (totalSec >= absoluteTimeout.inSeconds) {
        timer.cancel();
        try {
          terminateProcessTree(process);
        } catch (_) {}
        _cleanupMatchingFiles(targetDir, prefix);
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              'Délai maximal absolu dépassé (${totalSec}s) lors de la récupération des sous-titres.',
            ),
          );
        }
        return;
      }
    });

    int exitCode;
    try {
      exitCode = await completer.future;
    } finally {
      watchdogTimer.cancel();
    }

    if (cancelToken?.isCancelled ?? false) {
      _cleanupMatchingFiles(targetDir, prefix);
      throw const CancellationException();
    }

    if (exitCode != 0) {
      _cleanupMatchingFiles(targetDir, prefix);
      throw WebMediaProcessException(
        'Échec de récupération des sous-titres',
        exitCode: exitCode,
        stderr: stderrBuf.toString().trim(),
      );
    }

    // Rechercher le fichier de sous-titres généré
    for (final f in targetDir.listSync().whereType<File>()) {
      if (p.basename(f.path).startsWith(prefix) && f.path.endsWith('.$format')) {
        return f;
      }
    }

    return null;
  }

  // ── Énumération Playlists & Chaînes ──

  Future<List<WebMediaPlaylistItem>> enumeratePlaylist(
    String url, {
    int maxItems = 50,
    WebMediaCancellationToken? cancelToken,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!isEnabled) throw WebMediaDisabledException();

    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) throw WebMediaProcessException('yt-dlp.exe est introuvable.');

    final args = _buildBaseArgs();
    args.addAll([
      '--flat-playlist',
      '--playlist-end', '$maxItems',
      '--dump-json',
      url.trim(),
    ]);

    final process = await Process.start(ytdlp, args, runInShell: false);
    cancelToken?.attachProcess(process);

    final items = <WebMediaPlaylistItem>[];
    final stderrBuf = StringBuffer();
    final stdoutBuf = StringBuffer();

    // Draining both stdout and stderr to prevent pipe deadlocks (AUD-WEB-04 / TNR-076)
    process.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
    process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

    final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
      WebMediaService.terminateProcessTree(process);
      throw TimeoutException('Délai dépassé lors de l\'énumération de la playlist ($url)');
    });

    if (cancelToken?.isCancelled ?? false) {
      throw const CancellationException();
    }

    // ExitCode non nul traité comme une erreur, pas une liste vide silencieuse (AUD-WEB-04 / TNR-076)
    if (exitCode != 0) {
      throw WebMediaProcessException(
        'Échec de l\'énumération de la playlist',
        exitCode: exitCode,
        stderr: stderrBuf.toString().trim(),
      );
    }

    final rawOutput = stdoutBuf.toString().trim();
    if (rawOutput.isNotEmpty) {
      int candidateLines = 0;
      for (final line in rawOutput.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        candidateLines++;
        try {
          final data = jsonDecode(trimmed) as Map<String, dynamic>;
          items.add(WebMediaPlaylistItem.fromJson(data));
        } catch (_) {}
      }
      if (candidateLines > 0 && items.isEmpty) {
        throw WebMediaProcessException(
          'Format JSON invalide ou aucune entrée playlist exploitable.',
          exitCode: exitCode,
          stderr: stderrBuf.toString().trim(),
        );
      }
    }

    return items;
  }

  Future<List<WebMediaPlaylistItem>> enumerateChannel(
    String url, {
    int maxItems = 50,
    WebMediaCancellationToken? cancelToken,
  }) {
    return enumeratePlaylist(url, maxItems: maxItems, cancelToken: cancelToken);
  }

  // ── Commentaires (Opt-in) ──

  Future<List<WebMediaComment>> getComments(
    String url, {
    int maxComments = 20,
    WebMediaCancellationToken? cancelToken,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (!isEnabled) throw WebMediaDisabledException();

    final ytdlp = findYtDlpBinary();
    if (ytdlp == null) throw WebMediaProcessException('yt-dlp.exe est introuvable.');

    final args = _buildBaseArgs();
    args.addAll([
      '--no-playlist',
      '--skip-download',
      '--write-comments',
      '--extractor-args', 'youtube:max_comments=$maxComments,0,0,0',
      '--dump-json',
      url.trim(),
    ]);

    final process = await Process.start(ytdlp, args, runInShell: false);
    cancelToken?.attachProcess(process);

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();

    // Draining both stdout and stderr to prevent pipe deadlocks (AUD-WEB-04 / TNR-076)
    process.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
    process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

    final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
      WebMediaService.terminateProcessTree(process);
      throw TimeoutException('Délai dépassé lors de la récupération des commentaires ($url)');
    });

    if (cancelToken?.isCancelled ?? false) {
      throw const CancellationException();
    }

    // ExitCode non nul traité comme une erreur, pas une liste vide silencieuse (AUD-WEB-04 / TNR-076)
    if (exitCode != 0) {
      throw WebMediaProcessException(
        'Échec de la récupération des commentaires',
        exitCode: exitCode,
        stderr: stderrBuf.toString().trim(),
      );
    }

    try {
      final data = jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
      final rawComments = data['comments'] as List<dynamic>? ?? [];
      return rawComments
          .whereType<Map<String, dynamic>>()
          .take(maxComments)
          .map((c) => WebMediaComment.fromJson(c))
          .toList();
    } catch (e) {
      throw WebMediaProcessException('Format JSON invalide pour les commentaires: $e');
    }
  }

  // ── Mise à Jour Contrôlée yt-dlp ──

  Future<WebMediaUpdateStatus> checkUpdate() async {
    final currentVer = await getVersion();
    if (currentVer == null) {
      return const WebMediaUpdateStatus(
        installedVersion: 'Inconnue',
        latestVersion: null,
        updateAvailable: false,
        isChecking: false,
        isUpdating: false,
        error: 'Impossible de lire la version installée.',
      );
    }

    try {
      final resp = await http.get(
        Uri.parse('https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'),
        headers: {'User-Agent': 'Jarvisol-WebMedia/1.0'},
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final latestTag = (data['tag_name'] as String? ?? '').replaceFirst('v', '');
        final hasUpdate = latestTag.isNotEmpty && latestTag != currentVer;
        return WebMediaUpdateStatus(
          installedVersion: currentVer,
          latestVersion: latestTag,
          updateAvailable: hasUpdate,
          isChecking: false,
          isUpdating: false,
          statusMessage: hasUpdate
              ? 'Mise à jour disponible : $latestTag (installée : $currentVer)'
              : 'yt-dlp est à jour ($currentVer).',
        );
      }
    } catch (e) {
      return WebMediaUpdateStatus(
        installedVersion: currentVer,
        latestVersion: null,
        updateAvailable: false,
        isChecking: false,
        isUpdating: false,
        error: 'Vérification en ligne échouée : $e',
      );
    }

    return WebMediaUpdateStatus(
      installedVersion: currentVer,
      latestVersion: null,
      updateAvailable: false,
      isChecking: false,
      isUpdating: false,
    );
  }

  Future<bool> updateYtDlp({
    void Function(double progress, String status)? onProgress,
    String? testDownloadUrl,
    String? testChecksumUrl,
  }) async {
    final currentPath = findYtDlpBinary();
    if (currentPath == null) throw Exception('Emplacement de yt-dlp.exe introuvable.');

    onProgress?.call(0.1, 'Recherche de la dernière version...');
    final check = await checkUpdate();
    if (!check.updateAvailable || check.latestVersion == null) {
      onProgress?.call(1.0, 'Déjà à jour.');
      return false;
    }

    final targetTag = check.latestVersion!;

    // Fichier temporaire de staging .tmp (AUD-WEB-02 / TNR-027)
    final tmpFile = File('$currentPath.tmp');
    final bakFile = File('$currentPath.bak_prev');
    final bakTimestamped = File('$currentPath.bak_${DateTime.now().millisecondsSinceEpoch}');

    try {
      onProgress?.call(0.25, 'Téléchargement de la nouvelle version...');
      final downloadUrl = testDownloadUrl ??
          'https://github.com/yt-dlp/yt-dlp/releases/download/$targetTag/yt-dlp.exe';
      final resp = await http.get(Uri.parse(downloadUrl)).timeout(const Duration(minutes: 5));

      if (resp.statusCode != 200) {
        throw Exception('Échec du téléchargement HTTP : ${resp.statusCode}');
      }

      await tmpFile.writeAsBytes(resp.bodyBytes, flush: true);

      // Contrôle secondaire : vérification de taille minimale (> 1 Mo) (AUD-WEB-02 / TNR-027)
      if (!tmpFile.existsSync() || tmpFile.lengthSync() < 1024 * 1024) {
        throw Exception('Le binaire téléchargé est invalide ou trop petit (${tmpFile.existsSync() ? tmpFile.lengthSync() : 0} octets).');
      }

      // ── B-R1: Intégrité Cryptographique SHA-256 contre manifeste officiel (TNR-027) ──
      onProgress?.call(0.5, 'Récupération du manifeste checksum officiel (SHA2-256SUMS)...');
      final checksumUrl = testChecksumUrl ??
          'https://github.com/yt-dlp/yt-dlp/releases/download/$targetTag/SHA2-256SUMS';

      http.Response checksumResp;
      try {
        checksumResp = await http.get(Uri.parse(checksumUrl)).timeout(const Duration(seconds: 30));
      } catch (e) {
        throw Exception('Erreur lors du téléchargement du manifeste checksum officiel : $e');
      }

      if (checksumResp.statusCode != 200) {
        throw Exception('Manifeste checksum officiel introuvable ou inaccessible (HTTP ${checksumResp.statusCode}).');
      }

      final checksumBody = checksumResp.body;
      if (checksumBody.trim().isEmpty) {
        throw Exception('Manifeste checksum officiel vide ou invalide.');
      }

      // Extraction stricte de l\'entrée 'yt-dlp.exe'
      String? officialSha256;
      for (final rawLine in checksumBody.split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final match = RegExp(r'^([a-fA-F0-9]{64})\s+[*]?yt-dlp\.exe$', caseSensitive: false).firstMatch(line);
        if (match != null) {
          officialSha256 = match.group(1)!.toLowerCase();
          break;
        }
      }

      if (officialSha256 == null || officialSha256.length != 64) {
        throw Exception('Entrée yt-dlp.exe introuvable ou empreinte SHA-256 invalide dans le manifeste officiel.');
      }

      onProgress?.call(0.65, 'Validation de l\'intégrité cryptographique SHA-256...');
      final stagedBytes = await tmpFile.readAsBytes();
      final stagedSha256 = sha256.convert(stagedBytes).toString().toLowerCase();

      if (stagedSha256 != officialSha256) {
        throw Exception('Échec de vérification SHA-256 : l\'empreinte de l\'asset ($stagedSha256) ne correspond pas au manifeste officiel ($officialSha256).');
      }

      // Contrôle secondaire : test d'exécutabilité (--version)
      onProgress?.call(0.75, 'Validation de l\'exécutabilité du binaire...');
      final testRes = await Process.run(tmpFile.path, ['--version']);
      if (testRes.exitCode != 0) {
        throw Exception('Le binaire téléchargé ne démarre pas correctement (code: ${testRes.exitCode}).');
      }
      final stagedVersion = testRes.stdout.toString().trim();
      if (stagedVersion.isEmpty) {
        throw Exception('Le binaire téléchargé n\'a pas retourné de version valide.');
      }

      onProgress?.call(0.85, 'Sauvegarde de l\'ancienne version et remplacement atomique...');
      final currentFile = File(currentPath);
      if (currentFile.existsSync()) {
        try { currentFile.copySync(bakFile.path); } catch (_) {}
        try { currentFile.copySync(bakTimestamped.path); } catch (_) {}
      }

      // Remplacement atomique
      if (Platform.isWindows && currentFile.existsSync()) {
        currentFile.deleteSync();
      }
      tmpFile.renameSync(currentPath);

      // Smoke test final
      final finalRes = await Process.run(currentPath, ['--version']);
      if (finalRes.exitCode != 0) {
        // Rollback propre
        if (bakFile.existsSync()) {
          try { bakFile.copySync(currentPath); } catch (_) {}
        }
        throw Exception('Smoke test échoué, rollback effectué.');
      }

      onProgress?.call(1.0, 'Mise à jour réussie vers $targetTag !');
      return true;
    } catch (e) {
      Log.instance.e('web_media', 'Échec mise à jour yt-dlp : $e');
      // Rollback de sécurité si le fichier actuel est manquant ou vide
      final currentFile = File(currentPath);
      if ((!currentFile.existsSync() || currentFile.lengthSync() == 0) && bakFile.existsSync()) {
        try { bakFile.copySync(currentPath); } catch (_) {}
      }
      rethrow;
    } finally {
      if (tmpFile.existsSync()) {
        try { tmpFile.deleteSync(); } catch (_) {}
      }
    }
  }

  // ── Nettoyage Fichiers Temporaires ──

  void cleanupTempFiles({Duration olderThan = const Duration(hours: 24)}) {
    try {
      final tempDir = getTempDir();
      final now = DateTime.now();
      for (final f in tempDir.listSync().whereType<File>()) {
        try {
          final stat = f.statSync();
          if (now.difference(stat.modified) > olderThan) {
            f.deleteSync();
          }
        } catch (_) {}
      }
    } catch (e) {
      Log.instance.d('web_media', 'Nettoyage temp web_media ignoré : $e');
    }
  }
}

class CancellationException implements Exception {
  final String message;
  const CancellationException([this.message = 'Opération annulée par l\'utilisateur.']);
  @override
  String toString() => message;
}

class WebMediaUpdateStatus {
  final String installedVersion;
  final String? latestVersion;
  final bool updateAvailable;
  final bool isChecking;
  final bool isUpdating;
  final String? statusMessage;
  final String? error;

  const WebMediaUpdateStatus({
    required this.installedVersion,
    this.latestVersion,
    required this.updateAvailable,
    required this.isChecking,
    required this.isUpdating,
    this.statusMessage,
    this.error,
  });
}
