// lib/models/audiobook_rules.dart — customizable text cleaning, chapter detection, and dialogue diarization rules.

import 'dart:convert';

/// A single regex replacement or cleaning rule.
class TextCleaningRule {
  final String id;
  final String description;
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool enabled;

  const TextCleaningRule({
    required this.id,
    required this.description,
    required this.pattern,
    this.replacement = '',
    this.isRegex = true,
    this.enabled = true,
  });

  TextCleaningRule copyWith({
    String? id,
    String? description,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? enabled,
  }) {
    return TextCleaningRule(
      id: id ?? this.id,
      description: description ?? this.description,
      pattern: pattern ?? this.pattern,
      replacement: replacement ?? this.replacement,
      isRegex: isRegex ?? this.isRegex,
      enabled: enabled ?? this.enabled,
    );
  }

  String apply(String text) {
    if (!enabled || pattern.isEmpty) return text;
    try {
      if (isRegex) {
        final reg = RegExp(pattern, multiLine: true, caseSensitive: false);
        if (replacement.contains(r'$')) {
          return text.replaceAllMapped(reg, (match) {
            var res = replacement;
            for (int i = 1; i <= match.groupCount; i++) {
              res = res.replaceAll('\$$i', match.group(i) ?? '');
            }
            return res;
          });
        }
        return text.replaceAll(reg, replacement);
      } else {
        return text.replaceAll(pattern, replacement);
      }
    } catch (_) {
      return text;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'description': description,
        'pattern': pattern,
        'replacement': replacement,
        'isRegex': isRegex,
        'enabled': enabled,
      };

  factory TextCleaningRule.fromJson(Map<String, dynamic> json) => TextCleaningRule(
        id: json['id'] as String? ?? 'rule_${DateTime.now().millisecondsSinceEpoch}',
        description: json['description'] as String? ?? '',
        pattern: json['pattern'] as String? ?? '',
        replacement: json['replacement'] as String? ?? '',
        isRegex: json['isRegex'] as bool? ?? true,
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// Profile grouping rules for a specific book type (Standard, OCR, Theatre, etc.).
class AudiobookRuleProfile {
  final String id;
  final String name;
  final String description;
  final List<TextCleaningRule> cleaningRules;
  final String chapterRegex;
  final String dialogueMarkerRegex;
  final String femaleKeywordsRegex;
  final bool isBuiltin;

  const AudiobookRuleProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.cleaningRules,
    required this.chapterRegex,
    required this.dialogueMarkerRegex,
    required this.femaleKeywordsRegex,
    this.isBuiltin = false,
  });

  AudiobookRuleProfile copyWith({
    String? id,
    String? name,
    String? description,
    List<TextCleaningRule>? cleaningRules,
    String? chapterRegex,
    String? dialogueMarkerRegex,
    String? femaleKeywordsRegex,
    bool? isBuiltin,
  }) {
    return AudiobookRuleProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      cleaningRules: cleaningRules ?? this.cleaningRules,
      chapterRegex: chapterRegex ?? this.chapterRegex,
      dialogueMarkerRegex: dialogueMarkerRegex ?? this.dialogueMarkerRegex,
      femaleKeywordsRegex: femaleKeywordsRegex ?? this.femaleKeywordsRegex,
      isBuiltin: isBuiltin ?? this.isBuiltin,
    );
  }

