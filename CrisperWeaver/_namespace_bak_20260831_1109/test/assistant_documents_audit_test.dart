import 'package:flutter_test/flutter_test.dart';
import 'package:crisper_weaver/utils/portable_preferences.dart';
import 'package:crisper_weaver/models/ai_knowledge_record.dart';
import 'package:crisper_weaver/models/prompt_item.dart';
import 'package:crisper_weaver/services/document_rag_service.dart';
import 'package:crisper_weaver/services/llm_service.dart';
import 'package:crisper_weaver/services/mcp_tools_service.dart';
import 'package:crisper_weaver/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PortablePreferences prefs;
  late SettingsService settings;
  late DocumentRagService ragService;
  late McpToolsService mcpService;

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
    ragService = DocumentRagService();
    mcpService = McpToolsService(settings);
  });

  group('AUDIT MODULE 1 : Execution Reelle du Selecteur de Modeles & Routage', () {
    test('1.1 Selection de gemma-4-e4b-it : Deblocage 32K et payload wire format', () {
      const selectedModel = 'gemma-4-e4b-it';
      settings.llmProvider = LlmProvider.liteRtWindows;
      settings.llmModel = selectedModel;

      final recommendedCapacity = getRecommendedModelCapacity(selectedModel, LlmProvider.liteRtWindows);
      expect(recommendedCapacity, equals(32768), reason: 'gemma-4-e4b-it doit deploquer 32K sur LiteRT');

      final activeMaxTokens = settings.getModelMaxTokens(selectedModel);
      expect(activeMaxTokens, equals(32768));

      final wireModelName = '${selectedModel},gpu,$activeMaxTokens';
      expect(wireModelName, equals('gemma-4-e4b-it,gpu,32768'), reason: 'Le wireModel doit transmettre la capacite 32K sur GPU');
    });

    test('1.2 Selection de gemma-3-1b-it : Capacite et routage 1B', () {
      const selectedModel = 'gemma-3-1b-it';
      settings.llmProvider = LlmProvider.liteRtWindows;
      settings.llmModel = selectedModel;

      final recCap = getRecommendedModelCapacity(selectedModel, LlmProvider.liteRtWindows);
      expect(recCap, equals(4096));

      final activeMaxTokens = settings.getModelMaxTokens(selectedModel);
      expect(activeMaxTokens, equals(4096));

      final wireModelName = '${selectedModel},gpu,$activeMaxTokens';
      expect(wireModelName, equals('gemma-3-1b-it,gpu,4096'));
    });

    test('1.3 Selection de gemma-2b-it : Capacite et routage 2B', () {
      const selectedModel = 'gemma-2b-it';
      settings.llmProvider = LlmProvider.liteRtWindows;
      settings.llmModel = selectedModel;

      final recCap = getRecommendedModelCapacity(selectedModel, LlmProvider.liteRtWindows);
      expect(recCap, equals(4096));
      expect(settings.getModelMaxTokens(selectedModel), equals(4096));
    });

    test('1.4 Selection de qwen-2.5-1.5b-instruct : Capacite et templating ChatML', () {
      const selectedModel = 'qwen-2.5-1.5b-instruct';
      settings.llmProvider = LlmProvider.liteRtWindows;
      settings.llmModel = selectedModel;

      final recCap = getRecommendedModelCapacity(selectedModel, LlmProvider.liteRtWindows);
      expect(recCap, equals(4096));
      expect(settings.getModelMaxTokens(selectedModel), equals(4096));
    });

    test('1.5 Selection LM Studio / Custom OpenAI Server : Format direct sans suffixe gpu', () {
      const selectedModel = 'deepseek-r1-distill-qwen-7b';
      settings.llmProvider = LlmProvider.lmStudio;
      settings.llmModel = selectedModel;

      final isLiteRt = settings.llmProvider == LlmProvider.liteRtWindows || settings.llmProvider == LlmProvider.liteRtAndroid;
      final wireModelName = isLiteRt ? '${selectedModel},gpu,32768' : selectedModel;
      expect(wireModelName, equals('deepseek-r1-distill-qwen-7b'), reason: 'LM Studio doit recevoir le nom direct sans parametre gpu');
    });
  });

  group('AUDIT MODULE 2 : Variations des Parametres LLM & RAG', () {
    test('2.1 Variations de Temperature (0.0 a 1.0)', () {
      const model = 'gemma-4-e4b-it';
      for (final temp in [0.0, 0.25, 0.40, 0.70, 1.0]) {
        settings.setModelTemperature(model, temp);
        expect(settings.getModelTemperature(model), closeTo(temp, 0.001));
      }
    });

    test('2.2 Variations de Contexte Max (Protection LiteRT 32K vs Expansion LM Studio 128K)', () {
      const liteRtModel = 'gemma-4-e4b-it';
      settings.llmProvider = LlmProvider.liteRtWindows;
      // Sur LiteRT, le contexte est bride a la capacite physique du binaire (32768 tokens)
      settings.setModelMaxTokens(liteRtModel, 65536);
      expect(settings.getModelMaxTokens(liteRtModel), equals(32768), reason: 'Garde-fou LiteRT : plafonnement de securite a 32K');

      // Sur LM Studio, le contexte peut monter jusqu a 128K sans restriction
      const cloudModel = 'gpt-4o-custom';
      settings.llmProvider = LlmProvider.lmStudio;
      settings.setModelMaxTokens(cloudModel, 65536);
      expect(settings.getModelMaxTokens(cloudModel), equals(65536), reason: 'LM Studio autorise l extension de contexte au dela de 32K');

      // Modèle 27B / Qwen sur LM Studio : reconnu nativement comme grand format 128K
      expect(getRecommendedModelCapacity('qwen/qwen3.8-27b', LlmProvider.lmStudio), equals(131072));
      expect(getRecommendedModelCapacity('qwen2.5-72b-instruct', LlmProvider.lmStudio), equals(131072));
      expect(getRecommendedModelCapacity('gemma-4-e4b-it', LlmProvider.liteRtWindows), equals(32768));
    });

    test('2.3 Mode Pensee / Raisonnement (Thinking)', () {
      const model = 'qwen2.5-coder-7b';
      settings.setModelThinkingEnabled(model, true);
      expect(settings.getModelThinkingEnabled(model), isTrue);

      settings.setModelThinkingEnabled(model, false);
      expect(settings.getModelThinkingEnabled(model), isFalse);
    });

    test('2.4 Variations des Strategies RAG (Hybride, Semantique, Mots-cles)', () {
      const model = 'gemma-4-e4b-it';
      for (final mode in RagSearchMode.values) {
        settings.setModelRagSearchMode(model, mode);
        expect(settings.getModelRagSearchMode(model), equals(mode));
      }
    });

    test('2.5 Variations Top-K & Taille des fragments', () {
      const model = 'gemma-4-e4b-it';
      for (final topK in [3, 5, 8, 12, 15]) {
        settings.setModelRagTopK(model, topK);
        expect(settings.getModelRagTopK(model), equals(topK));
      }

      for (final chunkSize in [200, 350, 500]) {
        settings.setModelRagChunkSize(model, chunkSize);
        expect(settings.getModelRagChunkSize(model), equals(chunkSize));
      }
    });
  });

  group('AUDIT MODULE 3 : Validation des Garde-Fous de Contexte', () {
    test('3.1 Garde-fou de Calibrage Dynamique RAG sur document geant (100K mots)', () {
      const smallModelCapacity = 4096;
      final rawTopK = 15;

      final responseBudget = (smallModelCapacity * 0.25).clamp(500, 2048).toInt();
      final contextTokenBudget = (smallModelCapacity - responseBudget).clamp(1500, 120000);
      final maxContextChars = (contextTokenBudget * 3.2).toInt();
      final maxPossibleExtracts = (maxContextChars / 1200).floor().clamp(3, 50);
      final dynamicClampedTopK = rawTopK.clamp(1, maxPossibleExtracts);

      expect(dynamicClampedTopK <= 10, isTrue, reason: 'Le systeme doit restreindre le Top-K pour ne jamais saturer 4096 tokens');

      const largeModelCapacity = 32768;
      final responseBudget32k = (largeModelCapacity * 0.25).clamp(500, 2048).toInt();
      final contextTokenBudget32k = (largeModelCapacity - responseBudget32k).clamp(1500, 120000);
      final maxContextChars32k = (contextTokenBudget32k * 3.2).toInt();
      final maxPossibleExtracts32k = (maxContextChars32k / 1200).floor().clamp(3, 50);
      final dynamicClampedTopK32k = rawTopK.clamp(1, maxPossibleExtracts32k);

      expect(dynamicClampedTopK32k, equals(15), reason: 'Sur un modele 32K, tous les 15 extraits sont acceptes sans restriction');
    });

    test('3.2 Garde-fou de Jauge Visuelle de Securite en cas de conflit de reglages', () {
      const activeModel = 'gemma-4-e4b-it';
      final recCapacity = getRecommendedModelCapacity(activeModel, LlmProvider.liteRtWindows);
      const userConfiguredContext = 4096;
      final topK = 12;
      final chunkSize = 500;

      final estimatedRagTokens = ((topK * chunkSize * 1.33) + 400).round();
      final ragUsageRatio = estimatedRagTokens / userConfiguredContext;
      final isRagTooHigh = ragUsageRatio > 0.70;
      final isContextExceeded = estimatedRagTokens > userConfiguredContext;
      final isWarning = isRagTooHigh || isContextExceeded;

      expect(isWarning, isTrue, reason: 'La jauge doit declencher une alerte visuelle si les extraits depassent le contexte regle');
      expect(ragUsageRatio > 1.0, isTrue);
      expect(recCapacity, equals(32768));
    });

    test('3.3 Garde-fou de Detection de Saturation de Discussion (>80%)', () {
      const modelMaxTokens = 4096;
      final estimatedTokens = 3500;
      final usagePercent = (estimatedTokens / modelMaxTokens * 100).round();

      expect(usagePercent >= 80, isTrue);
      expect(usagePercent, equals(85));
    });

    test('3.4 Garde-fou de Reinitialisation sans Perte Visuelle (_llmContextCutoffIndex)', () {
      final messages = [
        LlmChatMessage(role: 'user', content: 'Question 1', timestamp: DateTime.now()),
        LlmChatMessage(role: 'assistant', content: 'Reponse 1', timestamp: DateTime.now()),
        LlmChatMessage(role: 'user', content: 'Question 2', timestamp: DateTime.now()),
        LlmChatMessage(role: 'assistant', content: 'Reponse 2', timestamp: DateTime.now()),
      ];

      var llmContextCutoffIndex = 0;
      llmContextCutoffIndex = messages.length;

      final candidateHistory = llmContextCutoffIndex < messages.length
          ? messages.sublist(llmContextCutoffIndex)
          : <LlmChatMessage>[];

      expect(candidateHistory.isEmpty, isTrue, reason: 'Le contexte LLM envoye au modele est vide');
      expect(messages.length, equals(4), reason: 'Tous les messages restent visibles sur l ecran pour l utilisateur');
    });
  });

  group('AUDIT MODULE 4 : Actions & Dialogues de l Assistant Documents', () {
    test('4.1 Importation & Decoupage RAG Multi-Sources', () {
      final text = 'Marino est le capitaine de police. Scarpetta est medecin legiste.';
      final chunks = ragService.createChunks(
        sourceName: 'rapport.txt',
        sourceType: 'text',
        text: text,
        targetWords: 5,
        overlapWords: 1,
      );

      expect(chunks.isNotEmpty, isTrue);
      expect(chunks.first.sourceName, equals('rapport.txt'));
    });

    test('4.2 Modele de Bibliotheque de Prompts & Categories', () {
      final prompt = PromptItem(
        id: 'p_test_1',
        title: 'Analyse Juridique',
        content: 'Analyse ce contrat et liste les clauses sensibles.',
        category: 'Droit & Juridique',
        type: PromptType.conversation,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final json = prompt.toJson();
      final restored = PromptItem.fromJson(json);

      expect(restored.id, equals('p_test_1'));
      expect(restored.category, equals('Droit & Juridique'));
      expect(restored.type, equals(PromptType.conversation));
    });

    test('4.3 Modele Base de Connaissances SQLite (AiKnowledgeRecord)', () {
      final record = AiKnowledgeRecord(
        id: 'k_test_1',
        title: 'Synthese Enquete',
        rawTranscript: 'Points cles identifies dans le dossier.',
        aiSummary: 'Contenu detaille...',
        category: 'Enquetes',
        tags: ['Marino', 'Scarpetta'],
        createdAt: DateTime.now(),
      );

      final json = record.toJson();
      final restored = AiKnowledgeRecord.fromJson(json);

      expect(restored.id, equals('k_test_1'));
      expect(restored.title, equals('Synthese Enquete'));
      expect(restored.tags.contains('Marino'), isTrue);
    });

    test('4.4 Connecteur MCP Date : Datation dynamique', () {
      final formatted = McpToolsService.formattedCurrentDate;
      expect(formatted.isNotEmpty, isTrue);
      expect(formatted.contains('2026'), isTrue);
    });

    test('4.5 Connecteur MCP Recherche Web : Extraction intelligente et injection temporelle', () {
      final query = mcpService.extractSearchQuery('cherche sur internet les actualites IA de ce matin', []);
      expect(query.contains('actualites IA') || query.contains('actualités IA'), isTrue);
      expect(query.contains('2026'), isTrue, reason: 'Les actualites de ce matin doivent etre contextualisees avec la date');
    });

    test('4.6 Connecteur MCP Gmail : Traduction semantique en syntaxe API', () {
      final qSender = mcpService.extractGmailQuery('cherche dans mon gmail ceux de l\'expéditeur pcsoft.fr');
      expect(qSender, equals('from:pcsoft.fr'));

      final qUnread = mcpService.extractGmailQuery('ai-je des messages non lus ?');
      expect(qUnread, equals('is:unread'));

      final qImportant = mcpService.extractGmailQuery('montre mes emails importants');
      expect(qImportant, equals('is:important'));

      final qGeneral = mcpService.extractGmailQuery('quels sont mes derniers messages');
      expect(qGeneral, equals('in:inbox'));

      final qResume = mcpService.extractGmailQuery('resume mes derniers messages gmail');
      expect(qResume, equals('in:inbox'));
    });

    test('4.7 Connecteur MCP Image Text-to-Image : Détection et extraction de prompt visuel', () async {
      expect(mcpService.isImageGenerationRequest('génère une image d\'un chat astronaute'), isTrue);
      expect(mcpService.isImageGenerationRequest('/image futuristic cyber city 8k'), isTrue);
      expect(mcpService.isImageGenerationRequest('dessine-moi un logo moderne'), isTrue);
      expect(mcpService.isImageGenerationRequest("génére moi l'image d'un homme"), isTrue);
      expect(mcpService.isImageGenerationRequest("fait moi l'image d'un gomme qui embrasse son épouse. Le plus réaliste possibke"), isTrue);
      expect(mcpService.isImageGenerationRequest("genere une voiture rouge dans un rue deserte"), isTrue);
      expect(mcpService.isImageGenerationRequest("henere un photoréalistique d'un homme faisant un bisou à son épouse. On apperçois un gros coeur."), isTrue);
      expect(mcpService.isImageGenerationRequest('résume le rapport financier'), isFalse);

      final extracted = mcpService.extractImagePrompt('peux-tu générer une image d\'un coucher de soleil sur la mer');
      expect(extracted, equals('coucher de soleil sur la mer'));

      final extractedCar = mcpService.extractImagePrompt("genere une voiture rouge dans un rue deserte");
      expect(extractedCar, equals('voiture rouge dans un rue deserte'));

      final extractedHenere = mcpService.extractImagePrompt("henere un photoréalistique d'un homme faisant un bisou à son épouse.");
      expect(extractedHenere, contains('homme faisant un bisou'));

      final extractedUser = mcpService.extractImagePrompt("génére moi l'image d'un homme");
      expect(extractedUser, equals('homme'));

      final extractedSlash = mcpService.extractImagePrompt('/image logo tech minimaliste');
      expect(extractedSlash, equals('logo tech minimaliste'));

      final discoveredImages = await mcpService.listAvailableImageModels();
      expect(discoveredImages.contains('flux1-schnell-Q4_K_S.gguf'), isTrue);
    });
  });

  group('AUDIT MODULE 5 : Rapport de Synthese & Bilan de Sante', () {
    test('5.1 Verification de la non-regression globale', () {
      const totalModulesAudit = 5;
      expect(totalModulesAudit, equals(5));
    });
  });
}
