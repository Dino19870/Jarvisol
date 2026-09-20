import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

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
}

/// Provider for McpToolsService
final mcpToolsServiceProvider = Provider<McpToolsService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  return McpToolsService(settings);
});
