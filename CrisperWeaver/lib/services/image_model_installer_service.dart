// lib/services/image_model_installer_service.dart
//
// Moteur de telechargement securise et d'installation atomique de modeles d'image
// pour Jarvisol (EXT-V1-02 Phase 1).

import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/image_model_catalog.dart';
import 'disk_space.dart';
import 'image_model_catalog_service.dart';

/// Interface d'ecriture par blocs pour le streaming I/O
abstract class FileChunkWriter {
  Future<void> writeChunk(List<int> bytes);
  Future<void> flush();
  Future<void> close();
}

/// Implementation par defaut basee sur RandomAccessFile avec operations I/O synchronisees
class DefaultRafChunkWriter implements FileChunkWriter {
  final RandomAccessFile _raf;
  DefaultRafChunkWriter(this._raf);

  static Future<DefaultRafChunkWriter> open(File file, FileMode mode, int startOffset) async {
    final raf = await file.open(mode: mode);
    if (startOffset > 0) {
      await raf.setPosition(startOffset);
    }
    return DefaultRafChunkWriter(raf);
  }

  @override
  Future<void> writeChunk(List<int> bytes) => _raf.writeFrom(bytes);

  @override
  Future<void> flush() => _raf.flush();

  @override
  Future<void> close() => _raf.close();
}

typedef FileChunkWriterFactory = FutureOr<FileChunkWriter> Function(
  File partFile,
  FileMode mode,
  int startOffset,
);

class ImageModelInstallerService {
  final ImageModelCatalogService catalogService;
  final http.Client _httpClient;
  final bool _ownsClient;
  final int Function(String path)? diskSpaceProbe;
  final FileChunkWriterFactory? writerFactory;

  final _progressController = StreamController<DownloadProgressEvent>.broadcast();
  bool _isCancelled = false;
  StreamSubscription<List<int>>? _activeStreamSub;
  Completer<void>? _activeCompleter;

