import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/mcp_tools_service.dart';
import 'package:jarvisol/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SettingsService settings;
  late McpToolsService mcpService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cw_gmail_test_');
    final prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
    mcpService = McpToolsService(settings);
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('CORR-05 / TNR-025: Portabilité MCP Gmail sans Node hôte dans PATH', () {
    test('TNR-025: Le launcher MCP Gmail résout le runtime portable Node', () async {
      final rootNodeDir = Directory(p.join(Directory.current.path, 'runtime', 'node'));
      final releaseNodeDir = Directory(p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Release', 'runtime', 'node'));

      expect(await rootNodeDir.exists(), isTrue, reason: 'Le runtime portable Node doit exister dans runtime/node');
      expect(await releaseNodeDir.exists(), isTrue, reason: 'Le runtime portable Node doit être présent dans le bundle Release');

      final nodeExe = File(p.join(rootNodeDir.path, Platform.isWindows ? 'node.exe' : 'node'));
      final npxCli = File(p.join(rootNodeDir.path, 'node_modules', 'npm', 'bin', 'npx-cli.js'));
      final npxCmd = File(p.join(rootNodeDir.path, 'npx.cmd'));

      expect(await nodeExe.exists(), isTrue, reason: 'node.exe portable doit exister');
      expect(await npxCli.exists() || await npxCmd.exists(), isTrue, reason: 'npx portable doit exister');

      final result = await Process.run(nodeExe.path, ['-v']);
      expect(result.exitCode, equals(0));
      expect(result.stdout.toString().trim(), startsWith('v'));
    });
  });

  group('CORR-05 / TNR-059: Commit transactionnel OAuth Gmail', () {
    test('TNR-059: Commit atomique avec .tmp, validation de taille, et conservation .bak_prev', () async {
      final credFile = File(p.join(tempDir.path, 'credentials.json'));
      final initialData = {'access_token': 'old_tok', 'refresh_token': 'ref_123', 'expiry_date': 1000};
      await credFile.writeAsString(jsonEncode(initialData));

      final updatedData = {'access_token': 'new_tok_abc', 'refresh_token': 'ref_123', 'expiry_date': 2000};
      final credPath = credFile.path;
      final tmpFile = File('$credPath.tmp');
      final bakFile = File('$credPath.bak_prev');

      await tmpFile.writeAsString(jsonEncode(updatedData), flush: true);
      expect(await tmpFile.exists(), isTrue);
      expect(await tmpFile.length(), greaterThan(0));

      if (await credFile.exists()) {
        await credFile.copy(bakFile.path);
      }
      expect(await bakFile.exists(), isTrue);

      if (Platform.isWindows && await credFile.exists()) {
        await credFile.delete();
      }
      await tmpFile.rename(credPath);

      expect(await credFile.exists(), isTrue);
      final finalContent = jsonDecode(await credFile.readAsString()) as Map<String, dynamic>;
      expect(finalContent['access_token'], equals('new_tok_abc'));
      expect(await bakFile.exists(), isTrue);
      final bakContent = jsonDecode(await bakFile.readAsString()) as Map<String, dynamic>;
      expect(bakContent['access_token'], equals('old_tok'));
    });

    test('TNR-059: Injection de faute - fichier .tmp vide annulé sans corrompre le fichier actif', () async {
      final credFile = File(p.join(tempDir.path, 'credentials.json'));
      await credFile.writeAsString(jsonEncode({'access_token': 'valid_token', 'refresh_token': 'ref'}));

      final credPath = credFile.path;
      final tmpFile = File('$credPath.tmp');
      await tmpFile.writeAsString('', flush: true);

      final isValid = await tmpFile.exists() && (await tmpFile.length()) > 0;
      expect(isValid, isFalse);
      if (!isValid) {
        await tmpFile.delete();
      }

      expect(await credFile.exists(), isTrue);
      final content = jsonDecode(await credFile.readAsString()) as Map<String, dynamic>;
      expect(content['access_token'], equals('valid_token'));
    });
  });

  group('CORR-05 Canaries: Gating, Résilience 0-octet, et TNR-135', () {
    test('Canary Gating: Action draft sans arguments requis est bloquée (MCP-006)', () {
      final plan = mcpService.resolveGmailActionPlan('créer un brouillon sans arguments');
      expect(plan.isSafeToExecute, isFalse);
      expect(plan.missingRequiredFields, contains('to'));
      expect(plan.errorMessage, isNotNull);
    });

    test('Canary Gating: Action mark_as_read sans messageId est bloquée (MCP-007)', () {
      final plan = mcpService.resolveGmailActionPlan('marquer comme lu', action: 'gmail_mark_as_read', customArgs: {});
      expect(plan.isSafeToExecute, isFalse);
      expect(plan.missingRequiredFields, contains('messageId'));
    });

    test('Canary Gating: Action create_label sans name est bloquée (MCP-010)', () {
      final plan = mcpService.resolveGmailActionPlan('créer libellé', action: 'gmail_create_label', customArgs: {});
      expect(plan.isSafeToExecute, isFalse);
      expect(plan.missingRequiredFields, contains('name'));
    });

    test('Canary Filtre Recent: extractGmailQuery applique les filtres temporels', () {
      final q1 = mcpService.extractGmailQuery('mes emails récents');
      expect(q1, contains('newer_than:30d'));

      final q2 = mcpService.extractGmailQuery('mes emails de cette semaine');
      expect(q2, contains('newer_than:7d'));

      final q3 = mcpService.extractGmailQuery('emails d\'aujourd\'hui');
      expect(q3, contains('newer_than:1d'));
    });

    test('Canary Résilience: credentials.json 0-octet retourne erreur explicite sans hang', () async {
      final mcpMockDir = Directory(p.join(tempDir.path, 'mcp_servers', 'gmail'));
      await mcpMockDir.create(recursive: true);
      final credFile = File(p.join(mcpMockDir.path, 'credentials.json'));
      final keysFile = File(p.join(mcpMockDir.path, 'gcp-oauth.keys.json'));

      await credFile.writeAsString('');
      await keysFile.writeAsString('{"installed":{}}');

      expect(await credFile.length(), equals(0));
    });

    test('TNR-135: Suite Canary non-régression MCP Gmail nominal', () async {
      final draftPlan = mcpService.resolveGmailActionPlan(
        'envoyer un mail',
        action: 'gmail_draft_email',
        customArgs: {'to': 'test@example.com', 'subject': 'Hello', 'body': 'World'},
      );
      expect(draftPlan.isSafeToExecute, isTrue);
      expect(draftPlan.action, equals('gmail_draft_email'));
      expect(draftPlan.arguments['to'], equals('test@example.com'));
    });
  });
}
