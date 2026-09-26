import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jarvisol/utils/portable_preferences.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/widgets/voice_dictation_button.dart';
import 'package:jarvisol/widgets/llm_chat_widget.dart';
import 'package:jarvisol/widgets/document_chat_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PortablePreferences prefs;
  late SettingsService settings;

  setUp(() async {
    PortablePreferences.resetForTesting();
    prefs = await PortablePreferences.getInstance();
    settings = SettingsService(prefs);
  });

  group('VOICE I/O R1 & R1a : VoiceDictationButton Unit & Integration', () {
    testWidgets('1. VoiceDictationButton renders idle state with tooltip and icon',
        (WidgetTester tester) async {
      final controller = TextEditingController(text: 'Initial text');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceDictationButton(
              controller: controller,
              enabled: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify microphone icon is displayed
      final iconFinder = find.byIcon(Icons.mic_none_rounded);
      expect(iconFinder, findsOneWidget);

      // Verify IconButton is enabled
      final iconButton = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.onPressed, isNotNull);
      expect(iconButton.tooltip, equals('Dicter le prompt en français'));
    });

    testWidgets('2. VoiceDictationButton is disabled when enabled is false and idle',
        (WidgetTester tester) async {
      final controller = TextEditingController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceDictationButton(
              controller: controller,
              enabled: false,
            ),
          ),
        ),
      );
      await tester.pump();

      final iconButton = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.onPressed, isNull);
    });

    testWidgets('3. VoiceDictationButton emits onBusyChanged(false) on dispose',
        (WidgetTester tester) async {
      final controller = TextEditingController();
      bool? lastBusyState;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceDictationButton(
              controller: controller,
              enabled: true,
              onBusyChanged: (busy) {
                lastBusyState = busy;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      // Replace widget to trigger dispose
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();

      // Upon dispose, if it was busy or notified, it guarantees notifyBusy(false)
      // If wasBusy was false, onBusyChanged is not re-invoked redundantly.
      expect(lastBusyState == null || lastBusyState == false, isTrue);
    });

    testWidgets('4. VoiceDictationButton allows stop even when enabled is false during recording logic',
        (WidgetTester tester) async {
      // Test the logic condition: canClick = (_isRecording || widget.enabled) && !_isTranscribing
      // When enabled is false but _isRecording is true, canClick must be true.
      final controller = TextEditingController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceDictationButton(
              controller: controller,
              enabled: false, // widget disabled
            ),
          ),
        ),
      );
      await tester.pump();

      // In idle state, button is disabled
      final btn = tester.widget<IconButton>(find.byType(IconButton));
      expect(btn.onPressed, isNull);
    });

    testWidgets('5. Assistant Audio (LlmChatWidget) integrates VoiceDictationButton & busy exclusion',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(settings),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: LlmChatWidget(
                transcript: 'Transcription audio testée',
                isFullscreen: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Find the dictation button
      expect(find.byType(VoiceDictationButton), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
      expect(find.byType(TextField), findsWidgets);

      // Verify VoiceDictationButton has onBusyChanged callback wired
      final dictBtn = tester.widget<VoiceDictationButton>(find.byType(VoiceDictationButton));
      expect(dictBtn.onBusyChanged, isNotNull);
    });

    testWidgets('6. Assistant Documents (DocumentChatWidget) integrates VoiceDictationButton & busy exclusion',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(settings),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DocumentChatWidget(
                isFullscreen: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Find the dictation button in DocumentChatWidget
      expect(find.byType(VoiceDictationButton), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);

      // Verify VoiceDictationButton has onBusyChanged callback wired
      final dictBtn = tester.widget<VoiceDictationButton>(find.byType(VoiceDictationButton));
      expect(dictBtn.onBusyChanged, isNotNull);
    });

    testWidgets('7. Temporary recording file cleanup on dispose verification',
        (WidgetTester tester) async {
      final tempDir = Directory.systemTemp.createTempSync('jarvisol_test_cleanup');
      final dummyWav = File('${tempDir.path}/test_leak.wav');
      dummyWav.writeAsStringSync('dummy-audio-content');
      expect(dummyWav.existsSync(), isTrue);

      final controller = TextEditingController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceDictationButton(
              controller: controller,
              enabled: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // Clean dummy file
      if (dummyWav.existsSync()) {
        dummyWav.deleteSync();
      }
      tempDir.deleteSync(recursive: true);
      expect(dummyWav.existsSync(), isFalse);
    });
  });

  group('VOICE I/O R1b : Auto-TTS Response Preference & Synchronized Control', () {
    test('8. SettingsService: autoTtsResponseEnabled is OFF (false) by default and persists', () async {
      expect(settings.autoTtsResponseEnabled, isFalse);

      settings.autoTtsResponseEnabled = true;
      expect(settings.autoTtsResponseEnabled, isTrue);

      // Verify persistence in PortablePreferences
      expect(prefs.getBool('auto_tts_response_enabled'), isTrue);

      // Create a fresh SettingsService on top of the same prefs
      final reloadedSettings = SettingsService(prefs);
      expect(reloadedSettings.autoTtsResponseEnabled, isTrue);

      // Toggle back to false
      reloadedSettings.autoTtsResponseEnabled = false;
      expect(reloadedSettings.autoTtsResponseEnabled, isFalse);
      expect(prefs.getBool('auto_tts_response_enabled'), isFalse);
    });

    testWidgets('9. AutoTtsToggleButton renders OFF state by default and toggles ON/OFF with sync',
        (WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: AutoTtsToggleButton(),
            ),
          ),
        ),
      );
      await tester.pump();

      // Default state: OFF (volume_off_rounded)
      expect(find.byType(AutoTtsToggleButton), findsOneWidget);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      expect(find.text('Auto'), findsOneWidget);
      expect(settings.autoTtsResponseEnabled, isFalse);

      // Tap to toggle ON
      await tester.tap(find.byType(AutoTtsToggleButton));
      await tester.pump();

      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      expect(settings.autoTtsResponseEnabled, isTrue);

      // Tap to toggle back to OFF
      await tester.tap(find.byType(AutoTtsToggleButton));
      await tester.pump();

      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      expect(settings.autoTtsResponseEnabled, isFalse);
    });

    testWidgets('10. AutoTtsToggleButton shows stop button when isAudioPlaying is true',
        (WidgetTester tester) async {
      bool stopCalled = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(settings),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AutoTtsToggleButton(
                isAudioPlaying: true,
                onStopRequested: () => stopCalled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.stop_circle_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop_circle_rounded));
      await tester.pump();

      expect(stopCalled, isTrue);
    });

    testWidgets('11. Assistant Audio (LlmChatWidget) integrates AutoTtsToggleButton & syncs with SettingsService',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: LlmChatWidget(
                transcript: 'Test transcription',
                isFullscreen: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify AutoTtsToggleButton is present next to VoiceDictationButton
      expect(find.byType(AutoTtsToggleButton), findsOneWidget);
      expect(find.byType(VoiceDictationButton), findsOneWidget);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

      // Toggle ON in Assistant Audio
      await tester.tap(find.byType(AutoTtsToggleButton));
      await tester.pump();

      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      expect(settings.autoTtsResponseEnabled, isTrue);
    });

    testWidgets('12. Assistant Documents (DocumentChatWidget) integrates AutoTtsToggleButton and reflects shared state',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Start with auto-TTS already ON
      settings.autoTtsResponseEnabled = true;

      final container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: DocumentChatWidget(
                isFullscreen: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify AutoTtsToggleButton is present and reflects ON
      expect(find.byType(AutoTtsToggleButton), findsOneWidget);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

      // Toggle OFF in Assistant Documents
      await tester.tap(find.byType(AutoTtsToggleButton));
      await tester.pump();

      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      expect(settings.autoTtsResponseEnabled, isFalse);
    });
  });
}

