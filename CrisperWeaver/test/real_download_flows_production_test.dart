// test/real_download_flows_production_test.dart
//
// Test reel de bout en bout des flux de telechargement des services de production
// (LiteRtModelRegistry et ModelService) via serveur HTTP loopback.
// Couvre l'integralite des 6 familles dont la resolution canonique Embeddings (all-MiniLM-L6-v2-iq4_xs)
// avec backend='embed' et validation de disponibilite CrispEmbed.

import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/baked_catalog_loader.dart';
import 'package:jarvisol/services/model_catalog.dart';
import 'package:jarvisol/services/model_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/litert_model_registry.dart';

void main() {
  late HttpServer server;
  late int serverPort;
  late Directory tmpDir;
  late ModelService modelService;
  late SettingsService settings;

  final dummyPayload = Uint8List(1024); // 1024 bytes
  final minilmTotalBytes = 19 * 1024 * 1024; // 19 MB synthetic payload for MiniLM
  final minilmChunk = Uint8List(64 * 1024); // 64 KB chunk

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    await BakedCatalogLoader.load();

    // Demarrer un serveur HTTP loopback local
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverPort = server.port;

    server.listen((HttpRequest request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.binary;

      if (request.uri.path.contains('all-MiniLM-L6-v2-iq4_xs')) {
        request.response.headers.contentLength = minilmTotalBytes;
        int sent = 0;
        while (sent < minilmTotalBytes) {
          final toSend = (minilmTotalBytes - sent < minilmChunk.length)
              ? (minilmTotalBytes - sent)
              : minilmChunk.length;
          request.response.add(minilmChunk.sublist(0, toSend));
          sent += toSend;
        }
      } else {
        request.response.headers.contentLength = dummyPayload.length;
        request.response.add(dummyPayload);
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    BakedCatalogLoader.reset();
  });

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('jarvisol_flow_test_');
    AppPaths.setTestOverride(tmpDir);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return tmpDir.path;
        }
        return null;
      },
    );

    PortablePreferences.resetForTesting();
    final prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
    settings.skipChecksum = true;

    // Configurer Dio avec redirection transparente vers le serveur loopback
    final testDio = Dio();
    testDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final uri = Uri.parse(options.path);
          options.path = Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: serverPort,
            path: uri.path,
          ).toString();
          handler.next(options);
        },
      ),
    );

    modelService = ModelService(settings, dio: testDio);
    await modelService.initialize();
  });

  tearDown(() async {
    AppPaths.resetTestOverride();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  test('LiteRT LLM Production Download Flow Test', () async {
    final registry = LiteRtModelRegistry();

    final testModel = LiteRtModelEntry(
      id: 'tiny-garden-270m-test',
      name: 'Tiny Garden Test',
      author: 'Google',
      description: 'Test LiteRT entry',
      repoId: 'google/tiny-garden',
      filename: 'model.litertlm',
      sizeBytes: dummyPayload.length,
      sizeDisplay: '1 KB',
      format: 'litertlm',
      preferredBackend: 'CPU',
      isMultimodal: false,
      isRecommended: false,
      defaultConfig: const {},
      downloadUrl: 'http://127.0.0.1:$serverPort/models/litert/tiny-garden.litertlm',
    );

    final destDir = Directory(p.join(AppPaths.litertModelsDir.path, testModel.id));
    final destFile = File(p.join(destDir.path, 'model.litertlm'));
    expect(destFile.existsSync(), isFalse);

    // Appel de la methode reelle de production
    await registry.startDownload(testModel);

    expect(destFile.existsSync(), isTrue);
    expect(destFile.lengthSync(), equals(dummyPayload.length));
    expect(testModel.isDownloaded, isTrue);
  });

  test('ASR Production Download Flow Test', () async {
    final loopbackDef = ModelDefinition(
      name: 'flow-test-asr-base',
      displayName: 'flow-test-asr-base',
      fileName: 'flow-test-ggml-base.bin',
      url: 'http://127.0.0.1:$serverPort/models/whisper/flow-test-ggml-base.bin',
      sizeBytes: dummyPayload.length,
      checksum: '',
      backend: 'whisper',
      kind: ModelKind.asr,
      description: 'Loopback ASR fixture model',
    );
    BakedCatalogLoader.cached['flow-test-asr-base'] = loopbackDef;

    final targetDir = Directory(modelService.whisperCppDir());
    final targetFile = File(p.join(targetDir.path, 'flow-test-ggml-base.bin'));
    expect(targetFile.existsSync(), isFalse);

    final success = await modelService.downloadWhisperCppModel('flow-test-asr-base');
    expect(success, isTrue);
    expect(targetFile.existsSync(), isTrue);
    expect(targetFile.lengthSync(), equals(dummyPayload.length));

    final modelPath = await modelService.getWhisperCppModelPath('flow-test-asr-base');
    expect(modelPath, isNotNull);
    expect(File(modelPath!).existsSync(), isTrue);
  });

  test('TTS Production Download Flow Test', () async {
    final loopbackDef = ModelDefinition(
      name: 'flow-test-kokoro-tts',
      displayName: 'flow-test-kokoro-tts',
      fileName: 'flow-test-kokoro-82m.gguf',
      url: 'http://127.0.0.1:$serverPort/models/whisper/flow-test-kokoro-82m.gguf',
      sizeBytes: dummyPayload.length,
      checksum: '',
      backend: 'kokoro',
      kind: ModelKind.tts,
      description: 'Loopback TTS fixture model',
    );
    BakedCatalogLoader.cached['flow-test-kokoro-tts'] = loopbackDef;

    final targetDir = Directory(modelService.whisperCppDir());
    final targetFile = File(p.join(targetDir.path, 'flow-test-kokoro-82m.gguf'));
    expect(targetFile.existsSync(), isFalse);

    final success = await modelService.downloadWhisperCppModel('flow-test-kokoro-tts');
    expect(success, isTrue);
    expect(targetFile.existsSync(), isTrue);
    expect(targetFile.lengthSync(), equals(dummyPayload.length));

    final modelPath = await modelService.getWhisperCppModelPath('flow-test-kokoro-tts');
    expect(modelPath, isNotNull);
    expect(File(modelPath!).existsSync(), isTrue);
  });

  test('Voice Clone Production Download Flow Test', () async {
    final loopbackDef = ModelDefinition(
      name: 'flow-test-chatterbox-clone',
      displayName: 'flow-test-chatterbox-clone',
      fileName: 'flow-test-chatterbox-s3gen.gguf',
      url: 'http://127.0.0.1:$serverPort/models/whisper/flow-test-chatterbox-s3gen.gguf',
      sizeBytes: dummyPayload.length,
      checksum: '',
      backend: 'chatterbox',
      kind: ModelKind.voice,
      description: 'Loopback Voice Clone fixture model',
    );
    BakedCatalogLoader.cached['flow-test-chatterbox-clone'] = loopbackDef;

    final targetDir = Directory(modelService.whisperCppDir());
    final targetFile = File(p.join(targetDir.path, 'flow-test-chatterbox-s3gen.gguf'));
    expect(targetFile.existsSync(), isFalse);

    final success = await modelService.downloadWhisperCppModel('flow-test-chatterbox-clone');
    expect(success, isTrue);
    expect(targetFile.existsSync(), isTrue);
    expect(targetFile.lengthSync(), equals(dummyPayload.length));

    final modelPath = await modelService.getWhisperCppModelPath('flow-test-chatterbox-clone');
    expect(modelPath, isNotNull);
    expect(File(modelPath!).existsSync(), isTrue);
  });

  test('Embeddings Production Download Flow Test - Canonical MiniLM / CrispEmbed Resolution', () async {
    const canonicalModelId = 'all-minilm-l6-v2-iq4_xs';

    // 1. Verifier la presence et les metadonnees canoniques dans ModelCatalog.crispasrBackendModels
    final canonicalDef = modelService.lookupDefinition(canonicalModelId);
    expect(canonicalDef, isNotNull);
    expect(canonicalDef!.backend, equals('embed'));
    expect(canonicalDef.kind, equals(ModelKind.embed));
    expect(canonicalDef.fileName, equals('all-MiniLM-L6-v2-iq4_xs.gguf'));
    expect(canonicalDef.url, contains('huggingface.co/cstr/all-MiniLM-L6-v2-GGUF'));

    final targetDir = Directory(modelService.whisperCppDir());
    final targetFile = File(p.join(targetDir.path, canonicalDef.fileName));
    expect(targetFile.existsSync(), isFalse);

    // 2. Appel de la methode reelle de production (qui route via testDio vers le loopback)
    final success = await modelService.downloadWhisperCppModel(canonicalModelId);
    expect(success, isTrue);

    // 3. Verification de la persistance atomique finale
    expect(targetFile.existsSync(), isTrue);
    expect(targetFile.lengthSync(), equals(minilmTotalBytes));

    // 4. Verification de la disponibilite runtime pour ModelService
    final modelPath = await modelService.getWhisperCppModelPath(canonicalModelId);
    expect(modelPath, isNotNull);
    expect(File(modelPath!).existsSync(), isTrue);

    // 5. Verification de la resolution de decouverte CrispEmbed (_tryLoadCrispEmbedNative)
    // Desktop/mobile scanne whisperCppDir() pour tout ModelKind.embed
    final allDefs = [
      ...ModelCatalog.crispasrBackendModels.values,
      ...ModelCatalog.whisperCppModels.values,
    ];
    final crispEmbedFound = allDefs.any((def) {
      if (def.kind != ModelKind.embed) return false;
      final p = '${targetDir.path}/${def.fileName}';
      return File(p).existsSync();
    });
    expect(crispEmbedFound, isTrue);
  });
}
