import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../constants/timeout_policy.dart';
import 'package:path/path.dart' as p;
import '../utils/app_paths.dart';

import 'llm_service.dart';
import '../utils/platform_utils.dart' as plat;
import 'log_service.dart';
import 'settings_service.dart';

/// Classification des types d'échecs lors de la traduction de prompt IA.
enum LlmTranslationFailureType {
  connectionRefused,
  responseTimeout,
  contextTooLarge,
  modelUnloaded,
  modelError,
  unknown,
}

/// Exception spécifique levée lorsque la traduction LLM du prompt visuel échoue.
class LlmTranslationException implements Exception {
  final String message;
  final LlmTranslationFailureType failureType;
  final String? technicalDetail;

  LlmTranslationException(
    this.message, {
    this.failureType = LlmTranslationFailureType.unknown,
    this.technicalDetail,
  });

  @override
  String toString() => message;
}

/// Résultat détaillé de l'exécution d'un processus MCP (script local).
class McpProcessExecutionResult {
  final String command;
  final String stdout;
  final String stderr;
  final int exitCode;
  final bool success;

  McpProcessExecutionResult({
    required this.command,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.success,
  });
}

/// Plan d'action structuré pour une opération Gmail MCP sécurisée (MCP-006).
class GmailActionPlan {
  final String action;
  final Map<String, dynamic> arguments;
  final List<String> missingRequiredFields;
  final bool isSafeToExecute;
  final String? errorMessage;

  const GmailActionPlan({
    required this.action,
    required this.arguments,
    this.missingRequiredFields = const [],
    required this.isSafeToExecute,
    this.errorMessage,
  });
}

/// Descripteur de lancement pour le runtime portable Node.js / Gmail MCP (AUD-GMAIL-01 / TNR-025).
class GmailMcpLauncher {
  final String executable;
  final List<String> arguments;
  final String pathEnv;
  final bool runInShell;

  const GmailMcpLauncher({
    required this.executable,
    required this.arguments,
    required this.pathEnv,
    this.runInShell = false,
  });
}

/// Central Portable Service for Date Injection, Web Search, and Gmail MCP connectors.
class McpToolsService {
  final SettingsService _settings;
  final http.Client _client;

  /// Optional mock command hook for testing MCP Gmail without network or credentials
  static String? mockGmailCommand;

  McpToolsService(this._settings, {http.Client? client})
      : _client = client ?? http.Client();

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

  /// Performs a portable web search using DuckDuckGo HTML and extracts titles, URLs + snippets.
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
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final html = response.body;

        // ─── Extraction des blocs résultats complets ─────────────────────
        // Chaque résultat DuckDuckGo HTML est dans un <div class="result ...">
        final blockReg = RegExp(
          r'<div class="result[^"]*"[^>]*>(.*?)</div>\s*</div>\s*</div>',
          dotAll: true, caseSensitive: false,
        );

        // Regex pour le titre (lien principal)
        final titleReg = RegExp(
          r'<a[^>]+class="result__a"[^>]*>(.*?)</a>',
          dotAll: true, caseSensitive: false,
        );

        // Regex pour l'URL affichée
        final urlReg = RegExp(
          r'<a[^>]+class="result__url"[^>]*>(.*?)</a>',
          dotAll: true, caseSensitive: false,
        );

        // Regex pour le snippet
        final snippetReg = RegExp(
          r'<a[^>]+class="result__snippet[^"]*"[^>]*>(.*?)</a>',
          dotAll: true, caseSensitive: false,
        );

        String _cleanHtml(String raw) => raw
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .replaceAll('&quot;', '"')
            .replaceAll('&amp;', '&')
            .replaceAll('&#x27;', "'")
            .replaceAll('&#39;', "'")
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&nbsp;', ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        final results = <String>[];
        int count = 0;

        for (final block in blockReg.allMatches(html)) {
          if (count >= 6) break;
          final blockText = block.group(1) ?? '';

          final title = _cleanHtml(titleReg.firstMatch(blockText)?.group(1) ?? '');
          final url = _cleanHtml(urlReg.firstMatch(blockText)?.group(1) ?? '');
          final snippet = _cleanHtml(snippetReg.firstMatch(blockText)?.group(1) ?? '');

          if (snippet.isEmpty && title.isEmpty) continue;

          final sb = StringBuffer();
          if (title.isNotEmpty) sb.write('**$title**');
          if (url.isNotEmpty) sb.write(' — $url');
          if (snippet.isNotEmpty) {
            if (sb.isNotEmpty) sb.write('\n  ');
            sb.write(snippet);
          }

          final line = sb.toString().trim();
          if (line.isNotEmpty) {
            results.add('${count + 1}. $line');
            count++;
          }
        }

        // Fallback : si le parsing par blocs échoue, utiliser les snippets seuls
        if (results.isEmpty) {
          final snippetOnly = RegExp(r'<a class="result__snippet[^>]*>(.*?)<\/a>',
              dotAll: true, caseSensitive: false);
          for (final m in snippetOnly.allMatches(html).take(5)) {
            final s = _cleanHtml(m.group(1) ?? '');
            if (s.isNotEmpty) results.add('• $s');
          }
        }

        if (results.isNotEmpty) {
          return '🔍 Résultats Web pour **"$query"** :\n\n${results.join("\n\n")}';
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

  /// Rafraîchit automatiquement l'access_token Gmail via le refresh_token.
  /// Retourne true si le renouvellement a réussi, false sinon.
  Future<bool> _refreshGmailToken(String credPath, String keysPath) async {
    final credFile = File(credPath);
    if (!await credFile.exists() || (await credFile.length()) == 0) {
      Log.instance.w('mcp_tools', 'Gmail: credentials.json introuvable ou 0-octet — refresh impossible');
      return false;
    }

    try {
      final credContent = await credFile.readAsString();
      if (credContent.trim().isEmpty) {
        Log.instance.w('mcp_tools', 'Gmail: credentials.json vide (0 octet)');
        return false;
      }
      final credJson = jsonDecode(credContent) as Map<String, dynamic>;
      final keysJson = jsonDecode(await File(keysPath).readAsString()) as Map<String, dynamic>;

      final refreshToken = credJson['refresh_token'] as String?;
      if (refreshToken == null || refreshToken.isEmpty) {
        Log.instance.w('mcp_tools', 'Gmail: pas de refresh_token dans credentials.json');
        return false;
      }

      final installed = keysJson['installed'] as Map<String, dynamic>?;
      final clientId = installed?['client_id'] as String?;
      final clientSecret = installed?['client_secret'] as String?;
      if (clientId == null || clientSecret == null) {
        Log.instance.w('mcp_tools', 'Gmail: client_id/secret manquant dans gcp-oauth.keys.json');
        return false;
      }

      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );

      if (response.statusCode == 200) {
        final newData = jsonDecode(response.body) as Map<String, dynamic>;
        final updatedCred = Map<String, dynamic>.from(credJson);
        updatedCred['access_token'] = newData['access_token'];
        final expiresIn = (newData['expires_in'] as num?)?.toInt() ?? 3600;
        updatedCred['expiry_date'] =
            DateTime.now().add(Duration(seconds: expiresIn - 60)).millisecondsSinceEpoch;

        // Transactional commit (AUD-GMAIL-02 / TNR-059):
        final tmpFile = File('$credPath.tmp');
        final bakFile = File('$credPath.bak_prev');
        final encoded = jsonEncode(updatedCred);
        await tmpFile.writeAsString(encoded, flush: true);

        if (!await tmpFile.exists() || (await tmpFile.length()) == 0) {
          try { await tmpFile.delete(); } catch (_) {}
          Log.instance.e('mcp_tools', 'Gmail: échec commit OAuth — fichier temporaire vide');
          return false;
        }

        if (await credFile.exists()) {
          try {
            await credFile.copy(bakFile.path);
          } catch (_) {}
        }

        try {
          if (Platform.isWindows && await credFile.exists()) {
            await credFile.delete();
          }
          await tmpFile.rename(credPath);
        } catch (commitErr) {
          Log.instance.e('mcp_tools', 'Gmail: échec commit atomique credentials: $commitErr');
          if (await bakFile.exists() && (!await credFile.exists() || (await credFile.length()) == 0)) {
            try { await bakFile.copy(credPath); } catch (_) {}
          }
          return false;
        }

        Log.instance.i('mcp_tools', 'Gmail: token rafraîchi avec succès (valide ${expiresIn}s)');
        return true;
      } else {
        Log.instance.w('mcp_tools', 'Gmail: échec du refresh (${response.statusCode}) : ${response.body}');
        return false;
      }
    } catch (e) {
      Log.instance.e('mcp_tools', 'Gmail: erreur lors du refresh du token: $e');
      return false;
    }
  }

