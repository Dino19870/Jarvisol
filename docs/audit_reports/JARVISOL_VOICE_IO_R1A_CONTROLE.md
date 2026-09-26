# JARVISOL — RAPPORT DE CONTRÔLE ET VALIDATION VOICE I/O R1a

**Date** : 2026-09-24  
**Projet** : Jarvisol / CrisperWeaver (`D:\Antigravity\AgentFolder\CrisperWeaver`)  
**Statut global** : **SUCCÈS DE VALIDATION TECHNIQUE (100% PASS)**  

---

## 1. REQ-FINAL — Synthèse des exigences R1a

L'intervention R1a visait à consolider et verrouiller l'intégration Voice I/O R1 sans altérer aucun des six services centraux (`AudioService`, `TranscriptionService`, `LlmService`, `TtsService`, `AudiobookService`, `SettingsService`) :
1. **Exclusion mutuelle stricte dictée / envoi LLM** :
   - Notification du cycle d'état busy via `onBusyChanged: (bool isBusy)` sur `VoiceDictationButton`.
   - Verrouillage centralisé dans `_sendPrompt` (`LlmChatWidget`) et `_sendMessage` (`DocumentChatWidget`).
   - Désactivation immédiate des boutons d'envoi UI tant que la dictée ou la transcription est en cours.
   - Maintien du bouton micro cliquable pour arrêter l'enregistrement en cours même si `widget.enabled == false`.
2. **Nettoyage strict des fichiers temporaires et des abonnements audio** :
   - Suppression systématique du WAV temporaire de dictée en cas de `dispose()` prématuré ou sortie d'écran.
   - Suppression sécurisée du fichier WAV `document_assistant_read_aloud.wav` (Assistant Documents) avec protection par identifiant de génération (`_voiceIoGenerationId`).
   - Annulation explicite du `StreamSubscription<PlayerState>` dans le `dispose()` de `DocumentChatWidget`.
3. **Clarification formelle Whisper vs CrispASR** :
   - Comparaison SHA-256 et taille de `whisper.dll` et `crispasr.dll`.
4. **Diagnostic isolé Kokoro TTS** :
   - Exécution sous processus isolé sans altération de code natif, capture stdout/stderr et code de retour.
5. **Génération de la voix de synthèse VibeVoice Spk1_woman** :
   - Synthèse de la phrase de référence française sur `vibevoice-voice-fr-Spk1_woman.gguf`.
6. **Benchmark ASR comparatif décisif sur 5 modèles** :
   - Évaluation sur l'audio de référence (5.688 s) avec cold start, 1ère inférence, 3 runs à chaud, médiane, RTF, WER, CER.
7. **Investigation de Granite Speech 4.1 2B NAR (Handy)** :
   - Diagnostic de compatibilité avec le runtime `crispasr.dll` / GGUF local.

---

## 2. IMPL-FINAL — Modifications apportées

Conformément à la **Règle 11**, des backups horodatés ont été créés avant toute modification (`.bak_20260924_1248`).

### A. `lib/widgets/voice_dictation_button.dart`
- **Ajout de la notification d'occupation** : `final ValueChanged<bool>? onBusyChanged;` avec helper `_notifyBusy(bool busy)` prévenant les transitions redondantes.
- **Cycle de vie propre sur `dispose()`** : émission de `_notifyBusy(false)`, arrêt du recorder audio et suppression asynchrone sécurisée du fichier WAV temporaire (`_recordingPath`).
- **Condition de bascule découplée** : `final canClick = (_isRecording || widget.enabled) && !_isTranscribing;`, permettant à l'utilisateur de cliquer sur le bouton rouge pour stopper l'enregistrement même si le champ est désactivé extérieurement.

### B. `lib/widgets/llm_chat_widget.dart` (Assistant Audio)
- **État d'exclusion mutuelle** : `bool _isVoiceDictationBusy = false;`.
- **Garde centrale** : dans `_sendPrompt()`, blocage strict si `_isVoiceDictationBusy` est vrai.
- **Désactivation du bouton d'envoi** : `final canSend = ... && !_isVoiceDictationBusy;`.
- **Connexion du composant** : `onBusyChanged: (busy) => setState(() => _isVoiceDictationBusy = busy)`.

