// lib/services/conversation_compactor_service.dart
//
// Service de compactage progressif et incrémental du contexte conversationnel.
// Conforme à la spécification R4-CMP :
// - Compactage additif et non destructif
// - Support incrémental strict (v1 -> v2 = v1 + tranche -> v3 = v2 + tranche)
// - Calcul dynamique du budget selon la capacité du modèle
// - Préservation absolue des identifiants, nombres et incertitudes
// - Écriture atomique et gestion des époques de reset mémoire

import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

import '../models/conversation_capsule.dart';
import '../utils/app_paths.dart';
import 'llm_service.dart';
import 'log_service.dart';
import 'settings_service.dart';

/// Budget global dynamique calculé pour allouer l'espace de manière chirurgicale
/// entre instructions système, métadonnées, gabarit chat, question utilisateur,
/// historique/capsule, réserve de réponse, marge explicite et fragments RAG.
class GlobalContextBudget {
  final int modelMaxTokens;
  final int responseReserve;
  final int safetyMargin;
  final int systemPromptTokens;
  final int documentInstructionsTokens;
  final int sourceMetadataTokens;
  final int chatTemplateTokens;
  final int currentUserTokens;
  final int conversationOrCapsuleTokens;
  final int remainingRagBudgetTokens;

  const GlobalContextBudget({
    required this.modelMaxTokens,
    required this.responseReserve,
    required this.safetyMargin,
    required this.systemPromptTokens,
    required this.documentInstructionsTokens,
    required this.sourceMetadataTokens,
    required this.chatTemplateTokens,
    required this.currentUserTokens,
    required this.conversationOrCapsuleTokens,
    required this.remainingRagBudgetTokens,
  });

  int get nonRagFixedTokens =>
      systemPromptTokens +
      documentInstructionsTokens +
      sourceMetadataTokens +
      chatTemplateTokens +
      currentUserTokens +
      conversationOrCapsuleTokens;

  int get totalReservedTokens => nonRagFixedTokens + responseReserve + safetyMargin;

  factory GlobalContextBudget.calculate({
    required int modelMaxTokens,
    int? responseReserve,
    int? safetyMargin,
    required int systemPromptTokens,
    required int documentInstructionsTokens,
    required int sourceMetadataTokens,
    int chatTemplateTokens = 20,
    required int currentUserTokens,
    required int conversationOrCapsuleTokens,
  }) {
    final respReserve = responseReserve ?? (modelMaxTokens * 0.25).clamp(500, 2048).toInt();
    final margin = safetyMargin ?? (modelMaxTokens * 0.05).round().clamp(80, 500);

    final nonRag = systemPromptTokens +
        documentInstructionsTokens +
        sourceMetadataTokens +
        chatTemplateTokens +
        currentUserTokens +
        conversationOrCapsuleTokens;

    final remainingRag = (modelMaxTokens - (respReserve + margin + nonRag)).clamp(0, modelMaxTokens);

    return GlobalContextBudget(
      modelMaxTokens: modelMaxTokens,
      responseReserve: respReserve,
      safetyMargin: margin,
      systemPromptTokens: systemPromptTokens,
      documentInstructionsTokens: documentInstructionsTokens,
      sourceMetadataTokens: sourceMetadataTokens,
      chatTemplateTokens: chatTemplateTokens,
      currentUserTokens: currentUserTokens,
      conversationOrCapsuleTokens: conversationOrCapsuleTokens,
      remainingRagBudgetTokens: remainingRag,
    );
  }
}

class CompactorBudget {
  final int modelMaxTokens;
  final int systemPromptTokens;
  final int docOrRagTokens;
  final int reserveOutputTokens;
  final int safetyMarginTokens;
  final int effectiveBudget;
  final int triggerThresholdTokens; // ~78%
  final int criticalThresholdTokens; // ~90%
  final int targetPostCompactionTokens; // ~50%
  final int recentZoneTokensTarget; // ~20%
  final int capsuleBudgetTokens; // ~8-10% (borne 400-2000)

