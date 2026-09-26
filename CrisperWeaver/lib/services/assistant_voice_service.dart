import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../utils/app_paths.dart';
import 'log_service.dart';
import 'settings_service.dart';
import 'tts_service.dart';

/// Modèle d'information d'une voix assistant (locale ou en ligne).
class AssistantVoiceInfo {
  final String id;
  final String displayName;
  final String gender; // 'Homme' ou 'Femme'
  final bool isOnline;
  final String description;

  const AssistantVoiceInfo({
    required this.id,
    required this.displayName,
    required this.gender,
    required this.isOnline,
    this.description = '',
  });

  @override
  String toString() => '$displayName ($id)';
}

/// Résultat d'une synthèse vocale pour les assistants.
class AssistantVoiceSynthesisResult {
  final String? filePath;
  final bool isOnline;
  final String voiceName;
  final bool isFallback;
  final int elapsedMs;
  final String? error;

  AssistantVoiceSynthesisResult({
    this.filePath,
    required this.isOnline,
    required this.voiceName,
    this.isFallback = false,
    this.elapsedMs = 0,
    this.error,
  });

  bool get success => filePath != null && filePath!.isNotEmpty && File(filePath!).existsSync();
  bool get isSuccess => success;
  String? get errorMessage => error;
  bool get usedOfflineFallback => isFallback;
}

/// Fournisseur TTS central pour les Assistants (Audio et Documents).
/// Gère les voix Windows OneCore hors-ligne et les voix Microsoft Edge neuronales en ligne.
class AssistantVoiceService {
  final SettingsService _settings;
  final TtsService? _ttsService;

  AssistantVoiceService(this._settings, {TtsService? ttsService})
      : _ttsService = ttsService;

  // --- Voix neuronales en ligne disponibles ---
  static const List<AssistantVoiceInfo> onlineVoices = [
    AssistantVoiceInfo(
      id: 'fr-FR-HenriNeural',
      displayName: 'Henri',
      gender: 'Homme',
      isOnline: true,
      description: 'Naturel, posé et chaleureux',
    ),
    AssistantVoiceInfo(
      id: 'fr-FR-DeniseNeural',
      displayName: 'Denise',
      gender: 'Femme',
      isOnline: true,
      description: 'Naturelle, fluide et engageante',
    ),
    AssistantVoiceInfo(
      id: 'fr-FR-RemyMultilingualNeural',
      displayName: 'Rémy',
      gender: 'Homme',
      isOnline: true,
      description: 'Multilingue, diction articulée',
    ),
    AssistantVoiceInfo(
      id: 'fr-FR-VivienneMultilingualNeural',
      displayName: 'Vivienne',
      gender: 'Femme',
      isOnline: true,
      description: 'Multilingue, douce et claire',
    ),
    AssistantVoiceInfo(
      id: 'fr-FR-EloiseNeural',
      displayName: 'Éloïse',
      gender: 'Femme',
      isOnline: true,
      description: 'Diction vive et positive',
    ),
  ];

  // --- Voix Windows OneCore par défaut si le scan n'a pas encore tourné ---
  static const List<AssistantVoiceInfo> defaultOfflineVoices = [
    AssistantVoiceInfo(
      id: 'Microsoft Paul',
      displayName: 'Microsoft Paul',
      gender: 'Homme',
      isOnline: false,
      description: 'Windows OneCore (Hors ligne)',
    ),
    AssistantVoiceInfo(
      id: 'Microsoft Hortense',
      displayName: 'Microsoft Hortense',
      gender: 'Femme',
      isOnline: false,
      description: 'Windows OneCore (Hors ligne)',
    ),
    AssistantVoiceInfo(
      id: 'Microsoft Julie',
      displayName: 'Microsoft Julie',
      gender: 'Femme',
      isOnline: false,
      description: 'Windows OneCore (Hors ligne)',
    ),
  ];

  List<AssistantVoiceInfo>? _cachedOfflineVoices;

