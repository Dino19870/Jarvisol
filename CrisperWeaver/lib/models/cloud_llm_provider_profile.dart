// lib/models/cloud_llm_provider_profile.dart — Represents custom Cloud LLM providers configured by the user.

class CloudLlmProviderProfile {
  final String id;
  final String name;
  final String endpoint;
  final String apiKey;
  final String defaultModel;
  final List<String> cachedModels;
  final double temperature;
  final int maxTokens;
  final DateTime createdAt;

  const CloudLlmProviderProfile({
    required this.id,
    required this.name,
    required this.endpoint,
    required this.apiKey,
    required this.defaultModel,
    this.cachedModels = const [],
    this.temperature = 0.7,
    this.maxTokens = 4096,
    required this.createdAt,
  });

  CloudLlmProviderProfile copyWith({
    String? id,
    String? name,
    String? endpoint,
    String? apiKey,
    String? defaultModel,
    List<String>? cachedModels,
    double? temperature,
    int? maxTokens,
    DateTime? createdAt,
  }) {
    return CloudLlmProviderProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      endpoint: endpoint ?? this.endpoint,
      apiKey: apiKey ?? this.apiKey,
      defaultModel: defaultModel ?? this.defaultModel,
      cachedModels: cachedModels ?? this.cachedModels,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'endpoint': endpoint,
        'apiKey': apiKey,
        'defaultModel': defaultModel,
        'cachedModels': cachedModels,
        'temperature': temperature,
        'maxTokens': maxTokens,
        'createdAt': createdAt.toIso8601String(),
      };

  factory CloudLlmProviderProfile.fromJson(Map<String, dynamic> json) =>
      CloudLlmProviderProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Fournisseur Cloud',
        endpoint: json['endpoint'] as String? ?? 'https://api.openai.com/v1',
        apiKey: json['apiKey'] as String? ?? '',
        defaultModel: json['defaultModel'] as String? ?? 'gpt-4o',
        cachedModels: (json['cachedModels'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
        maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 4096,
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
            : DateTime.now(),
      );

  /// Convenient presets for 1-click cloud provider setup
  static List<CloudLlmProviderProfile> get presets => [
        CloudLlmProviderProfile(
          id: 'preset_openai',
          name: 'OpenAI (Officiel)',
          endpoint: 'https://api.openai.com/v1',
          apiKey: '',
          defaultModel: 'gpt-4o',
          cachedModels: ['gpt-4o', 'gpt-4o-mini', 'o3-mini', 'gpt-4-turbo'],
          createdAt: DateTime.now(),
        ),
        CloudLlmProviderProfile(
          id: 'preset_groq',
          name: 'Groq Cloud (Ultra-Rapide)',
          endpoint: 'https://api.groq.com/openai/v1',
          apiKey: '',
          defaultModel: 'llama-3.3-70b-versatile',
          cachedModels: [
            'llama-3.3-70b-versatile',
            'llama-3.1-8b-instant',
            'mixtral-8x7b-32768',
            'deepseek-r1-distill-llama-70b'
          ],
          createdAt: DateTime.now(),
        ),
        CloudLlmProviderProfile(
          id: 'preset_mistral',
          name: 'Mistral AI (France)',
          endpoint: 'https://api.mistral.ai/v1',
          apiKey: '',
          defaultModel: 'mistral-large-latest',
          cachedModels: [
            'mistral-large-latest',
            'codestral-latest',
            'mistral-small-latest',
            'pixtral-large-latest'
          ],
          createdAt: DateTime.now(),
        ),
        CloudLlmProviderProfile(
          id: 'preset_deepseek',
          name: 'DeepSeek API',
          endpoint: 'https://api.deepseek.com/v1',
          apiKey: '',
          defaultModel: 'deepseek-chat',
          cachedModels: ['deepseek-chat', 'deepseek-reasoner'],
          createdAt: DateTime.now(),
        ),
        CloudLlmProviderProfile(
          id: 'preset_openrouter',
          name: 'OpenRouter (Multi-Modèles)',
          endpoint: 'https://openrouter.ai/api/v1',
          apiKey: '',
          defaultModel: 'anthropic/claude-3.5-sonnet',
          cachedModels: [
            'anthropic/claude-3.5-sonnet',
            'google/gemini-2.0-flash-exp:free',
            'meta-llama/llama-3.3-70b-instruct',
            'deepseek/deepseek-r1'
          ],
          createdAt: DateTime.now(),
        ),
      ];
}