  /// Extracts clean Gmail API search syntax from natural language.
  String extractGmailQuery(String prompt) {
    final pTrim = prompt.trim();
    final pLower = pTrim.toLowerCase();

    // ─── Filtres de récence explicites ───────────────────────────────────
    if (pLower.contains("aujourd'hui") || pLower.contains('ce matin') || pLower.contains('ce soir')) {
      return 'in:inbox newer_than:1d';
    }
    if (pLower.contains('cette semaine') || pLower.contains('cette semaine')) {
      return 'in:inbox newer_than:7d';
    }
    if (pLower.contains('ce mois') || pLower.contains('du mois')) {
      return 'in:inbox newer_than:30d';
    }
    // "derniers" / "récents" sans autre précision → 30 jours
    final isRecencyQuery = pLower.contains('dernier') || pLower.contains('récent') ||
        pLower.contains('recent') || pLower.contains('dernière');
    // ─────────────────────────────────────────────────────────────────────

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
      // Si la requête portait sur "derniers" / "récents" → forcer le filtre de récence
      return isRecencyQuery ? 'in:inbox newer_than:30d' : 'in:inbox';
    }

    // If it contains an email domain or address (e.g. pcsoft.fr or user@domain.com)
    if (clean.contains('@') || clean.contains('.fr') || clean.contains('.com') || clean.contains('.org') || clean.contains('.net')) {
      return 'from:$clean';
    }

