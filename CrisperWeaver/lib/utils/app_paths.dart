// lib/utils/app_paths.dart
//
// Service de chemins portables pour CrisperWeaver.
// Tous les chemins sont calculés depuis le répertoire de l'exécutable,
// ce qui rend l'application totalement portable (aucune dépendance au profil
// utilisateur Windows ou à path_provider).
//
// Utilisation :
//   AppPaths.dataDir          → Release\data\
//   AppPaths.logsDir          → Release\data\logs\
//   AppPaths.imagesDir        → Release\data\GeneratedImages\
//   AppPaths.ragCacheDir      → Release\data\rag_cache\
//   AppPaths.aiKnowledgeDir   → Release\data\ai_knowledge\
//   AppPaths.historyDir       → Release\data\history\
//   AppPaths.audiobooksDir    → Release\data\audiobooks\
//   AppPaths.espeakDataDir    → Release\data\espeak-ng-data\
//   AppPaths.tmpDir           → Release\data\tmp\
//   AppPaths.batchDir         → Release\data\batch\

import 'dart:io';

import 'package:path/path.dart' as p;

class AppPaths {
  AppPaths._();

  // ──────────────────────────────────────────────────────────────────────────
  // Support isolation tests
  // ──────────────────────────────────────────────────────────────────────────

  /// Lorsque non-null, remplace [appDir] uniquement dans les tests.
  /// Jamais défini en production (la valeur est null par défaut).
  static Directory? _testOverrideDir;

  /// Redirige [appDir] vers [dir] pour la durée d'un test.
  ///
  /// Appelé dans setUp(). Doit être suivi de [resetTestOverride] dans
  /// tearDown() pour ne pas contaminer les tests suivants.
  static void setTestOverride(Directory dir) => _testOverrideDir = dir;

  /// Supprime l'override de test et restaure le comportement production.
  static void resetTestOverride() => _testOverrideDir = null;

  // ──────────────────────────────────────────────────────────────────────────
  // Répertoire de base : dossier contenant l'exécutable (Release\ en prod,
  // dossier de compilation en debug). Sur Android/iOS on utilise quand même
  // path_provider via le fallback — AppPaths n'est vraiment utilisé que sur
  // Windows/Linux/macOS desktop pour la portabilité.
  // ──────────────────────────────────────────────────────────────────────────

  /// Répertoire contenant le binaire de l'application.
  /// Sur Windows Release : `...\Release\`
  /// Sur debug Flutter : `...\build\windows\x64\runner\Debug\` ou similaire
  /// En test : le répertoire temporaire fourni par [setTestOverride].
  static Directory get appDir =>
      _testOverrideDir ?? File(Platform.resolvedExecutable).parent;

  /// Répertoire racine des données applicatives : `<appDir>\data\`
  /// Créé automatiquement s'il n'existe pas.
  static Directory get dataDir => _ensure(p.join(appDir.path, 'data'));

  /// Répertoire des logs : `<dataDir>\logs\`
  static Directory get logsDir => _ensure(p.join(dataDir.path, 'logs'));

  /// Répertoire des images générées : `<dataDir>\GeneratedImages\`
  static Directory get imagesDir =>
      _ensure(p.join(dataDir.path, 'GeneratedImages'));

  /// Cache des embeddings RAG : `<dataDir>\rag_cache\`
  static Directory get ragCacheDir =>
      _ensure(p.join(dataDir.path, 'rag_cache'));

  /// Fiches de connaissance IA : `<dataDir>\ai_knowledge\`
  static Directory get aiKnowledgeDir =>
      _ensure(p.join(dataDir.path, 'ai_knowledge'));

  /// Historique des conversations : `<dataDir>\history\`
  static Directory get historyDir =>
      _ensure(p.join(dataDir.path, 'history'));

  /// Projets audiobooks : `<dataDir>\audiobooks\`
  static Directory get audiobooksDir =>
      _ensure(p.join(dataDir.path, 'audiobooks'));

