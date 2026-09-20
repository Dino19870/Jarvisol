import '../services/llm_service.dart';

/// A single saved AI analysis record containing transcription and LLM interactions.
class AiKnowledgeRecord {
  final String id;
  final DateTime createdAt;
  final String title;
  final String category;
  final String rawTranscript;
  final String? aiSummary;
  final String? actionItems;
  final List<LlmChatMessage> chatMessages;
  final String llmProvider;
  final String llmModel;
  final List<String> tags;

  const AiKnowledgeRecord({
    required this.id,
    required this.createdAt,
    required this.title,
    this.category = 'Général',
    required this.rawTranscript,
    this.aiSummary,
    this.actionItems,
    this.chatMessages = const [],
    this.llmProvider = 'LM Studio',
    this.llmModel = '',
    this.tags = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'title': title,
        'category': category,
        'rawTranscript': rawTranscript,
        'aiSummary': aiSummary,
        'actionItems': actionItems,
        'chatMessages': chatMessages.map((m) => m.toJson()).toList(),
        'llmProvider': llmProvider,
        'llmModel': llmModel,
        'tags': tags,
      };

  factory AiKnowledgeRecord.fromJson(Map<String, dynamic> json) {
    final rawChat = json['chatMessages'];
    List<LlmChatMessage> chat = [];
    if (rawChat is List) {
      chat = rawChat
          .map((m) => m is Map<String, dynamic>
              ? LlmChatMessage.fromJson(m)
              : (m is Map ? LlmChatMessage.fromJson(Map<String, dynamic>.from(m)) : null))
          .whereType<LlmChatMessage>()
          .toList();
    }

    final rawTags = json['tags'];
    List<String> parsedTags = [];
    if (rawTags is List) {
      parsedTags = rawTags.map((t) => t.toString()).toList();
    }

    return AiKnowledgeRecord(
      id: json['id'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      title: json['title'] as String? ?? 'Sans titre',
      category: json['category'] as String? ?? 'Général',
      rawTranscript: json['rawTranscript'] as String? ?? '',
      aiSummary: json['aiSummary'] as String?,
      actionItems: json['actionItems'] as String?,
      chatMessages: chat,
      llmProvider: json['llmProvider'] as String? ?? 'LM Studio',
      llmModel: json['llmModel'] as String? ?? '',
      tags: parsedTags,
    );
  }
}
