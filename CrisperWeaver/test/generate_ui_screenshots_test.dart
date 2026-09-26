import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/widgets/llm_chat_widget.dart';
import 'package:jarvisol/widgets/document_chat_widget.dart';
import 'package:jarvisol/screens/model_management_screen.dart';
import 'package:jarvisol/theme/app_theme.dart';
import 'package:jarvisol/l10n/generated/app_localizations.dart';

Future<void> saveScreenshot(GlobalKey key, String path) async {
  final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.0);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  final pngBytes = byteData!.buffer.asUint8List();
  File(path).writeAsBytesSync(pngBytes);
  print('Screenshot saved to $path (${pngBytes.length} bytes, ${image.width}x${image.height})');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PortablePreferences prefs;
  late SettingsService settings;

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
  });

  testWidgets('Generate Screenshot 01: Assistant Audio with Voice I/O Dictation',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repaintKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Jarvisol — Assistant Audio (Voice I/O R1a)'),
              actions: [
                IconButton(icon: const Icon(Icons.download), onPressed: () {}),
                IconButton(icon: const Icon(Icons.settings), onPressed: () {}),
              ],
            ),
            body: RepaintBoundary(
              key: repaintKey,
              child: const LlmChatWidget(
                transcript: 'Transcription audio en mémoire : Réunion technique Jarvisol Voice I/O.',
                isFullscreen: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await saveScreenshot(repaintKey, 'screenshot_01_assistant_audio.png');
    expect(File('screenshot_01_assistant_audio.png').existsSync(), isTrue);
  });

  testWidgets('Generate Screenshot 02: Assistant Documents with Voice I/O Dictation',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repaintKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Jarvisol — Assistant Documents (Voice I/O R1a)'),
              actions: [
                IconButton(icon: const Icon(Icons.download), onPressed: () {}),
                IconButton(icon: const Icon(Icons.settings), onPressed: () {}),
              ],
            ),
            body: RepaintBoundary(
              key: repaintKey,
              child: const DocumentChatWidget(
                isFullscreen: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await saveScreenshot(repaintKey, 'screenshot_02_assistant_documents.png');
    expect(File('screenshot_02_assistant_documents.png').existsSync(), isTrue);
  });

  testWidgets('Generate Screenshot 03: Model Management with Granite Speech 4.1 NAR',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repaintKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Jarvisol — Gestion des Modèles ASR (Granite Speech 4.1 NAR)'),
            ),
            body: RepaintBoundary(
              key: repaintKey,
              child: const ModelManagementScreen(
                initialKindFilter: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Type 'granite' in search to highlight Granite models
    final searchField = find.byType(TextField);
    if (searchField.evaluate().isNotEmpty) {
      await tester.enterText(searchField.first, 'granite');
      await tester.pumpAndSettle();
    }

    await saveScreenshot(repaintKey, 'screenshot_03_granite_nar.png');
    expect(File('screenshot_03_granite_nar.png').existsSync(), isTrue);
  });
}