  /// Énumération dynamique des voix françaises Windows OneCore réellement installées.
  Future<List<AssistantVoiceInfo>> getInstalledOfflineVoices() async {
    if (_cachedOfflineVoices != null && _cachedOfflineVoices!.isNotEmpty) {
      return _cachedOfflineVoices!;
    }

    if (!Platform.isWindows) {
      _cachedOfflineVoices = defaultOfflineVoices;
      return _cachedOfflineVoices!;
    }

    try {
      const psCommand = r'''
$sp = New-Object -ComObject SAPI.SpVoice
$cat = New-Object -ComObject SAPI.SpObjectTokenCategory
$cat.SetId("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices", $false)
$tokens = $cat.EnumerateTokens()
foreach ($t in $tokens) {
    $desc = $t.GetDescription()
    $id = $t.Id
    if ($desc -like "*French*" -or $desc -like "*fr-FR*" -or $desc -like "*frFR*") {
        Write-Output "$desc|||$id"
    }
}
''';

      final res = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        psCommand,
      ]);

      if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
        final lines = res.stdout.toString().split(RegExp(r'\r?\n'));
        final detected = <AssistantVoiceInfo>[];

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          final parts = trimmed.split('|||');
          final desc = parts[0].trim();

          // Déduire le genre et le nom court
          String shortName = desc;
          String gender = 'Femme';

          if (desc.toLowerCase().contains('paul')) {
            shortName = 'Microsoft Paul';
            gender = 'Homme';
          } else if (desc.toLowerCase().contains('hortense')) {
            shortName = 'Microsoft Hortense';
            gender = 'Femme';
          } else if (desc.toLowerCase().contains('julie')) {
            shortName = 'Microsoft Julie';
            gender = 'Femme';
          }