  const CompactorBudget({
    required this.modelMaxTokens,
    required this.systemPromptTokens,
    required this.docOrRagTokens,
    required this.reserveOutputTokens,
    required this.safetyMarginTokens,
    required this.effectiveBudget,
    required this.triggerThresholdTokens,
    required this.criticalThresholdTokens,
    required this.targetPostCompactionTokens,
    required this.recentZoneTokensTarget,
    required this.capsuleBudgetTokens,
  });

  factory CompactorBudget.calculate({
    required int modelMaxTokens,
    int systemPromptTokens = 800,
    int docOrRagTokens = 1500,
    int reserveOutputTokens = 1500,
    int safetyMarginTokens = 500,
  }) {
    final effective = (modelMaxTokens - (systemPromptTokens + docOrRagTokens + reserveOutputTokens + safetyMarginTokens))
        .clamp(500, modelMaxTokens);

    final trigger = (modelMaxTokens * 0.78).round();
    final critical = (modelMaxTokens * 0.90).round();
    final targetPost = (modelMaxTokens * 0.50).round();
    final recentZone = (modelMaxTokens * 0.20).round().clamp(400, 4000);
    final capsule = (modelMaxTokens * 0.08).round().clamp(400, 2000);

    return CompactorBudget(
      modelMaxTokens: modelMaxTokens,
      systemPromptTokens: systemPromptTokens,
      docOrRagTokens: docOrRagTokens,
      reserveOutputTokens: reserveOutputTokens,
      safetyMarginTokens: safetyMarginTokens,
      effectiveBudget: effective,
      triggerThresholdTokens: trigger,
      criticalThresholdTokens: critical,
      targetPostCompactionTokens: targetPost,
      recentZoneTokensTarget: recentZone,
      capsuleBudgetTokens: capsule,
    );
  }

  bool shouldTriggerAutoCompaction(int currentTokens) {
    return currentTokens >= triggerThresholdTokens;
  }

  bool isCritical(int currentTokens) {
    return currentTokens >= criticalThresholdTokens;
  }
}

class CompactionPartitionResult {
  final List<LlmChatMessage> zoneToCompact;
  final List<LlmChatMessage> recentZoneToKeep;
  final int compactStartIndex;
  final int compactEndIndex;

  const CompactionPartitionResult({
    required this.zoneToCompact,
    required this.recentZoneToKeep,
    required this.compactStartIndex,
    required this.compactEndIndex,
  });
}

class ConversationCompactorService {
  final Ref? ref;

  ConversationCompactorService([this.ref]);

  static int estimateTextTokens(String text) {
    if (text.isEmpty) return 0;
    return (text.length / 3.2).ceil();
  }

  static int estimateMessagesTokens(List<LlmChatMessage> messages) {
    int total = 0;
    for (final m in messages) {
      total += estimateTextTokens(m.content) + 4;
    }
    return total;
  }

  CompactorBudget computeBudget({
    required int modelMaxTokens,
    int systemPromptTokens = 800,
    int docOrRagTokens = 1500,
  }) {
    return CompactorBudget.calculate(
      modelMaxTokens: modelMaxTokens,
      systemPromptTokens: systemPromptTokens,
      docOrRagTokens: docOrRagTokens,
    );
  }

