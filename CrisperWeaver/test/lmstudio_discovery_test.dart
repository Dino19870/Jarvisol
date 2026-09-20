import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  group('LM Studio Dynamic Discovery & Separation Matrix', () {
    test('LMS-DISC-01: Probing /api/v0/models separates Chat vs Embeddings via type field', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/v0/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'google/gemma-4-26b-a4b-qat', 'type': 'llm'},
                {'id': 'lfm2.5-2.6b', 'type': 'llm'},
                {'id': 'mistralai/devstral-small-2-2512', 'type': 'vlm'},
                {'id': 'text-embedding-qwen3-embedding-4b', 'type': 'embeddings'},
                {'id': 'text-embedding-nomic-embed-text-v1.5', 'type': 'embeddings'},
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not found', 404);
      });

      final result = await LlmService.discoverLmStudioModels(
        'http://localhost:1234/v1',
        client: mockClient,
      );

      expect(result.isOnline, isTrue);
      expect(result.hasChatModels, isTrue);
      expect(result.hasEmbeddingModels, isTrue);

      // Chat models must strictly contain LLM/VLM models
      expect(result.chatModels, contains('google/gemma-4-26b-a4b-qat'));
      expect(result.chatModels, contains('lfm2.5-2.6b'));
      expect(result.chatModels, contains('mistralai/devstral-small-2-2512'));
      expect(result.chatModels.length, equals(3));

      // Embedding models must NOT be present in chat models
      expect(result.chatModels, isNot(contains('text-embedding-qwen3-embedding-4b')));
      expect(result.chatModels, isNot(contains('text-embedding-nomic-embed-text-v1.5')));

      // Embedding models must strictly be in embeddingModels
      expect(result.embeddingModels, contains('text-embedding-qwen3-embedding-4b'));
      expect(result.embeddingModels, contains('text-embedding-nomic-embed-text-v1.5'));
      expect(result.embeddingModels.length, equals(2));
    });

    test('LMS-DISC-02: Fallback to /v1/models when /api/v0/models returns 404', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/v0/models') {
          return http.Response('Not Found', 404);
        }
        if (request.url.path == '/v1/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'qwen2.5-coder-7b'},
                {'id': 'text-embedding-bge-m3'},
                {'id': 'llama-3.2-3b-instruct'},
                {'id': 'nomic-embed-text'},
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not found', 404);
      });

      final result = await LlmService.discoverLmStudioModels(
        'http://localhost:1234',
        client: mockClient,
      );

      expect(result.isOnline, isTrue);
      expect(result.chatModels, contains('qwen2.5-coder-7b'));
      expect(result.chatModels, contains('llama-3.2-3b-instruct'));
      expect(result.chatModels, isNot(contains('text-embedding-bge-m3')));
      expect(result.chatModels, isNot(contains('nomic-embed-text')));

      expect(result.embeddingModels, contains('text-embedding-bge-m3'));
      expect(result.embeddingModels, contains('nomic-embed-text'));
    });

    test('LMS-DISC-03: Offline server returns isOnline=false, empty models', () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('Connection refused');
      });

      final result = await LlmService.discoverLmStudioModels(
        'http://127.0.0.1:9999/v1',
        client: mockClient,
      );

      expect(result.isOnline, isFalse);
      expect(result.chatModels, isEmpty);
      expect(result.embeddingModels, isEmpty);
      expect(result.hasChatModels, isFalse);
      expect(result.hasEmbeddingModels, isFalse);
      expect(result.errorMessage, contains('Connection refused'));
    });

    test('LMS-DISC-04: Server timeout returns isOnline=false', () async {
      final mockClient = MockClient((request) async {
        await Future.delayed(const Duration(milliseconds: 200));
        return http.Response('{}', 200);
      });

      final result = await LlmService.discoverLmStudioModels(
        'http://localhost:1234',
        timeout: const Duration(milliseconds: 50),
        client: mockClient,
      );

      expect(result.isOnline, isFalse);
      expect(result.chatModels, isEmpty);
      expect(result.embeddingModels, isEmpty);
    });

    test('LMS-DISC-05: Real live probe against LM Studio if server is active on 1234', () async {
      final result = await LlmService.discoverLmStudioModels(
        'http://localhost:1234/v1',
        timeout: const Duration(seconds: 2),
      );

      if (result.isOnline) {
        expect(result.chatModels, isNotEmpty);
        for (final m in result.chatModels) {
          expect(m.toLowerCase().startsWith('text-embedding-'), isFalse);
        }
      } else {
        expect(result.isOnline, isFalse);
        expect(result.chatModels, isEmpty);
        expect(result.embeddingModels, isEmpty);
      }
    });
  });
}
