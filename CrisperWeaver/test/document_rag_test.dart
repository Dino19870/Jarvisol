import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/document_rag_service.dart';

void main() {
  group('DocumentRagService Tests', () {
    final ragService = DocumentRagService();

    test('1. Data cleaning re-connects hyphenated words and strips page noise', () {
      final rawText = '''
Kay Scarpetta - Postmortem
Page 12

L'inves-
tigateur principal s'avança vers le laboratoire.
Il examina l'échan-
tillon biologique prélevé sur la scène de crime.

- 13 -
      ''';

      final cleaned = ragService.cleanDocumentText(rawText);
      expect(cleaned.contains('investigateur'), isTrue);
      expect(cleaned.contains('échantillon'), isTrue);
      expect(cleaned.contains('Page 12'), isFalse);
      expect(cleaned.contains('- 13 -'), isFalse);
    });

    test('2. Smart chunking splits text without breaking sentences', () {
      final text = '''
## Chapitre 1 : L'appel nocturne
Il était deux heures du matin lorsque le téléphone sonna. Le détective Pete Marino était déjà sur les lieux.
La pluie tombait sans discontinuer sur la ville de Richmond. Le docteur Kay Scarpetta enfila son manteau de pluie.
Elle prit sa trousse médicale et quitta son domicile en toute hâte.
''';

      final chunks = ragService.createChunks(
        sourceName: 'postmortem.epub',
        sourceType: 'book',
        text: text,
        targetWords: 15,
        overlapWords: 5,
      );

      expect(chunks.isNotEmpty, isTrue);
      expect(chunks.first.chapterTitle, equals("Chapitre 1 : L'appel nocturne"));
      expect(chunks.first.sourceName, equals('postmortem.epub'));
      expect(chunks.first.text.contains('Pete Marino'), isTrue);
    });

    test('3. Keyword fallback search ranks relevant chunks on query match', () async {
      final chunks = [
        DocumentChunk(
          id: '1',
          sourceName: 'book.epub',
          sourceType: 'book',
          chapterTitle: 'Chapitre 1',
          text: 'Le lieutenant Pete Marino alluma un cigare en observant la victime sur la table d autopsie.',
          wordCount: 17,
        ),
        DocumentChunk(
          id: '2',
          sourceName: 'book.epub',
          sourceType: 'book',
          chapterTitle: 'Chapitre 2',
          text: 'Le soleil brillait sur la plage déserte et les vagues frappaient doucement le sable.',
          wordCount: 15,
        ),
      ];

      final results = await ragService.retrieveTopChunks(
        query: 'Qui est Pete Marino et que fait-il avec le cigare ?',
        chunks: chunks,
        endpoint: 'http://localhost:1234/v1',
      );

      expect(results.isNotEmpty, isTrue);
      expect(results.first.chunk.id, equals('1'));
      expect(results.first.chunk.text.contains('Pete Marino'), isTrue);
    });

    test('4. Chunk serialization and Hash calculation are deterministic', () {
      final chunk = DocumentChunk(
        id: 'chk_101',
        sourceName: 'sample.txt',
        sourceType: 'text',
        chapterTitle: 'Intro',
        text: 'Ceci est un texte de test pour le RAG.',
        wordCount: 9,
        embedding: [0.1, 0.2, 0.3],
      );

      final json = chunk.toJson();
      final restored = DocumentChunk.fromJson(json);

      expect(restored.id, equals('chk_101'));
      expect(restored.sourceName, equals('sample.txt'));
      expect(restored.text, equals('Ceci est un texte de test pour le RAG.'));
      expect(restored.embedding, equals([0.1, 0.2, 0.3]));

      final hash1 = ragService.computeFileHash('Contenu A');
      final hash2 = ragService.computeFileHash('Contenu A');
      final hash3 = ragService.computeFileHash('Contenu B');

      expect(hash1, equals(hash2));
      expect(hash1, isNot(equals(hash3)));
    });
  });
}
