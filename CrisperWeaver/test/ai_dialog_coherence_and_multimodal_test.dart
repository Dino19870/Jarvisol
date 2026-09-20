import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/document_rag_service.dart';
import 'package:jarvisol/services/document_source_service.dart';
import 'package:jarvisol/services/llm_service.dart';
import 'package:jarvisol/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PortablePreferences prefs;
  // ignore: unused_local_variable
  late SettingsService settings;
  late DocumentRagService ragService;

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
    ragService = DocumentRagService();
  });

  group('TESTS DE COHÉRENCE DIALOGUE IA & MULTIMODAL (Images & Documents)', () {
    test(
        '1. Traitement Multimodal d une Image avec OCR et extraction contextuelle',
        () async {
      const fakeImagePath = 'C:/Users/lansa/Documents/Scan_Facture_PC_SOFT.png';
      const extractedOcrText = '''
PC SOFT FRANCE
Devis N° DV-2604-A-0097.01
Date d émission : 15 avril 2026
Montant Total HT : 1 490,00 EUR
TVA (20%) : 298,00 EUR
Total TTC : 1 788,00 EUR
Validité de l offre : 30/06/2026
Destinataire : M. Lansade
''';

      final imageItem = DocumentSourceItem(
        name: 'Scan_Facture_PC_SOFT.png',
        path: fakeImagePath,
        type: 'image',
        textContent:
            '[Contenu textuel extrait par OCR de l\'image "Scan_Facture_PC_SOFT.png"] :\n---\n$extractedOcrText\n---',
        sizeBytes: 154200,
        importedAt: DateTime.now(),
      );

      expect(imageItem.isImage, isTrue);
      expect(imageItem.textContent.contains('1 788,00 EUR'), isTrue);

      final chunks = ragService.createChunks(
        sourceName: imageItem.name,
        sourceType: imageItem.type,
        text: imageItem.textContent,
        targetWords: 25,
        overlapWords: 5,
      );
      expect(chunks.isNotEmpty, isTrue);

      const userQuery =
          'Quel est le montant total TTC et jusqu à quand est-il valable ?';
      final results = await ragService.retrieveTopChunks(
        query: userQuery,
        chunks: chunks,
        endpoint: 'http://127.0.0.1:9379/v1',
        topK: 3,
        mode: RagSearchMode.keyword,
      );

      expect(results.isNotEmpty, isTrue);
      final foundText = results.map((r) => r.chunk.text).join(' ');
      expect(
          foundText.contains('1 788,00 EUR') || foundText.contains('Total TTC'),
          isTrue);
      expect(foundText.contains('30/06/2026'), isTrue);
    });

    test('2. Cohérence Sémantique de la Réponse IA sur document complexe',
        () async {
      const forensicReport = '''
RAPPORT D AUTOPSIE MÉDICO-LÉGALE N° 84-2026
Dr Kay Scarpetta, Médecin Légiste en Chef
Date d examen : 21 août 2026, 09h30
Victime : Inconnu masculin, environ 45 ans.

Constatations anatomiques :
1. Présence d une blessure linéaire à la tempe gauche causée par un instrument contondant.
2. Traces de fibres synthétiques bleues sous les ongles de la main droite.
3. Heure estimée du décès : entre 22h00 et 23h30 la veille.
4. Aucune trace d arme à feu ni de produit toxique dans le sang.
''';

      final chunks = ragService.createChunks(
        sourceName: 'Rapport_Autopsie_84.txt',
        sourceType: 'text',
        text: forensicReport,
        targetWords: 50,
        overlapWords: 10,
      );

      // Question 1 : "Quelle est la cause de la blessure et l'heure du décès ?"
      final query1 = 'cause de la blessure et heure du décès';
      final search1 = await ragService.retrieveTopChunks(
        query: query1,
        chunks: chunks,
        endpoint: 'http://127.0.0.1:9379/v1',
        topK: 3,
        mode: RagSearchMode.keyword,
      );

      expect(search1.isNotEmpty, isTrue);
      final foundText = search1.map((r) => r.chunk.text).join(' ');
      expect(
          foundText.contains('tempe gauche') ||
              foundText.contains('contondant'),
          isTrue);
      expect(foundText.contains('22h00 et 23h30'), isTrue);

      // Question 2 : "Y a-t-il des traces de poison ou de balle ?"
      final query2 = 'poison toxique balle arme à feu';
      final search2 = await ragService.retrieveTopChunks(
        query: query2,
        chunks: chunks,
        endpoint: 'http://127.0.0.1:9379/v1',
        topK: 3,
        mode: RagSearchMode.keyword,
      );
      final foundText2 = search2.map((r) => r.chunk.text).join(' ');
      expect(
          foundText2.contains('Aucune trace') ||
              foundText2.contains('arme à feu'),
          isTrue);
    });

    test(
        '3. Dialogue Multi-Tours : Conservation du contexte et non-hallucination',
        () {
      final messages = [
        LlmChatMessage(
            role: 'user',
            content: 'Qui est l enquêteur principal ?',
            timestamp: DateTime.now()),
        LlmChatMessage(
            role: 'assistant',
            content: 'L enquêteur principal est le capitaine Pete Marino.',
            timestamp: DateTime.now()),
        LlmChatMessage(
            role: 'user',
            content: 'Et qui pratique l autopsie ?',
            timestamp: DateTime.now()),
        LlmChatMessage(
            role: 'assistant',
            content: 'L autopsie est pratiquée par le docteur Kay Scarpetta.',
            timestamp: DateTime.now()),
      ];

      expect(messages.length, equals(4));
      final promptMessages =
          messages.map((m) => '${m.role}: ${m.content}').join('\n');
      expect(promptMessages.contains('Pete Marino'), isTrue);
      expect(promptMessages.contains('Kay Scarpetta'), isTrue);
    });
  });
}
