// test/litert_routing_test.dart
//
// Unit tests for LlmService.resolveWindowsModelId().
//
// B1 regression guard: ensures that gemma-3n-e4b-it is never misrouted to
// gemma-4-e4b-it by a broad contains('e4b') catch-all.
//
// Run: flutter test test/litert_routing_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  // Alias for brevity.
  String resolve(String id) => LlmService.resolveWindowsModelId(id);

  // --- Mandatory coverage (4 IDs from the incident report) ---
  group('B1 regression — mandatory 4 IDs', () {
    test('gemma-3n-e2b-it -> gemma-3n-e2b-it', () {
      expect(resolve('gemma-3n-e2b-it'), equals('gemma-3n-e2b-it'));
    });

    test('gemma-3n-e4b-it -> gemma-3n-E4B-IT  (was misrouted to gemma-4-e4b-it)', () {
      expect(resolve('gemma-3n-e4b-it'), equals('gemma-3n-E4B-IT'));
    });

    test('gemma-4-e4b-it -> gemma-4-e4b-it', () {
      expect(resolve('gemma-4-e4b-it'), equals('gemma-4-e4b-it'));
    });

    test('gemma-4-gpu -> gemma-4-gpu', () {
      expect(resolve('gemma-4-gpu'), equals('gemma-4-gpu'));
    });
  });

  // --- ID variants (real settings.llmModel shape on Windows:
  //     always the model ID, never a file path.
  //     The button 'Utiliser' writes m.id, not m.localPath) ---
  group('ID variants (real settings.llmModel shape on Windows)', () {
    test('gemma-3n-E4B-IT (canonical server casing) -> gemma-3n-E4B-IT', () {
      expect(resolve('gemma-3n-E4B-IT'), equals('gemma-3n-E4B-IT'));
    });

    test('gemma-3n-e2b-it (lowercase) -> gemma-3n-e2b-it', () {
      expect(resolve('gemma-3n-e2b-it'), equals('gemma-3n-e2b-it'));
    });

    test('gemma-4-e4b-it (exact) -> gemma-4-e4b-it', () {
      expect(resolve('gemma-4-e4b-it'), equals('gemma-4-e4b-it'));
    });
  });

  // --- Other model families ---
  group('other model families', () {
    test('gemma-4-12b-it-gpu -> gemma-4-12B-it-gpu', () {
      expect(resolve('gemma-4-12b-it-gpu'), equals('gemma-4-12B-it-gpu'));
    });

    test('deepseek-r1-distill-qwen-1.5b -> deepseek-r1-distill-qwen-1.5b', () {
      expect(resolve('deepseek-r1-distill-qwen-1.5b'), equals('deepseek-r1-distill-qwen-1.5b'));
    });

    test('tiny-garden-270m -> tiny-garden-270m', () {
      expect(resolve('tiny-garden-270m'), equals('tiny-garden-270m'));
    });

    test('qwen-2.5-1.5b-instruct -> qwen-2.5-1.5b-instruct', () {
      expect(resolve('qwen-2.5-1.5b-instruct'), equals('qwen-2.5-1.5b-instruct'));
    });

    test('unknown ID passthrough', () {
      expect(resolve('my-custom-model'), equals('my-custom-model'));
    });

    test('empty ID -> fallback gemma-4-e4b-it', () {
      expect(resolve(''), equals('gemma-4-e4b-it'));
    });
  });

  // --- Case / separator normalisation ---
  group('normalisation (case + separators)', () {
    test('Gemma-3N-E4B-IT (mixed case) -> gemma-3n-E4B-IT', () {
      expect(resolve('Gemma-3N-E4B-IT'), equals('gemma-3n-E4B-IT'));
    });

    test('gemma_3n_e4b_it (underscores) -> gemma-3n-E4B-IT', () {
      expect(resolve('gemma_3n_e4b_it'), equals('gemma-3n-E4B-IT'));
    });

    test('GEMMA-4-GPU (uppercase) -> gemma-4-gpu', () {
      expect(resolve('GEMMA-4-GPU'), equals('gemma-4-gpu'));
    });
  });

  // --- Critical disambiguation: 3n-e4b never touches 4-e4b bucket ---
  group('disambiguation — 3n-e4b vs 4-e4b', () {
    test('3n-e4b-it is NOT resolved to gemma-4-e4b-it', () {
      expect(resolve('gemma-3n-e4b-it'), isNot(equals('gemma-4-e4b-it')));
    });

    test('4-e4b-it is NOT resolved to gemma-3n-E4B-IT', () {
      expect(resolve('gemma-4-e4b-it'), isNot(equals('gemma-3n-E4B-IT')));
    });
  });
}