  String applyCleaning(String input) {
    var result = input;
    for (final rule in cleaningRules) {
      if (rule.enabled) {
        result = rule.apply(result);
      }
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'cleaningRules': cleaningRules.map((r) => r.toJson()).toList(),
        'chapterRegex': chapterRegex,
        'dialogueMarkerRegex': dialogueMarkerRegex,
        'femaleKeywordsRegex': femaleKeywordsRegex,
        'isBuiltin': isBuiltin,
      };

  factory AudiobookRuleProfile.fromJson(Map<String, dynamic> json) => AudiobookRuleProfile(
        id: json['id'] as String? ?? 'custom',
        name: json['name'] as String? ?? 'Profil Personnalisé',
        description: json['description'] as String? ?? '',
        cleaningRules: (json['cleaningRules'] as List<dynamic>?)
                ?.map((e) => TextCleaningRule.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        chapterRegex: json['chapterRegex'] as String? ?? defaultChapterRegex,
        dialogueMarkerRegex: json['dialogueMarkerRegex'] as String? ?? defaultDialogueRegex,
        femaleKeywordsRegex: json['femaleKeywordsRegex'] as String? ?? defaultFemaleRegex,
        isBuiltin: json['isBuiltin'] as bool? ?? false,
      );

  // Default Regex Constants
  static const String defaultChapterRegex =
      r'^(?:---\s*(?:chapitre\s*/\s*section|section|chapitre|chapter)\s*(\d+|[ivxldcm]+|[a-zÀ-ÿ\-]+)\s*---|###?\s*(?:chapitre|chapter|section|\d+)|(?:(?:chapitre|chapter|partie|livre|tome|acte|sc[eè]ne|section)\s+(?:\d+|[ivxldcm]+|[a-zÀ-ÿ\-]+))|(?:prologue|epilogue|épilogue|introduction|conclusion|pr[eé]face|table of contents)|(?:[ivxldcm]{1,8})|(?:\d{1,3}))\s*(?:[:\.\-–—]\s*.*)?$';

  static const String defaultDialogueRegex = r'(?:^|\s+)[—–]\s*';

  static const String defaultFemaleRegex =
      r"\b(elle|kay|lucy|abby|maman|femme|fille|amie|soeur|sœur|m[eè]re|dis-je|fis-je|g[eé]missait|r[eé]pondit-elle|demanda-t-elle|s'exclama-t-elle|murmura-t-elle)\b";

  /// 1. Standard Profile (Novels, Epubs with dashes)
  static final AudiobookRuleProfile standard = AudiobookRuleProfile(
    id: 'standard',
    name: '📖 Standard Littéraire',
    description: 'Recommandé pour les romans récents, EPUBs propres avec tirets cadratins (—) et guillemets.',
    isBuiltin: true,
    chapterRegex: defaultChapterRegex,
    dialogueMarkerRegex: defaultDialogueRegex,
    femaleKeywordsRegex: defaultFemaleRegex,
    cleaningRules: const [
      TextCleaningRule(
        id: 'std_césures',
        description: 'Reconnecter les césures de mots coupés en fin de ligne (inves-\\n tigateur)',
        pattern: r'(\b[a-zA-ZÀ-ÿ]+)-\s*\r?\n\s*([a-zA-ZÀ-ÿ]+\b)',
        replacement: r'$1$2',
      ),
      TextCleaningRule(
        id: 'std_page_num',
        description: 'Supprimer les numéros de pages isolés (Page 12, - 45 -)',
        pattern: r'^\s*(?:page\s+)?-?\s*\d+\s*-?\s*$',
        replacement: '',
      ),
    ],
  );

  /// 2. OCR & Scanned Book Profile (Aggressive OCR noise suppression, simple hyphen support)
  static final AudiobookRuleProfile ocrScans = AudiobookRuleProfile(
    id: 'ocr_scans',
    name: '🔍 Scan Numérisé & OCR Réparateur',
    description: 'Nettoie agressivement les symboles bizarres (~, .___ .C), répare les tirets simples (-) et les espaces hachés.',
    isBuiltin: true,
    chapterRegex: defaultChapterRegex,
    // Supports both em-dash and simple hyphen at line start or after space
    dialogueMarkerRegex: r'(?:^|\s+)[—–\-]\s*',
    femaleKeywordsRegex: defaultFemaleRegex,
    cleaningRules: const [
      TextCleaningRule(
        id: 'ocr_isolated_symbols',
        description: r'Supprimer les symboles OCR orphelins (~, .___ .C, & U$, etc.)',
        pattern: r'^\s*[~,\._&\|\$\*\^/\\;]{2,}\s*.*$',
        replacement: '',
      ),
      TextCleaningRule(
        id: 'ocr_corrupted_tokens',
        description: r'Supprimer les fragments aberrants (ex: &, $, ~ au milieu de nulle part)',
        pattern: r'[&~_]{2,}',
        replacement: ' ',
      ),
      TextCleaningRule(
        id: 'ocr_césures',
        description: 'Reconnecter les césures de mots coupés (ex: con-\\n sidérable)',
        pattern: r'(\b[a-zA-ZÀ-ÿ]+)-\s*\r?\n\s*([a-zA-ZÀ-ÿ]+\b)',
        replacement: r'$1$2',
      ),
      TextCleaningRule(
        id: 'ocr_hyphen_dialogues',
        description: 'Normaliser les tirets simples en début de ligne (- Bonjour -> — Bonjour)',
        pattern: r'^\s*-\s+',
        replacement: '— ',
      ),
      TextCleaningRule(
        id: 'ocr_isolated_short_lines',
        description: 'Supprimer les micro-lignes parasites de moins de 3 caractères non alphabétiques',
        pattern: r'^\s*[^a-zA-ZÀ-ÿ0-9\s]{1,3}\s*$',
        replacement: '',
      ),
    ],
  );

  /// 3. Theatre & Scripts (ALL CAPS CHARACTER NAMES)
  static final AudiobookRuleProfile theatre = AudiobookRuleProfile(
    id: 'theatre',
    name: '🎭 Théâtre & Pièces de Scène',
    description: 'Détecte les répliques précédées de noms de personnages en MAJUSCULES (ex: JAKE : , LUCY :)',
    isBuiltin: true,
    chapterRegex: r'^(?:(?:acte|sc[eè]ne|tableau|partie)\s+(?:\d+|[ivxldcm]+|[a-zÀ-ÿ\-]+))\s*.*$',
    dialogueMarkerRegex: r'^\s*([A-ZÀ-Ÿ\s]{2,25})\s*:\s*',
    femaleKeywordsRegex: defaultFemaleRegex,
    cleaningRules: const [
      TextCleaningRule(
        id: 'theatre_didascalies',
        description: 'Mettre en retrait ou isoler les didascalies entre parenthèses (Aparté, rires)',
        pattern: r'\([^\)]+\)',
        replacement: '',
      ),
    ],
  );

  static List<AudiobookRuleProfile> get defaultProfiles => [standard, ocrScans, theatre];
}