  CompactionPartitionResult partitionHistory({
    required List<LlmChatMessage> allMessages,
    required int startIndex,
    required CompactorBudget budget,
  }) {
    if (startIndex >= allMessages.length) {
      return CompactionPartitionResult(
        zoneToCompact: const [],
        recentZoneToKeep: const [],
        compactStartIndex: startIndex,
        compactEndIndex: startIndex,
      );
    }

    final candidateMessages = allMessages.sublist(startIndex);
    if (candidateMessages.length <= 4) {
      return CompactionPartitionResult(
        zoneToCompact: const [],
        recentZoneToKeep: candidateMessages,
        compactStartIndex: startIndex,
        compactEndIndex: startIndex,
      );
    }

    int accumulatedRecentTokens = 0;
    int splitFromEnd = 0;

    for (int i = candidateMessages.length - 1; i >= 0; i--) {
      final msgTokens = estimateTextTokens(candidateMessages[i].content) + 4;
      if (accumulatedRecentTokens + msgTokens > budget.recentZoneTokensTarget && splitFromEnd >= 3) {
        break;
      }
      accumulatedRecentTokens += msgTokens;
      splitFromEnd++;
      if (splitFromEnd >= 10) break;
    }

    final splitPoint = candidateMessages.length - splitFromEnd;
    if (splitPoint <= 0) {
      return CompactionPartitionResult(
        zoneToCompact: const [],
        recentZoneToKeep: candidateMessages,
        compactStartIndex: startIndex,
        compactEndIndex: startIndex,
      );
    }

    final toCompact = candidateMessages.sublist(0, splitPoint);
    final toKeep = candidateMessages.sublist(splitPoint);

    return CompactionPartitionResult(
      zoneToCompact: toCompact,
      recentZoneToKeep: toKeep,
      compactStartIndex: startIndex,
      compactEndIndex: startIndex + splitPoint - 1,
    );
  }

  String buildCompactionInstructionPrompt({
    required List<LlmChatMessage> newMessagesToCompact,
    ConversationCapsule? previousCapsule,
    int maxCapsuleTokens = 1500,
  }) {
    final sb = StringBuffer();
    sb.writeln('Tu es un moteur expert en compression sémantique de contexte conversationnel pour LLM.');
    sb.writeln('Ton rôle est d\'analyser une tranche de messages d\'une conversation et d\'en produire une synthèse ultra-fidèle, structurée et sans déperdition d\'informations critiques.');
    sb.writeln();

    if (previousCapsule != null) {
      sb.writeln('### CAPSULE PRÉCÉDENTE (v${previousCapsule.version}) À METTRE À JOUR INCRÉMENTALEMENT :');
      sb.writeln(previousCapsule.toContextPrompt());
      sb.writeln();
      sb.writeln('DIRECTIVE D\'INCRÉMENTATION :');
      sb.writeln('- Intègre les nouveaux faits de la tranche ci-dessous dans la synthèse précédente.');
      sb.writeln('- Si une décision ou contrainte antérieure a été contredite ou modifiée dans la nouvelle tranche, mets-la à jour explicitement.');
      sb.writeln('- Les faits établis précédemment qui restent valides doivent être conservés.');
    } else {
      sb.writeln('Il s\'agit du premier compactage (v1). Analyse l\'ensemble des messages fournis ci-dessous.');
    }

    sb.writeln();
    sb.writeln('### NOUVEAUX MESSAGES À COMPACTER :');
    for (int i = 0; i < newMessagesToCompact.length; i++) {
      final msg = newMessagesToCompact[i];
      final role = msg.role == 'user' ? 'UTILISATEUR' : 'ASSISTANT';
      sb.writeln('[$role] : ${msg.content}');
      sb.writeln('---');
    }

    sb.writeln();
    sb.writeln('### RÈGLES CRITIQUES DE PRÉSERVATION :');
    sb.writeln('1. Noms de fichiers, chemins, identifiants, hashs, codes d\'erreurs et nombres exacts doivent être conservés TEXTUELLEMENT.');
    sb.writeln('2. Les incertitudes, avertissements ou doutes émis par l\'utilisateur ou l\'assistant doivent être conservés explicitement dans la rubrique dédiée.');
    sb.writeln('3. Les éléments rejetés ou abandonnés doivent être notés pour ne pas être reproposés.');
    sb.writeln('4. Taille cible : environ $maxCapsuleTokens tokens maximum.');
    sb.writeln();
    sb.writeln('Tu DOIS répondre au format JSON strict avec les clés suivantes :');
    sb.writeln('{\n  "objective": "Objectif",\n  "constraints": [],\n  "decisions": [],\n  "keyFacts": [],\n  "identifiersAndPaths": [],\n  "workDone": [],\n  "results": [],\n  "incidents": [],\n  "abandoned": [],\n  "openPoints": [],\n  "uncertainties": [],\n  "nextStep": "Action suivante"\n}');

    return sb.toString();
  }

