// test/image_model_installer_p1_test.dart
//
// Suite de tests automatisee pour EXT-V1-02 Phase 1 :
// Moteur technique Image Model Installer (T01 a T25).
//
// Utilise un serveur HTTP local (dart:io loopback) et de petits fichiers factices.
// AUCUN telechargement lourd sur Internet.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:jarvisol/models/image_model_catalog.dart';
import 'package:jarvisol/services/image_model_catalog_service.dart';
import 'package:jarvisol/services/image_model_install_planner.dart';
import 'package:jarvisol/services/image_model_installer_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/utils/app_paths.dart';

class _TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _TestHttpOverrides();


  late Directory tempDir;
  late Directory tempModelsDir;
  late HttpServer testServer;
  late String serverBaseUrl;

  // Reponses controlees par chemin sur le serveur HTTP local
  final serverHandlers = <String, void Function(HttpRequest)>{};

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ext02_p1_test_');
    tempModelsDir = Directory(p.join(tempDir.path, 'models', 'Stable-diffusion'))..createSync(recursive: true);
    Directory(p.join(tempDir.path, 'data')).createSync(recursive: true);

    AppPaths.setTestOverride(tempDir);

    // Initialisation serveur HTTP loopback
    testServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverBaseUrl = 'http://${testServer.address.address}:${testServer.port}';

    testServer.listen((request) {
      final handler = serverHandlers[request.uri.path];
      if (handler != null) {
        handler(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      }
    });
  });

  tearDown(() async {
    AppPaths.resetTestOverride();
    serverHandlers.clear();
    await testServer.close(force: true);
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  String computeBytesSha256(List<int> bytes) {
    return sha256.convert(bytes).toString().toLowerCase();
  }

  group('EXT-V1-02 Phase 1 — Tests T01 a T25', () {
    // ────────────────────────────────────────────────────────────────────────
    // T01 : Catalogue valide charge
    // ────────────────────────────────────────────────────────────────────────
    test('T01: Catalogue canonique valide charge correctement', () async {
      final catalogFile = File(p.join(Directory.current.path, 'assets', 'models', 'image_model_catalog.json'));
      expect(await catalogFile.exists(), isTrue, reason: 'Le fichier image_model_catalog.json doit exister');

      final catalogJson = await catalogFile.readAsString();
      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      final catalog = await service.loadCatalog(jsonContent: catalogJson);

      expect(catalog.components.length, equals(13));
      expect(catalog.logicalModels.length, equals(8));

      // 5 GENERATION et 3 INPAINT
      final genModels = catalog.logicalModels.values.where((m) => m.category == ImageModelCategory.generation).toList();
      final inpModels = catalog.logicalModels.values.where((m) => m.category == ImageModelCategory.inpaint).toList();
      expect(genModels.length, equals(5));
      expect(inpModels.length, equals(3));

      // Verification du modele Chroma Flash
      final chroma = catalog.logicalModels['MOD_01_CHROMA_FLASH']!;
      expect(chroma.primaryComponentId, equals('CMP_04_CHROMA_FLASH_DIT'));
      expect(chroma.requiredComponentIds, contains('CMP_03_AE_SHARED'));
      expect(chroma.requiredComponentIds, contains('CMP_12_T5XXL_SHARED'));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T02 : Catalogue invalide rejete (empty SHA, malforme, URL, taille, etc.)
    // ────────────────────────────────────────────────────────────────────────
    test('T02: Catalogue invalide rejete avec INVALID_CATALOG_ENTRY', () {
      final service = ImageModelCatalogService(modelsDir: tempModelsDir);

      // SHA vide
      expect(
        () => service.parseCatalogJson('''{
          "schema_version": "1.0.0",
          "components": [{
            "component_id": "C1", "file_name": "f1.bin", "relative_install_path": "f1.bin",
            "download_url": "http://example.com/f1.bin", "expected_sha256": "",
            "expected_size_bytes": 100, "is_shared_dependency": false, "license_id": "L1"
          }],
          "logical_models": []
        }'''),
        throwsA(isA<InvalidCatalogException>().having((e) => e.code, 'code', 'INVALID_CATALOG_ENTRY')),
      );

      // SHA non-hex ou mauvaise longueur
      expect(
        () => service.parseCatalogJson('''{
          "schema_version": "1.0.0",
          "components": [{
            "component_id": "C1", "file_name": "f1.bin", "relative_install_path": "f1.bin",
            "download_url": "http://example.com/f1.bin", "expected_sha256": "not_a_sha256",
            "expected_size_bytes": 100, "is_shared_dependency": false, "license_id": "L1"
          }],
          "logical_models": []
        }'''),
        throwsA(isA<InvalidCatalogException>()),
      );

      // Taille <= 0
      expect(
        () => service.parseCatalogJson('''{
          "schema_version": "1.0.0",
          "components": [{
            "component_id": "C1", "file_name": "f1.bin", "relative_install_path": "f1.bin",
            "download_url": "http://example.com/f1.bin", "expected_sha256": "${'a' * 64}",
            "expected_size_bytes": 0, "is_shared_dependency": false, "license_id": "L1"
          }],
          "logical_models": []
        }'''),
        throwsA(isA<InvalidCatalogException>()),
      );

      // URL vide
      expect(
        () => service.parseCatalogJson('''{
          "schema_version": "1.0.0",
          "components": [{
            "component_id": "C1", "file_name": "f1.bin", "relative_install_path": "f1.bin",
            "download_url": "", "expected_sha256": "${'a' * 64}",
            "expected_size_bytes": 100, "is_shared_dependency": false, "license_id": "L1"
          }],
          "logical_models": []
        }'''),
        throwsA(isA<InvalidCatalogException>()),
      );

      // Composant duplique
      expect(
        () => service.parseCatalogJson('''{
          "schema_version": "1.0.0",
          "components": [
            { "component_id": "C1", "file_name": "f1.bin", "download_url": "http://e.com/1", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 10, "license_id": "L1" },
            { "component_id": "C1", "file_name": "f2.bin", "download_url": "http://e.com/2", "expected_sha256": "${'b' * 64}", "expected_size_bytes": 20, "license_id": "L1" }
          ],
          "logical_models": []
        }'''),
        throwsA(isA<InvalidCatalogException>()),
      );

      // Modele sans primaryComponent
      expect(
        () => service.parseCatalogJson('''{
          "schema_version": "1.0.0",
          "components": [
            { "component_id": "C1", "file_name": "f1.bin", "download_url": "http://e.com/1", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 10, "license_id": "L1" }
          ],
          "logical_models": [
            { "logical_model_id": "M1", "display_name": "M1", "category": "GENERATION", "primary_component_id": "", "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
          ]
        }'''),
        throwsA(isA<InvalidCatalogException>()),
      );

      // Dependance requise inconnue
      expect(
        () => service.parseCatalogJson('''{
          "schema_version": "1.0.0",
          "components": [
            { "component_id": "C1", "file_name": "f1.bin", "download_url": "http://e.com/1", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 10, "license_id": "L1" }
          ],
          "logical_models": [
            { "logical_model_id": "M1", "display_name": "M1", "category": "GENERATION", "primary_component_id": "C1", "required_component_ids": ["C1", "C_UNKNOWN"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
          ]
        }'''),
        throwsA(isA<InvalidCatalogException>()),
      );
    });

    // ────────────────────────────────────────────────────────────────────────
    // T03 : Logical model avec dependances partagees
    // ────────────────────────────────────────────────────────────────────────
    test('T03: Logical model avec dependances partagees est correctement mappe', () async {
      final catalogFile = File(p.join(Directory.current.path, 'assets', 'models', 'image_model_catalog.json'));
      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      final catalog = await service.loadCatalog(jsonContent: await catalogFile.readAsString());

      final flux = catalog.logicalModels['MOD_02_FLUX1_SCHNELL']!;
      expect(flux.sharedDependencyIds, contains('CMP_03_AE_SHARED'));
      expect(flux.sharedDependencyIds, contains('CMP_06_CLIP_L_SHARED'));
      expect(flux.sharedDependencyIds, contains('CMP_12_T5XXL_SHARED'));
      expect(flux.requiredComponentIds.length, equals(4)); // primary + 3 shared
    });

    // ────────────────────────────────────────────────────────────────────────
    // T04 : Deduplication des dependances partagees
    // ────────────────────────────────────────────────────────────────────────
    test('T04: Deduplication stricte des dependances partagees dans le plan', () async {
      final catalogFile = File(p.join(Directory.current.path, 'assets', 'models', 'image_model_catalog.json'));
      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: await catalogFile.readAsString());

      final planner = ImageModelInstallPlanner(catalogService: service);
      final plan = await planner.buildPlan(
        targetLogicalModelIds: ['MOD_01_CHROMA_FLASH', 'MOD_02_FLUX1_SCHNELL'],
        checkDiskSpace: false,
      );

      // Chroma necessite CMP_04, CMP_03 (ae), CMP_12 (t5xxl)
      // Flux necessite CMP_07, CMP_03 (ae), CMP_06 (clip_l), CMP_12 (t5xxl)
      // Union dedupliquee : CMP_04, CMP_07, CMP_03, CMP_06, CMP_12 (5 composants au total)
      final compIds = plan.componentsToDownload.map((c) => c.componentId).toList();
      expect(compIds.length, equals(5));
      expect(compIds.toSet().length, equals(5));
      expect(compIds, contains('CMP_03_AE_SHARED'));
      expect(compIds, contains('CMP_12_T5XXL_SHARED'));
      expect(compIds.where((id) => id == 'CMP_03_AE_SHARED').length, equals(1));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T05 : Calcul exact des tailles
    // ────────────────────────────────────────────────────────────────────────
    test('T05: Calcul exact de downloadRequiredBytes, totalRequiredBytes et overhead', () async {
      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C1", "file_name": "f1.bin", "download_url": "http://e.com/1", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 1000, "is_shared_dependency": false, "license_id": "L1" },
          { "component_id": "C2", "file_name": "f2.bin", "download_url": "http://e.com/2", "expected_sha256": "${'b' * 64}", "expected_size_bytes": 2000, "is_shared_dependency": false, "license_id": "L1" },
          { "component_id": "C_SHARED", "file_name": "shared.bin", "download_url": "http://e.com/s", "expected_sha256": "${'c' * 64}", "expected_size_bytes": 500, "is_shared_dependency": true, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M1", "display_name": "M1", "category": "GENERATION", "primary_component_id": "C1", "required_component_ids": ["C1", "C_SHARED"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" },
          { "logical_model_id": "M2", "display_name": "M2", "category": "GENERATION", "primary_component_id": "C2", "required_component_ids": ["C2", "C_SHARED"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service);
      final plan = await planner.buildPlan(
        targetLogicalModelIds: ['M1', 'M2'],
        checkDiskSpace: false,
      );

      // C1 (1000) + C2 (2000) + C_SHARED (500) = 3500
      expect(plan.totalRequiredBytes, equals(3500));
      expect(plan.downloadRequiredBytes, equals(3500));
      expect(plan.alreadyInstalledBytes, equals(0));
      expect(plan.temporaryOverheadBytes, equals(2000)); // taille du plus gros composant en sequentiel
    });

    // ────────────────────────────────────────────────────────────────────────
    // T06 : Disque insuffisant avant download (DISK_SPACE_INSUFFICIENT)
    // ────────────────────────────────────────────────────────────────────────
    test('T06: Disque insuffisant bloque avant telechargement avec DISK_SPACE_INSUFFICIENT', () async {
      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C1", "file_name": "f1.bin", "download_url": "http://e.com/1", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 10000000, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M1", "display_name": "M1", "category": "GENERATION", "primary_component_id": "C1", "required_component_ids": ["C1"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(
        catalogService: service,
        diskSpaceProbe: (path) => 500, // seulement 500 octets disponibles
      );

      final plan = await planner.buildPlan(
        targetLogicalModelIds: ['M1'],
        checkDiskSpace: true,
      );

      expect(plan.isDiskSpaceSufficient, isFalse);
      expect(plan.availableFreeDiskBytes, equals(500));

      final installer = ImageModelInstallerService(catalogService: service);
      await expectLater(
        () => installer.executePlan(plan),
        throwsA(isA<ImageInstallerException>().having((e) => e.code, 'code', 'DISK_SPACE_INSUFFICIENT')),
      );
    });

    // ────────────────────────────────────────────────────────────────────────
    // T07 : Download neuf -> .part -> hash -> atomic install
    // ────────────────────────────────────────────────────────────────────────
    test('T07: Download neuf -> .part -> verification SHA-256 -> installation atomique', () async {
      final payload = utf8.encode('Hello, Jarvisol model binary content test T07!');
      final expectedSha = computeBytesSha256(payload);

      serverHandlers['/model_t07.bin'] = (request) {
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.contentLength = payload.length;
        request.response.statusCode = HttpStatus.ok;
        request.response.add(payload);
        request.response.close();
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_T07", "file_name": "model_t07.bin", "download_url": "$serverBaseUrl/model_t07.bin", "expected_sha256": "$expectedSha", "expected_size_bytes": ${payload.length}, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_T07", "display_name": "M T07", "category": "GENERATION", "primary_component_id": "C_T07", "required_component_ids": ["C_T07"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 1000000000);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_T07']);

      final installer = ImageModelInstallerService(catalogService: service);
      await installer.executePlan(plan);

      final finalFile = File(p.join(tempModelsDir.path, 'model_t07.bin'));
      final partFile = File(p.join(tempModelsDir.path, 'model_t07.bin.part'));

      expect(await finalFile.exists(), isTrue);
      expect(await partFile.exists(), isFalse); // Supprime / renomme atomiquement
      expect(await finalFile.length(), equals(payload.length));
      expect(await ImageModelCatalogService.computeFileSha256(finalFile), equals(expectedSha));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T08 : Resume depuis .part avec HTTP 206
    // ────────────────────────────────────────────────────────────────────────
    test('T08: Reprise de telechargement depuis .part avec HTTP 206', () async {
      final payload = utf8.encode('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz');
      final expectedSha = computeBytesSha256(payload);
      const splitOffset = 20;

      // Creer le fichier partiel .part avec les 20 premiers octets
      final partFile = File(p.join(tempModelsDir.path, 'resume_model.bin.part'));
      await partFile.writeAsBytes(payload.sublist(0, splitOffset), flush: true);

      var receivedRangeHeader = '';
      serverHandlers['/resume_model.bin'] = (request) {
        final range = request.headers.value('range');
        receivedRangeHeader = range ?? '';

        if (range == 'bytes=$splitOffset-') {
          final chunk = payload.sublist(splitOffset);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('Content-Range', 'bytes $splitOffset-${payload.length - 1}/${payload.length}');
          request.response.headers.contentLength = chunk.length;
          request.response.add(chunk);
          request.response.close();
        } else {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.close();
        }
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_RESUME", "file_name": "resume_model.bin", "download_url": "$serverBaseUrl/resume_model.bin", "expected_sha256": "$expectedSha", "expected_size_bytes": ${payload.length}, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_RESUME", "display_name": "M Resume", "category": "GENERATION", "primary_component_id": "C_RESUME", "required_component_ids": ["C_RESUME"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 1000000000);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_RESUME']);

      final installer = ImageModelInstallerService(catalogService: service);
      await installer.executePlan(plan);

      expect(receivedRangeHeader, equals('bytes=$splitOffset-'));
      final finalFile = File(p.join(tempModelsDir.path, 'resume_model.bin'));
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), equals(payload.length));
      expect(await ImageModelCatalogService.computeFileSha256(finalFile), equals(expectedSha));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T09 : Serveur ignore Range et retourne 200
    // ────────────────────────────────────────────────────────────────────────
    test('T09: Serveur ignorant Range et renvoyant HTTP 200 recommence proprement de zero', () async {
      final payload = utf8.encode('Full payload served when server ignores Range completely!');
      final expectedSha = computeBytesSha256(payload);

      // Pre-creer un .part avec un residu quelconque
      final partFile = File(p.join(tempModelsDir.path, 'no_range.bin.part'));
      await partFile.writeAsBytes(utf8.encode('junk data before reset'), flush: true);

      serverHandlers['/no_range.bin'] = (request) {
        // Renvoie toujours 200 avec la totalite
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = payload.length;
        request.response.add(payload);
        request.response.close();
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_NORANGE", "file_name": "no_range.bin", "download_url": "$serverBaseUrl/no_range.bin", "expected_sha256": "$expectedSha", "expected_size_bytes": ${payload.length}, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_NORANGE", "display_name": "M No Range", "category": "GENERATION", "primary_component_id": "C_NORANGE", "required_component_ids": ["C_NORANGE"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 1000000000);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_NORANGE']);

      final installer = ImageModelInstallerService(catalogService: service);
      await installer.executePlan(plan);

      final finalFile = File(p.join(tempModelsDir.path, 'no_range.bin'));
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), equals(payload.length));
      expect(await ImageModelCatalogService.computeFileSha256(finalFile), equals(expectedSha));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T10 : Content-Range incoherent
    // ────────────────────────────────────────────────────────────────────────
    test('T10: Content-Range incoherent detecte et signale REMOTE_ARTIFACT_CHANGED', () async {
      final payload = utf8.encode('Test payload for inconsistent content range');
      final partFile = File(p.join(tempModelsDir.path, 'bad_range.bin.part'));
      await partFile.writeAsBytes(payload.sublist(0, 10), flush: true);

      serverHandlers['/bad_range.bin'] = (request) {
        // Envoie un Content-Range avec start = 0 alors que le client a demande start = 10
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('Content-Range', 'bytes 0-${payload.length - 1}/${payload.length}');
        request.response.add(payload);
        request.response.close();
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_BADRANGE", "file_name": "bad_range.bin", "download_url": "$serverBaseUrl/bad_range.bin", "expected_sha256": "${'a' * 64}", "expected_size_bytes": ${payload.length}, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_BADRANGE", "display_name": "M Bad Range", "category": "GENERATION", "primary_component_id": "C_BADRANGE", "required_component_ids": ["C_BADRANGE"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 1000000000);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_BADRANGE']);

      final installer = ImageModelInstallerService(catalogService: service);
      await expectLater(
        () => installer.executePlan(plan),
        throwsA(isA<ImageInstallerException>().having((e) => e.code, 'code', 'REMOTE_ARTIFACT_CHANGED')),
      );
    });

    // ────────────────────────────────────────────────────────────────────────
    // T11 : Annulation et .part coherent
    // ────────────────────────────────────────────────────────────────────────
    test('T11: Annulation propre avec preservation du .part et liberation des flux', () async {
      final payload = Uint8List(100000);

      serverHandlers['/cancel_test.bin'] = (request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = payload.length;
        request.response.add(payload.sublist(0, 1000));
        await request.response.flush();
        // Attendre un peu pour laisser le client recevoir et annuler
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          request.response.add(payload.sublist(1000));
          await request.response.close();
        } catch (_) {}
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_CANCEL", "file_name": "cancel_test.bin", "download_url": "$serverBaseUrl/cancel_test.bin", "expected_sha256": "${'a' * 64}", "expected_size_bytes": ${payload.length}, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_CANCEL", "display_name": "M Cancel", "category": "GENERATION", "primary_component_id": "C_CANCEL", "required_component_ids": ["C_CANCEL"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 1000000000);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_CANCEL']);

      final installer = ImageModelInstallerService(catalogService: service);

      installer.progressStream.listen((event) {
        if (event.status == ImageDownloadStatus.downloading && event.bytesDownloaded > 0) {
          installer.cancel();
        }
      });

      await expectLater(
        () => installer.executePlan(plan),
        throwsA(isA<ImageInstallerException>().having((e) => e.code, 'code', 'DOWNLOAD_CANCELLED')),
      );

      final partFile = File(p.join(tempModelsDir.path, 'cancel_test.bin.part'));
      expect(await partFile.exists(), isTrue);
      expect(await partFile.length(), greaterThan(0));

      final finalFile = File(p.join(tempModelsDir.path, 'cancel_test.bin'));
      expect(await finalFile.exists(), isFalse); // Pas de fichier final a moitie ecrit
    });

    // ────────────────────────────────────────────────────────────────────────
    // T12 : Hash mismatch
    // ────────────────────────────────────────────────────────────────────────
    test('T12: Hash mismatch rejete, supprime le .part et ne cree jamais le fichier final', () async {
      final payload = utf8.encode('Corrupted data with mismatched sha256');
      final wrongExpectedSha = '0' * 64;

      serverHandlers['/corrupt.bin'] = (request) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = payload.length;
        request.response.add(payload);
        request.response.close();
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_CORRUPT", "file_name": "corrupt.bin", "download_url": "$serverBaseUrl/corrupt.bin", "expected_sha256": "$wrongExpectedSha", "expected_size_bytes": ${payload.length}, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_CORRUPT", "display_name": "M Corrupt", "category": "GENERATION", "primary_component_id": "C_CORRUPT", "required_component_ids": ["C_CORRUPT"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 1000000000);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_CORRUPT']);

      final installer = ImageModelInstallerService(catalogService: service);

      await expectLater(
        () => installer.executePlan(plan),
        throwsA(isA<ImageInstallerException>().having((e) => e.code, 'code', 'HASH_MISMATCH')),
      );

      final finalFile = File(p.join(tempModelsDir.path, 'corrupt.bin'));
      expect(await finalFile.exists(), isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // T13 : Fichier final deja installe et hash correct
    // ────────────────────────────────────────────────────────────────────────
    test('T13: Fichier final deja installe et verifie est ignore dans le plan', () async {
      final payload = utf8.encode('Already installed valid binary model');
      final expectedSha = computeBytesSha256(payload);

      final finalFile = File(p.join(tempModelsDir.path, 'installed.bin'));
      await finalFile.writeAsBytes(payload, flush: true);

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_INSTALLED", "file_name": "installed.bin", "download_url": "http://e.com/i", "expected_sha256": "$expectedSha", "expected_size_bytes": ${payload.length}, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_INSTALLED", "display_name": "M Installed", "category": "GENERATION", "primary_component_id": "C_INSTALLED", "required_component_ids": ["C_INSTALLED"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      // Pre-verifier avec SHA pour le marquer verifie
      final status = await service.detectComponentStatus(service.catalog.components['C_INSTALLED']!, verifySha: true);
      expect(status.state, equals(ComponentVerificationState.installedVerified));

      final planner = ImageModelInstallPlanner(catalogService: service);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_INSTALLED'], checkDiskSpace: false);

      expect(plan.componentsToDownload.length, equals(0));
      expect(plan.alreadyInstalledComponents.length, equals(1));
      expect(plan.downloadRequiredBytes, equals(0));
      expect(plan.alreadyInstalledBytes, equals(payload.length));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T14 : Fichier final present hash faux
    // ────────────────────────────────────────────────────────────────────────
    test('T14: Fichier final present avec taille ou hash faux detecte CORRUPT_OR_MISMATCH', () async {
      final finalFile = File(p.join(tempModelsDir.path, 'corrupted_final.bin'));
      await finalFile.writeAsBytes(utf8.encode('wrong content on disk'), flush: true);

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_CF", "file_name": "corrupted_final.bin", "download_url": "http://e.com/cf", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 50000, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_CF", "display_name": "M CF", "category": "GENERATION", "primary_component_id": "C_CF", "required_component_ids": ["C_CF"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final status = await service.detectComponentStatus(service.catalog.components['C_CF']!, verifySha: false);
      expect(status.state, equals(ComponentVerificationState.corruptOrMismatch));

      final modelStatus = await service.getLogicalModelStatus('M_CF');
      expect(modelStatus.state, equals(LogicalModelInstallState.corrupt));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T15 : Partiellement installe logical model
    // ────────────────────────────────────────────────────────────────────────
    test('T15: Modele logique partiellement installe detecte PARTIALLY_INSTALLED', () async {
      final payload1 = utf8.encode('Component 1 installed');
      final sha1 = computeBytesSha256(payload1);

      await File(p.join(tempModelsDir.path, 'comp1.bin')).writeAsBytes(payload1, flush: true);

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C1", "file_name": "comp1.bin", "download_url": "http://e.com/1", "expected_sha256": "$sha1", "expected_size_bytes": ${payload1.length}, "is_shared_dependency": false, "license_id": "L1" },
          { "component_id": "C2", "file_name": "comp2.bin", "download_url": "http://e.com/2", "expected_sha256": "${'b' * 64}", "expected_size_bytes": 1000, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_PARTIAL", "display_name": "M Partial", "category": "GENERATION", "primary_component_id": "C1", "required_component_ids": ["C1", "C2"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      // Verifier comp1 avec SHA
      await service.detectComponentStatus(service.catalog.components['C1']!, verifySha: true);

      final modelStatus = await service.getLogicalModelStatus('M_PARTIAL');
      expect(modelStatus.state, equals(LogicalModelInstallState.partiallyInstalled));
      expect(modelStatus.missingComponentIds, equals(['C2']));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T16 : Shared dependency deja installee
    // ────────────────────────────────────────────────────────────────────────
    test('T16: Shared dependency deja installee est omise du telechargement', () async {
      final sharedPayload = utf8.encode('Shared VAE component installed');
      final sharedSha = computeBytesSha256(sharedPayload);

      await File(p.join(tempModelsDir.path, 'shared_vae.bin')).writeAsBytes(sharedPayload, flush: true);

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_MAIN", "file_name": "main.bin", "download_url": "http://e.com/main", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 2000, "is_shared_dependency": false, "license_id": "L1" },
          { "component_id": "C_SHARED", "file_name": "shared_vae.bin", "download_url": "http://e.com/s", "expected_sha256": "$sharedSha", "expected_size_bytes": ${sharedPayload.length}, "is_shared_dependency": true, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_SHARED", "display_name": "M Shared", "category": "GENERATION", "primary_component_id": "C_MAIN", "required_component_ids": ["C_MAIN", "C_SHARED"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);
      await service.detectComponentStatus(service.catalog.components['C_SHARED']!, verifySha: true);

      final planner = ImageModelInstallPlanner(catalogService: service);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_SHARED'], checkDiskSpace: false);

      expect(plan.componentsToDownload.length, equals(1));
      expect(plan.componentsToDownload.first.componentId, equals('C_MAIN'));
      expect(plan.alreadyInstalledComponents.first.componentId, equals('C_SHARED'));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T17 : License acceptance required
    // ────────────────────────────────────────────────────────────────────────
    test('T17: Modeles necessitant acceptation de licence bloquent sans confirmation explicite', () async {
      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_STABILITY", "file_name": "sd35.bin", "download_url": "http://e.com/sd35", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 1000, "is_shared_dependency": false, "license_id": "LIC_STABILITY" }
        ],
        "logical_models": [
          { "logical_model_id": "M_SD35", "display_name": "SD 3.5", "category": "GENERATION", "primary_component_id": "C_STABILITY", "required_component_ids": ["C_STABILITY"], "license_id": "LIC_STABILITY", "license_status": "LICENSE_REQUIRES_USER_ACCEPTANCE", "distribution_strategy": "S", "requires_user_acceptance": true, "installer_readiness": "READY_WITH_USER_ACCEPTANCE_FLOW" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 1000000000);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_SD35']);

      expect(plan.requiresLicenseAcceptance, isTrue);
      expect(plan.unacceptedLicenseModelIds, equals(['M_SD35']));

      final installer = ImageModelInstallerService(catalogService: service);

      // Bloque si acceptedLicenses = false
      await expectLater(
        () => installer.executePlan(plan, acceptedLicenses: false),
        throwsA(isA<ImageInstallerException>().having((e) => e.code, 'code', 'LICENSE_ACCEPTANCE_REQUIRED')),
      );
    });

    // ────────────────────────────────────────────────────────────────────────
    // T18 : Aucune modification active_image_model
    // ────────────────────────────────────────────────────────────────────────
    test('T18: Aucune modification de active_image_model lors du cycle installer', () async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);
      settings.activeImageModel = 'initial_test_image_model';

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C1", "file_name": "dummy.bin", "download_url": "http://e.com/1", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 10, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M1", "display_name": "M1", "category": "GENERATION", "primary_component_id": "C1", "required_component_ids": ["C1"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service);
      await planner.buildPlan(targetLogicalModelIds: ['M1'], checkDiskSpace: false);

      expect(settings.activeImageModel, equals('initial_test_image_model'));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T19 : Aucune modification active_inpaint_model
    // ────────────────────────────────────────────────────────────────────────
    test('T19: Aucune modification de active_inpaint_model lors du cycle installer', () async {
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);
      settings.activeInpaintModel = 'initial_test_inpaint_model';

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C1", "file_name": "dummy.bin", "download_url": "http://e.com/1", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 10, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M1", "display_name": "M1", "category": "INPAINT", "primary_component_id": "C1", "required_component_ids": ["C1"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service);
      await planner.buildPlan(targetLogicalModelIds: ['M1'], checkDiskSpace: false);

      expect(settings.activeInpaintModel, equals('initial_test_inpaint_model'));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T20 : Aucun path absolu dependant du PC de developpement
    // ────────────────────────────────────────────────────────────────────────
    test('T20: Le catalogue ne contient aucun chemin absolu dependant du PC de developpement', () async {
      final catalogFile = File(p.join(Directory.current.path, 'assets', 'models', 'image_model_catalog.json'));
      final content = await catalogFile.readAsString();

      expect(content.contains(r'C:\Users\'), isFalse);
      expect(content.contains(r'D:\Antigravity'), isFalse);
      expect(content.contains(r'/Users/'), isFalse);
      expect(content.contains(r'/home/'), isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // T21 : Download path depend de la racine portable reelle
    // ────────────────────────────────────────────────────────────────────────
    test('T21: Repertoire d\'installation depend dynamiquement de AppPaths.imageModelsDir', () {
      final customDir = Directory(p.join(tempDir.path, 'custom_portable_root'))..createSync(recursive: true);
      AppPaths.setTestOverride(customDir);

      final expectedPath = p.join(customDir.path, 'models', 'Stable-diffusion');
      expect(AppPaths.imageModelsDir.path, equals(expectedPath));

      final service = ImageModelCatalogService();
      expect(service.modelsDir.path, equals(expectedPath));
    });

    // ────────────────────────────────────────────────────────────────────────
    // T22 : Nom de fichier / path traversal malveillant rejete
    // ────────────────────────────────────────────────────────────────────────
    test('T22: Tentatives de path traversal rejetees par la validation', () {
      final invalidPaths = [
        '../evil.bin',
        '..\\\\evil.bin',
        '/evil.bin',
        r'C:\Windows\System32\cmd.exe',
        r'\\remote_server\share\evil.bin',
        'sub/../../evil.bin',
      ];

      for (final badPath in invalidPaths) {
        expect(
          () => PhysicalComponent.validateComponentData(
            componentId: 'BAD',
            fileName: badPath,
            relativeInstallPath: badPath,
            downloadUrl: 'https://example.com/file.bin',
            expectedSha256: 'a' * 64,
            expectedSizeBytes: 100,
          ),
          throwsA(isA<InvalidCatalogException>().having((e) => e.code, 'code', 'INVALID_CATALOG_ENTRY')),
          reason: 'Doit rejeter $badPath',
        );
      }
    });

    // ────────────────────────────────────────────────────────────────────────
    // T23 : URL non HTTP/HTTPS rejetee
    // ────────────────────────────────────────────────────────────────────────
    test('T23: URL non HTTP/HTTPS rejetee par la validation', () {
      final badUrls = [
        'ftp://example.com/file.bin',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'data:text/plain;base64,AAAA',
        'gopher://example.com',
      ];

      for (final badUrl in badUrls) {
        expect(
          () => PhysicalComponent.validateComponentData(
            componentId: 'BAD_URL',
            fileName: 'file.bin',
            relativeInstallPath: 'file.bin',
            downloadUrl: badUrl,
            expectedSha256: 'a' * 64,
            expectedSizeBytes: 100,
          ),
          throwsA(isA<InvalidCatalogException>().having((e) => e.code, 'code', 'INVALID_CATALOG_ENTRY')),
          reason: 'Doit rejeter $badUrl',
        );
      }
    });

    // ────────────────────────────────────────────────────────────────────────
    // T24 : Cleanup file handles apres erreur
    // ────────────────────────────────────────────────────────────────────────
    test('T24: Nettoyage et fermeture des descripteurs de fichiers apres erreur', () async {
      serverHandlers['/error_stream.bin'] = (request) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.close();
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C_ERR", "file_name": "error_stream.bin", "download_url": "$serverBaseUrl/error_stream.bin", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 1000, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M_ERR", "display_name": "M ERR", "category": "GENERATION", "primary_component_id": "C_ERR", "required_component_ids": ["C_ERR"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 1000000000);
      final plan = await planner.buildPlan(targetLogicalModelIds: ['M_ERR']);

      final installer = ImageModelInstallerService(catalogService: service);

      try {
        await installer.executePlan(plan);
      } catch (_) {}

      // Verifier qu'aucun verrou de fichier n'est actif sur le dossier ou les fichiers partiels
      final testFile = File(p.join(tempModelsDir.path, 'error_stream.bin.part'));
      if (await testFile.exists()) {
        expect(() => testFile.deleteSync(), returnsNormally);
      }
    });

    // ────────────────────────────────────────────────────────────────────────
    // T25 : Aucun credential ecrit dans logs / errors
    // ────────────────────────────────────────────────────────────────────────
    test('T25: Aucun secret, token personnel ou header d\'auth dans les logs ou messages d\'erreur', () async {
      final events = <DownloadProgressEvent>[];
      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          { "component_id": "C1", "file_name": "sec.bin", "download_url": "http://e.com/sec", "expected_sha256": "${'a' * 64}", "expected_size_bytes": 100, "is_shared_dependency": false, "license_id": "L1" }
        ],
        "logical_models": [
          { "logical_model_id": "M1", "display_name": "M1", "category": "GENERATION", "primary_component_id": "C1", "required_component_ids": ["C1"], "license_id": "L1", "license_status": "OK", "distribution_strategy": "S", "requires_user_acceptance": false, "installer_readiness": "READY" }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final installer = ImageModelInstallerService(catalogService: service);
      installer.progressStream.listen(events.add);

      // Simuler une exception
      try {
        final plan = await ImageModelInstallPlanner(catalogService: service, diskSpaceProbe: (_) => 10)
            .buildPlan(targetLogicalModelIds: ['M1']);
        await installer.executePlan(plan);
      } catch (e) {
        final errStr = e.toString();
        expect(errStr.contains('hf_'), isFalse);
        expect(errStr.contains('AIza'), isFalse);
        expect(errStr.contains('Bearer'), isFalse);
        expect(errStr.contains('client_secret'), isFalse);
      }

      for (final ev in events) {
        final str = ev.toString();
        expect(str.contains('hf_'), isFalse);
        expect(str.contains('AIza'), isFalse);
        expect(str.contains('Bearer'), isFalse);
        expect(str.contains('client_secret'), isFalse);
      }
    });

    // ────────────────────────────────────────────────────────────────────────
    // T26 : DOWNLOAD_DISK_FULL pendant le telechargement streaming sur .part
    // ────────────────────────────────────────────────────────────────────────
    test('T26: DOWNLOAD_DISK_FULL: interruption propre et liberation des ressources si disque plein pendant ecriture sur .part', () async {
      final bytes = List<int>.generate(100, (i) => i % 256);
      serverHandlers['/disk_full_model.bin'] = (request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 50));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        request.response.add(bytes.sublist(50));
        await request.response.close();
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          {
            "component_id": "CMP_DISK_FULL",
            "file_name": "disk_full_model.bin",
            "download_url": "$serverBaseUrl/disk_full_model.bin",
            "expected_sha256": "${sha256.convert(bytes).toString()}",
            "expected_size_bytes": 100,
            "is_shared_dependency": false,
            "license_id": "L1"
          }
        ],
        "logical_models": [
          {
            "logical_model_id": "MOD_DISK_FULL",
            "display_name": "Disk Full Test Model",
            "category": "GENERATION",
            "primary_component_id": "CMP_DISK_FULL",
            "required_component_ids": ["CMP_DISK_FULL"],
            "license_id": "L1",
            "license_status": "OK",
            "distribution_strategy": "S",
            "requires_user_acceptance": false,
            "installer_readiness": "READY"
          }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(
        catalogService: service,
        diskSpaceProbe: (_) => 200 * 1024 * 1024,
      );
      final plan = await planner.buildPlan(targetLogicalModelIds: ['MOD_DISK_FULL']);

      final installer = ImageModelInstallerService(
        catalogService: service,
        diskSpaceProbe: (_) => 200 * 1024 * 1024,
        writerFactory: (file, mode, startOffset) async {
          final realWriter = await DefaultRafChunkWriter.open(file, mode, startOffset);
          return MockFailingChunkWriter(realWriter, failAfterBytes: 60);
        },
      );

      final finalFile = File(p.join(tempModelsDir.path, 'disk_full_model.bin'));
      final partFile = File(p.join(tempModelsDir.path, 'disk_full_model.bin.part'));

      ImageInstallerException? thrownEx;
      try {
        await installer.executePlan(plan);
      } on ImageInstallerException catch (e) {
        thrownEx = e;
      }

      expect(thrownEx, isNotNull);
      expect(thrownEx!.code, equals('DOWNLOAD_DISK_FULL'));
      expect(await finalFile.exists(), isFalse, reason: 'Le fichier final ne doit pas apparaitre en cas de disk full');
      expect(await partFile.exists(), isTrue, reason: 'Le .part doit exister pour reprise future');
      final partStat = await partFile.stat();
      expect(partStat.size, equals(60));
      expect(() => partFile.deleteSync(), returnsNormally, reason: 'Handles de fichier doivent etre completement liberes');
    });

    // ────────────────────────────────────────────────────────────────────────
    // T27 : DOWNLOAD_DISK_FULL a la finalisation / flush de l'ecriture
    // ────────────────────────────────────────────────────────────────────────
    test('T27: DOWNLOAD_DISK_FULL a la finalisation/flush du flux d\'ecriture meme si les chunks semblent ecrits', () async {
      final bytes = List<int>.generate(100, (i) => i % 256);
      serverHandlers['/disk_full_flush.bin'] = (request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          {
            "component_id": "CMP_DISK_FULL_FLUSH",
            "file_name": "disk_full_flush.bin",
            "download_url": "$serverBaseUrl/disk_full_flush.bin",
            "expected_sha256": "${sha256.convert(bytes).toString()}",
            "expected_size_bytes": 100,
            "is_shared_dependency": false,
            "license_id": "L1"
          }
        ],
        "logical_models": [
          {
            "logical_model_id": "MOD_DISK_FULL_FLUSH",
            "display_name": "Disk Full Flush Test Model",
            "category": "GENERATION",
            "primary_component_id": "CMP_DISK_FULL_FLUSH",
            "required_component_ids": ["CMP_DISK_FULL_FLUSH"],
            "license_id": "L1",
            "license_status": "OK",
            "distribution_strategy": "S",
            "requires_user_acceptance": false,
            "installer_readiness": "READY"
          }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: tempModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(
        catalogService: service,
        diskSpaceProbe: (_) => 200 * 1024 * 1024,
      );
      final plan = await planner.buildPlan(targetLogicalModelIds: ['MOD_DISK_FULL_FLUSH']);

      final installer = ImageModelInstallerService(
        catalogService: service,
        diskSpaceProbe: (_) => 200 * 1024 * 1024,
        writerFactory: (file, mode, startOffset) async {
          final realWriter = await DefaultRafChunkWriter.open(file, mode, startOffset);
          return MockFailingChunkWriter(realWriter, failOnFlush: true);
        },
      );

      final finalFile = File(p.join(tempModelsDir.path, 'disk_full_flush.bin'));
      final partFile = File(p.join(tempModelsDir.path, 'disk_full_flush.bin.part'));

      ImageInstallerException? thrownEx;
      try {
        await installer.executePlan(plan);
      } on ImageInstallerException catch (e) {
        thrownEx = e;
      }

      expect(thrownEx, isNotNull, reason: 'Une exception ImageInstallerException doit etre levee');
      expect(thrownEx!.code, equals('DOWNLOAD_DISK_FULL'),
          reason: 'L\'oracle DOIT etre DOWNLOAD_DISK_FULL et non SIZE_MISMATCH ou HASH_MISMATCH');
      expect(await finalFile.exists(), isFalse, reason: 'Le fichier final ne doit jamais apparaitre');
      expect(await partFile.exists(), isTrue, reason: 'Le .part doit exister');
      expect(() => partFile.deleteSync(), returnsNormally, reason: 'Les handles doivent etre proprement liberes');
    });

    // T28: Installation reussie meme si models/Stable-diffusion est initialement absent
    test('T28: models/Stable-diffusion absent -> creation automatique du dossier et installation complete', () async {
      final absentModelsDir = Directory(p.join(tempDir.path, 'absent_models_dir', 'nested_sd'));
      if (absentModelsDir.existsSync()) {
        absentModelsDir.deleteSync(recursive: true);
      }
      expect(absentModelsDir.existsSync(), isFalse);

      final bytes = List<int>.generate(80, (i) => i % 256);
      serverHandlers['/auto_create_model.bin'] = (request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      };

      final dummyJson = '''{
        "schema_version": "1.0.0",
        "components": [
          {
            "component_id": "CMP_ABSENT_DIR_TEST",
            "file_name": "auto_create_model.bin",
            "download_url": "$serverBaseUrl/auto_create_model.bin",
            "expected_sha256": "${sha256.convert(bytes).toString()}",
            "expected_size_bytes": 80,
            "is_shared_dependency": false,
            "license_id": "L1"
          }
        ],
        "logical_models": [
          {
            "logical_model_id": "MOD_ABSENT_DIR_TEST",
            "display_name": "Auto Create Dir Model",
            "category": "GENERATION",
            "primary_component_id": "CMP_ABSENT_DIR_TEST",
            "required_component_ids": ["CMP_ABSENT_DIR_TEST"],
            "license_id": "L1",
            "license_status": "OK",
            "distribution_strategy": "S",
            "requires_user_acceptance": false,
            "installer_readiness": "READY"
          }
        ]
      }''';

      final service = ImageModelCatalogService(modelsDir: absentModelsDir);
      await service.loadCatalog(jsonContent: dummyJson);

      final planner = ImageModelInstallPlanner(
        catalogService: service,
        diskSpaceProbe: (_) => 200 * 1024 * 1024,
      );
      final plan = await planner.buildPlan(targetLogicalModelIds: ['MOD_ABSENT_DIR_TEST']);

      final installer = ImageModelInstallerService(
        catalogService: service,
        diskSpaceProbe: (_) => 200 * 1024 * 1024,
      );

      await installer.executePlan(plan);

      expect(absentModelsDir.existsSync(), isTrue, reason: 'Le dossier absent a ete cree automatiquement');
      final finalFile = File(p.join(absentModelsDir.path, 'auto_create_model.bin'));
      expect(finalFile.existsSync(), isTrue, reason: 'Le fichier final est installe');
      expect(finalFile.lengthSync(), equals(80));
      expect(sha256.convert(finalFile.readAsBytesSync()).toString(), equals(sha256.convert(bytes).toString()));
      final partFile = File(p.join(absentModelsDir.path, 'auto_create_model.bin.part'));
      expect(partFile.existsSync(), isFalse, reason: 'Le .part a ete finalise atomiquement');

      final modelStatus = await service.getLogicalModelStatus('MOD_ABSENT_DIR_TEST', verifySha: true);
      expect(modelStatus.state, equals(LogicalModelInstallState.installed));
    });
  });
}

/// Mock writer injecte pour tester les erreurs I/O physiques (disque plein, etc.)
class MockFailingChunkWriter implements FileChunkWriter {
  final DefaultRafChunkWriter _inner;
  final int failAfterBytes;
  final bool failOnFlush;
  final bool failOnClose;
  int _written = 0;

  MockFailingChunkWriter(
    this._inner, {
    this.failAfterBytes = -1,
    this.failOnFlush = false,
    this.failOnClose = false,
  });

  @override
  Future<void> writeChunk(List<int> bytes) async {
    if (failAfterBytes >= 0 && (_written + bytes.length) > failAfterBytes) {
      final allowed = failAfterBytes - _written;
      if (allowed > 0) {
        await _inner.writeChunk(bytes.sublist(0, allowed));
        _written += allowed;
      }
      throw const FileSystemException(
        'There is not enough space on the disk',
        '',
        OSError('There is not enough space on the disk', 112),
      );
    }
    await _inner.writeChunk(bytes);
    _written += bytes.length;
  }

  @override
  Future<void> flush() async {
    if (failOnFlush) {
      throw const FileSystemException(
        'There is not enough space on the disk',
        '',
        OSError('There is not enough space on the disk', 112),
      );
    }
    await _inner.flush();
  }

  @override
  Future<void> close() async {
    if (failOnClose) {
      throw const FileSystemException(
        'There is not enough space on the disk',
        '',
        OSError('There is not enough space on the disk', 112),
      );
    }
    await _inner.close();
  }
}
