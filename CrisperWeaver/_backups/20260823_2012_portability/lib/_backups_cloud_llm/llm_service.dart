import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'log_service.dart';
import 'settings_service.dart';

/// Supported local and remote LLM providers.
enum LlmProvider {
  liteRtWindows,
  lmStudio,
  ollama,
  liteRtAndroid,
  custom,
}

extension LlmProviderExtension on LlmProvider {
  String get id {
    switch (this) {
      case LlmProvider.liteRtWindows:
        return 'litert_windows';
      case LlmProvider.lmStudio:
        return 'lmstudio';
      case LlmProvider.ollama:
        return 'ollama';
      case LlmProvider.liteRtAndroid:
        return 'litert_android';
      case LlmProvider.custom:
        return 'custom';
    }
  }

  String get displayName {
    switch (this) {
      case LlmProvider.liteRtWindows:
        return 'Google LiteRT-LM (Serveur Windows)';
      case LlmProvider.lmStudio:
        return 'LM Studio';
      case LlmProvider.ollama:
        return 'Ollama';
      case LlmProvider.liteRtAndroid:
        return 'Google LiteRT-LM (Embarqué Android)';
      case LlmProvider.custom:
        return 'Personnalisé (OpenAI)';
    }
  }

  String get defaultEndpoint {
    switch (this) {
      case LlmProvider.liteRtWindows:
        return 'http://127.0.0.1:9379/v1';
      case LlmProvider.lmStudio:
        return 'http://localhost:1234/v1';
      case LlmProvider.ollama:
        return 'http://localhost:11434/v1';
      case LlmProvider.liteRtAndroid:
        return 'local_litert';
      case LlmProvider.custom:
        return 'http://localhost:1234/v1';
    }
  }
}

/// A chat message exchanged with the LLM.
class LlmChatMessage {
  final String role; // 'system', 'user', 'assistant'
  final String content;
  final DateTime timestamp;
  final String? actionPrompt;

  LlmChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.actionPrompt,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (actionPrompt != null) 'actionPrompt': actionPrompt,
      };

  factory LlmChatMessage.fromJson(Map<String, dynamic> json) => LlmChatMessage(
        role: json['role'] as String? ?? 'user',
        content: json['content'] as String? ?? '',
        actionPrompt: json['actionPrompt'] as String?,
      );
}

/// Service that communicates with local/remote LLM backends (LM Studio, Ollama, etc.).
class LlmService {
  final SettingsService _settings;
  final http.Client _client;

  LlmService(this._settings, {http.Client? client})
      : _client = client ?? http.Client();

  /// Normalized base endpoint without trailing slashes.
  String get endpoint {
    final custom = _settings.llmApiUrl;
    if (custom.isNotEmpty) {
      if (provider == LlmProvider.liteRtWindows) {
        if (custom.contains(':1234')) return LlmProvider.liteRtWindows.defaultEndpoint;
        return custom.replaceAll('localhost:9379', '127.0.0.1:9379').replaceAll(RegExp(r'/+$'), '');
      }
      if (provider == LlmProvider.lmStudio && custom.contains(':9379')) {
        return LlmProvider.lmStudio.defaultEndpoint;
      }
      return custom.replaceAll(RegExp(r'/+$'), '');
    }
    return provider.defaultEndpoint;
  }

  LlmProvider get provider => _settings.llmProvider;