    return isRecencyQuery ? '$clean newer_than:30d' : clean;
  }

  /// Extrait de façon sûre l'identifiant de message pour une action Gmail (MCP-006).
  String? extractMessageId(String prompt) {
    // 1. Identifiants explicites : id_msg_xxx, msg_xxx, ou chaîne hexadécimale d'au moins 8 caractères
    final explicitMatch = RegExp(r"\b(id_msg_[a-zA-Z0-9_-]+|msg_[a-zA-Z0-9_-]+|[0-9a-fA-F]{8,})\b", caseSensitive: false).firstMatch(prompt);
    if (explicitMatch != null) {
      return explicitMatch.group(1);
    }
    // 2. Motif contextuel : "message <id>", "mail <id>", "courriel <id>", "id <id>"
    final contextualMatch = RegExp(r"(?:id|identifiant|message|mail|courriel)\s+(?:(?:le|la|ce|de|du|un|n°|numéro)\s+)?([a-zA-Z0-9_-]{3,})", caseSensitive: false).firstMatch(prompt);
    if (contextualMatch != null) {
      final candidate = contextualMatch.group(1)!;
      const forbiddenWords = {'comme', 'lu', 'non', 'pour', 'avec', 'dans', 'sur', 'archive', 'archiver', 'libelle', 'libellé'};
      if (!forbiddenWords.contains(candidate.toLowerCase())) {
        return candidate;
      }
    }
    return null;
  }

  /// Extrait de façon stricte et sans ambiguïté le nom d'un libellé Gmail (MCP-006 / Fail-Closed).
  String? extractLabelName(String prompt) {
    const forbidden = {
      'gmail', 'mail', 'courriel', 'email', 'e-mail', 'pour', 'un', 'une',
      'le', 'la', 'les', 'des', 'du', 'ce', 'cet', 'cette', 'nouveau',
      'nouvelle', 'nommé', 'nomme', 'nommée', 'nommee', 'appelé', 'appele',
      'dans', 'sur', 'avec', 'et', 'à', 'a'
    };

    // 1. "nommé/nomme/appelé <label>"
    final namedMatch = RegExp(r"(?:nommé|nomme|nommée|nommee|appelé|appele)\s+([a-zA-Z0-9_-]+)", caseSensitive: false).firstMatch(prompt);
    if (namedMatch != null) {
      final cand = namedMatch.group(1)!;
      if (!forbidden.contains(cand.toLowerCase())) {
        return cand;
      }
    }

    // 2. "libellé/libelle/label [...] <label>"
    final labelMatch = RegExp(r"(?:libellé|libelle|label)\s+(.+)", caseSensitive: false).firstMatch(prompt);
    if (labelMatch != null) {
      final remainder = labelMatch.group(1)!;
      final tokens = remainder.split(RegExp(r"[\s,.:;!?]+"));
      for (final t in tokens) {
        final clean = t.replaceAll(RegExp(r"^['’]+|['’]+$"), "");
        if (clean.isNotEmpty && !forbidden.contains(clean.toLowerCase())) {
          return clean;
        }
      }
    }

    return null;
  }

  /// Résolution structurée et sécurisée d'une intention d'action Gmail (MCP-006).
  GmailActionPlan resolveGmailActionPlan(String query, {String? action, Map<String, dynamic>? customArgs}) {
    if (action != null) {
      final args = customArgs != null ? Map<String, dynamic>.from(customArgs) : <String, dynamic>{};
      final missing = <String>[];
      if (action == 'gmail_draft_email') {
        final to = args['to'];
        if (to == null || (to is List && to.isEmpty) || (to is String && to.trim().isEmpty)) {
          missing.add('to');
        }
        final subject = args['subject'];
        if (subject == null || subject.toString().trim().isEmpty) {
          missing.add('subject');
        }
        final body = args['body'];
        if (body == null || body.toString().trim().isEmpty) {
          missing.add('body');
        }
      } else if (action == 'gmail_mark_as_read' || action == 'gmail_mark_as_unread' || action == 'gmail_archive_email') {
        final msgId = args['messageId'];
        if (msgId == null || msgId.toString().trim().isEmpty) {
          missing.add('messageId');
        }
      } else if (action == 'gmail_create_label') {
        final name = args['name'];
        if (name == null || name.toString().trim().isEmpty) {
          missing.add('name');
        }
      }
      return GmailActionPlan(
        action: action,
        arguments: args,
        missingRequiredFields: missing,
        isSafeToExecute: missing.isEmpty,
        errorMessage: missing.isEmpty ? null : 'Champs requis manquants pour $action : ${missing.join(', ')}',
      );
    }

    final lowerPrompt = query.toLowerCase();
    if (lowerPrompt.contains("brouillon") || lowerPrompt.contains("draft")) {
      final toMatch = RegExp(r"(?:à|a|pour)\s+([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})", caseSensitive: false).firstMatch(query) ??
          RegExp(r"([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})").firstMatch(query);
      final toAddress = toMatch?.group(1);

      final subjMatch = RegExp(r"(?:sujet|titre|pour objet|objet)\s+[:\s]?\s*([^,\r\n]+)", caseSensitive: false).firstMatch(query);
      final subject = subjMatch?.group(1)?.trim();

      final bodyMatch = RegExp(r"(?:corps|message|contenu)\s+[:\s]?\s*(.+)", caseSensitive: false).firstMatch(query);
      final body = bodyMatch?.group(1)?.trim();

      final missing = <String>[];
      if (toAddress == null || toAddress.isEmpty) missing.add('to');
      if (subject == null || subject.isEmpty) missing.add('subject');
      if (body == null || body.isEmpty) missing.add('body');

      if (missing.isNotEmpty) {
        return GmailActionPlan(
          action: "gmail_draft_email",
          arguments: {
            if (toAddress != null && toAddress.isNotEmpty) "to": [toAddress],
            if (subject != null && subject.isNotEmpty) "subject": subject,
            if (body != null && body.isNotEmpty) "body": body,
          },
          missingRequiredFields: missing,
          isSafeToExecute: false,
          errorMessage: "Champs requis manquants pour la création du brouillon : ${missing.join(', ')}.",
        );
      }
      return GmailActionPlan(
        action: "gmail_draft_email",
        arguments: {
          "to": [toAddress],
          "subject": subject,
          "body": body,
        },
        missingRequiredFields: const [],
        isSafeToExecute: true,
      );
    } else if (lowerPrompt.contains("non lu") || lowerPrompt.contains("non-lu") || lowerPrompt.contains("unread")) {
      final msgId = extractMessageId(query);
      if (msgId == null) {
        return const GmailActionPlan(
          action: "gmail_mark_as_unread",
          arguments: {},
          missingRequiredFields: ["messageId"],
          isSafeToExecute: false,
          errorMessage: "Identifiant de message manquant : veuillez spécifier l'identifiant du message à marquer comme non lu.",
        );
      }
      return GmailActionPlan(
        action: "gmail_mark_as_unread",
        arguments: {"messageId": msgId},
        missingRequiredFields: const [],
        isSafeToExecute: true,
      );
    } else if (lowerPrompt.contains("comme lu") || lowerPrompt.contains("marquer lu") || lowerPrompt.contains("marque comme lu") || lowerPrompt.contains("mark as read") || lowerPrompt.contains("comme étant lu")) {
      final msgId = extractMessageId(query);
      if (msgId == null) {
        return const GmailActionPlan(
          action: "gmail_mark_as_read",
          arguments: {},
          missingRequiredFields: ["messageId"],
          isSafeToExecute: false,
          errorMessage: "Identifiant de message manquant : veuillez spécifier l'identifiant du message à marquer comme lu.",
        );
      }
      return GmailActionPlan(
        action: "gmail_mark_as_read",
        arguments: {"messageId": msgId},
        missingRequiredFields: const [],
        isSafeToExecute: true,
      );
    } else if (lowerPrompt.contains("archiver") || lowerPrompt.contains("archive")) {
      final msgId = extractMessageId(query);
      if (msgId == null) {
        return const GmailActionPlan(
          action: "gmail_archive_email",
          arguments: {},
          missingRequiredFields: ["messageId"],
          isSafeToExecute: false,
          errorMessage: "Identifiant de message manquant : veuillez spécifier l'identifiant du message à archiver.",
        );
      }
      return GmailActionPlan(
        action: "gmail_archive_email",
        arguments: {"messageId": msgId},
        missingRequiredFields: const [],
        isSafeToExecute: true,
      );
    } else if (lowerPrompt.contains("libellé") || lowerPrompt.contains("libelle") || lowerPrompt.contains("label")) {
      final labelName = extractLabelName(query);
      if (labelName == null) {
        return const GmailActionPlan(
          action: "gmail_create_label",
          arguments: {},
          missingRequiredFields: ["name"],
          isSafeToExecute: false,
          errorMessage: "Nom de libellé manquant ou ambigu : veuillez spécifier le nom du libellé à créer.",
        );
      }
      return GmailActionPlan(
        action: "gmail_create_label",
        arguments: {"name": labelName},
        missingRequiredFields: const [],
        isSafeToExecute: true,
      );
    } else {
      final effectiveQuery = extractGmailQuery(query);
      return GmailActionPlan(
        action: "gmail_list_emails",
        arguments: {"query": effectiveQuery, "maxResults": 5},
        missingRequiredFields: const [],
        isSafeToExecute: true,
      );
    }
  }

  /// Checks if a prompt is an explicit Gmail query or action (read or write) with strict contextual isolation (MCP-007 / VIG-MCP-DRAFT-INTENT-001).
  bool isGmailIntent(String prompt) {
    final lower = prompt.toLowerCase().trim();
    if (lower.startsWith("/gmail") || lower.startsWith("/mail")) return true;

    // Strict negative document context guards: local document references without mail context
    if (lower.contains("ce document") ||
        lower.contains("dans ce document") ||
        lower.contains("ce chapitre") ||
        lower.contains("dans ce chapitre") ||
        lower.contains("cette section") ||
        lower.contains("dans cette section") ||
        lower.contains("ce pdf") ||
        lower.contains("dans ce pdf") ||
        lower.contains("ce fichier") ||
        lower.contains("cette réponse") ||
        lower.contains("ce paragraphe") ||
        lower.contains("de résumé") ||
        lower.contains("du résumé")) {
      if (!lower.contains("gmail") && !lower.contains("@")) {
        return false;
      }
    }

    // Explicit email indicators
    final explicitMailMarkers = [
      "gmail",
      "mes mails",
      "mon mail",
      "mes courriels",
      "mon courriel",
      "ma boîte",
      "ma boite",
      "dans ma boite",
      "dans ma boîte",
      "boîte de réception",
      "boite de reception",
      "inbox",
    ];
    if (explicitMailMarkers.any((m) => lower.contains(m))) return true;

    final hasEmailAddress = RegExp(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}").hasMatch(prompt);
    final hasMailWord = lower.contains("mail") || lower.contains("courriel") || lower.contains("e-mail") || lower.contains("email");

    // Draft intent: ONLY if accompanied by explicit email markers or email address (VIG-MCP-DRAFT-INTENT-001)
    if (lower.contains("brouillon") || lower.contains("draft")) {
      if (hasMailWord || hasEmailAddress) {
        if ((lower.contains("document") || lower.contains("chapitre") || lower.contains("livre") || lower.contains("réponse") || lower.contains("paragraphe") || lower.contains("résumé")) && !hasEmailAddress) {
          return false;
        }
        return true;
      }
      return false;
    }

    // Read/Unread/Archive actions require explicit email token or mail keyword
    final hasEmailId = RegExp(r"\b(id_msg_[a-zA-Z0-9_-]+|msg_[a-zA-Z0-9_-]+|[0-9a-fA-F]{16,})\b").hasMatch(prompt);

    if (lower.contains("comme lu") || lower.contains("marquer lu") || lower.contains("marque comme lu") || lower.contains("mark as read") ||
        lower.contains("non lu") || lower.contains("non-lu") || lower.contains("unread") ||
        lower.contains("archiver") || lower.contains("archive")) {
      if (hasEmailId || hasEmailAddress || hasMailWord) {
        return true;
      }
    }

    // Label creation requires explicit email context
    if ((lower.contains("libellé") || lower.contains("libelle") || lower.contains("label")) &&
        (hasMailWord || lower.contains("boîte") || lower.contains("boite") || lower.contains("dossier mail"))) {
      return true;
    }

    return false;
  }

  /// Checks if a prompt is an explicit web search query with strict contextual isolation (MCP-007).
  bool isWebSearchIntent(String prompt) {
    final lower = prompt.toLowerCase().trim();
    if (lower.startsWith("/web") || lower.startsWith("/search") || lower.startsWith("/net")) {
      return true;
    }

    // Negative guards: document context references must not trigger web search
    if (lower.contains("ce document") ||
        lower.contains("dans ce document") ||
        lower.contains("ce pdf") ||
        lower.contains("dans le pdf") ||
        lower.contains("dans ce pdf") ||
        lower.contains("ce chapitre") ||
        lower.contains("dans ce chapitre") ||
        lower.contains("cette section") ||
        lower.contains("ce fichier") ||
        lower.contains("ce passage") ||
        lower.contains("le passage sur")) {
      if (!lower.contains("sur le web") && !lower.contains("sur internet")) {
        return false;
      }
    }

    // Explicit web search queries
    final explicitWebPhrases = [
      "recherche sur le web",
      "recherche web",
      "cherche sur le web",
      "cherche sur internet",
      "sur le web",
      "sur internet",
      "cours de la bourse",
      "dernières nouvelles",
      "dernieres nouvelles",
    ];

    if (explicitWebPhrases.any((kw) => lower.contains(kw))) {
      return true;
    }

    // Standalone "météo", "actualités" without document context
    if ((lower.contains("météo") || lower.contains("meteo") || lower.contains("actualités") || lower.contains("actualites")) &&
        (lower.startsWith("météo") || lower.startsWith("meteo") || lower.startsWith("quelle est la météo") || lower.startsWith("quel temps") || lower.startsWith("actualités") || lower.startsWith("les actualités"))) {
      return true;
    }

    return false;
  }

  /// Résout le runtime Node portable pour le MCP Gmail (AUD-GMAIL-01 / TNR-025).
  Future<GmailMcpLauncher> _resolveGmailMcpLauncher() async {
    final candidateDirs = <String>[];
    if (plat.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      candidateDirs.add(p.join(exeDir, 'runtime', 'node'));
    }
    candidateDirs.add(p.join(Directory.current.path, 'runtime', 'node'));
    candidateDirs.add(p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Release', 'runtime', 'node'));

    for (final dirPath in candidateDirs) {
      final nodeExe = File(p.join(dirPath, plat.isWindows ? 'node.exe' : 'node'));
      final localEntry = File(p.join(dirPath, 'node_modules', '@monsoft', 'mcp-gmail', 'dist', 'index.js'));
      final npxCli = File(p.join(dirPath, 'node_modules', 'npm', 'bin', 'npx-cli.js'));
      final npxCmd = File(p.join(dirPath, 'npx.cmd'));

      // 1. Priorité absolue : exécution directe du package embarqué localement (B-R2)
      if (await nodeExe.exists() && await localEntry.exists()) {
        final currentPath = Platform.environment['PATH'] ?? '';
        return GmailMcpLauncher(
          executable: nodeExe.path,
          arguments: [localEntry.path],
          pathEnv: '$dirPath;$currentPath',
          runInShell: false,
        );
      } else if (await nodeExe.exists() && await npxCli.exists()) {
        final currentPath = Platform.environment['PATH'] ?? '';
        return GmailMcpLauncher(
          executable: nodeExe.path,
          arguments: [npxCli.path, '-y', '@monsoft/mcp-gmail@0.4.0'],
          pathEnv: '$dirPath;$currentPath',
          runInShell: false,
        );
      } else if (await npxCmd.exists()) {
        final currentPath = Platform.environment['PATH'] ?? '';
        return GmailMcpLauncher(
          executable: 'cmd.exe',
          arguments: ['/c', npxCmd.path, '-y', '@monsoft/mcp-gmail@0.4.0'],
          pathEnv: '$dirPath;$currentPath',
          runInShell: true,
        );
      }
    }

    // Fallback système
    return GmailMcpLauncher(
      executable: 'cmd.exe',
      arguments: ['/c', 'npx', '-y', '@monsoft/mcp-gmail@0.4.0'],
      pathEnv: Platform.environment['PATH'] ?? '',
      runInShell: true,
    );
  }

  /// Executes an interactive JSON-RPC query or write action on the portable Gmail MCP server.
  Future<String> queryGmail(String query, {String? action, Map<String, dynamic>? customArgs}) async {
    try {
      // 1. Structured plan resolution with required fields gating (MCP-006)
      final plan = resolveGmailActionPlan(query, action: action, customArgs: customArgs);
      if (!plan.isSafeToExecute) {
        Log.instance.w("mcp_tools", "GmailActionPlan unsafe: ${plan.errorMessage}");
        return "⚠️ Action Gmail non exécutée : ${plan.errorMessage}";
      }

      final toolName = plan.action;
      final toolArgs = plan.arguments;

      final mcpDir = await _portableMcpServersDir;
      final gmailDir = p.join(mcpDir, "gmail");
      final credPath = p.join(gmailDir, "credentials.json");
      final keysPath = p.join(gmailDir, "gcp-oauth.keys.json");

      final mockCmd = mockGmailCommand ?? Platform.environment['GMAIL_MCP_MOCK_CMD'];
      if ((mockCmd == null || mockCmd.isEmpty) && (!await File(credPath).exists() || !await File(keysPath).exists())) {
        return "⚠️ Fichiers d'accès Gmail introuvables dans \"$gmailDir\". Veuillez placer \"credentials.json\" et \"gcp-oauth.keys.json\" dans ce dossier.";
      }

      // Check credentials file integrity (fail-closed if 0 bytes or corrupted)
      if (mockCmd == null || mockCmd.isEmpty) {
        final credFile = File(credPath);
        if (await credFile.length() == 0) {
          return "⚠️ Fichier credentials.json vide (0 octet). Relancez LOGIN_GMAIL.bat pour vous réauthentifier.";
        }
        try {
          final credRaw = jsonDecode(await credFile.readAsString()) as Map<String, dynamic>;
          final expiryMs = credRaw["expiry_date"] as int?;
          final expiry = expiryMs != null ? DateTime.fromMillisecondsSinceEpoch(expiryMs) : null;
          final needsRefresh = expiry == null || expiry.isBefore(DateTime.now().add(const Duration(minutes: 5)));
          if (needsRefresh) {
            Log.instance.i("mcp_tools", "Gmail: token expiré — rafraîchissement automatique...");
            final refreshed = await _refreshGmailToken(credPath, keysPath);
            if (!refreshed) {
              Log.instance.w("mcp_tools", "Gmail: impossible de rafraîchir — token expiré. Relancez LOGIN_GMAIL.bat.");
            }
          }
        } catch (e) {
          Log.instance.w("mcp_tools", "Gmail: credentials.json invalide ($e). Relancez LOGIN_GMAIL.bat.");
          return "⚠️ Fichier credentials.json invalide ou corrompu. Relancez LOGIN_GMAIL.bat pour vous réauthentifier.";
        }
      }

      final Process process;
      if (mockCmd != null && mockCmd.isNotEmpty) {
        final parts = mockCmd.split(' ');
        process = await Process.start(parts[0], parts.sublist(1));
      } else {
        final launcher = await _resolveGmailMcpLauncher();
        final nodeModulesDir = p.join(p.dirname(launcher.executable), 'node_modules');
        process = await Process.start(
          launcher.executable,
          launcher.arguments,
          environment: {
            ...Platform.environment,
            'PATH': launcher.pathEnv,
            'NODE_PATH': nodeModulesDir,
            'GMAIL_OAUTH_PATH': keysPath,
            'GMAIL_CREDENTIALS_PATH': credPath,
          },
          runInShell: launcher.runInShell,
        );
      }

      final completer = Completer<String>();
      final stderrBuffer = StringBuffer();

      // Drain stderr concurrently to prevent buffer deadlock (TNR-079)
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (stderrBuffer.length < 8192) {
          if (stderrBuffer.isNotEmpty) stderrBuffer.write('\n');
          stderrBuffer.write(line);
        }
      });

      final sub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.trim().isEmpty) return;
        try {
          final jsonMsg = jsonDecode(line) as Map<String, dynamic>;
          final id = jsonMsg['id'];
          if (id == 2) {
            if (completer.isCompleted) return;

            // Strict JSON-RPC error branch (WRITE_ERROR)
            if (jsonMsg.containsKey('error') && jsonMsg['error'] != null) {
              final err = jsonMsg['error'];
              final errMsg = err is Map ? (err['message']?.toString() ?? jsonEncode(err)) : err.toString();
              completer.complete('WRITE_ERROR: $errMsg');
              return;
            }

            final result = jsonMsg['result'] as Map<String, dynamic>?;

            // Strict MCP isError branch (WRITE_ERROR)
            if (result?['isError'] == true) {
              final contentList = result?['content'] as List<dynamic>?;
              final errMsg = contentList != null && contentList.isNotEmpty
                  ? contentList.map((c) => (c as Map<String, dynamic>)['text']?.toString() ?? '').join('\n')
                  : 'Erreur retournée par le serveur Gmail';
              completer.complete('WRITE_ERROR: $errMsg');
              return;
            }

            final contentList = result?['content'] as List<dynamic>?;
            final isReadAction = toolName == 'gmail_list_emails';

            if (isReadAction) {
              if (contentList != null && contentList.isNotEmpty) {
                final text = contentList
                    .map((c) => (c as Map<String, dynamic>)['text']?.toString() ?? '')
                    .join('\n');
                completer.complete(text.isNotEmpty ? text : 'EMPTY_READ_RESULT');
              } else {
                completer.complete('EMPTY_READ_RESULT');
              }
            } else {
              // Write action success
              final details = contentList != null && contentList.isNotEmpty
                  ? contentList.map((c) => (c as Map<String, dynamic>)['text']?.toString() ?? '').join('\n')
                  : (result != null ? jsonEncode(result) : 'Action exécutée avec succès.');
              completer.complete('WRITE_SUCCESS: $details');
            }
          }
        } catch (_) {}
      });

      String rawResult;
      try {
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
        await process.stdin.flush();

        rawResult = await completer.future.timeout(
          const Duration(seconds: 12),
          onTimeout: () => 'TIMEOUT: Délai de réponse du serveur Gmail dépassé.',
        );
      } finally {
        await sub.cancel();
        await stderrSub.cancel();
        await _terminateProcessTree(process);
      }

      if (rawResult.startsWith('WRITE_ERROR:')) {
        final errText = rawResult.substring(12).trim();
        final detail = stderrBuffer.isNotEmpty ? ' ($stderrBuffer)' : '';
        return '❌ Échec de l\'action Gmail : $errText$detail';
      } else if (rawResult.startsWith('WRITE_SUCCESS:')) {
        return '✅ Action Gmail exécutée avec succès : ${rawResult.substring(14).trim()}';
      } else if (rawResult == 'EMPTY_READ_RESULT') {
        return '✉️ Boîte Gmail : Aucun e-mail trouvé pour cette recherche.';
      } else if (rawResult.startsWith('TIMEOUT:')) {
        if (stderrBuffer.isNotEmpty) {
          Log.instance.w('mcp_tools', 'Gmail timeout stderr: $stderrBuffer');
        }
        return '⏱️ Délai de réponse du serveur Gmail dépassé.';
      } else {
        return '✉️ Données récentes de votre boîte Gmail :\n$rawResult';
      }
    } catch (e) {
      Log.instance.e('mcp_tools', 'Gmail query error: $e');
      return 'Erreur lors de la communication Gmail MCP : $e';
    }
  }

  /// Terminate a process and all its descendants cleanly (TNR-079)
  static Future<void> _terminateProcessTree(Process proc) async {
    final pid = proc.pid;
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
      } else {
        proc.kill(ProcessSignal.sigkill);
      }
    } catch (_) {
      try {
        proc.kill();
      } catch (_) {}
    }
    try {
      await proc.exitCode.timeout(const Duration(milliseconds: 1500));
    } catch (_) {}
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
      'énère', 'enere', 'énére', 'énérer', 'enerer',
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

    const verbPattern = r'(?:[gh]?[eéè]n[eéè]rer?|[gh]?[eéè]n[eéè]rez?|[gh]?[eéè]n[eéè]res?|[gh]?[eéè]n[eéè]ré|cr[eéè]er?|cr[eéè]ez?|cr[eéè]es?|cr[eéè]é|faire?|fais?|fait|faites|dessiner?|dessinez?|dessines?|illustrer?|illustrez?|illustres?|peindre?|peins?|peint|produire?|produis?|produit|afficher?|affichez?|affiche|show|generate|create|draw|paint|render|make)';
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
    Log.instance.i('mcp_tools', 'Generating image with model "${_settings.activeImageModel}": "$visualPrompt" (Prompt: "$promptToSend") on $endpoint [${isCloud ? "cloud" : "local"}]');

    Uint8List? imageBytes;
    String lastError = '';

    final startTime = DateTime.now();
    Duration remainingBudget() {
      final elapsed = DateTime.now().difference(startTime);
      final rem = TimeoutPolicy.imageGenGlobalBudget - elapsed;
      return rem.isNegative ? Duration.zero : rem;
    }

    // 1. Protocole natif SD WebUI / Forge (/sdapi/v1/txt2img) — LOCAL UNIQUEMENT
    if (!isCloud) {
      try {
        final baseHost = endpoint.replaceAll(RegExp(r'/(v1|sdapi/v1).*$'), '');
        final sdUrl = '$baseHost/sdapi/v1/txt2img';
        Log.instance.d('mcp_tools', '[generateImage] Sending POST to $sdUrl (prompt="$promptToSend")');
        final localTimeout = remainingBudget() < TimeoutPolicy.imageGenLocalAttempt
            ? remainingBudget()
            : TimeoutPolicy.imageGenLocalAttempt;
        final response = await _client.post(
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
        ).timeout(localTimeout);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final imagesList = data['images'] as List<dynamic>?;
          if (imagesList != null && imagesList.isNotEmpty) {
            final b64 = imagesList.first.toString();
            imageBytes = base64Decode(b64);
            Log.instance.i('mcp_tools', '[generateImage] Image successfully generated via SD WebUI (${imageBytes.length} bytes)');
          }
        } else {
          lastError = 'SD WebUI HTTP ${response.statusCode}: ${response.body}';
          Log.instance.w('mcp_tools', '[generateImage] $lastError');
        }
      } catch (e) {
        lastError = 'SD WebUI unavailable: $e';
        Log.instance.d('mcp_tools', '[generateImage] $lastError');
      }
    }

    // 2. Protocole standard OpenAI (/v1/images/generations) — LOCAL ET CLOUD
    if (imageBytes == null) {
      final rem = remainingBudget();
      if (rem.inSeconds <= 10) {
        Log.instance.w('mcp_tools', '[generateImage] Budget global épuisé (${TimeoutPolicy.imageGenGlobalBudget.inMinutes} min) — abandon du fallback');
        throw Exception('Délai maximal global de génération d\'image dépassé (${TimeoutPolicy.imageGenGlobalBudget.inMinutes} min)');
      }

      try {
        final openAiUrl = endpoint.endsWith('/images/generations')
            ? endpoint
            : (endpoint.endsWith('/v1') ? '$endpoint/images/generations' : '$endpoint/v1/images/generations');

        Log.instance.d('mcp_tools', '[generateImage] Sending POST to $openAiUrl (prompt="$promptToSend", budget restant=${rem.inSeconds}s)');
        final cloudTimeout = rem < TimeoutPolicy.imageGenCloudAttempt ? rem : TimeoutPolicy.imageGenCloudAttempt;
        final response = await _client.post(
          Uri.parse(openAiUrl),
          headers: _imageHeaders(),
          body: jsonEncode({
            'prompt': promptToSend,
            'model': _settings.activeImageModel,
            'n': 1,
            'size': size,
            'response_format': 'b64_json',
          }),
        ).timeout(cloudTimeout);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final dataList = data['data'] as List<dynamic>?;
          if (dataList != null && dataList.isNotEmpty) {
            final firstItem = dataList.first as Map<String, dynamic>;
            if (firstItem.containsKey('b64_json') && firstItem['b64_json'] != null) {
              imageBytes = base64Decode(firstItem['b64_json'] as String);
              Log.instance.i('mcp_tools', '[generateImage] Image successfully generated via OpenAI endpoint (${imageBytes.length} bytes)');
            } else if (firstItem.containsKey('url') && firstItem['url'] != null) {
              final imgUrl = firstItem['url'] as String;
              if (imgUrl.startsWith('data:image')) {
                final base64Part = imgUrl.split(',').last;
                imageBytes = base64Decode(base64Part);
              } else {
                final imgRes = await _client.get(Uri.parse(imgUrl), headers: _imageHeaders(json: false));
                if (imgRes.statusCode == 200) {
                  imageBytes = imgRes.bodyBytes;
                }
              }
              Log.instance.i('mcp_tools', '[generateImage] Image downloaded from URL (${imageBytes?.length ?? 0} bytes)');
            }
          }
        } else {
          lastError = 'OpenAI image endpoint HTTP ${response.statusCode}: ${response.body}';
          Log.instance.w('mcp_tools', '[generateImage] $lastError');
        }
      } catch (e) {
        lastError = 'OpenAI image endpoint error: $e';
        Log.instance.e('mcp_tools', '[generateImage] $lastError');
      }
    }

    if (imageBytes != null) {
      // Chemin portable correct : Release\data\GeneratedImages\
      final imgDir = AppPaths.imagesDir;

      final timeTag = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'gen_image_$timeTag.png';
      final filePath = p.join(imgDir.path, fileName);
      final file = File(filePath);
      await file.writeAsBytes(imageBytes);

      final fileUri = Uri.file(filePath).toString();
      Log.instance.i('mcp_tools', '[generateImage] Image written to disk: $filePath ($fileUri)');
      return '🎨 **Image générée avec succès :**\n\n![$visualPrompt]($fileUri)\n\n*(Prompt visuel : "$visualPrompt" | Résolution : $size)*';
    }

    final modeLabel = isCloud ? 'cloud (${_settings.imageGenApiUrl})' : 'local (${_settings.imageGenApiUrl})';
    return '⚠️ **Serveur de Génération d\'Images Injoignable ou Erreur**\n\n'
        'Le serveur image $modeLabel n\'a pas pu générer l\'image.\n\n'
        '${lastError.isNotEmpty ? "Détail : *$lastError*\n\n" : ""}'
        '💡 ${isCloud ? "Vérifiez l'URL et la clé API cloud dans les paramètres LLM." : "Assurez-vous que \"sd_server.exe\" ou \"webui-user.bat\" est lancé sur ${_settings.imageGenApiUrl}."}';
  }

  /// Translates and enhances a French image prompt into a rich, detailed English prompt for diffusion models.
  /// Uses [llmService] as the single source of truth for the active provider and endpoint if provided.
  /// Throws [LlmTranslationException] if LLM translation was explicitly requested but failed.
  Future<String> translateToEnglishPrompt(
    String prompt, {
    bool allowLlm = true,
    LlmService? llmService,
  }) async {
    final clean = prompt.trim();
    if (clean.isEmpty) return clean;
    if (!allowLlm) return clean;

    // 1. Source de vérité absolue pour le provider et l'endpoint
    final provider = llmService?.provider ?? _settings.llmProvider;
    final baseEndpoint = llmService?.endpoint ?? _getLlmBaseEndpoint();
    final finalEndpoint = '$baseEndpoint/chat/completions';

    final activeModel = _settings.llmModel.isNotEmpty
        ? _settings.llmModel
        : (provider == LlmProvider.liteRtWindows ? 'gemma-4-e4b-it' : '');

    // 2. Preuve de diagnostic dans les logs (Requis E)
    Log.instance.i('image-translate', '[image-translate] provider=${provider.name}');
    Log.instance.i('image-translate', '[image-translate] model=$activeModel');
    Log.instance.i('image-translate', '[image-translate] baseEndpoint=$baseEndpoint');
    Log.instance.i('image-translate', '[image-translate] finalEndpoint=$finalEndpoint');

    const systemInstruction =
        'You are an expert AI translator. Translate the user description faithfully and accurately into English for an image generation model. Keep ALL described elements (objects, subjects, architecture, illuminated windows, trees, street, lighting, atmosphere) clear, detailed and visible. Do NOT invent camera effects, lenses, depth of field, blur, or bokeh that were not requested by the user. Output ONLY the clean English prompt with no intro or quotes.';

    final sw = Stopwatch()..start();
    String? resultStatus;

    try {
      // Pré-vérification de connectivité rapide (évite de bloquer inutilement sur une adresse morte)
      final uri = Uri.tryParse(finalEndpoint);
      if (uri != null && uri.host.isNotEmpty && uri.port > 0 && _client.runtimeType.toString() != 'MockClient') {
        try {
          final socket = await Socket.connect(uri.host, uri.port, timeout: TimeoutPolicy.llmConnectTimeout);
          socket.destroy();
        } catch (e) {
          throw LlmTranslationException(
            'Le serveur LLM ne répond pas.',
            failureType: LlmTranslationFailureType.connectionRefused,
            technicalDetail: 'Connection probe failed to ${uri.host}:${uri.port} ($e)',
          );
        }
      }

      String? translatedContent;

      if (llmService != null) {
        // Utilisation directe du service LLM actif avec le timeout centralisé de 5 minutes
        translatedContent = await llmService.completeChat(
          messages: [
            LlmChatMessage(role: 'system', content: systemInstruction),
            LlmChatMessage(role: 'user', content: clean),
          ],
          model: activeModel.isNotEmpty ? activeModel : null,
          temperature: 0.3,
        ).timeout(TimeoutPolicy.imagePromptTranslation);
      } else {
        // Fallback direct via client HTTP avec le timeout centralisé de 5 minutes
        final headers = <String, String>{'Content-Type': 'application/json'};
        if (_settings.llmApiKey.isNotEmpty) {
          headers['Authorization'] = 'Bearer ${_settings.llmApiKey}';
        }

        final res = await _client.post(
          Uri.parse(finalEndpoint),
          headers: headers,
          body: jsonEncode({
            if (activeModel.isNotEmpty) 'model': activeModel,
            'messages': [
              {'role': 'system', 'content': systemInstruction},
              {'role': 'user', 'content': clean}
            ],
            'temperature': 0.3,
            'max_tokens': 150,
          }),
        ).timeout(TimeoutPolicy.imagePromptTranslation);

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final choices = data['choices'] as List<dynamic>?;
          if (choices != null && choices.isNotEmpty) {
            translatedContent = choices.first['message']?['content']?.toString() ?? '';
          }
        } else {
          throw _classifyError(
            Exception('HTTP ${res.statusCode}'),
            statusCode: res.statusCode,
            responseBody: res.body,
            endpoint: finalEndpoint,
          );
        }
      }

      final trimmed = (translatedContent ?? '').trim();
      if (trimmed.isNotEmpty && !trimmed.toLowerCase().contains('sorry') && !trimmed.toLowerCase().contains('cannot')) {
        final filtered = trimmed.replaceAll('"', '').replaceAll("'", '').trim();
        resultStatus = 'SUCCESS';
        Log.instance.i('image-translate',
            '[image-translate] provider=${provider.name} model=$activeModel endpoint=$finalEndpoint '
            'prompt_chars=${clean.length} request_messages=2 document_context=false rag_context=false '
            'history_context=false timeout=${TimeoutPolicy.imagePromptTranslation.inSeconds}s '
            'duration=${sw.elapsed.inSeconds}s result=$resultStatus');
        Log.instance.i('mcp_tools', 'LLM translated visual prompt: "$clean" -> "$filtered"');
        return filtered;
      }
      throw LlmTranslationException('Réponse vide ou invalide reçue du modèle LLM',
          failureType: LlmTranslationFailureType.modelError);
    } catch (e) {
      final classified = _classifyError(
        e,
        endpoint: finalEndpoint,
      );
      resultStatus = classified.failureType.name.toUpperCase();
      Log.instance.w('image-translate',
          '[image-translate] provider=${provider.name} model=$activeModel endpoint=$finalEndpoint '
          'prompt_chars=${clean.length} request_messages=2 document_context=false rag_context=false '
          'history_context=false timeout=${TimeoutPolicy.imagePromptTranslation.inSeconds}s '
          'duration=${sw.elapsed.inSeconds}s result=$resultStatus');
      throw classified;
    }
  }

  /// Classifie précisément l'erreur rencontrée lors de la traduction IA du prompt.
  LlmTranslationException _classifyError(
    Object error, {
    int? statusCode,
    String? responseBody,
    required String endpoint,
  }) {
    if (error is LlmTranslationException) return error;

    if (error is TimeoutException) {
      return LlmTranslationException(
        'La traduction IA prend trop de temps et a été interrompue.',
        failureType: LlmTranslationFailureType.responseTimeout,
        technicalDetail: 'Timeout après ${TimeoutPolicy.imagePromptTranslation.inSeconds}s sur $endpoint',
      );
    }

    final rawText = '${error.toString()} ${responseBody ?? ""}'.toLowerCase();

    if (error is SocketException ||
        rawText.contains('connection refused') ||
        rawText.contains('failed host lookup') ||
        rawText.contains('connection reset') ||
        rawText.contains('network is unreachable') ||
        rawText.contains('clientexception with socketexception') ||
        rawText.contains('failed to connect') ||
        rawText.contains('connection closed') ||
        rawText.contains('10061')) {
      return LlmTranslationException(
        'Le serveur LLM ne répond pas.',
        failureType: LlmTranslationFailureType.connectionRefused,
        technicalDetail: 'Connection failed to $endpoint: $error',
      );
    }

    if (rawText.contains('context_length_exceeded') ||
        rawText.contains('context_window') ||
        rawText.contains('exceed_context_size_error') ||
        rawText.contains('maximum context length') ||
        rawText.contains('too many tokens') ||
        rawText.contains('context is too large')) {
      return LlmTranslationException(
        'La requête dépasse la taille maximale de contexte du modèle.',
        failureType: LlmTranslationFailureType.contextTooLarge,
        technicalDetail: responseBody ?? error.toString(),
      );
    }

    if (rawText.contains('model unloaded') ||
        rawText.contains('model not loaded') ||
        rawText.contains('no model loaded') ||
        rawText.contains('model_not_found') ||
        rawText.contains('not loaded into memory') ||
        rawText.contains('model is not loaded')) {
      return LlmTranslationException(
        'Le modèle LLM n\'est pas chargé en mémoire.',
        failureType: LlmTranslationFailureType.modelUnloaded,
        technicalDetail: responseBody ?? error.toString(),
      );
    }

    String detail = error.toString();
    if (responseBody != null && responseBody.isNotEmpty) {
      try {
        final decoded = jsonDecode(responseBody);
        if (decoded is Map && decoded['error'] != null) {
          final err = decoded['error'];
          if (err is Map && err['message'] != null) {
            detail = err['message'].toString();
          } else if (err is String) {
            detail = err;
          }
        }
      } catch (_) {
        detail = responseBody;
      }
    }

    return LlmTranslationException(
      'Erreur du modèle LLM : $detail',
      failureType: LlmTranslationFailureType.modelError,
      technicalDetail: 'Error on $endpoint ($statusCode): $error',
    );
  }

  /// Résout l'endpoint de base du provider LLM actif en respectant les fallbacks de LlmProvider.
  String _getLlmBaseEndpoint() {
    final custom = _settings.llmApiUrl.trim();
    final provider = _settings.llmProvider;
    if (custom.isNotEmpty) {
      if (provider == LlmProvider.liteRtWindows) {
        if (custom.contains(':1234')) return 'http://127.0.0.1:9379/v1';
        return custom.replaceAll('localhost:9379', '127.0.0.1:9379').replaceAll(RegExp(r'/+$'), '');
      }
      if (provider == LlmProvider.lmStudio && custom.contains(':9379')) {
        return 'http://localhost:1234/v1';
      }
      return custom.replaceAll(RegExp(r'/+$'), '');
    }
    return switch (provider) {
      LlmProvider.liteRtWindows => 'http://127.0.0.1:9379/v1',
      LlmProvider.lmStudio      => 'http://localhost:1234/v1',
      LlmProvider.ollama        => 'http://localhost:11434/v1',
      LlmProvider.liteRtAndroid => 'local_litert',
      LlmProvider.custom        => 'http://localhost:1234/v1',
    };
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
      candidateDirs.add(p.join(Directory.current.path, '..', 'Jarvisol_V1_EXT03_Candidate', 'models', 'Stable-diffusion'));

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
                // Exclure les modèles inpainting (filtre lexical — filet de secours)
                if (fileName.contains('inpaint')) {
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

      // Requête /v1/models/image — endpoint structuré avec flag is_inpainting
      // Remplace /sdapi/v1/sd-models qui ne distinguait pas inpainting des modèles text-to-image
      try {
        final endpoint = _settings.imageGenApiUrl.trim().replaceAll(RegExp(r'/+$'), '');
        final baseHost = endpoint.replaceAll(RegExp(r'/(v1|sdapi/v1).*$'), '');
        final modelsUri = Uri.parse('$baseHost/v1/models/image');
        final res = await http.get(modelsUri, headers: _imageHeaders(json: false))
            .timeout(const Duration(seconds: 2));
        if (res.statusCode == 200) {
          final list = jsonDecode(res.body) as List<dynamic>?;
          if (list != null) {
            // Le serveur fait autorité : on écrase le scan dossier
            discovered.clear();
            for (final item in list) {
              if (item is Map) {
                final name = item['name']?.toString() ?? '';
                final isInpainting = item['is_inpainting'] == true;
                // Conserver UNIQUEMENT les modèles text-to-image (is_inpainting == false)
                if (name.isNotEmpty && !isInpainting) {
                  discovered.add(name);
                }
              }
            }
          }
        }
      } catch (_) {
        // Serveur injoignable → le scan dossier (avec filtre lexical) reste en résultat
      }
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

  // ── MCPs custom : exécution HTTP & Script ────────────────────────────────

  /// Exécute un MCP custom de type HTTP. Retourne la réponse à injecter dans le prompt.
  Future<String> executeMcpHttp(Map<String, dynamic> mcp, String userMessage) async {
    final endpoint = mcp['endpoint'] as String? ?? '';
    final method   = (mcp['method'] as String? ?? 'POST').toUpperCase();
    final bodyTpl  = mcp['body_template'] as String? ?? '';
    final rpath    = mcp['response_path'] as String? ?? '';
    if (endpoint.isEmpty) return '';
    try {
      final uri = Uri.parse(endpoint);
      final bodyStr = bodyTpl.isEmpty
          ? jsonEncode({'message': userMessage})
          : bodyTpl.replaceAll('{{user_message}}', userMessage);
      final client = http.Client();
      http.Response response;
      final headers = {'Content-Type': 'application/json; charset=utf-8'};
      if (method == 'GET') {
        response = await client.get(uri, headers: headers)
            .timeout(const Duration(seconds: 10));
      } else {
        response = await client.post(uri, headers: headers, body: bodyStr)
            .timeout(const Duration(seconds: 10));
      }
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Extraire via response_path (ex: "result" ou "data.text")
        dynamic extracted = data;
        if (rpath.isNotEmpty) {
          for (final key in rpath.split('.')) {
            if (extracted is Map) extracted = extracted[key];
            else break;
          }
        }
        return extracted?.toString() ?? response.body;
      }
      return '';
    } catch (e) {
      Log.instance.d('mcp_tools', 'executeMcpHttp error: $e');
      return '';
    }
  }

  /// Exécute un MCP custom de type script (Python/shell). Retourne la sortie stdout.


  /// Exécute manuellement un MCP custom de type script avec capture complète du processus.
  Future<McpProcessExecutionResult> runMcpScript(Map<String, dynamic> mcp, [String userMessage = ""]) async {
    final scriptPath = mcp["script_path"] as String? ?? "";
    final argsTpl = List<String>.from(mcp["args_template"] as List? ?? []);
    if (scriptPath.isEmpty) {
      return McpProcessExecutionResult(
        command: "(aucun script défini)",
        stdout: "",
        stderr: "Le chemin du script est vide.",
        exitCode: 1,
        success: false,
      );
    }
    try {
      final args = argsTpl.map((a) => a.replaceAll("{{user_message}}", userMessage)).toList();
      final ext = scriptPath.toLowerCase();
      final String executable;
      final List<String> finalArgs;
      if (ext.endsWith(".py")) {
        executable = "python";
        finalArgs = [scriptPath, ...args];
      } else if (ext.endsWith(".bat") || ext.endsWith(".cmd")) {
        executable = "cmd.exe";
        finalArgs = ["/c", scriptPath, ...args];
      } else if (ext.endsWith(".ps1")) {
        executable = "powershell.exe";
        finalArgs = ["-ExecutionPolicy", "Bypass", "-File", scriptPath, ...args];
      } else {
        executable = scriptPath;
        finalArgs = args;
      }
      final cmdDisplay = "$executable ${finalArgs.join(' ')}".trim();
      final proc = await Process.start(executable, finalArgs);
      final pid = proc.pid;
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();

      proc.stdout.transform(utf8.decoder).listen((s) => stdoutBuffer.write(s));
      proc.stderr.transform(utf8.decoder).listen((s) => stderrBuffer.write(s));

      int exitCode;
      try {
        exitCode = await proc.exitCode.timeout(TimeoutPolicy.mcpProcessTimeout);
      } on TimeoutException {
        Log.instance.w('mcp_tools', 'MCP CLI process PID=$pid timed out after ${TimeoutPolicy.mcpProcessTimeout.inSeconds}s — killing process tree');
        try {
          if (Platform.isWindows) {
            await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
          } else {
            proc.kill(ProcessSignal.sigkill);
          }
        } catch (killErr) {
          Log.instance.w('mcp_tools', 'Error killing timed out MCP process PID=$pid: $killErr');
        }
        return McpProcessExecutionResult(
          command: cmdDisplay,
          stdout: stdoutBuffer.toString().trim(),
          stderr: "Délai dépassé (${TimeoutPolicy.mcpProcessTimeout.inSeconds}s) — processus tué",
          exitCode: -1,
          success: false,
        );
      }

      return McpProcessExecutionResult(
        command: cmdDisplay,
        stdout: stdoutBuffer.toString().trim(),
        stderr: stderrBuffer.toString().trim(),
        exitCode: exitCode,
        success: exitCode == 0,
      );
    } catch (e) {
      return McpProcessExecutionResult(
        command: scriptPath,
        stdout: "",
        stderr: "Exception lors de l'exécution: $e",
        exitCode: -1,
        success: false,
      );
    }
  }

  Future<String> executeMcpScript(Map<String, dynamic> mcp, String userMessage) async {
    final scriptPath = mcp['script_path'] as String? ?? '';
    final argsTpl    = List<String>.from(mcp['args_template'] as List? ?? []);
    if (scriptPath.isEmpty) return '';
    try {
      final args = argsTpl.map((a) => a.replaceAll('{{user_message}}', userMessage)).toList();
      final ext = scriptPath.toLowerCase();
      final String executable;
      final List<String> finalArgs;
      if (ext.endsWith('.py')) {
        executable = 'python';
        finalArgs = [scriptPath, ...args];
      } else {
        executable = scriptPath;
        finalArgs = args;
      }
      final proc = await Process.start(executable, finalArgs);
      final pid = proc.pid;
      final stdoutBuffer = StringBuffer();
      proc.stdout.transform(utf8.decoder).listen((s) => stdoutBuffer.write(s));

      try {
        await proc.exitCode.timeout(TimeoutPolicy.mcpProcessTimeout);
      } on TimeoutException {
        Log.instance.w('mcp_tools', 'MCP script PID=$pid timed out — killing');
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
        } else {
          proc.kill(ProcessSignal.sigkill);
        }
        return '';
      }
      return stdoutBuffer.toString().trim();
    } catch (e) {
      Log.instance.d('mcp_tools', 'executeMcpScript error: $e');
      return '';
    }
  }
}

/// Provider for McpToolsService
final mcpToolsServiceProvider = Provider<McpToolsService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  return McpToolsService(settings);
});
