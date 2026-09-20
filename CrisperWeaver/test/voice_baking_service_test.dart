// Pure-Dart smoke check on VoiceBakingService — pins the platform-
// support contract and the default script path. The real Process.start
// flow is opt-in slow (needs Python + chatterbox-tts on the test
// host), so we don't exercise that here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:jarvisol/utils/app_paths.dart';
import 'package:jarvisol/services/voice_baking_service.dart';

void main() {
  late Directory fakeRoot;

  setUp(() async {
    // Pointer AppPaths vers un répertoire temporaire vide so que
    // defaultScriptPath cherche ses candidats dans un tree contrôlé.
    fakeRoot = await Directory.systemTemp
        .createTemp('jarvisol_voice_bake_test_');
    AppPaths.setTestOverride(fakeRoot);
  });

  tearDown(() async {
    AppPaths.resetTestOverride();
    if (await fakeRoot.exists()) await fakeRoot.delete(recursive: true);
  });

  group('VoiceBakingService', () {
    test('isSupported is true on desktop and false on mobile', () {
      final expected = Platform.isMacOS || Platform.isLinux || Platform.isWindows;
      expect(VoiceBakingService.isSupported, expected);
    });

    test('default script path is <appDir>/tools/voice_bake/... (portable release layout)',
        () {
      // Aucun des candidats n'existe dans fakeRoot -> firstWhere retourne
      // orElse: candidates.first = <appDir>/tools/voice_bake/...
      // Ce comportement valide que le chemin production est le fallback nominal.
      final expected = p.join(
        AppPaths.appDir.path,
        'tools',
        'voice_bake',
        'bake-chatterbox-voice-from-wav.py',
      );
      expect(VoiceBakingService.defaultScriptPath, expected);
    });

    test('default script path resolves to tools/voice_bake/ when script is present',
        () async {
      // Si le script existe a l'emplacement production, defaultScriptPath
      // le trouve via File.existsSync() sans passer par orElse.
      final scriptPath = p.join(
        fakeRoot.path,
        'tools',
        'voice_bake',
        'bake-chatterbox-voice-from-wav.py',
      );
      await Directory(p.dirname(scriptPath)).create(recursive: true);
      await File(scriptPath).writeAsString('#!/usr/bin/env python3\n');
      expect(VoiceBakingService.defaultScriptPath, scriptPath);
    });

    test('VoiceBakingException carries a user-readable message', () {
      const e = VoiceBakingException('python3 not found on PATH');
      expect(e.message, 'python3 not found on PATH');
      expect(e.toString(), contains('python3 not found on PATH'));
    });
  });
}