  ConversationCapsule? parseCapsuleResponse({
    required String responseText,
    required int nextVersion,
    required int messageStartIndex,
    required int messageEndIndex,
    required int cutoffEpoch,
    required String modelUsed,
    required int tokensBefore,
    required String inputHash,
  }) {
    if (responseText.trim().isEmpty) {
      Log.instance.w('compactor', 'Réponse LLM vide.');
      return null;
    }

    String cleanJson = responseText.trim();
    final jsonBlockMatch = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(cleanJson);
    if (jsonBlockMatch != null) {
      cleanJson = jsonBlockMatch.group(1)!.trim();
    } else {
      final firstBrace = cleanJson.indexOf('{');
      final lastBrace = cleanJson.lastIndexOf('}');
      if (firstBrace != -1 && lastBrace != -1 && lastBrace > firstBrace) {
        cleanJson = cleanJson.substring(firstBrace, lastBrace + 1);
      }
    }

    try {
      final decoded = jsonDecode(cleanJson);
      if (decoded is! Map<String, dynamic>) {
        Log.instance.w('compactor', 'Format JSON non conforme (pas un objet Map).');
        return null;
      }
      final map = decoded;

      List<String> extractList(String key) {
        final val = map[key];
        if (val is List) {
          return val.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
        }
        return const [];
      }

      final objective = map['objective']?.toString().trim() ?? '';
      final constraints = extractList('constraints');
      final decisions = extractList('decisions');
      final keyFacts = extractList('keyFacts');
      final identifiersAndPaths = extractList('identifiersAndPaths');
      final workDone = extractList('workDone');
      final results = extractList('results');
      final incidents = extractList('incidents');
      final abandoned = extractList('abandoned');
      final openPoints = extractList('openPoints');
      final uncertainties = extractList('uncertainties');
      final nextStep = map['nextStep']?.toString().trim() ?? '';

      // Validation sémantique minimale (Section 3) :
      // La capsule ne doit pas être manifestement vide. Au moins l'objectif OU des faits/décisions/travaux doivent être présents.
      final hasMeaningfulContent = objective.isNotEmpty ||
          decisions.isNotEmpty ||
          keyFacts.isNotEmpty ||
          workDone.isNotEmpty ||
          results.isNotEmpty ||
          constraints.isNotEmpty;

      if (!hasMeaningfulContent) {
        Log.instance.w('compactor', 'Capsule rejetée : contenu sémantique insuffisant ou vide.');
        return null;
      }

      final capsule = ConversationCapsule(
        version: nextVersion,
        timestamp: DateTime.now(),
        messageStartIndex: messageStartIndex,
        messageEndIndex: messageEndIndex,
        cutoffEpoch: cutoffEpoch,
        modelUsed: modelUsed,
        tokensBefore: tokensBefore,
        tokensAfter: 0,
        inputHash: inputHash,
        objective: objective,
        constraints: constraints,
        decisions: decisions,
        keyFacts: keyFacts,
        identifiersAndPaths: identifiersAndPaths,
        workDone: workDone,
        results: results,
        incidents: incidents,
        abandoned: abandoned,
        openPoints: openPoints,
        uncertainties: uncertainties,
        nextStep: nextStep,
      );

      final tokensAfter = estimateTextTokens(capsule.toContextPrompt());
      return capsule.copyWith(tokensAfter: tokensAfter);
    } catch (e) {
      Log.instance.w('compactor', 'Parsing JSON de la capsule échoué ($e). Rejet strict de la sortie invalide.');
      return null;
    }
  }

  static String computeInputHash(List<LlmChatMessage> messages, ConversationCapsule? prevCapsule) {
    final sb = StringBuffer();
    if (prevCapsule != null) {
      sb.write('prev:${prevCapsule.version}:${prevCapsule.inputHash};');
    }
    for (final m in messages) {
      sb.write('${m.role}:${m.content};');
    }
    return sha256.convert(utf8.encode(sb.toString())).toString();
  }

