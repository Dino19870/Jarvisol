/// Type of prompt: System prompt (AI role & instructions) or Conversation prompt (pre-written user query).
enum PromptType {
  system,
  conversation;

  String get displayName => switch (this) {
        PromptType.system => 'Prompt Système (Rôle IA)',
        PromptType.conversation => 'Prompt de Discussion (Requête)',
      };

  String get badgeLabel => switch (this) {
        PromptType.system => '🤖 Système',
        PromptType.conversation => '💬 Discussion',
      };
}

/// Represents a single stored prompt template.
class PromptItem {
  final String id;
  final String title;
  final String content;
  final PromptType type;
  final String category;
  final String description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isBuiltIn;

  const PromptItem({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    this.category = 'Général',
    this.description = '',
    required this.createdAt,
    required this.updatedAt,
    this.isBuiltIn = false,
  });

  PromptItem copyWith({
    String? id,
    String? title,
    String? content,
    PromptType? type,
    String? category,
    String? description,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isBuiltIn,
  }) {
    return PromptItem(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      type: type ?? this.type,
      category: category ?? this.category,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'type': type.name,
        'category': category,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isBuiltIn': isBuiltIn,
      };

  factory PromptItem.fromJson(Map<String, dynamic> json) {
    return PromptItem(
      id: json['id'] as String? ?? UniqueKey().toString(),
      title: json['title'] as String? ?? 'Prompt sans titre',
      content: json['content'] as String? ?? '',
      type: (json['type'] as String?) == 'conversation'
          ? PromptType.conversation
          : PromptType.system,
      category: json['category'] as String? ?? 'Général',
      description: json['description'] as String? ?? '',
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
    );
  }
}

// Utility UniqueKey placeholder for factory when flutter isn't imported
class UniqueKey {
  @override
  String toString() => DateTime.now().microsecondsSinceEpoch.toString();
}
