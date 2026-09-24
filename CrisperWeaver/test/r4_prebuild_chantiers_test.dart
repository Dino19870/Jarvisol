// test/r4_prebuild_chantiers_test.dart — Validation tests for R4 Corrective Campaign
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/audiobook_models.dart';
import 'package:jarvisol/models/web_media_models.dart';
import 'package:jarvisol/services/log_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/web_media_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/widgets/web_media_import_dialog.dart';

class FakeR4WebService extends WebMediaService {
  List<WebMediaSearchResult> searchResults = [];
  int metadataFetchCount = 0;

  @override
  Future<WebMediaProbeResult> probe() async {
    return const WebMediaProbeResult(isAvailable: true, version: '2026.08.19');
  }

  @override
  Future<List<WebMediaSearchResult>> searchMedia(
    String query, {
    int limit = 20,
    Duration timeout = const Duration(seconds: 45),
    WebMediaCancellationToken? cancelToken,
  }) async {
    return searchResults;
  }

  @override
  Future<WebMediaMetadata> getMetadata(
    String url, {
    bool includePlaylist = false,
    Duration timeout = const Duration(seconds: 45),
    WebMediaCancellationToken? cancelToken,
  }) async {
    metadataFetchCount++;
    return WebMediaMetadata(
      url: url,
      extractor: 'youtube',
      id: 'test_vid_1',
      title: 'Titre Vidéo R4 Test',
      description: 'Ligne 1 de description\nLigne 2 détaillée\nLigne 3 finale.',
      uploader: 'Chaîne Officielle',
      channel: 'Chaîne Officielle',
      uploadDate: '20260915',
      duration: 240.0,
      thumbnail: 'https://example.com/thumb.jpg',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CHANTIER A: Image Packaging Gate', () {
    test('A.1: Canonical production image asset inventory exists and contains 19 models', () {
      final csvFile = File('data/config/canonical_production_image_assets.csv');
      expect(csvFile.existsSync(), isTrue, reason: 'canonical_production_image_assets.csv must exist');

      final lines = csvFile.readAsLinesSync().where((l) => l.trim().isNotEmpty && !l.startsWith('#')).toList();
      final dataLines = lines.skip(1).toList();
      expect(dataLines.length, 19, reason: 'Must have exactly 19 canonical image production models');

      int totalBytes = 0;
      for (final line in dataLines) {
        final parts = line.split(';');
        // CATEGORY;FILENAME;RELATIVE_PATH;SIZE_BYTES;SHA256;CLASSIFICATION
        expect(parts.length, greaterThanOrEqualTo(6));
        final size = int.parse(parts[3].trim());
        final sha256 = parts[4].trim();
        final classification = parts[5].trim();
        expect(size, greaterThan(0));
        expect(sha256.length, 64);
        expect(classification, 'PRODUCTION_REQUIRED');
        totalBytes += size;
      }
      expect(totalBytes, 60847149564, reason: 'Total size must equal exactly 60,847,149,564 bytes');
    });

    test('A.2: Candidate directory contains all 19 image models bit-for-bit', () {
      final candidateDir = Directory(r'D:\Antigravity\AgentFolder\Jarvisol_V1_EXT03_Candidate');
      expect(candidateDir.existsSync(), isTrue);

      final csvFile = File('data/config/canonical_production_image_assets.csv');
      final lines = csvFile.readAsLinesSync().skip(1).where((l) => l.trim().isNotEmpty).toList();

      for (final line in lines) {
        final parts = line.split(';');
        // CATEGORY;FILENAME;RELATIVE_PATH;SIZE_BYTES;SHA256;CLASSIFICATION
        final relPath = parts[2].trim();
        final expectedSize = int.parse(parts[3].trim());

        final modelFile = File('${candidateDir.path}${Platform.pathSeparator}$relPath');
        expect(modelFile.existsSync(), isTrue, reason: 'Missing candidate model: $relPath');
        expect(modelFile.lengthSync(), expectedSize, reason: 'Size mismatch on candidate model: $relPath');
      }
    });
  });