  /// Check connection health and return true if reachable.
  Future<bool> checkConnection() async {
    try {
      final models = await getAvailableModels();
      return models.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// List available models from the local server.
  Future<List<String>> getAvailableModels() async {
    if (provider == LlmProvider.liteRtAndroid && Platform.isAndroid) {
      try {
        final res = await const MethodChannel('crisperweaver/litert_lm')
            .invokeListMethod<Map<dynamic, dynamic>>('listLocalModels');
        if (res != null) {
          return res.map((m) => m['path'].toString()).toList();
        }
      } catch (_) {}
      return [];
    }
    return fetchModelsForEndpoint(endpoint);
  }

  static Process? _litertProcess;

  /// Kill the LiteRT background server if it was started by the app.
  static void stopWindowsServer() {
    try {
      _litertProcess?.kill();
      _litertProcess = null;
    } catch (_) {}
  }

  /// Ensure the local LiteRT-LM server is running on Windows (http://127.0.0.1:9379/v1).
  Future<bool> _ensureWindowsServerRunning() async {
    if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) return true;
    try {
      final socket = await Socket.connect('127.0.0.1', 9379, timeout: const Duration(milliseconds: 600));
      socket.destroy();
      return true; // Server is already up, listening, and ready!
    } catch (_) {}

    try {
      Log.instance.i('llm', 'Démarrage automatique du serveur LiteRT-LM Windows en arrière-plan...');
      final userProfile = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? p.join(userProfile, r'AppData\Local');
      final appDir = p.dirname(Platform.resolvedExecutable);

      final candidates = [
        'litert-lm',
        p.join(appDir, 'litert-lm.exe'),
        p.join(appDir, 'bin', 'litert-lm.exe'),
        p.join(localAppData, r'Programs\litert-lm\litert-lm.exe'),
        p.join(localAppData, r'pipx\venvs\litert-lm\Scripts\litert-lm.exe'),
        p.join(localAppData, r'hermes\hermes-agent\venv\Scripts\litert-lm.exe'),
        p.join(userProfile, r'AppData\Local\hermes\hermes-agent\venv\Scripts\litert-lm.exe'),
        p.join(userProfile, r'.local\bin\litert-lm.exe'),
      ];

      String executable = 'litert-lm';
      for (final c in candidates) {
        if (c != 'litert-lm' && File(c).existsSync()) {
          executable = c;
          break;
        }
      }

      try {
        await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Process -FilePath "$executable" -ArgumentList "serve --port 9379" -WindowStyle Hidden',
        ]);
      } catch (_) {
        _litertProcess = await Process.start(
          executable,
          ['serve', '--port', '9379'],
          mode: ProcessStartMode.detached,
        );
      }

      for (int i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          final res = await _client.get(
            Uri.parse('http://127.0.0.1:9379/v1/models'),
          ).timeout(const Duration(milliseconds: 500));
          if (res.statusCode == 200) {
            Log.instance.i('llm', 'Serveur LiteRT-LM Windows prêt sur http://127.0.0.1:9379/v1');
            return true;
          }
        } catch (_) {}
      }
    } catch (e) {
      Log.instance.d('llm', 'Auto-start litert-lm failed: $e');
    }
    return false;
  }

  /// List available models for any given base endpoint.
  Future<List<String>> fetchModelsForEndpoint(String baseEndpoint) async {
    if (provider == LlmProvider.liteRtAndroid && Platform.isAndroid) {
      return getAvailableModels();
    }
    if (provider == LlmProvider.liteRtWindows) {
      await _ensureWindowsServerRunning();
    }
    final clean = baseEndpoint.trim().replaceAll(RegExp(r'/+$'), '');
    final url = '$clean/models';
    try {
      final res = await _client.get(
        Uri.parse(url),
        headers: _buildHeaders(),
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['data'] is List) {
          final list = (data['data'] as List)
              .map((m) => m is Map ? (m['id']?.toString() ?? '') : '')
              .where((id) => id.isNotEmpty)
              .toList();
          return list;
        }
      }
    } catch (e) {
      Log.instance.d('llm', 'fetchModelsForEndpoint failed for $url: $e');
    }
    return [];
  }

  /// Send a streaming chat completion request.
  Stream<String> streamChat({
    required List<LlmChatMessage> messages,
    String? model,
    double temperature = 0.7,
    int? maxTokens,
  }) async* {
    String targetModel = model ?? _settings.llmModel;

    if (provider == LlmProvider.liteRtWindows) {
      await _ensureWindowsServerRunning();
      final rawTarget = (model != null && model.isNotEmpty) ? model : _settings.llmModel;
      final cleanId = p.basenameWithoutExtension(rawTarget).toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');

      if (cleanId == 'gemma-4-e4b-it' || cleanId == 'gemma-4-e4b' || cleanId == '4-e4b-it' || cleanId == '4-e4b' || cleanId.contains('e4b')) {
        targetModel = 'gemma-4-e4b-it';
      } else if (cleanId == 'gemma-4-12b-it-gpu' || cleanId == 'gemma-4-12b' || cleanId.contains('12b')) {
        targetModel = 'gemma-4-12B-it-gpu';
      } else if (cleanId.contains('deepseek') || cleanId.contains('r1')) {
        targetModel = 'deepseek-r1-distill-qwen-1.5b';
      } else if (cleanId.contains('mobile') || cleanId.contains('action')) {
        targetModel = 'mobile-actions-270m';
      } else if (cleanId.contains('tiny') || cleanId.contains('garden')) {
        targetModel = 'tiny-garden-270m';
      } else if (cleanId.contains('gemma-3n-e4b') || cleanId.contains('3n-e4b')) {
        targetModel = 'gemma-3n-E4B-IT';
      } else if (cleanId.contains('gemma-3n-e2b') || cleanId.contains('3n-e2b') || cleanId.contains('3n')) {
        targetModel = 'gemma-3n-e2b-it';
      } else if (cleanId.contains('gemma-4-e2b') || cleanId.contains('4-e2b') || cleanId == 'gemma-4-gpu') {
        targetModel = 'gemma-4-gpu';
      } else if (cleanId.contains('gemma-3-1b') || cleanId.contains('3-1b')) {
        targetModel = 'gemma-3-1b-it';
      } else if (cleanId.contains('gemma-2b') || cleanId.contains('2b-it')) {
        targetModel = 'gemma-2b-it';
      } else if (cleanId.contains('gemma')) {
        targetModel = 'gemma-4-e4b-it';
      } else if (cleanId.contains('qwen')) {
        targetModel = 'qwen-2.5-1.5b-instruct';
      } else {
        targetModel = targetModel.isNotEmpty ? targetModel : 'gemma-4-e4b-it';
      }
      Log.instance.i('llm', 'Routage LiteRT Windows: modèle demandé="$model" (settings: "${_settings.llmModel}"), résolu="$targetModel" sur $endpoint');
    }
    if (provider == LlmProvider.liteRtAndroid && Platform.isAndroid) {
      // Construction du format de dialogue multi-tours adapté à la famille du modèle
      final buffer = StringBuffer();
      String? systemContext;
      for (final m in messages) {
        if (m.role == 'system') {
          systemContext = m.content;
          break;
        }
      }

      final activeModelLower = targetModel.toLowerCase();
      final isQwenOrDeepSeek = activeModelLower.contains('qwen') || activeModelLower.contains('deepseek');
      final isTinyGarden = activeModelLower.contains('tiny_garden') || activeModelLower.contains('mobile_actions') || activeModelLower.contains('garden');

      // Protection mémoire & budget tokens adapté (3000 car. pour modèles 1024 tokens, 14000 car. pour modèles 4096 tokens)
      final maxContextChars = isTinyGarden ? 3000 : 12000;
      if (systemContext != null && systemContext.length > maxContextChars) {
        systemContext = '${systemContext.substring(0, maxContextChars)}\n\n[... Début du document fourni ci-dessus pour analyse ...]';
      }

      if (isQwenOrDeepSeek) {
        // Gabarit ChatML (<|im_start|>) pour Qwen 2.5 et DeepSeek
        if (systemContext != null && systemContext.isNotEmpty) {
          buffer.writeln('<|im_start|>system');
          buffer.writeln(systemContext);
          buffer.writeln('<|im_end|>');
        }
        for (final m in messages) {
          if (m.role == 'system') continue;
          final role = m.role == 'user' ? 'user' : 'assistant';
          buffer.writeln('<|im_start|>$role');
          buffer.writeln(m.content);
          buffer.writeln('<|im_end|>');
        }
        buffer.write('<|im_start|>assistant\n');
      } else if (isTinyGarden) {
        // Gabarit Direct épuré pour TinyGarden
        if (systemContext != null && systemContext.isNotEmpty) {
          buffer.writeln('Contexte documentaire :');
          buffer.writeln(systemContext);
          buffer.writeln();
        }
        for (final m in messages) {
          if (m.role == 'system') continue;
          final role = m.role == 'user' ? 'Utilisateur' : 'Assistant';
          buffer.writeln('$role : ${m.content}');
        }
        buffer.write('Assistant : ');
      } else {
        // Format naturel pour Gemma 4 / Gemma 3 / Gemma 2
        // LiteRT-LM applique déjà le templating de dialogue en interne.
        if (systemContext != null && systemContext.isNotEmpty) {
          buffer.writeln(systemContext);
          buffer.writeln();
        }
        for (final m in messages) {
          if (m.role == 'system') continue;
          buffer.writeln(m.content);
        }
      }
      final prompt = buffer.toString();

      Log.instance.i('llm-litert', 'Lancement de la génération LiteRT sur Android (prompt: ${prompt.length} car., ${messages.length} messages dans l\'historique)');
      try {
        String? res;
        try {
          res = await const MethodChannel('crisperweaver/litert_lm')
              .invokeMethod<String>('generateResponse', {
            'prompt': prompt,
            'temperature': _settings.llmTemperature,
            'maxTokens': maxTokens ?? _settings.llmMaxTokens,
          });
        } on PlatformException catch (pe) {
          if (pe.code == 'not_initialized') {
            Log.instance.i('llm-litert', 'Auto-initialisation du modèle LiteRT sur Android...');
            final modelToLoad = _settings.llmModel.isNotEmpty ? _settings.llmModel : 'gemma-2b-it-gpu-int4.bin';
            await const MethodChannel('crisperweaver/litert_lm')
                .invokeMethod('initModel', {
              'modelPath': modelToLoad,
              'temperature': _settings.llmTemperature,
              'maxTokens': _settings.llmMaxTokens,
            });
            res = await const MethodChannel('crisperweaver/litert_lm')
                .invokeMethod<String>('generateResponse', {
              'prompt': prompt,
              'temperature': _settings.llmTemperature,
              'maxTokens': maxTokens ?? _settings.llmMaxTokens,
            });
          } else {
            rethrow;
          }
        }
        Log.instance.i('llm-litert', 'Génération LiteRT réussie (${res?.length ?? 0} caractères)');
        yield res ?? '';
      } catch (e, st) {
        Log.instance.e('llm-litert', 'Erreur LiteRT-LM', error: e, stack: st);
        yield '\n\n❌ Erreur LiteRT-LM : $e\nConsultez l\'onglet 📜 Logs & Diagnostics pour voir les détails.';
      }
      return;
    }

    final url = Uri.parse('$endpoint/chat/completions');
    final thinkingEnabled = _settings.getModelThinkingEnabled(targetModel);
    final isThinkingDisabled = !thinkingEnabled;

    final effectiveMessages = List<LlmChatMessage>.from(messages);
    if (isThinkingDisabled) {
      // Direct response directive for thinking models (DeepSeek-R1, Qwen-Thinking, LFM, etc.)
      final sysIdx = effectiveMessages.indexWhere((m) => m.role == 'system');
      const directive = '\n[Consigne absolue : Ne produis aucun bloc <think>, <thought> ni aucun préambule d\'analyse interne en anglais ("The user is asking..."). Réponds immédiatement, directement et uniquement en français.]';
      if (sysIdx >= 0) {
        effectiveMessages[sysIdx] = LlmChatMessage(
          role: 'system',
          content: '${effectiveMessages[sysIdx].content}$directive',
          timestamp: effectiveMessages[sysIdx].timestamp,
        );
      }
    }

    final isLiteRt = provider == LlmProvider.liteRtWindows || provider == LlmProvider.liteRtAndroid;
    final modelCapacity = _settings.getModelMaxTokens(targetModel);

    final wireModelName = (provider == LlmProvider.liteRtWindows)
        ? '$targetModel,gpu,$modelCapacity'
        : (targetModel.isNotEmpty ? targetModel : 'default');

    final payloadMap = <String, dynamic>{
      'model': wireModelName,
      'messages': effectiveMessages.map((m) => m.toJson()).toList(),
      'temperature': _settings.llmTemperature,
      if (!isLiteRt) 'frequency_penalty': 0.3,
      if (!isLiteRt) 'presence_penalty': 0.2,
      if (!isLiteRt) 'repetition_penalty': 1.15,
      'stream': true,
      'max_tokens': maxTokens ?? _settings.llmMaxTokens,
      if (!isLiteRt && isThinkingDisabled) 'thinking': false,
      if (!isLiteRt && isThinkingDisabled) 'chat_template_kwargs': {'thinking': false},
      if (!isLiteRt && isThinkingDisabled) 'reasoning_effort': 'none',
    };

    final bodyBytes = utf8.encode(jsonEncode(payloadMap));

    final nativeClient = HttpClient();
    HttpClientResponse res;
    try {
      final req = await nativeClient.postUrl(url);
      _buildHeaders().forEach((k, v) {
        req.headers.set(k, v);
      });
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.headers.set('Accept', 'text/event-stream, */*');
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      res = await req.close();
    } catch (e) {
      nativeClient.close();
      Log.instance.e('llm-stream', 'Erreur ouverture HTTP vers $url', error: e);
      yield '❌ Impossible de se connecter au serveur LLM sur $endpoint ($e). Vérifiez que le serveur est démarré.';
      return;
    }

    if (res.statusCode != 200) {
      final body = await res.transform(utf8.decoder).join();
      Log.instance.w('llm-stream', 'Stream error ${res.statusCode}: $body');
      yield '❌ Erreur ${res.statusCode} du serveur LLM : $body';
      return;
    }

    String lastLine = '';
    int duplicateLineCount = 0;
    final accumulatedBuffer = StringBuffer();

    try {
      final lines = res
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed == 'data: [DONE]' || trimmed == 'data:[DONE]') break;
        if (trimmed.startsWith('data:') || trimmed.startsWith('data :')) {
          final jsonStr = trimmed.substring(trimmed.indexOf(':') + 1).trim();
          if (jsonStr == '[DONE]') break;
          try {
            final data = jsonDecode(jsonStr);
            if (data is Map && data['error'] != null) {
              final err = data['error'].toString();
              Log.instance.e('llm-stream', 'Erreur SSE du serveur LLM: $err');
              yield '\n\n❌ Erreur du serveur LLM : $err';
              break;
            }
            if (data is Map && data['choices'] is List && (data['choices'] as List).isNotEmpty) {
              final choice = data['choices'][0];
              final delta = choice['delta'];
              String? chunk;
              if (delta is Map) {
                chunk = isThinkingDisabled
                    ? (delta['content'] ?? delta['text'])?.toString()
                    : (delta['content'] ?? delta['reasoning_content'] ?? delta['text'])?.toString();
              } else if (choice['text'] != null) {
                chunk = choice['text'].toString();
              }
              if (chunk != null && chunk.isNotEmpty) {
                accumulatedBuffer.write(chunk);
                if (chunk.contains('\n')) {
                  final fullText = accumulatedBuffer.toString();
                  final allLines = fullText.split('\n');
                  if (allLines.length >= 2) {
                    final prevLine = allLines[allLines.length - 2].trim();
                    if (prevLine.length > 15 && prevLine == lastLine) {
                      duplicateLineCount++;
                      if (duplicateLineCount >= 3) {
                        Log.instance.w('llm-stream', 'Disjoncteur anti-boucle activé : ligne répétée 3 fois de suite, interruption.');
                        break;
                      }
                    } else {
                      duplicateLineCount = 0;
                      if (prevLine.isNotEmpty) lastLine = prevLine;
                    }
                  }
                }
                yield chunk;
              }
            }
          } catch (_) {
            // ignore non-json SSE frames
          }
        } else if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
          try {
            final data = jsonDecode(trimmed);
            if (data is Map && data['choices'] is List && (data['choices'] as List).isNotEmpty) {
              final choice = data['choices'][0];
              final text = choice['message']?['content'] ?? choice['text'];
              if (text != null && text.toString().isNotEmpty) {
                yield text.toString();
              }
            }
          } catch (_) {}
        }
      }
    } finally {
      nativeClient.close();
    }
  }

  /// Send a non-streaming completion.
  Future<String> completeChat({
    required List<LlmChatMessage> messages,
    String? model,
    double temperature = 0.7,
  }) async {
    final targetModel = model ?? _settings.llmModel;
    final url = '$endpoint/chat/completions';

    final res = await _client.post(
      Uri.parse(url),
      headers: _buildHeaders(),
      body: jsonEncode({
        if (targetModel.isNotEmpty) 'model': targetModel,
        'messages': messages.map((m) => m.toJson()).toList(),
        'temperature': temperature,
        'stream': false,
      }),
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      if (data is Map && data['choices'] is List && (data['choices'] as List).isNotEmpty) {
        final msg = data['choices'][0]['message'];
        if (msg is Map && msg['content'] != null) {
          return msg['content'].toString();
        }
      }
    }
    throw Exception('LLM error ${res.statusCode}: ${res.body}');
  }

  Map<String, String> _buildHeaders() {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final key = _settings.llmApiKey;
    if (key.isNotEmpty) {
      headers['Authorization'] = 'Bearer $key';
    }
    return headers;
  }
}

/// Riverpod provider for LlmService.
final llmServiceProvider = Provider<LlmService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  return LlmService(settings);
});