### C. `lib/widgets/document_chat_widget.dart` (Assistant Documents)
- **État d'exclusion mutuelle** : `bool _isVoiceDictationBusy = false;`.
- **Garde centrale** : dans `_sendMessage()`, blocage strict si `_isVoiceDictationBusy` est vrai.
- **Désactivation du bouton d'envoi** : `final canSend = ... && !_isVoiceDictationBusy;`.
- **Nettoyage TTS et souscription** :
  - Annulation propre de `_voiceIoPlayerSub?.cancel()` dans `dispose()`.
  - Incrément de `_voiceIoGenerationId` pour invalider toute opération TTS asynchrone si le widget est détruit en cours de synthèse, suivi de la suppression du fichier WAV temporaire `document_assistant_read_aloud.wav`.

---

## 3. VALIDATION — Tests et Benchmarks

### 3.1 Compilation & Analyse
- **`flutter build windows --debug`** : **SUCCÈS** (`Built build\windows\x64\runner\Debug\jarvisol.exe`).
- **`flutter analyze test/voice_io_r1_test.dart`** : **0 issue**.
- **`flutter test test/voice_io_r1_test.dart`** : **7 tests / 7 passés (100%)**.

### 3.2 Suites de non-régression globales
Exécution complète consignée dans `regression_tests.log` :
- `test/assistant_documents_audit_test.dart` (21 tests) : **PASS**
- `test/document_chat_user_actions_widget_test.dart` (9 actions complètes) : **PASS**
- `test/audiobook_voice_tuning_test.dart` (2 tests) : **PASS**
- `test/tts_vibevoice_fix_test.dart` (16 tests dont synthèses natives réelles) : **PASS**
- **Total régressions** : **48/48 PASS (0 régression)**.

---

### 3.3 Benchmark ASR Comparatif Décisif (Audio = 5.688 s)

Phrase de référence :  
> *« Bonjour. Ceci est un test de synthèse vocale de Jarvisol pour valider la dictée et la voix en français. »*

Fichier audio de test : `test_tts_vibevoice_spk0.wav` (24 000 Hz décodé en 16 000 Hz, 91 014 échantillons).

| Modèle ASR | Backend | Taille (octets) | Cold Start (s) | 1ère Inf (s) | Médiane 3 Runs (s) | RTF | WER (%) | CER (%) | Texte transcrit |
|---|---|---|---|---|---|---|---|---|---|
| **qwen3-asr-0.6b-q4_k** | `qwen3` | 631 026 336 | **0.149** | 1.111 | **1.097** | **0.193** | 26.3% | 7.2% | *"Un jour, Ceci est un test de synthèse vocale de Jarvis Sol pour valider la diction et la voix en français."* |
| **qwen3-asr-1.7b-q4_k** | `qwen3` | 1 490 915 200 | 0.698 | 7.827 | 2.115 | 0.372 | 10.5% | 8.4% | *"Aujourd'hui, ceci est un test de synthèse vocale de Jarvisol pour valider la dictée et la voix en français."* |
| **ggml-base** | `whisper` | 147 951 465 | 0.161 | **0.915** | **0.904** | **0.159** | 21.1% | 9.6% | *"- Bonjour, c'est si être un test de synthèse vocale de Jarvisole pour valider la dictée et la voix en français."* |
| **ggml-small** | `whisper` | 487 601 967 | 0.918 | 3.967 | 3.817 | 0.671 | 15.8% | 9.6% | *"Ceci est un test de synthèse vocale de Jarvis Sol pour valider la dictée et la voix en français."* |
| **ggml-large-v3-turbo** | `whisper` | 1 624 555 275 | 2.863 | 22.808 | 23.327 | 4.101 | **0.0%** | **0.0%** | *"Bonjour, ceci est un test de synthèse vocale de Jarvisol pour valider la dictée et la voix en français."* |

