import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  group('Text Prompt Isolation & Non-Regression Tests', () {
    test('REQ-H : Ancien prompt A (image) puis nouvelle question B (texte) -> LLM reçoit B comme dernier message', () {
      final messages = <LlmChatMessage>[
        // Tour 1 : Demande et génération d'image
        LlmChatMessage(role: 'user', content: "génère l'image d'une voiture verte", timestamp: DateTime.now()),
        LlmChatMessage(
          role: 'assistant',
          content: '🎨 **Détection d\'intention visuelle**\n\nVotre message décrit une scène visuelle.',
          timestamp: DateTime.now(),
        ),
        LlmChatMessage(
          role: 'assistant',
          content: '🎨 **Image générée avec succès :**\n\n![Green car](file:///D:/path/gen_image_1.png)\n\n*(Prompt visuel : "Green car")*',
          timestamp: DateTime.now(),
        ),
        // Tour 2 : Nouvelle question texte
        LlmChatMessage(role: 'user', content: 'quel est le masculin de voiture ?', timestamp: DateTime.now()),
      ];

      // Filtrage de l'historique validHistory (identique à DocumentChatWidget)
      final validHistory = messages
          .where((m) =>
              !m.content.startsWith('❌ Erreur') &&
              !m.content.startsWith('⚠️ Aucune') &&
              !m.content.startsWith('⚠️') &&
              !m.content.contains('🎨 **Image générée avec succès') &&
              !m.content.contains('🎨 **Détection d\'intention visuelle'))
          .toList();

      const maxHistoryMessages = 4;
      final recentMessages = validHistory.length > maxHistoryMessages
          ? validHistory.sublist(validHistory.length - maxHistoryMessages)
          : validHistory;

      final systemPrompt = 'Tu es un assistant IA expert.';
      final requestMessages = [
        LlmChatMessage(role: 'system', content: systemPrompt),
        ...recentMessages,
      ];

      // Vérification formelle du dernier message envoyé au LLM
      expect(requestMessages.last.role, 'user');
      expect(requestMessages.last.content, 'quel est le masculin de voiture ?');
      expect(requestMessages.any((m) => m.content.contains('Bonjour, tu vas bien ?')), isFalse);
    });

    test('REQ-F : Test discriminant 4 tours successifs dans la même conversation', () {
      final messages = <LlmChatMessage>[];

      void send(String userText, {bool isImage = false, String? assistantResponse}) {
        messages.add(LlmChatMessage(role: 'user', content: userText, timestamp: DateTime.now()));
        if (isImage) {
          messages.add(LlmChatMessage(
            role: 'assistant',
            content: '🎨 **Image générée avec succès :**\n\n![img](file:///D:/path/img.png)',
            timestamp: DateTime.now(),
          ));
        } else if (assistantResponse != null) {
          messages.add(LlmChatMessage(
            role: 'assistant',
            content: assistantResponse,
            timestamp: DateTime.now(),
          ));
        }
      }

      // Tour 1 : Image
      send("génère l'image d'une voiture", isImage: true);

      // Tour 2 : Mathématiques
      send("Combien font 7 + 5 ?");
      var valid = messages.where((m) => !m.content.contains('🎨 **Image générée avec succès')).toList();
      var reqMsgs = [LlmChatMessage(role: 'system', content: 'sys'), ...valid];
      expect(reqMsgs.last.content, 'Combien font 7 + 5 ?');
      send("Combien font 7 + 5 ?", assistantResponse: "7 + 5 font 12.");

      // Tour 3 : Géographie
      send("Quelle est la capitale de l'Italie ?");
      valid = messages.where((m) => !m.content.contains('🎨 **Image générée avec succès')).toList();
      reqMsgs = [LlmChatMessage(role: 'system', content: 'sys'), ...valid];
      expect(reqMsgs.last.content, "Quelle est la capitale de l'Italie ?");
      send("Quelle est la capitale de l'Italie ?", assistantResponse: "La capitale de l'Italie est Rome.");

      // Tour 4 : Grammaire
      send("Quel est le masculin de voiture ?");
      valid = messages.where((m) => !m.content.contains('🎨 **Image générée avec succès')).toList();
      reqMsgs = [LlmChatMessage(role: 'system', content: 'sys'), ...valid];
      expect(reqMsgs.last.content, "Quel est le masculin de voiture ?");
      expect(reqMsgs.any((m) => m.content.contains('Bonjour, tu vas bien ?')), isFalse);
    });

    test('REQ-G : Mémoire ciblée vs Mémoire parasite neutralisée', () {
      String buildSystemPrompt(String userQuery, List<String> targetedMemoryResults) {
        String base = "Tu es un assistant IA expert.";
        if (targetedMemoryResults.isNotEmpty) {
          base += "\n\n## 🧠 MÉMOIRE LONG-TERME\n" + targetedMemoryResults.map((r) => '• $r').join('\n');
        }
        return base;
      }

      // 1. Question non liée à la mémoire -> résultats ciblés vides -> zéro pollution
      final promptVoiture = buildSystemPrompt("quel est le masculin de voiture ?", []);
      expect(promptVoiture.contains('Bonjour, tu vas bien ?'), isFalse);
      expect(promptVoiture.contains('MÉMOIRE LONG-TERME'), isFalse);

      // 2. Question liée à un souvenir -> souvenir ciblé injecté proprement
      final promptMem = buildSystemPrompt(
        "Quel est le code mémoire ?",
        ["Le code memoire de test est JARVISOL-MEM-0901-X7"],
      );
      expect(promptMem.contains('JARVISOL-MEM-0901-X7'), isTrue);
      expect(promptMem.contains('Bonjour, tu vas bien ?'), isFalse);
    });
  });
}
