import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'llm_service.dart';
import '../utils/platform_utils.dart' as plat;
import 'log_service.dart';
import 'settings_service.dart';

/// Central Portable Service for Date Injection, Web Search, and Gmail MCP connectors.
class McpToolsService {
  final SettingsService _settings;

  McpToolsService(this._settings);

  /// Returns the current date formatted in French (e.g. "vendredi 21 août 2026").
  static String get formattedCurrentDate {
    final now = DateTime.now();
    const days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'
    ];
    final dayName = days[now.weekday - 1];
    final monthName = months[now.month - 1];
    return '$dayName ${now.day} $monthName ${now.year}';
  }

  /// Injects the current date into the system prompt if the tool is enabled.
  String enrichPromptWithDate(String baseSystemPrompt) {
    if (!_settings.enableCurrentDateTool) return baseSystemPrompt;
    final dateStr = formattedCurrentDate;
    return 'Aujourd\'hui nous sommes le $dateStr.\n\n$baseSystemPrompt';
  }

  /// Gets the absolute path to the portable `mcp_servers` directory.
  Future<String> get _portableMcpServersDir async {
    if (plat.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final dir = Directory(p.join(exeDir, 'mcp_servers'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir.path;
    }
    final appDir = Directory.current;
    final dir = Directory(p.join(appDir.path, 'mcp_servers'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Smart query extractor to turn conversational prompts into clean web search terms.
  String extractSearchQuery(String currentText, List<dynamic> history) {
    var clean = currentText
        .replaceAll(RegExp(r'tu as (un|des)?\s*mcp.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'tu as (accès|access) à internet.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'fais?( une)?\s*(des)?\s*recherches?.*?(dans|sur|avec)?', caseSensitive: false), '')
        .replaceAll(RegExp(r'recherche (sur|dans|les)?\s*(le web|internet|google)?', caseSensitive: false), '')
        .replaceAll(RegExp(r'cherche (sur|dans|les)?\s*(le web|internet|google)?', caseSensitive: false), '')
        .replaceAll(RegExp(r'peux-tu (me )?(chercher|trouver|dire).*?(sur)?', caseSensitive: false), '')
        .trim();

    clean = clean.replaceAll(RegExp(r'^[,\.\s:\?!]+|[,\.\s:\?!]+$'), '');

    final isMeta = clean.isEmpty ||
        clean.contains('sources') ||
        clean.contains('donner') ||
        clean.contains('viens de') ||
        clean.length < 3;

    if (isMeta) {
      for (final msg in history.reversed) {
        try {
          final role = (msg as dynamic).role as String?;
          final content = (msg as dynamic).content as String?;
          if (role == 'user' && content != null) {
            final prevClean = content
                .replaceAll(RegExp(r'recherche (sur|dans)?\s*(le web|internet)?', caseSensitive: false), '')
                .replaceAll(RegExp(r'tu as (un|des)?\s*mcp.*', caseSensitive: false), '')
                .trim();
            if (prevClean.length >= 3 && !prevClean.contains('sources')) {
              clean = prevClean;
              break;
            }
          }
        } catch (_) {}
      }
    }

    final queryCandidate = clean.isNotEmpty ? clean : currentText;

    // Temporal contextualization: if user mentions today / ce matin / actualités, append current date
    final queryLower = queryCandidate.toLowerCase();
    if (queryLower.contains('aujourd') || queryLower.contains('ce matin') || queryLower.contains('ce soir') || queryLower.contains('actu') || queryLower.contains('nouvelles')) {
      final now = DateTime.now();
      const months = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
      final dateTag = '${now.day} ${months[now.month - 1]} ${now.year}';
      if (!queryLower.contains('${now.year}')) {
        return '$queryCandidate $dateTag';
      }
    }

    return queryCandidate;
  }

  /// Performs a portable web search using DuckDuckGo API & HTML fallback.
  Future<String> searchWeb(String query) async {
    try {
      final uri = Uri.parse(
          'https://html.duckduckgo.com/html/?q=${Uri.encodeComponent(query)}');
      final response = await http.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final html = response.body;
        final reg = RegExp(r'<a class="result__snippet[^>]*>(.*?)<\/a>',
            dotAll: true, caseSensitive: false);
        final matches = reg.allMatches(html);

        final results = <String>[];
        for (final m in matches.take(5)) {
          final cleanSnippet = m
              .group(1)!
              .replaceAll(RegExp(r'<[^>]*>'), '')
              .replaceAll('&quot;', '"')
              .replaceAll('&amp;', '&')
              .replaceAll('&#x27;', "'")
              .replaceAll('&#39;', "'")
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>')
              .replaceAll('&nbsp;', ' ')
              .trim();
          if (cleanSnippet.isNotEmpty) {
            results.add('• $cleanSnippet');
          }
        }

        if (results.isNotEmpty) {
          return 'Résultats de recherche Web pour "$query" :\n${results.join("\n")}';
        }
      }
      return 'Aucun résultat Web concluant trouvé pour "$query".';
    } catch (e) {
      Log.instance.e('mcp_tools', 'Web search error: $e');
      return 'Erreur lors de la recherche Web : $e';
    }
  }

  /// Checks if portable Gmail OAuth credentials exist in `mcp_servers/gmail/`.
  Future<bool> hasGmailCredentials() async {
    final mcpDir = await _portableMcpServersDir;
    final credFile = File(p.join(mcpDir, 'gmail', 'credentials.json'));
    return await credFile.exists();
  }

  /// Extracts clean Gmail API search syntax from natural language.
  String extractGmailQuery(String prompt) {
    final pTrim = prompt.trim();
    final pLower = pTrim.toLowerCase();

    if (pLower.contains('non lu') || pLower.contains('unread') || pLower.contains('pas lu')) {
      return 'is:unread';
    }
    if (pLower.contains('important') || pLower.contains('urgent')) {
      return 'is:important';
    }
    if (pLower.contains('brouillon') || pLower.contains('draft')) {
      return 'is:draft';
    }
    if (pLower.contains('envoyé') || pLower.contains('sent')) {
      return 'in:sent';
    }
    if (pLower.contains('corbeille') || pLower.contains('trash')) {
      return 'in:trash';
    }

    // Check for explicit sender patterns: "expéditeur X", "de X", "de la part de X", "provenant de X"
    final senderMatch = RegExp(
      r"(?:exp[eé]diteur|de\s+la\s+part\s+de|provenant\s+de|de\s+l'exp[eé]diteur)\s+([a-zA-Z0-9@\._-]+)",
      caseSensitive: false,
    ).firstMatch(pTrim);

    if (senderMatch != null) {
      final sender = senderMatch.group(1)!.trim();
      if (sender.isNotEmpty && !['mon', 'mes', 'ceux', 'cet', 'cette', 'gmail', 'mail', 'courriel'].contains(sender.toLowerCase())) {
        return 'from:$sender';
      }
    }

    // General keyword extraction: remove common conversational stop-phrases and action verbs
    final clean = pTrim
        .replaceAll(RegExp(r"(r[eé]sume|synth[eé]tise|synth[eé]se|analyse|r[eé]capitule|r[eé]cap|lis|extrais)\s+(moi\s+)?", caseSensitive: false), '')
        .replaceAll(RegExp(r"cherche\s+(dans\s+)?(mon\s+)?(gmail|bo[iî]te|mails?|courriels?|messages?)", caseSensitive: false), '')
        .replaceAll(RegExp(r"regarde\s+(dans\s+)?(mon\s+)?(gmail|bo[iî]te|mails?|courriels?|messages?)", caseSensitive: false), '')
        .replaceAll(RegExp(r"(mes\s+)?(derniers?\s+)?(e?mails?|courriels?|messages?|gmail)", caseSensitive: false), '')
        .replaceAll(RegExp(r"quelles?\s+sont\s+(les\s+)?", caseSensitive: false), '')
        .replaceAll(RegExp(r"ceux\s+de\s+(l'exp[eé]diteur\s+)?", caseSensitive: false), '')
        .replaceAll(RegExp(r"(donne|affiche|montre|trouve|quels?\s+sont)\s+(moi\s+)?", caseSensitive: false), '')
        .replaceAll(RegExp(r"^[,\.\s:\?!'\-]+|[,\.\s:\?!'\-]+$"), '')
        .trim();

    if (clean.isEmpty || clean.length < 3 || ['resume', 'résume', 'recap', 'mails', 'messages', 'derniers'].contains(clean.toLowerCase())) {
      return 'in:inbox';
    }

    // If it contains an email domain or address (e.g. pcsoft.fr or user@domain.com)
    if (clean.contains('@') || clean.contains('.fr') || clean.contains('.com') || clean.contains('.org') || clean.contains('.net')) {
      return 'from:$clean';
    }

    return clean;
  }

  /// Executes an interactive JSON-RPC query on the portable Gmail MCP server.
  Future<String> queryGmail(String query) async {
    try {
      final mcpDir = await _portableMcpServersDir;
      final gmailDir = p.join(mcpDir, 'gmail');
      final credPath = p.join(gmailDir, 'credentials.json');
      final keysPath = p.join(gmailDir, 'gcp-oauth.keys.json');

      if (!await File(credPath).exists() || !await File(keysPath).exists()) {
        return '⚠️ Fichiers d\'accès Gmail introuvables dans "$gmailDir". Veuillez placer "credentials.json" et "gcp-oauth.keys.json" dans ce dossier.';
      }

      // Determine the best Gmail MCP tool to call based on the user prompt
      const String toolName = 'gmail_list_emails';
      final effectiveQuery = extractGmailQuery(query);
      final toolArgs = <String, dynamic>{'query': effectiveQuery, 'maxResults': 5};

      final process = await Process.start(
        'cmd.exe',
        ['/c', 'npx', '-y', '@monsoft/mcp-gmail@0.4.0'],
        environment: {
          'GMAIL_OAUTH_PATH': keysPath,
          'GMAIL_CREDENTIALS_PATH': credPath,
        },
        runInShell: true,
      );

      final completer = Completer<String>();

      final sub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.trim().isEmpty) return;
        try {
          final jsonMsg = jsonDecode(line) as Map<String, dynamic>;
          final id = jsonMsg['id'];
          if (id == 2) {
            final result = jsonMsg['result'] as Map<String, dynamic>?;
            final contentList = result?['content'] as List<dynamic>?;
            if (contentList != null && contentList.isNotEmpty) {
              final text = contentList
                  .map((c) => (c as Map<String, dynamic>)['text']?.toString() ?? '')
                  .join('\n');
              if (!completer.isCompleted) completer.complete(text);
            } else if (!completer.isCompleted) {
              completer.complete('Aucun e-mail trouvé pour cette recherche.');
            }
          }
        } catch (_) {}
      });

      // 1. Initialize
      process.stdin.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, dynamic>{
          'protocolVersion': '2024-11-05',
          'capabilities': <String, dynamic>{},
          'clientInfo': <String, dynamic>{'name': 'CrisperWeaver', 'version': '1.0.0'}
        }
      }));
      process.stdin.writeln(jsonEncode(<String, dynamic>{'jsonrpc': '2.0', 'method': 'notifications/initialized', 'params': <String, dynamic>{}}));

      // 2. Call tool
      process.stdin.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': toolName,
          'arguments': toolArgs,
        }
      }));

      final emailContent = await completer.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => '⏱️ Délai de réponse du serveur Gmail dépassé.',
      );

      await sub.cancel();
      process.kill();

      return '✉️ Données récentes de votre boîte Gmail :\n$emailContent';
    } catch (e) {
      Log.instance.e('mcp_tools', 'Gmail query error: $e');
      return 'Erreur lors de la communication Gmail MCP : $e';
    }
  }

  /// Checks if a prompt is an explicit image generation command (e.g. /image, /draw).
  bool isExplicitImageCommand(String prompt) {
    final lower = prompt.toLowerCase().trim();
    return lower.startsWith('/image') ||
        lower.startsWith('/img') ||
        lower.startsWith('/draw') ||
        lower.startsWith('/flux') ||
        lower.startsWith('/photo') ||
        lower.startsWith('/sd');
  }

  /// Checks if a user prompt is requesting an image generation.
  bool isImageGenerationRequest(String prompt) {
    final lower = prompt.toLowerCase().trim();
    if (isExplicitImageCommand(prompt)) {
      return true;
    }

    // Direct diffusion prompt markers (when user types raw english prompt)
    final diffusionMarkers = [
      'photorealistic', '8k resolution', '8k uhd', 'cinematic lighting', 'masterpiece', 'sharp focus',
      'highly detailed', 'ultra detailed', 'digital art', 'oil painting', 'hyperrealistic', 'unreal engine'
    ];
    if (diffusionMarkers.any((m) => lower.contains(m))) {
      return true;
    }

    final visualPrefixes = [
      'a photo of', 'photo of', 'a portrait of', 'portrait of', 'an image of', 'image of',
      'a painting of', 'painting of', 'a close-up of', 'close-up of', 'a picture of', 'picture of'
    ];
    if (visualPrefixes.any((p) => lower.startsWith(p))) {
      return true;
    }

    // Garde-fou textuel : si la demande concerne l'analyse textuelle/RAG, ce n'est JAMAIS une génération d'image
    final textualKeywords = [
      'synthèse', 'synthese', 'résumé', 'resume', 'rapport', 'document', 'documents', 'texte', 'textes',
      'faq', 'question', 'questions', 'analyse', 'analyser', 'extraits', 'extrait', 'chapitre', 'note',
      'pdf', 'docx', 'epub', 'livre', 'histoire', 'traduis', 'traduire', 'explique', 'expliquer', 'points clés', 'points cles'
    ];
    if (textualKeywords.any((k) => lower.contains(k))) {
      return false;
    }

    // Pure visual verbs: dessine, peins, illustre
    final pureVisualVerbs = ['dessine', 'dessiner', 'peins', 'peindre', 'illustre', 'illustrer', 'draw', 'paint'];
    if (pureVisualVerbs.any((v) => lower.startsWith(v) || lower.contains(' $v '))) {
      return true;
    }

    // Creation verbs + visual nouns
    final creationVerbs = [
      'génère', 'genere', 'génére', 'générer', 'generer',
      'henere', 'hénère', 'hénére', 'hener',
      'crée', 'cree', 'créer', 'creer',
      'fais', 'fait', 'faire',
      'produis', 'produit', 'produire',
      'generate', 'create', 'make', 'produce'
    ];

    final visualNouns = [
      'image', 'photo', 'illustration', 'dessin', 'visuel', 'portrait', 'tableau', 'picture', 'rendu', 'artwork',
      'photoréalisme', 'photoréaliste', 'photoréalistique', 'peinture', 'avatar', 'logo', 'fond d\'écran',
      'voiture', 'car', 'auto', 'paysage', 'coucher de soleil', 'homme', 'femme', 'chat', 'chien', 'animal', 'forêt', 'foret', 'plage', 'mer', 'rue'
    ];

    final hasVerb = creationVerbs.any((k) => lower.startsWith(k) || lower.contains(' $k '));
    final hasVisualNoun = visualNouns.any((n) => lower.contains(n));
    if (hasVerb && hasVisualNoun) {
      return true;
    }

    return false;
  }

  /// Extracts the visual subject and styling instructions from natural language prompt.
  String extractImagePrompt(String prompt) {
    var clean = prompt.trim();
    if (clean.startsWith('/image') ||
        clean.startsWith('/img') ||
        clean.startsWith('/draw') ||
        clean.startsWith('/flux') ||
        clean.startsWith('/photo') ||
        clean.startsWith('/sd')) {
      clean = clean.replaceFirst(RegExp(r'^\/(image|img|draw|flux|photo|sd)\s*', caseSensitive: false), '');
    }

    const verbPattern = r'(?:[gh][eéè]n[eéè]rer?|[gh][eéè]n[eéè]rez?|[gh][eéè]n[eéè]res?|[gh][eéè]n[eéè]ré|cr[eéè]er?|cr[eéè]ez?|cr[eéè]es?|cr[eéè]é|faire?|fais?|fait|faites|dessiner?|dessinez?|dessines?|illustrer?|illustrez?|illustres?|peindre?|peins?|peint|produire?|produis?|produit|afficher?|affichez?|affiche|show|generate|create|draw|paint|render|make)';
    final noisePattern = RegExp(
      r'^(?:peux-tu|pourrais-tu|veuillez|merci de|peux tu|please)?\s*' +
          verbPattern +
          r'(?:-moi|\s+moi)?\s*(?:une?|l\x27|des|le|la|du|un|an?|the|me)?\s*(?:image|photo|illustration|dessin|visuel|portrait|rendu|tableau|peinture|artwork|picture|drawing|photor[eé]aliste|photor[eé]alistique)?\s*(?:de\s+|d\x27un\s+|d\x27une\s+|d\x27|sur\s+|avec\s+|repr[eé]sentant\s+|montrant\s+|of\s+|about\s+|showing\s+)?',
      caseSensitive: false,
    );

    clean = clean.replaceAll(noisePattern, '').trim();

    return clean.isEmpty ? prompt : clean;
  }

  /// Construit les headers HTTP pour les appels au serveur image.
  /// Injecte automatiquement le Bearer token si imageGenApiKey est défini (mode cloud).
  Map<String, String> _imageHeaders({bool json = true}) {
    final headers = <String, String>{
      if (json) 'Content-Type': 'application/json',
      if (json) 'Accept': 'application/json',
    };
    final apiKey = _settings.imageGenApiKey.trim();
    if (apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    return headers;
  }

  /// Checks if the Image Generation server (local SD WebUI or cloud OpenAI-compatible) is responding.
  Future<bool> isImageServerRunning() async {
    final isCloud = _settings.imageGenIsCloud;

    if (!isCloud) {
      // Mode local : vérifier d'abord le port SD WebUI natif
      try {
        final endpoint = _settings.imageGenApiUrl.trim().replaceAll(RegExp(r'/+$'), '');
        final baseHost = endpoint.replaceAll(RegExp(r'/(v1|sdapi/v1).*$'), '');
        final checkUri = Uri.parse('$baseHost/sdapi/v1/options');
        final res = await http.get(checkUri).timeout(const Duration(milliseconds: 1200));
        if (res.statusCode == 200) return true;
      } catch (_) {}
    }

    // Vérification universelle : GET /models (compatible local ET cloud)
    try {
      final endpoint = _settings.imageGenApiUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final checkUri = Uri.parse(endpoint.endsWith('/v1') ? '$endpoint/models' : '$endpoint/v1/models');
      final res = await http.get(checkUri, headers: _imageHeaders(json: false))
          .timeout(const Duration(milliseconds: 2000));
      if (res.statusCode == 200) return true;
    } catch (_) {}

    return false;
  }

  /// Automatically launches webui-user.bat in the background if the server is not yet running.
  Future<bool> ensureImageServerStarted() async {
    if (await isImageServerRunning()) return true;

    if (!plat.isWindows) return false;

    try {
      final candidates = <String>[];
      final exeDir = p.dirname(Platform.resolvedExecutable);
      candidates.add(p.join(exeDir, 'webui-user.bat'));
      candidates.add(p.join(exeDir, '..', 'webui-user.bat'));
      candidates.add(p.join(exeDir, '..', '..', 'webui-user.bat'));
      candidates.add(p.join(Directory.current.path, 'webui-user.bat'));
      candidates.add(p.join(Directory.current.path, 'CrisperWeaver', 'webui-user.bat'));

      String? targetBat;
      for (final c in candidates) {
        final f = File(c);
        if (await f.exists()) {
          targetBat = f.path;
          break;
        }
      }

      if (targetBat != null) {
        Log.instance.i('mcp_tools', 'Auto-launching local SD server: $targetBat');
        await Process.start(
          'cmd.exe',
          ['/c', targetBat],
          workingDirectory: p.dirname(targetBat),
          runInShell: true,
          mode: ProcessStartMode.detached,
        );
        return true;
      }
    } catch (e) {
      Log.instance.w('mcp_tools', 'Failed to auto-launch webui-user.bat: $e');
    }
    return false;
  }

  /// Calls the local Text-to-Image endpoint (supporting both SD WebUI txt2img and OpenAI formats).
  Future<String> generateImage(String visualPrompt, {String size = '512x512', bool allowLlmTranslation = false}) async {
    final endpoint = _settings.imageGenApiUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final isCloud = _settings.imageGenIsCloud;

    final promptToSend = allowLlmTranslation
        ? await translateToEnglishPrompt(visualPrompt, allowLlm: true)
        : visualPrompt.trim();
    Log.instance.i('mcp_tools', 'Generating image: "$visualPrompt" (Prompt: "$promptToSend") on $endpoint [${isCloud ? "cloud" : "local"}]');

    Uint8List? imageBytes;

    // 1. Protocole natif SD WebUI / Forge (/sdapi/v1/txt2img) — LOCAL UNIQUEMENT
    if (!isCloud) {
      try {
        final baseHost = endpoint.replaceAll(RegExp(r'/(v1|sdapi/v1).*$'), '');
        final sdUrl = '$baseHost/sdapi/v1/txt2img';
        final response = await http.post(
          Uri.parse(sdUrl),
          headers: _imageHeaders(),
          body: jsonEncode({
            'prompt': promptToSend,
            'model': _settings.activeImageModel,
            'steps': 4,
            'cfg_scale': 1.5,
            'width': 768,
            'height': 768,
            'sampler_name': 'Euler a',
          }),
        ).timeout(const Duration(minutes: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final imagesList = data['images'] as List<dynamic>?;
          if (imagesList != null && imagesList.isNotEmpty) {
            final b64 = imagesList.first.toString();
            imageBytes = base64Decode(b64);
          }
        }
      } catch (_) {}
    }

    // 2. Protocole standard OpenAI (/v1/images/generations) — LOCAL ET CLOUD
    if (imageBytes == null) {
      try {
        final openAiUrl = endpoint.endsWith('/images/generations')
            ? endpoint
            : (endpoint.endsWith('/v1') ? '$endpoint/images/generations' : '$endpoint/v1/images/generations');

        final response = await http.post(
          Uri.parse(openAiUrl),
          headers: _imageHeaders(),
          body: jsonEncode({
            'prompt': promptToSend,
            'model': _settings.activeImageModel,
            'n': 1,
            'size': size,
            'response_format': 'b64_json',
          }),
        ).timeout(const Duration(minutes: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final dataList = data['data'] as List<dynamic>?;
          if (dataList != null && dataList.isNotEmpty) {
            final firstItem = dataList.first as Map<String, dynamic>;
            if (firstItem.containsKey('b64_json') && firstItem['b64_json'] != null) {
              imageBytes = base64Decode(firstItem['b64_json'] as String);
            } else if (firstItem.containsKey('url') && firstItem['url'] != null) {
              final imgUrl = firstItem['url'] as String;
              if (imgUrl.startsWith('data:image')) {
                final base64Part = imgUrl.split(',').last;
                imageBytes = base64Decode(base64Part);
              } else {
                final imgRes = await http.get(Uri.parse(imgUrl), headers: _imageHeaders(json: false));
                if (imgRes.statusCode == 200) {
                  imageBytes = imgRes.bodyBytes;
                }
              }
            }
          }
        }
      } catch (e) {
        Log.instance.e('mcp_tools', 'Image generation error: $e');
      }
    }

    if (imageBytes != null) {
      final docsDir = await getApplicationDocumentsDirectory();
      final imgDir = Directory(p.join(docsDir.path, 'CrisperWeaver', 'GeneratedImages'));
      if (!await imgDir.exists()) await imgDir.create(recursive: true);

      final timeTag = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'gen_image_$timeTag.png';
      final filePath = p.join(imgDir.path, fileName);
      final file = File(filePath);
      await file.writeAsBytes(imageBytes);

      final fileUri = 'file:///${filePath.replaceAll("\\", "/")}';
      return '🎨 **Image générée avec succès :**\n\n![$visualPrompt]($fileUri)\n\n*(Prompt visuel : "$visualPrompt" | Résolution : $size)*';
    }

    final modeLabel = isCloud ? 'cloud (${_settings.imageGenApiUrl})' : 'local (${_settings.imageGenApiUrl})';
    return '⚠️ **Serveur de Génération d\'Images Injoignable**\n\n'
        'Le serveur image $modeLabel n\'a pas répondu.\n\n'
        '💡 ${isCloud ? "Vérifiez l'URL et la clé API cloud dans les paramètres LLM." : "Assurez-vous que \"webui-user.bat\" est lancé sur ${_settings.imageGenApiUrl}."}';
  }

  /// Translates and enhances a French image prompt into a rich, detailed English prompt for diffusion models.
  Future<String> translateToEnglishPrompt(String prompt, {bool allowLlm = true}) async {
    final clean = prompt.trim();
    if (clean.isEmpty) return clean;
    if (!allowLlm) return clean;

    // 1. Traduction par le modèle de texte LLM actif (LM Studio, LiteRT, Ollama)
    try {
      final isLiteRt = _settings.llmProvider == LlmProvider.liteRtWindows || _settings.llmProvider == LlmProvider.liteRtAndroid;
      final llmEndpoint = isLiteRt
          ? 'http://127.0.0.1:9379/v1/chat/completions'
          : '${_settings.llmApiUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

      final activeModel = _settings.llmModel.isNotEmpty ? _settings.llmModel : (isLiteRt ? 'gemma-4-e4b-it' : '');

      final res = await http.post(
        Uri.parse(llmEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          if (activeModel.isNotEmpty) 'model': activeModel,
          'messages': [
            {
              'role': 'system',
              'content': 'You are an expert AI translator. Translate the user description faithfully and accurately into English for an image generation model. Keep ALL described elements (objects, subjects, architecture, illuminated windows, trees, street, lighting, atmosphere) clear, detailed and visible. Do NOT invent camera effects, lenses, depth of field, blur, or bokeh that were not requested by the user. Output ONLY the clean English prompt with no intro or quotes.'
            },
            {'role': 'user', 'content': clean}
          ],
          'temperature': 0.3,
          'max_tokens': 150,
        }),
      ).timeout(const Duration(seconds: 30));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>?;
        if (choices != null && choices.isNotEmpty) {
          final content = choices.first['message']?['content']?.toString().trim() ?? '';
          if (content.isNotEmpty && !content.toLowerCase().contains('sorry') && !content.toLowerCase().contains('cannot')) {
            final filtered = content.replaceAll('"', '').replaceAll("'", '').trim();
            Log.instance.i('mcp_tools', 'LLM translated visual prompt: "$clean" -> "$filtered"');
            return filtered;
          }
        }
      } else {
        Log.instance.w('mcp_tools', 'LLM prompt translation HTTP ${res.statusCode}: ${res.body}');
      }
    } catch (e) {
      Log.instance.d('mcp_tools', 'LLM prompt translation unavailable: $e');
    }

    // 2. Si aucun LLM n'est chargé, conserver le prompt brut de l'utilisateur tel quel sans le dénaturer
    return clean;
  }

  /// Annule la génération en cours — local SD WebUI uniquement (pas applicable en mode cloud).
  Future<void> cancelImageGeneration() async {
    if (_settings.imageGenIsCloud) return; // Pas d'endpoint d'interruption sur les APIs cloud
    try {
      final endpoint = _settings.imageGenApiUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final baseHost = endpoint.replaceAll(RegExp(r'/(v1|sdapi/v1).*$'), '');
      final interruptUri = Uri.parse('$baseHost/sdapi/v1/interrupt');
      await http.post(interruptUri, headers: _imageHeaders(json: false)).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Découvre les modèles image disponibles :
  /// - Mode local : scan filesystem + requête SD WebUI API
  /// - Mode cloud : requête GET /models avec Bearer token
  Future<List<String>> listAvailableImageModels() async {
    final discovered = <String>{};
    final isCloud = _settings.imageGenIsCloud;

    if (!isCloud) {
      // Mode local : scan des dossiers models/Stable-diffusion
      final candidateDirs = <String>[];
      final exeDir = p.dirname(Platform.resolvedExecutable);
      candidateDirs.add(p.join(exeDir, 'models', 'Stable-diffusion'));
      candidateDirs.add(p.join(Directory.current.path, 'models', 'Stable-diffusion'));
      candidateDirs.add(p.join(Directory.current.path, 'CrisperWeaver', 'models', 'Stable-diffusion'));

      for (final dirPath in candidateDirs) {
        final dir = Directory(dirPath);
        if (dir.existsSync()) {
          try {
            final entries = dir.listSync();
            for (final entry in entries) {
              if (entry is File) {
                final fileName = p.basename(entry.path).toLowerCase();
                final ext = p.extension(entry.path).toLowerCase();
                // Exclure les composants d'assistance (VAE, CLIP, T5) pour ne garder que les modèles de diffusion complets
                if (fileName.startsWith('ae.') ||
                    fileName.startsWith('clip_') ||
                    fileName.startsWith('t5xxl') ||
                    fileName.startsWith('test_')) {
                  continue;
                }
                if (['.safetensors', '.ckpt', '.gguf', '.bin', '.pt'].contains(ext)) {
                  discovered.add(p.basename(entry.path));
                }
              }
            }
          } catch (_) {}
        }
      }

      // Requête SD WebUI API si disponible
      try {
        final endpoint = _settings.imageGenApiUrl.trim().replaceAll(RegExp(r'/+$'), '');
        final baseHost = endpoint.replaceAll(RegExp(r'/(v1|sdapi/v1).*$'), '');
        final modelsUri = Uri.parse('$baseHost/sdapi/v1/sd-models');
        final res = await http.get(modelsUri, headers: _imageHeaders(json: false)).timeout(const Duration(seconds: 2));
        if (res.statusCode == 200) {
          final list = jsonDecode(res.body) as List<dynamic>?;
          if (list != null) {
            for (final item in list) {
              if (item is Map) {
                final title = item['title']?.toString() ?? item['model_name']?.toString();
                if (title != null && title.isNotEmpty) {
                  discovered.add(title);
                }
              }
            }
          }
        }
      } catch (_) {}
    } else {
      // Mode cloud : GET /models avec Bearer token (format OpenAI standard)
      try {
        final endpoint = _settings.imageGenApiUrl.trim().replaceAll(RegExp(r'/+$'), '');
        final modelsUrl = endpoint.endsWith('/v1') ? '$endpoint/models' : '$endpoint/v1/models';
        final res = await http.get(Uri.parse(modelsUrl), headers: _imageHeaders(json: false))
            .timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          List<dynamic>? items;
          if (data is Map && data['data'] is List) {
            items = data['data'] as List<dynamic>;
          } else if (data is List) {
            items = data;
          }
          if (items != null) {
            for (final item in items) {
              if (item is Map) {
                final id = item['id']?.toString() ?? item['name']?.toString() ?? '';
                if (id.isNotEmpty) discovered.add(id);
              }
            }
          }
        }
      } catch (e) {
        Log.instance.d('mcp_tools', 'Cloud image models fetch failed: $e');
      }
    }

    final result = discovered.toList()..sort();
    return result;
  }
}

/// Provider for McpToolsService
final mcpToolsServiceProvider = Provider<McpToolsService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  return McpToolsService(settings);
});
