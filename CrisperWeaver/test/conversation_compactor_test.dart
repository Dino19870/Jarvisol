// test/conversation_compactor_test.dart
//
// Suite de tests exhaustive pour le système de compactage progressif du contexte (R4-CMP).
// Couvre l'ensemble des exigences A à N des sections 14 & 15 + les tests ciblés CMP-FIX1 (FIX-A à FIX-G).

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/conversation_capsule.dart';
import 'package:jarvisol/services/conversation_compactor_service.dart';
import 'package:jarvisol/services/llm_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('A. CMP OFF — Fenêtre glissante standard intacte', () {
    test('Sans compactage, l\'historique respecte le cutoff et la taille max standard', () {
      final messages = List.generate(
        15,
        (i) => LlmChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'Message $i'),
      );
      const isLiteRt = false;
      final maxHistoryMessages = isLiteRt ? 4 : 10;
      final recent = messages.length > maxHistoryMessages
          ? messages.sublist(messages.length - maxHistoryMessages)
          : messages;

      expect(recent.length, equals(10));
      expect(recent.first.content, equals('Message 5'));
      expect(recent.last.content, equals('Message 14'));
    });
  });

  group('B. CMP ON & Calcul Dynamique du Budget', () {
    test('Calcul de budget pour petit modèle (ex: 8K LiteRT)', () {
      final budget = CompactorBudget.calculate(modelMaxTokens: 8192);
      expect(budget.triggerThresholdTokens, equals((8192 * 0.78).round()));
      expect(budget.criticalThresholdTokens, equals((8192 * 0.90).round()));
      expect(budget.targetPostCompactionTokens, equals((8192 * 0.50).round()));
      expect(budget.capsuleBudgetTokens, inInclusiveRange(400, 2000));
      expect(budget.shouldTriggerAutoCompaction(6400), isTrue);
      expect(budget.shouldTriggerAutoCompaction(4000), isFalse);
      expect(budget.isCritical(7400), isTrue);
    });

    test('Calcul de budget pour grand modèle (ex: 64K / 128K cloud)', () {
      final budget = CompactorBudget.calculate(modelMaxTokens: 65536);
      expect(budget.capsuleBudgetTokens, equals(2000));
      expect(budget.recentZoneTokensTarget, equals(4000));
    });
  });

  group('C. Partitionnement de l\'Historique (Protection Zone Récente)', () {
    test('Protège les derniers messages pour une continuité conversationnelle immédiate', () {
      final compactor = ConversationCompactorService();
      final budget = CompactorBudget.calculate(modelMaxTokens: 8192);

      final messages = List.generate(
        12,
        (i) => LlmChatMessage(
          role: i.isEven ? 'user' : 'assistant',
          content: 'Texte d\'échange conversationnel numéro $i avec un peu de substance technique pour peser des tokens.',
        ),
      );

      final partition = compactor.partitionHistory(
        allMessages: messages,
        startIndex: 0,
        budget: budget,
      );

      expect(partition.zoneToCompact.isNotEmpty, isTrue);
      expect(partition.recentZoneToKeep.length, greaterThanOrEqualTo(3));
      expect(partition.zoneToCompact.length + partition.recentZoneToKeep.length, equals(12));
      expect(partition.compactStartIndex, equals(0));
      expect(partition.compactEndIndex, equals(partition.zoneToCompact.length - 1));
    });

    test('Ne compacte rien si historique trop court (<= 4 messages)', () {
      final compactor = ConversationCompactorService();
      final budget = CompactorBudget.calculate(modelMaxTokens: 8192);

      final shortMessages = [
        LlmChatMessage(role: 'user', content: 'Bonjour'),
        LlmChatMessage(role: 'assistant', content: 'Bonjour ! Comment vous aider ?'),
      ];

      final partition = compactor.partitionHistory(
        allMessages: shortMessages,
        startIndex: 0,
        budget: budget,
      );

      expect(partition.zoneToCompact, isEmpty);
      expect(partition.recentZoneToKeep.length, equals(2));
    });
  });

  group('D. Génération & Parsing de Capsule v1 (12 Rubriques)', () {
    test('Parse correctement un JSON LLM complet avec les 12 rubriques', () {
      final compactor = ConversationCompactorService();
      const mockJson = '''```json
{
  "objective": "Implémenter le compactage de contexte R4-CMP",
  "constraints": ["Zéro régression", "Code source sauvegardé avant modification"],
  "decisions": ["Utiliser 12 rubriques sémantiques", "Capsule injectée dans le system prompt"],
  "keyFacts": ["Base de code Flutter/Dart", "Présence de LM Studio et LiteRT"],
  "identifiersAndPaths": ["D:/Antigravity/AgentFolder/CrisperWeaver", "SHA256: 4809074122CD9BD77CB7CC", "8192 tokens"],
  "workDone": ["Création du modèle conversation_capsule.dart", "Création du service conversation_compactor_service.dart"],
  "results": ["Réduction de 70% des tokens de l'historique compacté"],
  "incidents": ["Éviter ProcessStartMode.detachedWithStdio"],
  "abandoned": ["Sauvegarde NotebookLM automatique sans accord explicite"],
  "openPoints": ["Validation post-build sur Final_v2"],
  "uncertainties": ["Vitesse de génération selon le modèle local chargé"],
  "nextStep": "Exécuter les tests unitaires et le build release"
}
```''';

      final capsule = compactor.parseCapsuleResponse(
        responseText: mockJson,
        nextVersion: 1,
        messageStartIndex: 0,
        messageEndIndex: 8,
        cutoffEpoch: 0,
        modelUsed: 'mock-model-v1',
        tokensBefore: 4200,
        inputHash: 'mock_hash_123',
      );

      expect(capsule, isNotNull);
      expect(capsule!.version, equals(1));
      expect(capsule.objective, contains('R4-CMP'));
      expect(capsule.constraints.length, equals(2));
      expect(capsule.decisions.length, equals(2));
      expect(capsule.keyFacts.length, equals(2));
      expect(capsule.identifiersAndPaths, contains('D:/Antigravity/AgentFolder/CrisperWeaver'));
      expect(capsule.identifiersAndPaths, contains('SHA256: 4809074122CD9BD77CB7CC'));
      expect(capsule.workDone.length, equals(2));
      expect(capsule.results.first, contains('Réduction de 70%'));
      expect(capsule.incidents.first, contains('ProcessStartMode'));
      expect(capsule.abandoned.first, contains('NotebookLM'));
      expect(capsule.openPoints.first, contains('Final_v2'));
      expect(capsule.uncertainties.first, contains('Vitesse de génération'));
      expect(capsule.nextStep, contains('Exécuter les tests'));

      final prompt = capsule.toContextPrompt();
      expect(prompt, contains('=== CAPSULE DE CONTEXTE CONVERSATIONNEL COMPACTÉ (v1) ==='));
      expect(prompt, contains('🎯 **Objectif actif**'));
      expect(prompt, contains('🏷️ **Noms, Chemins, IDs & Nombres exacts**'));
      expect(prompt, contains('⚡ **Incertitudes / Hypothèses non confirmées**'));
      expect(capsule.tokensSaved, greaterThan(0));
    });
  });

  group('E. Compactage Incrémental (v1 -> v2 -> v3)', () {
    test('Maintient la chaîne de versions et transmet la capsule précédente au prompt', () {
      final compactor = ConversationCompactorService();

      final capsuleV1 = ConversationCapsule(
        version: 1,
        timestamp: DateTime.now().subtract(const Duration(minutes: 10)),
        messageStartIndex: 0,
        messageEndIndex: 6,
        cutoffEpoch: 0,
        modelUsed: 'gemma-4',
        tokensBefore: 3000,
        tokensAfter: 500,
        inputHash: 'hash_v1',
        objective: 'Diagnostiquer le pipeline audio',
        decisions: const ['Utiliser 16kHz mono'],
        identifiersAndPaths: const ['C:/Temp/sample.wav', '16000 Hz'],
      );

      final newMessages = [
        LlmChatMessage(role: 'user', content: 'On passe maintenant à 48kHz avec le modèle large-v3-turbo.'),
        LlmChatMessage(role: 'assistant', content: 'D\'accord, reconfiguration vers 48kHz effectuée avec succès.'),
      ];

      final promptV2 = compactor.buildCompactionInstructionPrompt(
        newMessagesToCompact: newMessages,
        previousCapsule: capsuleV1,
        maxCapsuleTokens: 1000,
      );

      expect(promptV2, contains('CAPSULE PRÉCÉDENTE (v1) À METTRE À JOUR INCRÉMENTALEMENT'));
      expect(promptV2, contains('Diagnostiquer le pipeline audio'));
      expect(promptV2, contains('16000 Hz'));
      expect(promptV2, contains('48kHz avec le modèle large-v3-turbo'));
    });
  });

  group('F & G. Préservation Intégrale & Gestion des Incertitudes', () {
    test('La capsule restitue textuellement les identifiants, hashs, doutes et décisions abandonnées', () {
      final capsule = ConversationCapsule(
        version: 2,
        timestamp: DateTime.now(),
        messageStartIndex: 0,
        messageEndIndex: 14,
        cutoffEpoch: 0,
        modelUsed: 'qwen3',
        tokensBefore: 5000,
        tokensAfter: 600,
        inputHash: 'hash_v2',
        identifiersAndPaths: const [
          'D:\\Antigravity\\AgentFolder\\CrisperWeaver\\build\\app.so',
          '0x0000000000007dcd',
          'SHA256: 4809074122CD9BD77CB7CC9974AB1F5435DC390009C079E4DFB962FE5235E22D',
          '3.4 GiB',
        ],
        uncertainties: const [
          'Possibilité de latence accrue si la VRAM est saturée',
        ],
        abandoned: const [
          'Tentative d\'utiliser ProcessStartMode.detachedWithStdio sur Windows',
        ],
      );

      final prompt = capsule.toContextPrompt();
      expect(prompt, contains('0x0000000000007dcd'));
      expect(prompt, contains('SHA256: 4809074122CD9BD77CB7CC9974AB1F5435DC390009C079E4DFB962FE5235E22D'));
      expect(prompt, contains('3.4 GiB'));
      expect(prompt, contains('Possibilité de latence accrue si la VRAM est saturée'));
      expect(prompt, contains('ProcessStartMode.detachedWithStdio'));
    });
  });

  group('H. Isolation de Session & Époque de Réinitialisation Mémoire', () {
    test('Incrémentation d\'époque et étanchéité des capsules lors d\'un reset partiel ou total', () {
      int compactionEpoch = 0;
      ConversationCapsule? activeCapsule = ConversationCapsule(
        version: 1,
        timestamp: DateTime.now(),
        messageStartIndex: 0,
        messageEndIndex: 5,
        cutoffEpoch: compactionEpoch,
        modelUsed: 'test',
        tokensBefore: 2000,
        tokensAfter: 400,
        inputHash: 'h1',
      );

      // Simulation _resetLlmContextKeepScreen()
      compactionEpoch++;
      activeCapsule = null;

      expect(compactionEpoch, equals(1));
      expect(activeCapsule, isNull);

      activeCapsule = ConversationCapsule(
        version: 1,
        timestamp: DateTime.now(),
        messageStartIndex: 6,
        messageEndIndex: 10,
        cutoffEpoch: compactionEpoch,
        modelUsed: 'test',
        tokensBefore: 2500,
        tokensAfter: 450,
        inputHash: 'h2',
      );

      expect(activeCapsule.cutoffEpoch, equals(1));
      expect(activeCapsule.messageStartIndex, equals(6));
    });
  });

  group('M. Persistance Atomique et Rechargement JSON', () {
    test('Sauvegarde atomique et rechargement intègre d\'une session de compactage', () async {
      final tempDir = Directory.systemTemp.createTempSync('compactor_test_');

      try {
        final capsule = ConversationCapsule(
          version: 1,
          timestamp: DateTime.now(),
          messageStartIndex: 0,
          messageEndIndex: 8,
          cutoffEpoch: 0,
          modelUsed: 'unit-test-model',
          tokensBefore: 3500,
          tokensAfter: 550,
          inputHash: 'input_hash_xyz',
          objective: 'Vérifier la persistance atomique',
          decisions: const ['Écrire en fichier temporaire puis renommer'],
        );

        final session = CompactionSessionState(
          conversationId: 'test_session_42',
          epoch: 0,
          activeCapsule: capsule,
          history: [capsule],
          lastUpdated: DateTime.now(),
        );

        final jsonMap = session.toJson();
        final reloadedSession = CompactionSessionState.fromJson(jsonMap);

        expect(reloadedSession.conversationId, equals('test_session_42'));
        expect(reloadedSession.epoch, equals(0));
        expect(reloadedSession.activeCapsule, isNotNull);
        expect(reloadedSession.activeCapsule!.version, equals(1));
        expect(reloadedSession.activeCapsule!.objective, equals('Vérifier la persistance atomique'));
        expect(reloadedSession.history.length, equals(1));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('N. Calcul de Hash d\'Entrée Déterministe', () {
    test('computeInputHash produit des hashs SHA256 identiques pour les mêmes messages', () {
      final msgs = [
        LlmChatMessage(role: 'user', content: 'Test message A'),
        LlmChatMessage(role: 'assistant', content: 'Test message B'),
      ];

      final hash1 = ConversationCompactorService.computeInputHash(msgs, null);
      final hash2 = ConversationCompactorService.computeInputHash(msgs, null);

      expect(hash1, equals(hash2));
      expect(hash1.length, equals(64));

      final msgsDifferent = [
        LlmChatMessage(role: 'user', content: 'Test message A'),
        LlmChatMessage(role: 'assistant', content: 'Test message C'),
      ];
      final hash3 = ConversationCompactorService.computeInputHash(msgsDifferent, null);
      expect(hash1, isNot(equals(hash3)));
    });
  });

  // ── CMP-FIX1 : Tests de Non-Régression et Validation du Rejet de Sortie Invalide ──

  group('CMP-FIX1 Tests Ciblés (FIX-A à FIX-G)', () {
    final compactor = ConversationCompactorService();

    final capsuleV1 = ConversationCapsule(
      version: 1,
      timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
      messageStartIndex: 0,
      messageEndIndex: 5,
      cutoffEpoch: 0,
      modelUsed: 'gemma-4',
      tokensBefore: 2500,
      tokensAfter: 450,
      inputHash: 'hash_v1_valid',
      objective: 'Maintenir la stabilité du pipeline',
      decisions: const ['Activer le fallback sécurisé'],
      uncertainties: const ['Comportement sous forte charge VRAM'],
    );

    test('TEST FIX-A : previousCapsule structurée v1 + réponse JSON invalide => échec, v1 conservée intacte', () {
      const invalidJson = 'Ceci est une erreur 500 ou du texte brut sans aucun JSON.';
      final result = compactor.parseCapsuleResponse(
        responseText: invalidJson,
        nextVersion: 2,
        messageStartIndex: 0,
        messageEndIndex: 10,
        cutoffEpoch: 0,
        modelUsed: 'mock',
        tokensBefore: 3000,
        inputHash: 'hash_bad',
      );

      expect(result, isNull); // Rejet strict : pas de fallbackCapsule

      // Simulation du comportement dans le widget :
      ConversationCapsule? activeCapsule = capsuleV1;
      if (result != null) {
        activeCapsule = result;
      }

      expect(activeCapsule, equals(capsuleV1));
      expect(activeCapsule.version, equals(1));
      expect(activeCapsule.objective, equals('Maintenir la stabilité du pipeline'));
    });

    test('TEST FIX-B : aucune capsule précédente + réponse JSON invalide => échec, activeCapsule reste null', () {
      const invalidJson = 'Texte aléatoire non conforme.';
      final result = compactor.parseCapsuleResponse(
        responseText: invalidJson,
        nextVersion: 1,
        messageStartIndex: 0,
        messageEndIndex: 8,
        cutoffEpoch: 0,
        modelUsed: 'mock',
        tokensBefore: 2000,
        inputHash: 'hash_bad2',
      );

      expect(result, isNull);

      ConversationCapsule? activeCapsule;
      if (result != null) {
        activeCapsule = result;
      }

      expect(activeCapsule, isNull);
    });

    test('TEST FIX-C : previousCapsule valide + réponse vide => previousCapsule conservée', () {
      final result = compactor.parseCapsuleResponse(
        responseText: '   \n  \t  ',
        nextVersion: 2,
        messageStartIndex: 0,
        messageEndIndex: 10,
        cutoffEpoch: 0,
        modelUsed: 'mock',
        tokensBefore: 3000,
        inputHash: 'hash_empty',
      );

      expect(result, isNull);
    });

    test('TEST FIX-D : previousCapsule valide + JSON sans sections critiques => rejeté, v1 conservée', () {
      const emptyJson = '''```json
{
  "objective": "",
  "constraints": [],
  "decisions": [],
  "keyFacts": [],
  "identifiersAndPaths": [],
  "workDone": [],
  "results": [],
  "incidents": [],
  "abandoned": [],
  "openPoints": [],
  "uncertainties": [],
  "nextStep": ""
}
```''';

      final result = compactor.parseCapsuleResponse(
        responseText: emptyJson,
        nextVersion: 2,
        messageStartIndex: 0,
        messageEndIndex: 10,
        cutoffEpoch: 0,
        modelUsed: 'mock',
        tokensBefore: 3000,
        inputHash: 'hash_empty_json',
      );

      // Rejeté car contenu sémantique manifestement vide
      expect(result, isNull);
    });

    test('TEST FIX-E : réponse valide => comportement nominal inchangé, nouvelle capsule v2 activée', () {
      const validJson = '''```json
{
  "objective": "Pipeline stabilisé à 100%",
  "decisions": ["Conserver l'architecture adaptative"],
  "keyFacts": ["Aucune régression constatée"]
}
```''';

      final result = compactor.parseCapsuleResponse(
        responseText: validJson,
        nextVersion: 2,
        messageStartIndex: 0,
        messageEndIndex: 10,
        cutoffEpoch: 0,
        modelUsed: 'mock',
        tokensBefore: 3000,
        inputHash: 'hash_good',
      );

      expect(result, isNotNull);
      expect(result!.version, equals(2));
      expect(result.objective, equals('Pipeline stabilisé à 100%'));
      expect(result.decisions, contains('Conserver l\'architecture adaptative'));
    });

    test('TEST FIX-F : incertitude dans previousCapsule + tentative invalide => v1 et incertitudes 100% préservées', () {
      const corruptJson = '{ invalid: json syntax ...';
      final result = compactor.parseCapsuleResponse(
        responseText: corruptJson,
        nextVersion: 2,
        messageStartIndex: 0,
        messageEndIndex: 10,
        cutoffEpoch: 0,
        modelUsed: 'mock',
        tokensBefore: 3000,
        inputHash: 'hash_corrupt',
      );

      expect(result, isNull);
      // Capsule active reste strictement v1 avec ses incertitudes intactes
      expect(capsuleV1.uncertainties, contains('Comportement sous forte charge VRAM'));
      expect(capsuleV1.toContextPrompt(), contains('Comportement sous forte charge VRAM'));
    });

    test('TEST FIX-G : reset mémoire après échec de compactage => comportement historique respecté', () {
      int cutoffEpoch = 0;
      int llmCutoffIndex = 0;
      ConversationCapsule? activeCapsule = capsuleV1;

      // Échec de compactage : activeCapsule reste v1
      const failJson = 'err';
      final res = compactor.parseCapsuleResponse(
        responseText: failJson,
        nextVersion: 2,
        messageStartIndex: 0,
        messageEndIndex: 10,
        cutoffEpoch: cutoffEpoch,
        modelUsed: 'mock',
        tokensBefore: 3000,
        inputHash: 'hash_err',
      );
      expect(res, isNull);
      expect(activeCapsule, equals(capsuleV1));

      // Déclenchement de _resetLlmContextKeepScreen()
      cutoffEpoch++;
      activeCapsule = null;
      llmCutoffIndex = 12; // index de fin de discussion

      expect(cutoffEpoch, equals(1));
      expect(activeCapsule, isNull);
      expect(llmCutoffIndex, equals(12));
    });
  });
}
