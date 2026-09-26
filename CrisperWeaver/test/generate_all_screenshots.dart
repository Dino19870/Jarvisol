import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/model_service.dart';
import 'package:jarvisol/widgets/llm_chat_widget.dart';
import 'package:jarvisol/widgets/document_chat_widget.dart';
import 'package:jarvisol/screens/model_management_screen.dart';
import 'package:jarvisol/theme/app_theme.dart';
import 'package:jarvisol/main.dart' show modelServiceProvider;
import 'package:jarvisol/l10n/generated/app_localizations.dart';

Future<void> loadFonts() async {
  // 1. Material Icons
  final iconFile = File(r'D:\Antigravity\AgentFolder\CrisperWeaver\build\windows\x64\runner\Release\data\flutter_assets\fonts\MaterialIcons-Regular.otf');
  if (iconFile.existsSync()) {
    final iconLoader = FontLoader('MaterialIcons');
    iconLoader.addFont(Future.value(ByteData.view(iconFile.readAsBytesSync().buffer)));
    await iconLoader.load();
  }

  // 2. Segoe UI
  final segoeFile = File(r'C:\Windows\Fonts\segoeui.ttf');
  if (segoeFile.existsSync()) {
    final bytes = segoeFile.readAsBytesSync();
    for (final fam in ['Segoe UI', 'Roboto', 'Arial', '.SF UI Text', 'sans-serif']) {
      final l = FontLoader(fam);
      l.addFont(Future.value(ByteData.view(bytes.buffer)));
      await l.load();
    }
  }

  // 3. Segoe UI Emoji
  final emojiFile = File(r'C:\Windows\Fonts\seguiemj.ttf');
  if (emojiFile.existsSync()) {
    final bytes = emojiFile.readAsBytesSync();
    final l = FontLoader('Segoe UI Emoji');
    l.addFont(Future.value(ByteData.view(bytes.buffer)));
    await l.load();
  }
}

Future<void> saveScreenshot(GlobalKey key, String path) async {
  final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.0);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  final pngBytes = byteData!.buffer.asUint8List();
  File(path).writeAsBytesSync(pngBytes);
  print('Screenshot saved to $path (${pngBytes.length} bytes, ${image.width}x${image.height})');
}

class FastOfflineModelService extends ModelService {
  FastOfflineModelService(SettingsService settings) : super(settings);
  @override
  bool get hasProbedQuants => true;
  @override
  Future<QuantProbeResult> refreshAvailableQuants({bool force = false}) async {
    return QuantProbeResult(added: 0, failedRepos: const []);
  }
}

ThemeData getScreenshotTheme() {
  const fallback = ['Segoe UI Emoji', 'Segoe UI', 'Roboto', 'Arial'];
  return AppTheme.darkTheme.copyWith(
    textTheme: AppTheme.darkTheme.textTheme.apply(
      fontFamily: 'Segoe UI',
      fontFamilyFallback: fallback,
    ),
    primaryTextTheme: AppTheme.darkTheme.primaryTextTheme.apply(
      fontFamily: 'Segoe UI',
      fontFamilyFallback: fallback,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PortablePreferences prefs;
  late SettingsService settings;

  setUpAll(() async {
    await loadFonts();
  });

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
  });

  testWidgets('1. Capture screenshot_01_assistant_audio.png', (WidgetTester tester) async {
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
          theme: getScreenshotTheme(),
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
                transcript: 'Transcription audio chargée : Réunion technique de validation Voice I/O R1a et CrispASR.',
                isFullscreen: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await saveScreenshot(repaintKey, 'screenshot_01_assistant_audio.png');
  });

  testWidgets('2. Capture screenshot_02_assistant_documents.png', (WidgetTester tester) async {
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
          theme: getScreenshotTheme(),
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
    await tester.pump(const Duration(milliseconds: 300));

    await saveScreenshot(repaintKey, 'screenshot_02_assistant_documents.png');
  });

  testWidgets('3. Capture screenshot_03_granite_nar.png', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repaintKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          modelServiceProvider.overrideWithValue(FastOfflineModelService(settings)),
        ],
        child: MaterialApp(
          theme: getScreenshotTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Scaffold(
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
    await tester.pump(const Duration(milliseconds: 300));

    // Filter by 'granite'
    final search = find.byType(TextField);
    if (search.evaluate().isNotEmpty) {
      await tester.enterText(search.first, 'granite');
      await tester.pump(const Duration(milliseconds: 300));
    }

    await saveScreenshot(repaintKey, 'screenshot_03_granite_nar.png');
  });
}
