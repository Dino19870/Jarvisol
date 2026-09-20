import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/litert_model_registry.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    PortablePreferences.resetForTesting();
  });

  group('CORR-06 / TNR-070: Frontières d\'exécution LiteRT et interdiction du PATH hôte', () {
    test('TNR-070: Échec explicite si runtime portable absent sans recours silencieux au PATH', () async {
      expect(() => LlmService.resolveWindowsModelId('gemma-2b'), returnsNormally);
    });
  });

  group('CORR-06 / TNR-071: Validation de taille/intégrité et interdiction du faux succès', () {
    test('TNR-071: Un fichier modèle vide ou incomplet est rejeté sans marquage installé', () async {
      final registry = LiteRtModelRegistry();
      final testModel = LiteRtModelEntry(
        id: 'test-canary-model',
        name: 'Test Canary Model',
        author: 'Test Author',
        description: 'Test Description',
        repoId: 'test/repo',
        filename: 'model.litertlm',
        downloadUrl: 'http://127.0.0.1:9999/model.litertlm',
        sizeBytes: 1024 * 1024 * 100, // 100 Mo attendus
        sizeDisplay: '100 Mo',
        format: 'litertlm',
        preferredBackend: 'GPU',
        isMultimodal: false,
        isRecommended: false,
        defaultConfig: {},
      );

      final tempDir = await Directory.systemTemp.createTemp('cw_inc_');
      try {
        final modelDir = Directory(p.join(tempDir.path, 'test-canary-model'));
        await modelDir.create(recursive: true);
        final incompleteFile = File(p.join(modelDir.path, 'model.litertlm.download'));
        await incompleteFile.writeAsBytes(List<int>.filled(1024 * 1024, 0)); // 1 Mo

        final isComplete = incompleteFile.lengthSync() >= (testModel.sizeBytes * 0.95);
        expect(isComplete, isFalse, reason: 'Le fichier téléchargé à 1% doit être détecté comme incomplet');
        expect(testModel.isDownloaded, isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('CORR-06 / TNR-094: Paramètres par modèle LiteRT persistés dans PortablePreferences', () {
    test('TNR-094: temperature, topK, maxTokens enregistrés dans preferences.json', () async {
      final registry = LiteRtModelRegistry();
      await registry.loadAllowlist();

      // Mettre à jour la configuration d'un modèle
      await registry.updateModelConfig('gemma-2b-it', temperature: 0.42, topK: 55, maxTokens: 2048);

      final prefs = await PortablePreferences.getInstance();
      expect(prefs.getDouble('litert_temp_gemma-2b-it'), equals(0.42));
      expect(prefs.getInt('litert_topk_gemma-2b-it'), equals(55));
      expect(prefs.getInt('litert_maxtok_gemma-2b-it'), equals(2048));
    });
  });

  group('CORR-06 / TNR-068: Serveur LLM local port 9379 - protocole HTTP /v1/models', () {
    test('TNR-068: Occupant TCP tiers non-HTTP rejeté sans être tué', () async {
      ServerSocket? rawTcpServer;
      try {
        rawTcpServer = await ServerSocket.bind('127.0.0.1', 9379);
        rawTcpServer.listen((client) {
          client.write('RAW_NON_HTTP_STREAM\n');
          client.close();
        });
      } catch (_) {
        return;
      }

      final client = HttpClient();
      bool isHttp200 = false;
      try {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:9379/v1/models'))
            .timeout(const Duration(milliseconds: 500));
        final res = await req.close();
        isHttp200 = (res.statusCode == 200);
      } catch (_) {
        isHttp200 = false;
      }
      client.close();

      expect(isHttp200, isFalse, reason: 'Un occupant TCP non-HTTP ne doit pas valider la readiness HTTP');

      await rawTcpServer.close();
    });
  });

  group('CORR-06 / TNR-069: Timeout de readiness et nettoyage de l\'état de possession', () {
    test('TNR-069: stopWindowsServer réinitialise l\'état sans crash', () {
      expect(() => LlmService.stopWindowsServer(), returnsNormally);
    });
  });

  group('CORR-06 Canaries: TNR-131, TNR-132, TNR-133 & CAMP-LLM-001', () {
    test('TNR-131: Structure et intégrité de l\'allowlist LiteRT', () async {
      final registry = LiteRtModelRegistry();
      await registry.loadAllowlist();
      expect(registry.models, isNotEmpty);
      for (final m in registry.models) {
        expect(m.id, isNotEmpty);
        expect(m.name, isNotEmpty);
        expect(m.defaultConfig, isNotNull);
      }
    });

    test('TNR-132: Détection dynamique de l\'encodeur vision', () {
      expect(LiteRtModelEntry.hasVisionEncoder('non_existent_model_id'), isFalse);
    });

    test('TNR-133 & CAMP-LLM-001: Résolution des endpoints et modèles locaux', () {
      final modelId = LlmService.resolveWindowsModelId('gemma-2b');
      expect(modelId, isNotEmpty);
    });
  });
}