          detected.add(AssistantVoiceInfo(
            id: shortName,
            displayName: '$shortName ($gender)',
            gender: gender,
            isOnline: false,
            description: desc,
          ));
        }

        if (detected.isNotEmpty) {
          _cachedOfflineVoices = detected;
          return _cachedOfflineVoices!;
        }
      }
    } catch (e) {
      Log.instance.w('assistant_voice', 'Erreur détection voix OneCore: $e');
    }

    _cachedOfflineVoices = defaultOfflineVoices;
    return _cachedOfflineVoices!;
  }

  /// Synthétise une réponse pour un assistant selon le mode configuré.
  Future<AssistantVoiceSynthesisResult> synthesize({
    required String text,
    String? mode,
    String? onlineVoiceId,
    String? offlineVoiceId,
    bool? allowOnline,
    void Function(String infoMessage)? onFallback,
  }) async {
    final effectiveMode = mode ?? _settings.voiceIoMode; // 'auto', 'online_only', 'offline_only'
    final effectiveOnlineVoice = onlineVoiceId ?? _settings.voiceIoOnlineVoice;
    final effectiveOfflineVoice = offlineVoiceId ?? _settings.voiceIoOfflineVoice;
    final consent = allowOnline ?? (_settings.voiceIoOnlineConsent == true);

    final cleanText = cleanTextForSpeech(text);
    if (cleanText.isEmpty) {
      return AssistantVoiceSynthesisResult(
        filePath: null,
        isOnline: false,
        voiceName: effectiveOfflineVoice,
        error: 'Aucun texte à vocaliser.',
      );
    }

    final sw = Stopwatch()..start();

    // 1. Mode Hors ligne uniquement : 0 requête réseau
    if (effectiveMode == 'offline_only') {
      try {
        final path = await _synthesizeWindowsOneCore(cleanText, effectiveOfflineVoice);
        sw.stop();
        return AssistantVoiceSynthesisResult(
          filePath: path,
          isOnline: false,
          voiceName: effectiveOfflineVoice,
          elapsedMs: sw.elapsedMilliseconds,
        );
      } catch (e) {
        Log.instance.w('assistant_voice', 'Échec OneCore en mode hors-ligne, tentative secours VibeVoice: $e');
        onFallback?.call('Voix Windows indisponible. Basculement sur le moteur local VibeVoice...');
        try {
          final path = await _synthesizeVibeVoice(cleanText);
          sw.stop();
          return AssistantVoiceSynthesisResult(
            filePath: path,
            isOnline: false,
            voiceName: 'VibeVoice Realtime (Secours)',
            isFallback: true,
            elapsedMs: sw.elapsedMilliseconds,
          );
        } catch (vibeErr) {
          sw.stop();
          return AssistantVoiceSynthesisResult(
            filePath: null,
            isOnline: false,
            voiceName: effectiveOfflineVoice,
            elapsedMs: sw.elapsedMilliseconds,
            error: 'Échec synthèse hors ligne: $e (Secours VibeVoice: $vibeErr)',
          );
        }
      }
    }

    // 2. Mode En ligne uniquement
    if (effectiveMode == 'online_only') {
      if (!consent) {
        return AssistantVoiceSynthesisResult(
          filePath: null,
          isOnline: true,
          voiceName: effectiveOnlineVoice,
          error: 'Le consentement pour l’utilisation des voix en ligne Microsoft est requis dans les réglages.',
        );
      }
      try {
        final path = await _synthesizeEdgeNeural(cleanText, effectiveOnlineVoice);
        sw.stop();
        return AssistantVoiceSynthesisResult(
          filePath: path,
          isOnline: true,
          voiceName: effectiveOnlineVoice,
          elapsedMs: sw.elapsedMilliseconds,
        );
      } catch (e) {
        sw.stop();
        return AssistantVoiceSynthesisResult(
          filePath: null,
          isOnline: true,
          voiceName: effectiveOnlineVoice,
          elapsedMs: sw.elapsedMilliseconds,
          error: 'Échec synthèse en ligne: $e',
        );
      }
    }

    // 3. Mode Automatique (en ligne avec secours hors ligne)
    if (consent) {
      try {
        final path = await _synthesizeEdgeNeural(cleanText, effectiveOnlineVoice)
            .timeout(const Duration(seconds: 5));
        sw.stop();
        return AssistantVoiceSynthesisResult(
          filePath: path,
          isOnline: true,
          voiceName: effectiveOnlineVoice,
          elapsedMs: sw.elapsedMilliseconds,
        );
      } catch (e) {
        Log.instance.w('assistant_voice', 'Échec voix en ligne en mode auto, basculement local: $e');
        onFallback?.call('Voix en ligne indisponible. Basculement sur la voix locale ($effectiveOfflineVoice)...');
      }
    }

    // Fallback vers la voix locale OneCore, puis secours VibeVoice
    try {
      final path = await _synthesizeWindowsOneCore(cleanText, effectiveOfflineVoice);
      sw.stop();
      return AssistantVoiceSynthesisResult(
        filePath: path,
        isOnline: false,
        voiceName: effectiveOfflineVoice,
        isFallback: true,
        elapsedMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      Log.instance.w('assistant_voice', 'Échec voix OneCore en mode auto, basculement VibeVoice: $e');
      onFallback?.call('Voix Windows OneCore indisponible. Basculement sur le moteur local VibeVoice...');
      try {
        final path = await _synthesizeVibeVoice(cleanText);
        sw.stop();
        return AssistantVoiceSynthesisResult(
          filePath: path,
          isOnline: false,
          voiceName: 'VibeVoice Realtime (Secours)',
          isFallback: true,
          elapsedMs: sw.elapsedMilliseconds,
        );
      } catch (vibeErr) {
        sw.stop();
        return AssistantVoiceSynthesisResult(
          filePath: null,
          isOnline: false,
          voiceName: effectiveOfflineVoice,
          isFallback: true,
          elapsedMs: sw.elapsedMilliseconds,
          error: 'Échec synthèse hors ligne: $e (Secours VibeVoice: $vibeErr)',
        );
      }
    }
  }

  /// Synthèse via Windows OneCore (hors ligne).
  Future<String> _synthesizeWindowsOneCore(String text, String voiceName) async {
    final tempDir = AppPaths.tmpDir;
    final outFile = File(p.join(
      tempDir.path,
      'assistant_onecore_${DateTime.now().millisecondsSinceEpoch}.wav',
    ));

    final sanitizedForPs = text
        .replaceAll('`', '``')
        .replaceAll('"', '`"')
        .replaceAll('\$', '`\$');

    final escapedOutPath = outFile.path.replaceAll(r'\', r'\\');

    final psScript = '''
\$sp = New-Object -ComObject SAPI.SpVoice
\$cat = New-Object -ComObject SAPI.SpObjectTokenCategory
\$cat.SetId("HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech_OneCore\\Voices", \$false)
\$found = \$false
foreach (\$t in \$cat.EnumerateTokens()) {
    if (\$t.GetDescription() -like "*$voiceName*") {
        \$sp.Voice = \$t
        \$found = \$true
        break
    }
}
if (-not \$found) {
    Write-Error "Voix OneCore introuvable: $voiceName"
    exit 1
}
\$fs = New-Object -ComObject SAPI.SpFileStream
\$fs.Open("$escapedOutPath", 3, \$false)
\$sp.AudioOutputStream = \$fs
\$sp.Speak("$sanitizedForPs")
\$fs.Close()
''';

    final res = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      psScript,
    ]);

    if (res.exitCode != 0 || !outFile.existsSync() || outFile.lengthSync() < 100) {
      throw Exception('Erreur de synthèse vocale Windows OneCore (${res.stderr})');
    }

    return outFile.path;
  }

  /// Synthèse via les voix neuronales Edge.
  Future<String> _synthesizeEdgeNeural(String text, String voiceName) async {
    final edgeExe = await _findEdgeTtsExecutable();
    if (edgeExe == null) {
      throw Exception('Exécutable de synthèse vocale en ligne introuvable.');
    }

    final tempDir = AppPaths.tmpDir;
    final outFile = File(p.join(
      tempDir.path,
      'assistant_edge_${DateTime.now().millisecondsSinceEpoch}.mp3',
    ));

    final res = await Process.run(edgeExe, [
      '--voice',
      voiceName,
      '--text',
      text,
      '--write-media',
      outFile.path,
    ]);

    if (res.exitCode != 0 || !outFile.existsSync() || outFile.lengthSync() < 100) {
      throw Exception('Erreur de synthèse vocale en ligne (${res.stderr})');
    }

    return outFile.path;
  }

  /// Synthèse vocale de secours via le moteur VibeVoice Realtime embarqué.
  Future<String> _synthesizeVibeVoice(String text) async {
    final tts = _ttsService;
    if (tts == null) {
      throw Exception('Service TTS local (VibeVoice) non configuré');
    }

    // Recherche portable des modèles dans l'arborescence sans duplication
    Future<String?> resolveAny(List<String> candidates) async {
      for (final c in candidates) {
        final direct = await tts.resolvePath(c);
        if (direct != null && File(direct).existsSync()) return direct;

        final inModels = p.join(AppPaths.dataDir.path, 'models', 'whisper_cpp', c);
        if (File(inModels).existsSync()) return inModels;
        final inModelsGguf = p.join(AppPaths.dataDir.path, 'models', 'whisper_cpp', '$c.gguf');
        if (File(inModelsGguf).existsSync()) return inModelsGguf;

        final inAppDir = p.join(AppPaths.appDir.path, 'data', 'models', 'whisper_cpp', c);
        if (File(inAppDir).existsSync()) return inAppDir;
        final inAppDirGguf = p.join(AppPaths.appDir.path, 'data', 'models', 'whisper_cpp', '$c.gguf');
        if (File(inAppDirGguf).existsSync()) return inAppDirGguf;
      }
      return null;
    }

    final modelPath = await resolveAny([
      'vibevoice-realtime-0.5b-q4_k',
      'vibevoice-realtime-0.5b-q4_k.gguf',
      'vibevoice-realtime-0.5b-tts-f16',
      'vibevoice-realtime-0.5b-tts-f16.gguf',
    ]);
    if (modelPath == null) {
      throw Exception('Modèle VibeVoice Realtime (0.5B) introuvable dans les modèles locaux.');
    }

    final voicePath = await resolveAny([
      'vibevoice-voice-fr-Spk0_man',
      'vibevoice-voice-fr-Spk0_man.gguf',
      'vibevoice-voice-fr-Spk1_woman',
      'vibevoice-voice-fr-Spk1_woman.gguf',
    ]);
    if (voicePath == null) {
      throw Exception('Voicepack français VibeVoice introuvable dans les modèles locaux.');
    }

    Log.instance.i('assistant_voice', 'Préparation secours VibeVoice', fields: {
      'model': p.basename(modelPath),
      'voice': p.basename(voicePath),
    });

    final loadStatus = await tts.prepare(
      modelName: modelPath,
      voiceName: voicePath,
    );
    if (!loadStatus.ready) {
      throw Exception(loadStatus.errorMessage ?? 'Échec initialisation VibeVoice');
    }

    final audio = await tts.synthesize(text);
    if (audio == null || audio.samples.isEmpty) {
      throw Exception('Aucun échantillon audio produit par VibeVoice.');
    }

    final outFile = await tts.writeWav(
      audio,
      basename: 'assistant_vibevoice_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    return outFile.path;
  }

  /// Recherche de l'utilitaire edge-tts autonome et portable.
  /// Le seul exécutable autorisé est `<APP_DIR>\runtime\edge_tts\edge-tts.exe`.
  /// Ne jamais rechercher edge-tts dans PATH, AppData, Python, Hermes ou un répertoire de développement.
  Future<String?> _findEdgeTtsExecutable() async {
    final exe = File(p.join(AppPaths.appDir.path, 'runtime', 'edge_tts', 'edge-tts.exe'));
    if (exe.existsSync()) return exe.path;

    // Support si exécuté depuis la racine projet (tests unitaires / flutter test)
    final rootExe = File(p.join(Directory.current.path, 'runtime', 'edge_tts', 'edge-tts.exe'));
    if (rootExe.existsSync()) return rootExe.path;

    return null;
  }

  /// Nettoie le texte pour une élocution fluide et naturelle.
  static String cleanTextForSpeech(String rawText) {
    var text = rawText;

    // Supprimer les balises <think>...</think>
    text = text.replaceAll(RegExp(r'<think>[\s\S]*?<\/think>', caseSensitive: false), '');

    // Supprimer les blocs de code markdown ```...```
    text = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' (code omis) ');

    // Supprimer le code inline `...`
    text = text.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1] ?? '');

    // Remplacer les liens markdown [texte](url) par texte
    text = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), (m) => m[1] ?? '');

    // Supprimer les titres markdown #, ##, ###
    text = text.replaceAll(RegExp(r'^[#]+\s*', multiLine: true), '');

    // Supprimer le gras/italique **texte** ou *texte*
    text = text.replaceAllMapped(RegExp(r'\*\*([^\*]+)\*\*'), (m) => m[1] ?? '');
    text = text.replaceAllMapped(RegExp(r'\*([^\*]+)\*'), (m) => m[1] ?? '');
    text = text.replaceAllMapped(RegExp(r'__([^_]+)__'), (m) => m[1] ?? '');
    text = text.replaceAllMapped(RegExp(r'_([^_]+)_'), (m) => m[1] ?? '');

    // Supprimer les puces markdown (*, -, +)
    text = text.replaceAll(RegExp(r'^\s*[\*\-\+]\s+', multiLine: true), '');

    // Supprimer les séparateurs horizontaux ---
    text = text.replaceAll(RegExp(r'^\s*[-=_]{3,}\s*$', multiLine: true), '');

    // Nettoyer les espaces multiples et retours à la ligne excessifs
    text = text.replaceAll(RegExp(r'\n{2,}'), '. ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return text;
  }
}

/// Provider Riverpod du service AssistantVoiceService.
final assistantVoiceServiceProvider = Provider<AssistantVoiceService>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  final tts = ref.watch(ttsServiceProvider);
  return AssistantVoiceService(settings, ttsService: tts);
});
