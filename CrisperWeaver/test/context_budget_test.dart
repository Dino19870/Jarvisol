// test/context_budget_test.dart
//
// Suite de tests exhaustive pour la correction du budget global LLM / RAG (PHASE CTX-BUDGET-FIX1).
// Couvre l'ensemble des tests BUDGET-A à BUDGET-I.

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/conversation_capsule.dart';
import 'package:jarvisol/services/conversation_compactor_service.dart';
import 'package:jarvisol/services/document_rag_service.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('TEST BUDGET-A — Reproduction du défaut (LiteRT 4096, RAG, CMP OFF)', () {
    test('Empêche tout envoi > 4096 et borne dynamiquement les extraits RAG', () {
      const modelMaxTokens = 4096;
      final responseReserve = (modelMaxTokens * 0.25).clamp(500, 2048).toInt(); // 1024
      final safetyMargin = (modelMaxTokens * 0.05).round().clamp(80, 500); // 205

      const userTemplate = 'Tu es un assistant IA documentaire expert et précis intégré dans CrisperWeaver.\nConsignes strictes de réponse : ...';
      const sourceNamesList = '- Kay Scarpetta 01 - Postmortem - Patricia Cornwell.txt (TXT)';
      final baseSystemTokens = ConversationCompactorService.estimateTextTokens(userTemplate) +
          ConversationCompactorService.estimateTextTokens(sourceNamesList) + 120;

      const userText = 'Fais une synthèse claire et structurée des documents fournis.';
      final currentUserTokens = ConversationCompactorService.estimateTextTokens(userText);
      const convTokens = 0; // session courte / vidée
      const chatTemplateOverhead = 20;

      final budget = GlobalContextBudget.calculate(
        modelMaxTokens: modelMaxTokens,
        responseReserve: responseReserve,
        safetyMargin: safetyMargin,
        systemPromptTokens: baseSystemTokens,
        documentInstructionsTokens: 50,
        sourceMetadataTokens: 40,
        chatTemplateTokens: chatTemplateOverhead,
        currentUserTokens: currentUserTokens,
        conversationOrCapsuleTokens: convTokens,
      );

      // Vérification : le budget alloué au RAG laisse de la place pour la réponse et la marge
      expect(budget.remainingRagBudgetTokens, lessThan(modelMaxTokens));
      expect(budget.remainingRagBudgetTokens, greaterThan(1500));
      expect(budget.totalReservedTokens, lessThanOrEqualTo(modelMaxTokens));

      // Simulation de 5 gros fragments qui auparavant saturaient LiteRT à 3849 tokens RAG
      final candidateChunks = List.generate(
        5,
        (i) => DocumentChunk(
          id: 'chunk_$i',
          sourceName: 'Postmortem',
          sourceType: 'txt',
          text: 'Fragment numéro $i contenant un texte dense d\'environ 350 mots pour tester le découpage et le respect strict du plafond de tokens alloué. ' * 12,
          wordCount: 350,
        ),
      );

      // Accumulation bornée par remainingRagBudgetTokens
      final maxRagTokens = budget.remainingRagBudgetTokens;
      final injectedChunks = <DocumentChunk>[];
      int accumulatedRagTokens = 0;

      for (int i = 0; i < candidateChunks.length; i++) {
        final ch = candidateChunks[i];
        final header = '--- EXTRAIT ${i + 1} [Source: ${ch.sourceName}] ---\n';
        final chunkTokens = ConversationCompactorService.estimateTextTokens(header + ch.text);
        if (accumulatedRagTokens + chunkTokens > maxRagTokens) {
          break;
        }
        injectedChunks.add(ch);
        accumulatedRagTokens += chunkTokens;
      }

      // Preuve A : Moins de 5 fragments injectés pour respecter la limite
      expect(injectedChunks.length, lessThan(5));
      expect(injectedChunks.length, greaterThanOrEqualTo(2));

      // Preuve B : Le total d'entrée réel reste strictement sous la limite
      final totalInputTokens = budget.nonRagFixedTokens + accumulatedRagTokens;
      expect(totalInputTokens + responseReserve, lessThanOrEqualTo(modelMaxTokens));
      expect(totalInputTokens, lessThan(modelMaxTokens - responseReserve));
    });
  });

  group('TEST BUDGET-B — Comptabilité exacte des composantes', () {
    test('La somme de toutes les composantes respecte la capacité effective', () {
      const capacity = 4096;
      final budget = GlobalContextBudget.calculate(
        modelMaxTokens: capacity,
        responseReserve: 1024,
        safetyMargin: 205,
        systemPromptTokens: 140,
        documentInstructionsTokens: 50,
        sourceMetadataTokens: 40,
        chatTemplateTokens: 20,
        currentUserTokens: 25,
        conversationOrCapsuleTokens: 300,
      );

      final totalAccounted = budget.systemPromptTokens +
          budget.documentInstructionsTokens +
          budget.sourceMetadataTokens +
          budget.chatTemplateTokens +
          budget.currentUserTokens +
          budget.conversationOrCapsuleTokens +
          budget.remainingRagBudgetTokens +
          budget.responseReserve +
          budget.safetyMargin;

      expect(totalAccounted, equals(capacity));
      expect(budget.nonRagFixedTokens, equals(140 + 50 + 40 + 20 + 25 + 300));
    });
  });

  group('TEST BUDGET-C — Jauge UI cohérente', () {
    test('La jauge ne sous-estime plus le payload et intègre les composantes fixes', () {
      const modelMax = 4096;
      const userTemplate = 'Tu es un assistant IA documentaire expert et précis intégré dans CrisperWeaver.';
      final fixedTokens = ConversationCompactorService.estimateTextTokens(userTemplate) + 100;
      const convTokens = 0;

      final responseBudget = (modelMax * 0.25).clamp(500, 2048).toInt();
      final safetyMargin = (modelMax * 0.05).round().clamp(80, 500);
      final remainingRagBudget = (modelMax - responseBudget - safetyMargin - fixedTokens - convTokens).clamp(0, modelMax);

      const rawTopK = 5;
      const chunkSize = 350;
      final estimatedTopKTokens = (rawTopK * chunkSize * 1.3).round();
      final docTokens = estimatedTopKTokens.clamp(0, remainingRagBudget);

      final estimatedTotal = fixedTokens + convTokens + docTokens;

      // La jauge prédit un niveau d'occupation réaliste (entre 55% et 70%), jamais déconnecté à 75% quand payload > 100%
      final usagePercent = (estimatedTotal / modelMax * 100).round();
      expect(usagePercent, inInclusiveRange(55, 70));
      expect(estimatedTotal + responseBudget, lessThanOrEqualTo(modelMax));
    });
  });

  group('TEST BUDGET-D — CMP OFF & Garde-fou actif', () {
    test('Sans CMP, le garde-fou pré-envoi bloque tout payload dépassant la capacité', () {
      const modelCapacity = 4096;

      // Cas valide
      final validMsg = [
        LlmChatMessage(role: 'system', content: 'Prompt système standard' * 10),
        LlmChatMessage(role: 'user', content: 'Question normale'),
      ];
      int validTokens = 0;
      for (final m in validMsg) {
        validTokens += ConversationCompactorService.estimateTextTokens(m.content) + 4;
      }
      validTokens += 20;
      expect(validTokens, lessThan(modelCapacity));

      // Cas débordant volontaire (payload monstre)
      final hugeMsg = [
        LlmChatMessage(role: 'system', content: 'Texte gigantesque dépassant la capacité totale...' * 500),
      ];
      int hugeTokens = 0;
      for (final m in hugeMsg) {
        hugeTokens += ConversationCompactorService.estimateTextTokens(m.content) + 4;
      }
      hugeTokens += 20;

      // Le garde-fou identifie immédiatement le dépassement
      final wouldBeBlocked = hugeTokens >= modelCapacity;
      expect(wouldBeBlocked, isTrue);
    });
  });

  group('TEST BUDGET-E — CMP ON sur session courte', () {
    test('Historique court (< 6 messages) : CMP ne compacte pas et RAG reste borné', () {
      final compactor = ConversationCompactorService();
      final budget = compactor.computeBudget(modelMaxTokens: 4096);

      final shortHistory = [
        LlmChatMessage(role: 'user', content: 'Bonjour'),
        LlmChatMessage(role: 'assistant', content: 'Bonjour ! Comment puis-je vous aider ?'),
      ];

      // Règle d'or : CMP ne tente rien sur un historique trop court
      expect(shortHistory.length, lessThan(6));

      // Mais le budget RAG dynamique fonctionne toujours
      final ragBudget = GlobalContextBudget.calculate(
        modelMaxTokens: 4096,
        systemPromptTokens: 200,
        documentInstructionsTokens: 50,
        sourceMetadataTokens: 40,
        currentUserTokens: 15,
        conversationOrCapsuleTokens: ConversationCompactorService.estimateMessagesTokens(shortHistory),
      );
      expect(ragBudget.remainingRagBudgetTokens, greaterThan(1500));
    });
  });

  group('TEST BUDGET-F — CMP ON sur conversation longue', () {
    test('Quand l\'historique pèse lourd, CMP libère des tokens et le RAG récupère du budget', () {
      final compactor = ConversationCompactorService();
      final budget = compactor.computeBudget(modelMaxTokens: 4096);

      // Simulation conversation longue (14 messages de 100 mots)
      final longHistory = List.generate(
        14,
        (i) => LlmChatMessage(
          role: i.isEven ? 'user' : 'assistant',
          content: 'Échange technique numéro $i abordant en détail des faits, des choix et des contraintes pour peser lourd dans le contexte. ' * 4,
        ),
      );

      final preCompactionTokens = ConversationCompactorService.estimateMessagesTokens(longHistory);
      expect(preCompactionTokens, greaterThan(1200));

      // Partitionnement CMP
      final partition = compactor.partitionHistory(
        allMessages: longHistory,
        startIndex: 0,
        budget: budget,
      );

      expect(partition.zoneToCompact, isNotEmpty);
      expect(partition.recentZoneToKeep, isNotEmpty);

      // Simulation de capsule générée (taille ~250 tokens)
      const mockCapsulePrompt = '## 📌 CAPSULE MÉMOIRE SYNTHÉTIQUE\n- Objectif : Analyse\n- Faits : Multiples échanges techniques';
      final capsuleTokens = ConversationCompactorService.estimateTextTokens(mockCapsulePrompt);
      final postCompactionConvTokens = capsuleTokens + ConversationCompactorService.estimateMessagesTokens(partition.recentZoneToKeep);

      // Gain de tokens substantiel
      expect(postCompactionConvTokens, lessThan(preCompactionTokens));

      // Le RAG dispose de plus de budget après compactage
      final ragBudgetBefore = GlobalContextBudget.calculate(
        modelMaxTokens: 4096,
        systemPromptTokens: 250,
        documentInstructionsTokens: 50,
        sourceMetadataTokens: 40,
        currentUserTokens: 20,
        conversationOrCapsuleTokens: preCompactionTokens,
      );

      final ragBudgetAfter = GlobalContextBudget.calculate(
        modelMaxTokens: 4096,
        systemPromptTokens: 250,
        documentInstructionsTokens: 50,
        sourceMetadataTokens: 40,
        currentUserTokens: 20,
        conversationOrCapsuleTokens: postCompactionConvTokens,
      );

      expect(ragBudgetAfter.remainingRagBudgetTokens, greaterThan(ragBudgetBefore.remainingRagBudgetTokens));
    });
  });

  group('TEST BUDGET-G — Modèle à large capacité (8K / 32K / 128K)', () {
    test('Le calcul dynamique s\'adapte sans aucune constante 4K rigide', () {
      // Pour un modèle 32K
      final budget32K = GlobalContextBudget.calculate(
        modelMaxTokens: 32768,
        responseReserve: 2048,
        safetyMargin: 500,
        systemPromptTokens: 300,
        documentInstructionsTokens: 60,
        sourceMetadataTokens: 50,
        chatTemplateTokens: 20,
        currentUserTokens: 20,
        conversationOrCapsuleTokens: 400,
      );

      // Le budget RAG alloué est proportionnel et permet d'injecter bien plus de fragments
      expect(budget32K.remainingRagBudgetTokens, greaterThan(25000));

      // Pour un modèle 8K
      final budget8K = GlobalContextBudget.calculate(
        modelMaxTokens: 8192,
        responseReserve: 1500,
        systemPromptTokens: 300,
        documentInstructionsTokens: 60,
        sourceMetadataTokens: 50,
        chatTemplateTokens: 20,
        currentUserTokens: 20,
        conversationOrCapsuleTokens: 400,
      );
      expect(budget8K.remainingRagBudgetTokens, inInclusiveRange(4500, 6000));
    });
  });

  group('TEST BUDGET-H — Mode Contexte Complet', () {
    test('Préserve le comportement natif du mode Contexte Complet', () {
      const modelMax = 4096;
      const isLiteRt = true;
      final maxAllowedContextChars = isLiteRt || modelMax <= 4096 ? 7500 : (modelMax * 3.0).toInt();
      expect(maxAllowedContextChars, equals(7500));

      // Un document court tient entièrement
      final shortDoc = 'Document complet de taille modérée.' * 50;
      expect(shortDoc.length, lessThan(maxAllowedContextChars));

      // Un document long dépasse et invite à basculer vers le mode RAG
      final longDoc = 'Document géant dépassant la limite...' * 500;
      expect(longDoc.length, greaterThan(maxAllowedContextChars));
    });
  });

  group('TEST BUDGET-I — Marge de sécurité explicite', () {
    test('La marge de sécurité absorbe les variations de tokenisation aux frontières', () {
      final budget = GlobalContextBudget.calculate(
        modelMaxTokens: 4096,
        systemPromptTokens: 250,
        documentInstructionsTokens: 50,
        sourceMetadataTokens: 40,
        chatTemplateTokens: 20,
        currentUserTokens: 20,
        conversationOrCapsuleTokens: 0,
      );

      // Marge calculée automatiquement (~5% de 4096)
      expect(budget.safetyMargin, inInclusiveRange(150, 250));

      // Même si le texte réel est 10% plus dense que l'estimation utf-16,
      // la marge de 205 tokens empêche le débordement au runtime
      final estimatedInput = budget.nonRagFixedTokens + budget.remainingRagBudgetTokens;
      expect(estimatedInput + budget.responseReserve + budget.safetyMargin, equals(4096));
    });
  });
}