  ImageModelInstallerService({
    required this.catalogService,
    http.Client? httpClient,
    this.diskSpaceProbe,
    this.writerFactory,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// Flux observable des evenements d'installation
  Stream<DownloadProgressEvent> get progressStream => _progressController.stream;

  /// Indique si une annulation a ete demandee
  bool get isCancelled => _isCancelled;

  /// Repertoire cible d'installation
  Directory get targetDir => catalogService.modelsDir;

  /// Demande l'annulation immediate du telechargement en cours
  void cancel() {
    _isCancelled = true;
    try {
      _activeStreamSub?.cancel();
    } catch (_) {}
    _activeStreamSub = null;

    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      _activeCompleter!.completeError(
        ImageInstallerException('DOWNLOAD_CANCELLED', 'Telechargement annule par l\'utilisateur'),
      );
    }

    _progressController.add(const DownloadProgressEvent(
      status: ImageDownloadStatus.cancelled,
      errorMessage: 'Operation annulee par l\'utilisateur',
    ));
  }

  /// Execution complete d'un plan d'installation
  Future<void> executePlan(
    InstallationPlan plan, {
    bool acceptedLicenses = false,
  }) async {
    _isCancelled = false;

    // 1. Verifier l'acceptation prealable des licences
    if (plan.requiresLicenseAcceptance && !acceptedLicenses) {
      const msg = 'L\'installation requiert l\'acceptation explicite prealable de la licence utilisateur';
      _progressController.add(const DownloadProgressEvent(
        status: ImageDownloadStatus.failed,
        errorMessage: msg,
      ));
      throw ImageInstallerException('LICENSE_ACCEPTANCE_REQUIRED', msg);
    }

    // 2. Verifier l'espace disque disponible
    if (!plan.isDiskSpaceSufficient) {
      final msg = 'Espace disque insuffisant sur le volume de destination '
          '(disponible: ${plan.availableFreeDiskBytes} octets, requis: ${plan.minimumFreeDiskBytes} octets)';
      _progressController.add(DownloadProgressEvent(
        status: ImageDownloadStatus.failed,
        errorMessage: msg,
      ));
      throw ImageInstallerException('DISK_SPACE_INSUFFICIENT', msg);
    }

    // 3. Telecharger sequentiellement chaque composant manquant
    var totalDownloadedBytesSoFar = 0;
    final totalBytesToDownload = plan.downloadRequiredBytes;

    for (final comp in plan.componentsToDownload) {
      if (_isCancelled) {
        throw ImageInstallerException('DOWNLOAD_CANCELLED', 'Operation annulee');
      }

      await _installComponent(
        comp,
        totalBytesToDownload: totalBytesToDownload,
        cumulativeBytesDownloaded: totalDownloadedBytesSoFar,
      );

      totalDownloadedBytesSoFar += comp.expectedSizeBytes;
    }

    _progressController.add(DownloadProgressEvent(
      status: ImageDownloadStatus.completed,
      bytesDownloaded: totalBytesToDownload,
      totalBytes: totalBytesToDownload,
      progressPercentage: 1.0,
    ));
  }

  /// Telecharge, verifie et installe unitairement un composant
  Future<void> _installComponent(
    PhysicalComponent component, {
    required int totalBytesToDownload,
    required int cumulativeBytesDownloaded,
  }) async {
    final finalFile = File(p.join(targetDir.path, component.fileName));
    final partFile = File(p.join(targetDir.path, '${component.fileName}.part'));

    // Verification si deja installe
    if (await finalFile.exists()) {
      final stat = await finalFile.stat();
      if (stat.size == component.expectedSizeBytes) {
        final existingSha = await ImageModelCatalogService.computeFileSha256(finalFile);
        if (existingSha == component.expectedSha256) {
          await catalogService.recordVerifiedComponent(
            component.fileName,
            stat.size,
            stat.modified.millisecondsSinceEpoch,
            existingSha,
          );
          return; // Deja installe et verifie
        }
      }
      // Fichier present mais invalide
      throw ImageInstallerException(
        'CORRUPT_OR_MISMATCH',
        'Le fichier final existe deja mais ne correspond pas aux specifications: ${component.fileName}',
      );
    }

    // S'assurer que le dossier cible existe
    await targetDir.create(recursive: true);

    var existingPartBytes = 0;
    if (await partFile.exists()) {
      existingPartBytes = (await partFile.stat()).size;
      if (existingPartBytes > component.expectedSizeBytes) {
        await partFile.delete();
        existingPartBytes = 0;
      }
    }

    // Verification d'espace disque dynamique avant chaque composant
    final neededForThis = component.expectedSizeBytes - existingPartBytes;
    final availSpace = diskSpaceProbe != null
        ? diskSpaceProbe!(targetDir.path)
        : getAvailableDiskSpace(targetDir.path);
    if (availSpace >= 0 && availSpace < neededForThis) {
      throw ImageInstallerException(
        'DOWNLOAD_DISK_FULL',
        'Espace disque epuise sur le volume cible avant telechargement de ${component.fileName}',
      );
    }

    _progressController.add(DownloadProgressEvent(
      status: ImageDownloadStatus.checking,
      currentComponentId: component.componentId,
      currentFileName: component.fileName,
      bytesDownloaded: cumulativeBytesDownloaded + existingPartBytes,
      totalBytes: totalBytesToDownload,
      progressPercentage: totalBytesToDownload > 0
          ? (cumulativeBytesDownloaded + existingPartBytes) / totalBytesToDownload
          : 0.0,
      isResumed: existingPartBytes > 0,
    ));

    final request = http.Request('GET', Uri.parse(component.downloadUrl));
    if (existingPartBytes > 0 && component.supportsResume) {
      request.headers['Range'] = 'bytes=$existingPartBytes-';
    }

    http.StreamedResponse response;
    try {
      response = await _httpClient.send(request);
    } catch (e) {
      if (_isCancelled) {
        throw ImageInstallerException('DOWNLOAD_CANCELLED', 'Operation annulee pendant la connexion');
      }
      throw ImageInstallerException('DOWNLOAD_NETWORK_ERROR', 'Echec de connexion HTTP: $e', e);
    }

    var fileMode = FileMode.writeOnly;
    var bytesReceivedForFile = 0;
    var isResumed = false;

    if (response.statusCode == 206) {
      isResumed = true;
      fileMode = FileMode.writeOnlyAppend;
      bytesReceivedForFile = existingPartBytes;

      final contentRange = response.headers['content-range'];
      if (contentRange != null) {
        final match = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)').firstMatch(contentRange);
        if (match != null) {
          final rangeStart = int.tryParse(match.group(1)!);
          if (rangeStart != null && rangeStart != existingPartBytes) {
            throw ImageInstallerException(
              'REMOTE_ARTIFACT_CHANGED',
              'Content-Range incoherent avec l\'offset local ($rangeStart != $existingPartBytes)',
            );
          }
        }
      }
    } else if (response.statusCode == 200) {
      fileMode = FileMode.writeOnly;
      bytesReceivedForFile = 0;
      isResumed = false;
    } else if (response.statusCode == 416) {
      if (existingPartBytes == component.expectedSizeBytes) {
        bytesReceivedForFile = existingPartBytes;
      } else {
        fileMode = FileMode.writeOnly;
        bytesReceivedForFile = 0;
      }
    } else {
      throw ImageInstallerException(
        'DOWNLOAD_HTTP_ERROR',
        'Statut HTTP inattendu: ${response.statusCode} (${response.reasonPhrase}) pour ${component.fileName}',
      );
    }

    final writeStartOffset = isResumed ? existingPartBytes : 0;

    if (response.statusCode == 200 || response.statusCode == 206) {
      FileChunkWriter writer;
      try {
        if (writerFactory != null) {
          writer = await writerFactory!(partFile, fileMode, writeStartOffset);
        } else {
          writer = await DefaultRafChunkWriter.open(partFile, fileMode, writeStartOffset);
        }
      } catch (e) {
        if (isDiskFullError(e)) {
          throw ImageInstallerException(
            'DOWNLOAD_DISK_FULL',
            'Espace disque sature a l\'ouverture de ${component.fileName}: $e',
            e,
          );
        }
        throw ImageInstallerException('FILE_OPEN_ERROR', 'Impossible d\'ouvrir le fichier partiel: $e', e);
      }

      _progressController.add(DownloadProgressEvent(
        status: ImageDownloadStatus.downloading,
        currentComponentId: component.componentId,
        currentFileName: component.fileName,
        bytesDownloaded: cumulativeBytesDownloaded + bytesReceivedForFile,
        totalBytes: totalBytesToDownload,
        progressPercentage: totalBytesToDownload > 0
            ? (cumulativeBytesDownloaded + bytesReceivedForFile) / totalBytesToDownload
            : 0.0,
        isResumed: isResumed,
      ));

      final completer = Completer<void>();
      _activeCompleter = completer;
      var writerClosed = false;

      late StreamSubscription<List<int>> sub;
      sub = response.stream.listen(
        (chunk) async {
          if (_isCancelled) return;
          sub.pause();
          try {
            await writer.writeChunk(chunk);
            bytesReceivedForFile += chunk.length;

            _progressController.add(DownloadProgressEvent(
              status: ImageDownloadStatus.downloading,
              currentComponentId: component.componentId,
              currentFileName: component.fileName,
              bytesDownloaded: cumulativeBytesDownloaded + bytesReceivedForFile,
              totalBytes: totalBytesToDownload,
              progressPercentage: totalBytesToDownload > 0
                  ? (cumulativeBytesDownloaded + bytesReceivedForFile) / totalBytesToDownload
                  : 0.0,
              isResumed: isResumed,
            ));
          } catch (e) {
            if (!completer.isCompleted) completer.completeError(e);
          } finally {
            if (!_isCancelled && !completer.isCompleted) {
              sub.resume();
            }
          }
        },
        onError: (Object error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
        onDone: () async {
          try {
            await writer.flush();
            await writer.close();
            writerClosed = true;
            if (!completer.isCompleted) completer.complete();
          } catch (e) {
            if (!completer.isCompleted) completer.completeError(e);
          }
        },
        cancelOnError: true,
      );
      _activeStreamSub = sub;

      try {
        await completer.future;
      } catch (e) {
        _classifyAndRethrow(e, component.fileName);
      } finally {
        try {
          await sub.cancel();
        } catch (_) {}
        _activeStreamSub = null;
        _activeCompleter = null;
        if (!writerClosed) {
          try {
            await writer.close();
          } catch (_) {
            // Premier echec deja capture et propage par completer
          }
        }
      }
    }

    if (_isCancelled) {
      throw ImageInstallerException('DOWNLOAD_CANCELLED', 'Telechargement annule par l\'utilisateur');
    }

    // 4. Verification de taille du .part
    final partStat = await partFile.stat();
    if (partStat.size != component.expectedSizeBytes) {
      throw ImageInstallerException(
        'SIZE_MISMATCH',
        'Taille finale du fichier .part invalide pour ${component.fileName}: '
        '${partStat.size} octets (attendu: ${component.expectedSizeBytes})',
      );
    }

    // 5. Verification SHA-256 du .part
    _progressController.add(DownloadProgressEvent(
      status: ImageDownloadStatus.verifying,
      currentComponentId: component.componentId,
      currentFileName: component.fileName,
      bytesDownloaded: cumulativeBytesDownloaded + bytesReceivedForFile,
      totalBytes: totalBytesToDownload,
      progressPercentage: totalBytesToDownload > 0
          ? (cumulativeBytesDownloaded + bytesReceivedForFile) / totalBytesToDownload
          : 1.0,
    ));

    final actualSha = await ImageModelCatalogService.computeFileSha256(partFile);
    if (actualSha.toLowerCase() != component.expectedSha256.toLowerCase()) {
      try {
        await partFile.delete();
      } catch (_) {}
      throw ImageInstallerException(
        'HASH_MISMATCH',
        'SHA-256 invalide pour ${component.fileName}: $actualSha (attendu: ${component.expectedSha256})',
      );
    }

    // 6. Installation atomique : rename sur le meme volume
    _progressController.add(DownloadProgressEvent(
      status: ImageDownloadStatus.installing,
      currentComponentId: component.componentId,
      currentFileName: component.fileName,
      bytesDownloaded: cumulativeBytesDownloaded + bytesReceivedForFile,
      totalBytes: totalBytesToDownload,
      progressPercentage: 1.0,
    ));

    try {
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await partFile.rename(finalFile.path);
    } catch (e) {
      throw ImageInstallerException(
        'ATOMIC_INSTALL_ERROR',
        'Echec du renommage atomique vers ${finalFile.path}: $e',
        e,
      );
    }

    // 7. Enregistrement dans le cache d'integrite
    final finalStat = await finalFile.stat();
    await catalogService.recordVerifiedComponent(
      component.fileName,
      finalStat.size,
      finalStat.modified.millisecondsSinceEpoch,
      actualSha,
    );
  }

  /// Classification robuste des erreurs disque plein (OS code 112 Windows, 28 POSIX, ou message)
  static bool isDiskFullError(Object error) {
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      if (code == 112 || code == 28) {
        return true;
      }
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('not enough space') ||
        msg.contains('disk full') ||
        msg.contains('espace disque') ||
        msg.contains('plein') ||
        msg.contains('satur') ||
        msg.contains('no space left');
  }

  /// Traitement d'exception et requalification en codes oracles metier
  Never _classifyAndRethrow(Object e, String fileName) {
    if (_isCancelled || (e is ImageInstallerException && e.code == 'DOWNLOAD_CANCELLED')) {
      throw ImageInstallerException('DOWNLOAD_CANCELLED', 'Telechargement annule par l\'utilisateur');
    }
    if (e is ImageInstallerException) {
      throw e;
    }
    if (isDiskFullError(e)) {
      throw ImageInstallerException(
        'DOWNLOAD_DISK_FULL',
        'Espace disque sature pendant l\'ecriture de $fileName: $e',
        e,
      );
    }
    if (e is FileSystemException) {
      throw ImageInstallerException(
        'FILE_WRITE_ERROR',
        'Erreur d\'ecriture fichier sur $fileName: $e',
        e,
      );
    }
    throw ImageInstallerException(
      'DOWNLOAD_STREAM_ERROR',
      'Erreur pendant le flux de telechargement de $fileName: $e',
      e,
    );
  }

  /// Nettoyage des ressources
  void dispose() {
    if (_ownsClient) {
      _httpClient.close();
    }
    _progressController.close();
  }
}
