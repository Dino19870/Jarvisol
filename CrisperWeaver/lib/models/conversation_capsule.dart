// lib/models/conversation_capsule.dart
//
// Modèle de données pour la capsule de contexte conversationnel compacté.
// Respecte les 12 rubriques sémantiques obligatoires pour une compression fidèle.

class ConversationCapsule {
  final int version; // v1, v2, v3...
  final DateTime timestamp;
  final int messageStartIndex; // indice de début dans l'historique global
  final int messageEndIndex; // indice de fin dans l'historique global
  final int cutoffEpoch; // ère de réinitialisation contextuelle
  final String modelUsed; // modèle LLM ayant produit la capsule
  final int tokensBefore; // estimation tokens avant compactage
  final int tokensAfter; // estimation tokens après compactage
  final String inputHash; // hash SHA256 des messages sources

  // Les 12 rubriques sémantiques
  final String objective;
  final List<String> constraints;
  final List<String> decisions;
  final List<String> keyFacts;
  final List<String> identifiersAndPaths;
  final List<String> workDone;
  final List<String> results;
  final List<String> incidents;
  final List<String> abandoned;
  final List<String> openPoints;
  final List<String> uncertainties;
  final String nextStep;

  // Texte brut généré ou markdown alternatif
  final String rawSummary;

  const ConversationCapsule({
    required this.version,
    required this.timestamp,
    required this.messageStartIndex,
    required this.messageEndIndex,
    required this.cutoffEpoch,
    required this.modelUsed,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.inputHash,
    this.objective = '',
    this.constraints = const [],
    this.decisions = const [],
    this.keyFacts = const [],
    this.identifiersAndPaths = const [],
    this.workDone = const [],
    this.results = const [],
    this.incidents = const [],
    this.abandoned = const [],
    this.openPoints = const [],
    this.uncertainties = const [],
    this.nextStep = '',
    this.rawSummary = '',
  });

  int get tokensSaved => (tokensBefore - tokensAfter).clamp(0, tokensBefore);

  /// Convertit la capsule en chaîne Markdown structurée injectée dans le contexte LLM.
  String toContextPrompt() {
    final sb = StringBuffer();
    sb.writeln('=== CAPSULE DE CONTEXTE CONVERSATIONNEL COMPACTÉ (v$version) ===');
    sb.writeln('<!-- Messages couverts : index $messageStartIndex à $messageEndIndex | Époque : $cutoffEpoch -->');
    sb.writeln('<!-- Synthèse condensée fidèle de la discussion antérieure. Ne pas réinventer ni altérer ces faits. -->');
    sb.writeln();

    if (objective.trim().isNotEmpty) {
      sb.writeln('🎯 **Objectif actif** : $objective');
    }
    if (constraints.isNotEmpty) {
      sb.writeln('⚠️ **Contraintes actives** :');
      for (final c in constraints) {
        sb.writeln('  - $c');
      }
    }
    if (decisions.isNotEmpty) {
      sb.writeln('⚖️ **Décisions établies** :');
      for (final d in decisions) {
        sb.writeln('  - $d');
      }
    }
    if (keyFacts.isNotEmpty) {
      sb.writeln('📌 **Faits importants & données** :');
      for (final f in keyFacts) {
        sb.writeln('  - $f');
      }
    }
    if (identifiersAndPaths.isNotEmpty) {
      sb.writeln('🏷️ **Noms, Chemins, IDs & Nombres exacts** :');
      for (final id in identifiersAndPaths) {
        sb.writeln('  - $id');
      }
    }
    if (workDone.isNotEmpty) {
      sb.writeln('🔨 **Travail déjà effectué** :');
      for (final w in workDone) {
        sb.writeln('  - $w');
      }
    }
    if (results.isNotEmpty) {
      sb.writeln('📊 **Résultats obtenus** :');
      for (final r in results) {
        sb.writeln('  - $r');
      }
    }
    if (incidents.isNotEmpty) {
      sb.writeln('🚨 **Incidents / Erreurs / Limites connus** :');
      for (final inc in incidents) {
        sb.writeln('  - $inc');
      }
    }
    if (abandoned.isNotEmpty) {
      sb.writeln('❌ **Éléments rejetés ou abandonnés** :');
      for (final ab in abandoned) {
        sb.writeln('  - $ab');
      }
    }
    if (openPoints.isNotEmpty) {
      sb.writeln('❓ **Points encore ouverts** :');
      for (final op in openPoints) {
        sb.writeln('  - $op');
      }
    }
    if (uncertainties.isNotEmpty) {
      sb.writeln('⚡ **Incertitudes / Hypothèses non confirmées** :');
      for (final unc in uncertainties) {
        sb.writeln('  - $unc');
      }
    }
    if (nextStep.trim().isNotEmpty) {
      sb.writeln('➡️ **Prochaine étape attendue** : $nextStep');
    }

    if (rawSummary.trim().isNotEmpty &&
        objective.isEmpty &&
        decisions.isEmpty &&
        keyFacts.isEmpty) {
      sb.writeln(rawSummary.trim());
    }

    sb.writeln('=== FIN DE LA CAPSULE COMPACTÉE ===');
    return sb.toString();
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'timestamp': timestamp.toIso8601String(),
        'messageStartIndex': messageStartIndex,
        'messageEndIndex': messageEndIndex,
        'cutoffEpoch': cutoffEpoch,
        'modelUsed': modelUsed,
        'tokensBefore': tokensBefore,
        'tokensAfter': tokensAfter,
        'inputHash': inputHash,
        'objective': objective,
        'constraints': constraints,
        'decisions': decisions,
        'keyFacts': keyFacts,
        'identifiersAndPaths': identifiersAndPaths,
        'workDone': workDone,
        'results': results,
        'incidents': incidents,
        'abandoned': abandoned,
        'openPoints': openPoints,
        'uncertainties': uncertainties,
        'nextStep': nextStep,
        'rawSummary': rawSummary,
      };