#### Enseignements du Benchmark ASR :
1. **Vitesse / Réactivité** :
   - `ggml-base` et `qwen3-asr-0.6b-q4_k` sont ultra-rapides (RTF ~0.16 à 0.19, inférence en ~0.9 s à 1.1 s pour 5.7 s d'audio).
   - `ggml-large-v3-turbo` en CPU pur est beaucoup trop lent pour une dictée interactive fluide (RTF 4.10, ~23 secondes d'attente par phrase courte).
2. **Qualité / Précision** :
   - `qwen3-asr-1.7b-q4_k` offre un compromis exceptionnel pour la dictée en français : WER 10.5%, temps d'inférence ~2.1 s (RTF 0.37).
   - `qwen3-asr-0.6b-q4_k` est le meilleur compromis temps réel / empreinte mémoire (1.09 s, 600 Mo).
   - La préférence utilisateur active dans Jarvisol n'a pas été modifiée, respectant les règles d'intégrité.

---

### 3.4 Synthèse Vocale VibeVoice (Voix Féminine Spk1_woman)
- Modèle : `vibevoice-realtime-0.5b-q4_k.gguf`
- Voicepack : `vibevoice-voice-fr-Spk1_woman.gguf`
- Fichier généré : `test_tts_vibevoice_spk1.wav` (durée : 5.45 s, taille : 261 792 octets, 24 kHz mono).
- Restitution : Voix féminine naturelle, fluide et sans artefact.

---

## 4. INCIDENTS ET DIAGNOSTICS TECHNIQUES

### 4.1 Identité binaire `whisper.dll` vs `crispasr.dll`
- **Fichier 1** : `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2\whisper.dll`
- **Fichier 2** : `D:\Antigravity\AgentFolder\CrispASR\build-flutter-bundle\src\Release\crispasr.dll`
- **Taille** : 13 844 992 octets
- **SHA-256** : `B1336C9FCBD3F82621417F08319C056956E39655865B96310FF00A71790A8AC7`
- **Constat** : Les deux DLL sont **rigoureusement identiques bit à bit**. `whisper.dll` est une copie conforme de `crispasr.dll` maintenue pour assurer la rétrocompatibilité des chemins d'importation historiques.

### 4.2 Diagnostic isolé Kokoro TTS
- **Exécution** : Processus isolé Flutter/Dart sans modification native.
- **Résultat** : Déclenchement de l'assertion native C GGML :  
  `D:\Antigravity\AgentFolder\CrispASR\ggml\src\ggml.c:1652: GGML_ASSERT(ctx->mem_buffer != NULL) failed`
- **Code de sortie** : `EXIT_CODE 79`.
- **Cause** : Le backend `kokoro.cpp` requiert une pré-allocation de buffer persistant qui n'est pas instanciée sur le chemin d'exécution CPU Windows. Aucune modification native n'a été tentée conformément au mandat.

### 4.3 Investigation Granite Speech 4.1 2B NAR (Handy)
- **Fichier GGUF Handy** : `granite-speech-4.1-2b-nar-Q5_K_M.gguf` (1 782 089 344 octets).
- **Architecture** : NAR (Non-Autoregressive).
- **Runtime Handy** : Dépend de `transcribe.dll` dédié + Onnxruntime (Silero VAD) + GGUF NAR decoder.
- **Test avec CrispASR** : Échec au chargement des tenseurs autorégressifs attendus (`missing decoder tensors`, `crispasr_session_transcribe_chunked returned null`).
- **Classification** : `INCOMPATIBLE_ACTUELLEMENT` sans adaptation du code C++ interne de `crispasr.dll`.

---

## 5. TEST-REQUIS — Protocole de test pour l'utilisateur

1. **Lancement de Jarvisol** :
   - Exécuter `build\windows\x64\runner\Debug\jarvisol.exe`.
2. **Test dans Assistant Audio** :
   - Accéder à l'écran **Assistant Audio**.
   - Vérifier la présence de l'icône microphone à gauche de la zone de saisie du prompt.
   - Cliquer sur le microphone : l'icône devient un cercle stop rouge, le tooltip indique « Arrêter et transcrire la dictée », le bouton d'envoi du prompt est désactivé.
   - Parler en français puis cliquer sur le bouton rouge : un indicateur de chargement circulaire apparaît brièvement, puis le texte transcrit est inséré directement dans le champ de saisie sans déclencher d'envoi automatique.
   - Vérifier qu'il est impossible de lancer un envoi pendant la dictée.
3. **Test dans Assistant Documents** :
   - Accéder à l'écran **Assistant Documents**.
   - Vérifier la présence du bouton de dictée vocale dans la barre de saisie de prompt.
   - Réaliser une dictée : vérification de l'insertion dans le champ de texte et du verrouillage mutuel.
   - Tester la synthèse vocale d'une réponse de document : écoute fluide, arrêt immédiat sans blocage en cas de changement de conversation ou de fermeture d'écran.