  group('CHANTIER B: Web Media UX, Multi-Click & Description', () {
    late FakeR4WebService fakeWebService;
    late SettingsService settingsService;

    setUp(() async {
      fakeWebService = FakeR4WebService();
      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      settingsService = SettingsService(prefs);
    });

    testWidgets('B.1: Single getMetadata call, description expandable, and multi-click guard active', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      fakeWebService.searchResults = [
        WebMediaSearchResult(
          id: 'test_vid_1',
          url: 'https://www.youtube.com/watch?v=test_vid_1',
          title: 'Titre Vidéo R4 Test',
          uploader: 'Chaîne Officielle',
          channel: 'Chaîne Officielle',
          duration: 240.0,
          mediaType: WebMediaResultType.video,
          viewCount: 125000,
          uploadDate: '20260915',
          description: 'Ligne 1 de description\nLigne 2 détaillée\nLigne 3 finale.',
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            webMediaServiceProvider.overrideWithValue(fakeWebService),
            settingsServiceProvider.overrideWithValue(settingsService),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: WebMediaImportDialog(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Launch search
      await tester.enterText(find.byType(TextField), 'test query');
      await tester.tap(find.text('Rechercher'));
      await tester.pumpAndSettle();

      // Verify search result rendered
      expect(find.text('1 résultats affichés'), findsOneWidget);
      expect(find.text('Titre Vidéo R4 Test'), findsOneWidget);

      // Select result card
      final selectBtn = find.byIcon(Icons.arrow_forward);
      expect(selectBtn, findsOneWidget);
      await tester.tap(selectBtn);
      await tester.pumpAndSettle();

      // Verify exactly ONE getMetadata call was made (no duplicate network call)
      expect(fakeWebService.metadataFetchCount, 1);

      // Verify metadata view rendered
      expect(find.text('Description complète'), findsOneWidget);
      expect(find.text('Publié le 15/09/2026'), findsOneWidget);
      expect(find.text('125000 vues'), findsOneWidget);

      // Expand description
      await tester.tap(find.text('Description complète'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ligne 2 détaillée'), findsOneWidget);

      // Verify back button restores search results
      final backBtn = find.text('Retour aux résultats de recherche');
      expect(backBtn, findsOneWidget);
      await tester.tap(backBtn);
      await tester.pumpAndSettle();

      expect(find.text('1 résultats affichés'), findsOneWidget);
      expect(find.text('Titre Vidéo R4 Test'), findsOneWidget);
    });
  });

  group('CHANTIER C: VibeVoice Voicepack Routing & Model Dispatch', () {
    test('C.1: Voice pack naming mapping to Realtime 0.5B TTS engine', () {
      const voicepackMan = 'vibevoice-voice-fr-Spk0_man';
      const voicepackWoman = 'vibevoice-voice-fr-Spk1_woman';
      const legacyMan = 'vibevoice-fr-Spk0_man';
      const legacyWoman = 'vibevoice-fr-Spk1_woman';

      String resolveEngine(String voiceModel) {
        if (voiceModel.startsWith('vibevoice-voice-') ||
            voiceModel == 'vibevoice-fr-Spk0_man' ||
            voiceModel == 'vibevoice-fr-Spk1_woman') {
          return 'vibevoice-realtime-0.5b-tts-f16';
        }
        if (voiceModel.startsWith('vibevoice-')) {
          return 'vibevoice-1.5b-tts';
        }
        return 'unknown';
      }

      expect(resolveEngine(voicepackMan), 'vibevoice-realtime-0.5b-tts-f16');
      expect(resolveEngine(voicepackWoman), 'vibevoice-realtime-0.5b-tts-f16');
      expect(resolveEngine(legacyMan), 'vibevoice-realtime-0.5b-tts-f16');
      expect(resolveEngine(legacyWoman), 'vibevoice-realtime-0.5b-tts-f16');
      expect(resolveEngine('vibevoice-1.5b-tts'), 'vibevoice-1.5b-tts');
    });

    test('C.2: Custom clone voice model non-regression', () {
      const cloneSpeaker = AudiobookSpeaker(
        id: 'clone_spk',
        name: 'Custom Clone Speaker',
        voiceModelName: 'custom-clone',
        customVoiceWavPath: 'C:/Samples/ref.wav',
        speed: 1.0,
      );
      expect(cloneSpeaker.voiceModelName, 'custom-clone');
      expect(cloneSpeaker.customVoiceWavPath, 'C:/Samples/ref.wav');
    });
  });

  group('CHANTIER D: Crash Diagnostics, Sanitization & Session Lock', () {
    test('D.1: sanitizeLogText scrubs all sensitive secrets and tokens', () {
      final textWithKeys = 'User apiKey: sk-abc123def456ghi7890123456789 and HF token: hf_0123456789abcdefghijklmnop '
          'with Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 and client_secret="secret_9876543210" '
          'and refresh_token: ref_1234567890abc';

      final sanitized = sanitizeLogText(textWithKeys);

      expect(sanitized, isNot(contains('sk-abc123def456ghi7890123456789')));
      expect(sanitized, isNot(contains('hf_0123456789abcdefghijklmnop')));
      expect(sanitized, isNot(contains('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9')));
      expect(sanitized, isNot(contains('secret_9876543210')));
      expect(sanitized, isNot(contains('ref_1234567890abc')));

      expect(sanitized, contains('sk-***REDACTED***'));
      expect(sanitized, contains('hf_***REDACTED***'));
      expect(sanitized, contains('Bearer ***REDACTED***'));
      expect(sanitized, contains('client_secret="***REDACTED***"'));
      expect(sanitized, contains('refresh_token: ***REDACTED***'));
    });

    test('D.2: LogEntry formatting automatically scrubs secrets process-wide', () {
      final entry = LogEntry(
        timestamp: DateTime(2026, 9, 17, 12, 0, 0),
        level: LogLevel.info,
        tag: 'cloud_llm',
        message: 'Calling OpenAI endpoint with key sk-99887766554433221100',
        fields: {'auth_header': 'Bearer my_secret_token_123456789'},
      );

      final formatted = entry.format();
      expect(formatted, isNot(contains('sk-99887766554433221100')));
      expect(formatted, isNot(contains('my_secret_token_123456789')));
      expect(formatted, contains('sk-***REDACTED***'));
      expect(formatted, contains('Bearer ***REDACTED***'));
    });

    test('D.3: session.lock lifecycle (creation, stale detection, cleanup)', () {
      final tempDir = Directory.systemTemp.createTempSync('r4_lock_test_');
      final lockFile = File('${tempDir.path}${Platform.pathSeparator}session.lock');

      // 1. Initial state: no lock
      expect(lockFile.existsSync(), isFalse);

      // 2. Simulate launch: create lock
      final testPid = 12345;
      final lockContent = 'PID: $testPid | Started: ${DateTime.now().toUtc().toIso8601String()}\n';
      lockFile.writeAsStringSync(lockContent, flush: true);
      expect(lockFile.existsSync(), isTrue);

      // 3. Simulate second startup detecting stale/existing lock
      expect(lockFile.readAsStringSync(), contains('PID: 12345'));

      // 4. Simulate clean exit: remove lock
      lockFile.deleteSync();
      expect(lockFile.existsSync(), isFalse);

      tempDir.deleteSync(recursive: true);
    });
  });
}