  /// Références WAV des voix clonées : `<dataDir>\voices\cloned\`
  static Directory get clonedVoicesDir =>
      _ensure(p.join(dataDir.path, 'voices', 'cloned'));

  /// Voice Packs GGUF importés (Chatterbox, Qwen3-TTS) : `<dataDir>\models\tts\voices\`
  static Directory get importedVoicesDir =>
      _ensure(p.join(dataDir.path, 'models', 'tts', 'voices'));

  /// Fichier d'index des Voice Packs importés : `<importedVoicesDir>\imported_voices.json`
  static File get importedVoicesIndexFile =>
      File(p.join(importedVoicesDir.path, 'imported_voices.json'));

  /// Données eSpeak-NG : `<dataDir>\espeak-ng-data\`
  /// (Dossier extrait depuis les assets Android, ou copié sous Windows)
  static Directory get espeakDataDir =>
      _ensure(p.join(dataDir.path, 'espeak-ng-data'));

  /// Fichiers temporaires de l'application : `<dataDir>\tmp\`
  static Directory get tmpDir => _ensure(p.join(dataDir.path, 'tmp'));

  /// Dossier batch (exports, transcriptions par lot) : `<dataDir>\batch\`
  static Directory get batchDir => _ensure(p.join(dataDir.path, 'batch'));

  /// Dossier des prompts personnalisés : `<dataDir>\prompts\`
  static Directory get promptsDir =>
      _ensure(p.join(dataDir.path, 'prompts'));

  /// Capsules de compactage conversationnel : `<dataDir>\compaction_capsules\`
  static Directory get compactionCapsulesDir =>
      _ensure(p.join(dataDir.path, 'compaction_capsules'));

  /// Répertoire HOME portable pour litert-lm : `<dataDir>\litert_home\`
  /// En définissant USERPROFILE=litertHomeDir au démarrage du serveur,
  /// litert-lm stocke ses modèles dans `litert_home\.litert-lm\models\`.
  static Directory get litertHomeDir =>
      _ensure(p.join(dataDir.path, 'litert_home'));

  /// Chemin des modèles LiteRT portables : `<dataDir>\litert_home\.litert-lm\models\`
  static Directory get litertModelsDir =>
      _ensure(p.join(litertHomeDir.path, '.litert-lm', 'models'));

  /// Répertoire des modèles d'image portables : `<appDir>\models\Stable-diffusion\`
  static Directory get imageModelsDir =>
      _ensure(p.join(appDir.path, 'models', 'Stable-diffusion'));

  /// Fichier de préférences portable : `<dataDir>\preferences.json`
  static File get preferencesFile =>
      File(p.join(dataDir.path, 'preferences.json'));

  /// Fichier de log principal : `<logsDir>\crisperweaver.log`
  static File get logFile =>
      File(p.join(logsDir.path, 'crisperweaver.log'));

  // ──────────────────────────────────────────────────────────────────────────
  // Helpers de migration — chemins "anciens" basés sur le profil utilisateur
  // Utilisés une seule fois au premier lancement pour migrer les données.
  // ──────────────────────────────────────────────────────────────────────────

  /// Ancien dossier Documents\CrisperWeaver (Windows — getApplicationDocumentsDirectory)
  static Directory? get legacyDocumentsDir {
    if (!Platform.isWindows) return null;
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile == null) return null;
    final dir = Directory(p.join(userProfile, 'Documents', 'CrisperWeaver'));
    return dir.existsSync() ? dir : null;
  }

  /// Ancien fichier SharedPreferences Windows
  /// `%APPDATA%\com.crispstrobe\crisper_weaver\shared_preferences.json`
  static File? get legacyPreferencesFile {
    if (!Platform.isWindows) return null;
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return null;
    final f = File(p.join(
        appData, 'com.crispstrobe', 'crisper_weaver', 'shared_preferences.json'));
    return f.existsSync() ? f : null;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Helper interne
  // ──────────────────────────────────────────────────────────────────────────

  static Directory _ensure(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }
}