  factory ConversationCapsule.fromJson(Map<String, dynamic> json) {
    List<String> parseList(dynamic val) {
      if (val is List) {
        return val.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      }
      return const [];
    }

    return ConversationCapsule(
      version: (json['version'] as num?)?.toInt() ?? 1,
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now(),
      messageStartIndex: (json['messageStartIndex'] as num?)?.toInt() ?? 0,
      messageEndIndex: (json['messageEndIndex'] as num?)?.toInt() ?? 0,
      cutoffEpoch: (json['cutoffEpoch'] as num?)?.toInt() ?? 0,
      modelUsed: json['modelUsed']?.toString() ?? 'unknown',
      tokensBefore: (json['tokensBefore'] as num?)?.toInt() ?? 0,
      tokensAfter: (json['tokensAfter'] as num?)?.toInt() ?? 0,
      inputHash: json['inputHash']?.toString() ?? '',
      objective: json['objective']?.toString() ?? '',
      constraints: parseList(json['constraints']),
      decisions: parseList(json['decisions']),
      keyFacts: parseList(json['keyFacts']),
      identifiersAndPaths: parseList(json['identifiersAndPaths']),
      workDone: parseList(json['workDone']),
      results: parseList(json['results']),
      incidents: parseList(json['incidents']),
      abandoned: parseList(json['abandoned']),
      openPoints: parseList(json['openPoints']),
      uncertainties: parseList(json['uncertainties']),
      nextStep: json['nextStep']?.toString() ?? '',
      rawSummary: json['rawSummary']?.toString() ?? '',
    );
  }

  ConversationCapsule copyWith({
    int? version,
    DateTime? timestamp,
    int? messageStartIndex,
    int? messageEndIndex,
    int? cutoffEpoch,
    String? modelUsed,
    int? tokensBefore,
    int? tokensAfter,
    String? inputHash,
    String? objective,
    List<String>? constraints,
    List<String>? decisions,
    List<String>? keyFacts,
    List<String>? identifiersAndPaths,
    List<String>? workDone,
    List<String>? results,
    List<String>? incidents,
    List<String>? abandoned,
    List<String>? openPoints,
    List<String>? uncertainties,
    String? nextStep,
    String? rawSummary,
  }) {
    return ConversationCapsule(
      version: version ?? this.version,
      timestamp: timestamp ?? this.timestamp,
      messageStartIndex: messageStartIndex ?? this.messageStartIndex,
      messageEndIndex: messageEndIndex ?? this.messageEndIndex,
      cutoffEpoch: cutoffEpoch ?? this.cutoffEpoch,
      modelUsed: modelUsed ?? this.modelUsed,
      tokensBefore: tokensBefore ?? this.tokensBefore,
      tokensAfter: tokensAfter ?? this.tokensAfter,
      inputHash: inputHash ?? this.inputHash,
      objective: objective ?? this.objective,
      constraints: constraints ?? this.constraints,
      decisions: decisions ?? this.decisions,
      keyFacts: keyFacts ?? this.keyFacts,
      identifiersAndPaths: identifiersAndPaths ?? this.identifiersAndPaths,
      workDone: workDone ?? this.workDone,
      results: results ?? this.results,
      incidents: incidents ?? this.incidents,
      abandoned: abandoned ?? this.abandoned,
      openPoints: openPoints ?? this.openPoints,
      uncertainties: uncertainties ?? this.uncertainties,
      nextStep: nextStep ?? this.nextStep,
      rawSummary: rawSummary ?? this.rawSummary,
    );
  }
}

/// État persistant d'une session de compactage
class CompactionSessionState {
  final String conversationId;
  final int epoch;
  final ConversationCapsule? activeCapsule;
  final List<ConversationCapsule> history;
  final DateTime lastUpdated;

  const CompactionSessionState({
    required this.conversationId,
    required this.epoch,
    this.activeCapsule,
    this.history = const [],
    required this.lastUpdated,
  });

  Map<String, dynamic> toJson() => {
        'conversationId': conversationId,
        'epoch': epoch,
        'activeCapsule': activeCapsule?.toJson(),
        'history': history.map((c) => c.toJson()).toList(),
        'lastUpdated': lastUpdated.toIso8601String(),
      };

  factory CompactionSessionState.fromJson(Map<String, dynamic> json) {
    return CompactionSessionState(
      conversationId: json['conversationId']?.toString() ?? 'default',
      epoch: (json['epoch'] as num?)?.toInt() ?? 0,
      activeCapsule: json['activeCapsule'] != null
          ? ConversationCapsule.fromJson(json['activeCapsule'] as Map<String, dynamic>)
          : null,
      history: (json['history'] as List<dynamic>?)
              ?.map((e) => ConversationCapsule.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      lastUpdated: DateTime.tryParse(json['lastUpdated']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}