  Future<ConversationCapsule?> executeCompaction({
    required List<LlmChatMessage> messagesToCompact,
    ConversationCapsule? previousCapsule,
    required int cutoffEpoch,
    required LlmService llmService,
    required SettingsService settings,
    required CompactorBudget budget,
  }) async {
    if (messagesToCompact.isEmpty) return previousCapsule;

    final nextVersion = (previousCapsule?.version ?? 0) + 1;
    final tokensBefore = (previousCapsule?.tokensAfter ?? 0) + estimateMessagesTokens(messagesToCompact);
    final inputHash = computeInputHash(messagesToCompact, previousCapsule);

    final instructionPrompt = buildCompactionInstructionPrompt(
      newMessagesToCompact: messagesToCompact,
      previousCapsule: previousCapsule,
      maxCapsuleTokens: budget.capsuleBudgetTokens,
    );

    Log.instance.i('compactor', 'Démarrage compactage incrémental vers v$nextVersion (tokens d\'entrée estimés: $tokensBefore, budget capsule: ${budget.capsuleBudgetTokens})');

    try {
      final messages = [
        LlmChatMessage(role: 'system', content: instructionPrompt),
        LlmChatMessage(role: 'user', content: 'Génère la capsule de contexte conversationnel compacté en respectant scrupuleusement la structure demandée.'),
      ];

      final stream = llmService.streamChat(messages: messages);
      final sb = StringBuffer();

      await for (final chunk in stream) {
        sb.write(chunk);
      }

      final fullResponse = sb.toString().trim();
      if (fullResponse.isEmpty) {
        Log.instance.w('compactor', 'Échec compactage : réponse vide du LLM.');
        return null;
      }

      final capsule = parseCapsuleResponse(
        responseText: fullResponse,
        nextVersion: nextVersion,
        messageStartIndex: previousCapsule?.messageStartIndex ?? 0,
        messageEndIndex: (previousCapsule?.messageEndIndex ?? 0) + messagesToCompact.length,
        cutoffEpoch: cutoffEpoch,
        modelUsed: settings.llmModel,
        tokensBefore: tokensBefore,
        inputHash: inputHash,
      );

      if (capsule == null) {
        Log.instance.w('compactor', 'Échec compactage : réponse non structurée ou invalide rejetée.');
        return null;
      }

      Log.instance.i('compactor', 'Compactage v$nextVersion réussi : $tokensBefore -> ${capsule.tokensAfter} tokens (gain: ${capsule.tokensSaved} tokens)');
      return capsule;
    } catch (e, st) {
      Log.instance.e('compactor', 'Erreur lors du compactage LLM : $e', fields: {'stack': st.toString()});
      return null;
    }
  }

  Future<void> saveCompactionStateAtomically(CompactionSessionState session) async {
    try {
      final dir = AppPaths.compactionCapsulesDir;
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      final targetFile = File(p.join(dir.path, 'session_${session.conversationId}.json'));
      final tempFile = File('${targetFile.path}.tmp_${DateTime.now().millisecondsSinceEpoch}');

      final jsonStr = const JsonEncoder.withIndent('  ').convert(session.toJson());
      await tempFile.writeAsString(jsonStr, flush: true);

      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }
      await tempFile.rename(targetFile.path);

      if (session.activeCapsule != null) {
        final versionFile = File(p.join(dir.path, 'capsule_${session.conversationId}_v${session.activeCapsule!.version}.json'));
        final verJson = const JsonEncoder.withIndent('  ').convert(session.activeCapsule!.toJson());
        await versionFile.writeAsString(verJson, flush: true);
      }
    } catch (e) {
      Log.instance.w('compactor', 'Échec sauvegarde atomique capsule : $e');
    }
  }

  Future<CompactionSessionState?> loadCompactionState(String conversationId) async {
    try {
      final targetFile = File(p.join(AppPaths.compactionCapsulesDir.path, 'session_$conversationId.json'));
      if (!targetFile.existsSync()) return null;

      final content = await targetFile.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
      return CompactionSessionState.fromJson(map);
    } catch (e) {
      Log.instance.w('compactor', 'Échec lecture session compactage : $e');
      return null;
    }
  }
}

final conversationCompactorServiceProvider = Provider<ConversationCompactorService>((ref) {
  return ConversationCompactorService(ref);
});
