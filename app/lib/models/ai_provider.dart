class AIModelOption {
  final String id;
  final String name;
  final String description;
  final int? contextLength;

  const AIModelOption({
    required this.id,
    required this.name,
    this.description = '',
    this.contextLength,
  });

  factory AIModelOption.fromJson(Map<String, dynamic> json) {
    return AIModelOption(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['id'] as String? ?? '',
      description: json['description'] as String? ?? '',
      contextLength: json['context_length'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'context_length': contextLength,
      };
}

class AIProviderInfo {
  final String id;
  final String name;
  final String defaultModel;
  final String? baseUrl;
  final String tag;
  final String keyPlaceholder;
  final String docUrl;

  const AIProviderInfo({
    required this.id,
    required this.name,
    this.defaultModel = '',
    this.baseUrl,
    required this.tag,
    required this.keyPlaceholder,
    required this.docUrl,
  });
}

class AIConfig {
  final bool isConfigured;
  final String primaryProvider;
  final String primaryModel;
  final String? primaryApiKeyMasked;
  final String? primaryBaseUrl;

  final String? fallbackProvider;
  final String? fallbackModel;
  final String? fallbackApiKeyMasked;
  final String? fallbackBaseUrl;

  const AIConfig({
    required this.isConfigured,
    required this.primaryProvider,
    required this.primaryModel,
    this.primaryApiKeyMasked,
    this.primaryBaseUrl,
    this.fallbackProvider,
    this.fallbackModel,
    this.fallbackApiKeyMasked,
    this.fallbackBaseUrl,
  });

  factory AIConfig.fromJson(Map<String, dynamic> json) {
    return AIConfig(
      isConfigured: json['is_configured'] as bool? ?? false,
      primaryProvider: json['primary_provider'] as String? ?? 'openrouter',
      primaryModel: json['primary_model'] as String? ?? '',
      primaryApiKeyMasked: json['primary_api_key_masked'] as String?,
      primaryBaseUrl: json['primary_base_url'] as String?,
      fallbackProvider: json['fallback_provider'] as String?,
      fallbackModel: json['fallback_model'] as String?,
      fallbackApiKeyMasked: json['fallback_api_key_masked'] as String?,
      fallbackBaseUrl: json['fallback_base_url'] as String?,
    );
  }

  AIConfig copyWith({
    bool? isConfigured,
    String? primaryProvider,
    String? primaryModel,
    String? primaryApiKeyMasked,
    String? primaryBaseUrl,
    String? fallbackProvider,
    String? fallbackModel,
    String? fallbackApiKeyMasked,
    String? fallbackBaseUrl,
  }) {
    return AIConfig(
      isConfigured: isConfigured ?? this.isConfigured,
      primaryProvider: primaryProvider ?? this.primaryProvider,
      primaryModel: primaryModel ?? this.primaryModel,
      primaryApiKeyMasked: primaryApiKeyMasked ?? this.primaryApiKeyMasked,
      primaryBaseUrl: primaryBaseUrl ?? this.primaryBaseUrl,
      fallbackProvider: fallbackProvider ?? this.fallbackProvider,
      fallbackModel: fallbackModel ?? this.fallbackModel,
      fallbackApiKeyMasked: fallbackApiKeyMasked ?? this.fallbackApiKeyMasked,
      fallbackBaseUrl: fallbackBaseUrl ?? this.fallbackBaseUrl,
    );
  }
}

const List<AIProviderInfo> kSupportedProviders = [
  AIProviderInfo(
    id: 'openrouter',
    name: 'OpenRouter',
    tag: 'Aggregator',
    keyPlaceholder: 'sk-or-v1-...',
    docUrl: 'https://openrouter.ai/keys',
  ),
  AIProviderInfo(
    id: 'gemini',
    name: 'Google Gemini',
    tag: 'Official',
    keyPlaceholder: 'Enter API key...',
    docUrl: 'https://aistudio.google.com/app/apikey',
  ),
  AIProviderInfo(
    id: 'nvidia',
    name: 'NVIDIA NIM',
    tag: 'Accelerated',
    keyPlaceholder: 'nvapi-...',
    docUrl: 'https://build.nvidia.com',
  ),
  AIProviderInfo(
    id: 'groq',
    name: 'Groq',
    tag: 'Ultra-Fast',
    keyPlaceholder: 'gsk_...',
    docUrl: 'https://console.groq.com/keys',
  ),
  AIProviderInfo(
    id: 'deepseek',
    name: 'DeepSeek',
    tag: 'Cost-Effective',
    keyPlaceholder: 'sk-...',
    docUrl: 'https://platform.deepseek.com/api_keys',
  ),
  AIProviderInfo(
    id: 'openai',
    name: 'OpenAI',
    tag: 'Official',
    keyPlaceholder: 'sk-proj-...',
    docUrl: 'https://platform.openai.com/api-keys',
  ),
  AIProviderInfo(
    id: 'anthropic',
    name: 'Anthropic',
    tag: 'Official',
    keyPlaceholder: 'sk-ant-...',
    docUrl: 'https://console.anthropic.com/settings/keys',
  ),
  AIProviderInfo(
    id: 'mistral',
    name: 'Mistral AI',
    tag: 'European Frontier',
    keyPlaceholder: '...',
    docUrl: 'https://console.mistral.ai/api-keys/',
  ),
  AIProviderInfo(
    id: 'together',
    name: 'Together AI',
    tag: 'Inference Cloud',
    keyPlaceholder: '...',
    docUrl: 'https://api.together.ai/settings/api-keys',
  ),
  AIProviderInfo(
    id: 'custom',
    name: 'Custom / Local (Ollama, vLLM)',
    baseUrl: 'http://localhost:11434/v1',
    tag: 'Self-Hosted',
    keyPlaceholder: 'Optional API Key or Token',
    docUrl: 'https://ollama.ai',
  ),
];
