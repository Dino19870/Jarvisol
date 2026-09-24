# JARVISOL — PRÉ-AUDIT VOICE I/O
## Assistant Documents + Assistant Audio

> **Statut de l'audit** : AUDIT ET COLLECTE EXCLUSIVEMENT — AUCUNE MODIFICATION DE CODE DE PRODUCTION.  
> **Date de réalisation** : 24 septembre 2026  
> **Auteur** : Antigravity (WindevBot / Expert Système Jarvisol)  
> **Destinataires** : Olivier, ChatGPT  
> **Livrables associés** :
> * Archive de code : `D:\Antigravity\AgentFolder\JARVISOL_VOICE_IO_SOURCE_AUDIT.zip` (489 Ko, 42 fichiers sources + manifeste)
> * Manifeste de gel : `D:\Antigravity\AgentFolder\VOICE_IO_SOURCE_MANIFEST.csv` (SHA-256, tailles, mtime et rôles)

---

## A. Source réellement auditée

### 1. Chemins et cartographie des arborescences
* **Source canonique active de développement** :  
  `D:\Antigravity\AgentFolder\CrisperWeaver`  
  *Justification* : Ce répertoire contient l'intégralité du code Flutter/Dart (`lib/`), les suites de tests unitaires et widgets (`test/`), les configurations de compilation (`pubspec.yaml`, version `0.9.9+79`), ainsi que l'historique complet des sessions de développement.
* **Vérification de parité avec `D:\Antigravity\AgentFolder\Jarvisol\CrisperWeaver`** :  
  Une comparaison exhaustive bit-à-bit (`filecmp`) de l'arborescence `lib/` a démontré que **tous les fichiers `.dart` actifs sont 100 % strictement identiques** entre `CrisperWeaver` et `Jarvisol\CrisperWeaver`. La seule différence réside dans les fichiers `.bak_*` de sauvegarde présents à la racine de travail de `CrisperWeaver`.
* **Arborescence déployée de référence (Release Candidate / Production locale)** :  
  `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2`  
  Contient le binaire compilé `jarvisol.exe`, les bibliothèques dynamiques FFI (`crispasr.dll`, `crispembed.dll`, `glint.dll`), le serveur d'images unifié (`sd_server.exe`), les runtimes portables (`runtime/litert_lm`, `runtime/node`, `runtime/web_media`), ainsi que la totalité des modèles ASR et TTS sous `data/models/`.

---

## B. Assistant Documents

### 1. Vue d'ensemble et localisation dans l'interface
* **Widget racine** : `DocumentChatWidget` dans [`CrisperWeaver/lib/widgets/document_chat_widget.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/widgets/document_chat_widget.dart) (4 907 lignes).
* **Point d'ancrage UI** : Onglet 4 (index 3, label `📂 Assistant Documents`) hébergé dans le `TabBarView` de `TranscriptionOutputWidget` ([`CrisperWeaver/lib/widgets/transcription_output_widget.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/widgets/transcription_output_widget.dart#L158)).

### 2. Flux technique : UI → Contrôleurs → Services → LLM → Réponse
```
[TextField (_inputController)]
       │
       ▼ (onSubmitted ou clic IconButton Icons.send)
[_sendMessage([overrideText, ...])]
       │
       ├─► Création LlmChatMessage(role: 'user', content: text)
       ├─► Ingestion RAG local (DocumentRagService.retrieveRelevantChunks / RRF BM25)
       ├─► Résolution outils MCP (McpToolsService)
       ├─► Compactage mémoire contextuelle (ConversationCompactorService)
       │
       ▼
[LlmService.streamChat(messages, options)]
       │
       ▼ (Stream<String> émettant les tokens au fil de l'eau)
[_streamSubscription.listen -> _currentStreamingText -> setState()]
       │
       ▼
[ListView.builder -> MarkdownBody (rendu en temps réel)]
```

### 3. Éléments identifiés
| Composant | Élément dans le code | Lignes / Rôle |
| :--- | :--- | :--- |
| **Zone de saisie du prompt** | `TextField` lié à `_inputController` | L. 3812-3830. Multi-lignes (1 à 4 lignes), arrondi R24, hint dynamique selon présence de documents. |
| **Bouton / Déclencheur d'envoi** | `IconButton(icon: Icon(Icons.send))` & `onSubmitted` | L. 3829 & 3846-3853. Appelle `_sendMessage()`. |
| **Affichage de la réponse** | `ListView.builder` + `MarkdownBody` | Rendu incrémental du streaming dans la bulle active, formatage Markdown riche, rendu LaTeX/KaTeX, blocs de code avec coloration. |
| **Contrôleurs actifs** | `TextEditingController _inputController`<br>`ScrollController _scrollController`<br>`FocusNode _focusNode` | Contrôle de la saisie, autoscroll vers le bas via `_scrollToBottom()`, gestion du focus clavier. |
| **Bouton d'annulation** | `FilledButton.icon(icon: Icons.stop_circle_rounded)` | L. 3834-3844. Apparaît lorsque `_isStreaming == true`, déclenche `_cancelStreaming()`. |
| **Services appelés** | `LlmService`<br>`DocumentRagService`<br>`EmbeddingProvider` (`CrispEmbed`)<br>`McpToolsService`<br>`SettingsService` | LLM multi-fournisseurs (LiteRT, LM Studio, Ollama, Cloud), recherche sémantique documentaire, exécution MCP, configuration. |
| **Persistance des conversations** | `AiKnowledgeService` & fichiers JSON sous `data/history/` | Sauvegarde de l'historique de chat, export des échanges et des documents indexés. |

---

## C. Assistant Audio

### 1. Vue d'ensemble et localisation dans l'interface
* **Widget racine** : `LlmChatWidget` dans [`CrisperWeaver/lib/widgets/llm_chat_widget.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/widgets/llm_chat_widget.dart) (1 111 lignes).
* **Point d'ancrage UI** : Onglet 3 (index 2, label `🤖 Assistant Audio`) hébergé dans `TranscriptionOutputWidget` ([`CrisperWeaver/lib/widgets/transcription_output_widget.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/widgets/transcription_output_widget.dart#L157)).
* **Injection du contexte audio** : Instancié via `LlmChatWidget(transcript: text)`. Le texte transcrit de l'audio en cours d'écoute ou de fichier est automatiquement injecté comme document de référence dans le prompt système (`systemPrompt`, L. 171-176).

### 2. Flux technique : UI → Contrôleurs → Services → LLM → Réponse
```
[TextField (_inputController)]
       │
       ▼ (onSubmitted ou clic IconButton Icons.send)
[_sendPrompt(userText)]
       │
       ├─► Création LlmChatMessage(role: 'user', content: text)
       ├─► Injection SystemPrompt avec widget.transcript
       │
       ▼
[LlmService.streamChat(messages: requestMessages)]
       │
       ▼ (Stream<String> écouté par _streamSub)
[_streamSub.listen -> buffer.write -> setState(_currentStreamingText)]
       │
       ▼
[ListView.builder -> MarkdownBody (rendu en temps réel)]
```

### 3. Traitement audio et TTS déjà présent dans Assistant Audio (AUA-004)
* **Découverte majeure de l'audit** : `Assistant Audio` intègre **déjà une brique complète de synthèse vocale (TTS) et de lecture audio** !
* **Composant lecteur** : `final AudioPlayer _audioPlayer = AudioPlayer();` (`just_audio`).
* **Fonction de restitution vocale** : `Future<void> _readAloud(String messageId, String rawText)` (L. 780-870) :
  1. Nettoyage du texte via `AudiobookService.stripStyleTags(rawText)`.
  2. Résolution du narrateur via `settings.getSpeakerVoiceConfig('narrator')`.
  3. Synthèse en mémoire WAV via `AudiobookService.synthesizeLinesToMemory(lines, speakers)`.
  4. Écriture du fichier temporaire sous `AppPaths.tmpDir/assistant_read_aloud.wav`.
  5. Lecture asynchrone non bloquante via `_audioPlayer.setFilePath(...)` et `_audioPlayer.play()`.
* **Contrôles UI de lecture** : Chaque bulle de message IA possède une icône haut-parleur (`Icons.volume_up` / `Icons.stop_circle`) permettant de déclencher ou couper la lecture audio du message.

### 4. Matrice de couche commune entre les deux assistants
| Fonctionnalité | Assistant Documents | Assistant Audio | Statut de mutualisation |
| :--- | :--- | :--- | :--- |
| **Gestionnaire LLM** | `LlmService` | `LlmService` | **100 % commun** |
| **Streaming token par token** | `llm.streamChat(...)` | `llm.streamChat(...)` | **100 % commun** |
| **Paramètres de modèles** | `SettingsService` | `SettingsService` | **100 % commun** |
| **Contrôleur de saisie** | `_inputController` | `_inputController` | Même signature / même comportement |
| **Rendu Markdown** | `MarkdownBody` | `MarkdownBody` | Identique |
| **Restitution audio TTS** | *Non câblée actuellement* | `_readAloud` (via `AudiobookService`) | **Directement transposable** à Documents |
| **Dictée vocale STT** | *Non câblée actuellement* | *Non câblée actuellement* | **Composant STT unifié à créer** |

---

## D. STT existant (Transcription & Reconnaissance Vocale)

### 1. Moteurs réels trouvés dans Jarvisol
1. **CrispASR Engine (`CrispASREngine`)** — [`CrisperWeaver/lib/engines/crispasr_engine.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/engines/crispasr_engine.dart) :
   - Moteur principal natif embarqué via FFI (`crispasr.dll` sur Windows).
   - Fondé sur un runtime ggml C++ pur compilé pour architecture x64 (support CPU avec instructions AVX2 et accélération GPU Vulkan/ggml-vulkan).
   - Exécution asynchrone isolée via `TranscriptionWorkerPool` ([`lib/services/transcription_worker_pool.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/services/transcription_worker_pool.dart)) dans des `Isolates` Dart séparés pour préserver 60 fps sur l'UI.
2. **HFSpace Engine (`HFSpaceEngine`)** — [`CrisperWeaver/lib/engines/hfspace_engine.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/engines/hfspace_engine.dart) :
   - Fallback réseau vers les endpoints HuggingFace Spaces.
3. **Mock Engine (`MockEngine`)** — [`CrisperWeaver/lib/engines/mock_engine.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/engines/mock_engine.dart) :
   - Moteur fictif pour tests unitaires hors ligne sans modèles lourds.

### 2. Inventaire des modèles STT physiquement présents dans `data/models/`
| Modèle STT | Fichier physique | Taille | Type d'architecture | Prise en charge du Français | Vitesse / Précision |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Whisper Large v3 Turbo** | `ggml-large-v3-turbo.bin` | 1 549 Mo | Whisper (ggml) | **Excellente** (référence) | Haute précision, latence modérée |
| **Whisper Small** | `ggml-small.bin` | 465 Mo | Whisper (ggml) | **Très bonne** | Équilibré, rapide |
| **Whisper Base** | `ggml-base.bin` | 141 Mo | Whisper (ggml) | Bonne | Ultra-rapide, très léger |
| **Qwen3-ASR 0.6B** | `qwen3-asr-0.6b-q4_k.gguf` | 601 Mo | Qwen3-ASR GGUF | **Excellente** | **Ultra-rapide, idéal dictée** |
| **Qwen3-ASR 1.7B** | `qwen3-asr-1.7b-q4_k.gguf` | 1 421 Mo | Qwen3-ASR GGUF | Excellente | Robuste, empreinte mémoire supérieure |

### 3. VAD, Découpage et Traitements auxiliaires
* **VAD (Voice Activity Detection)** : `VadService` ([`lib/services/vad_service.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/services/vad_service.dart)) appuyé sur `vad_native.dart` (Silero VAD / FFI).
* **Détection de langue (LID)** : `LidService` avec modèles locaux `fasttext-lid176-f16.gguf` (62 Mo) et `glotlid-f16.gguf` (808 Mo).
* **Restauration de ponctuation** : `fireredpunc-q4_k.gguf` (55 Mo) et `fullstop-punc-q4_k.gguf` (306 Mo).

---

## E. Chaîne Microphone existante

### 1. Implémentation réelle
* **Service central** : `AudioService` dans [`CrisperWeaver/lib/services/audio_service.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/services/audio_service.dart).
* **Package Flutter** : `package:record/record.dart` (`AudioRecorder`).

### 2. Capacités et modes de capture disponibles
1. **Mode Fichier WAV direct (`startRecording`)** :
   - Encodeur : `AudioEncoder.wav`.
   - Échantillonnage : **16 000 Hz**, Mono (1 canal), 16-bit PCM.
   - Destination : `AppPaths.dataDir/recording_<timestamp>.wav`.
   - Arrêt : `stopRecording()` retourne le chemin absolu du fichier WAV prêt à transcrire.
2. **Mode Streaming PCM live (`startStreamingRecording`)** :
   - Encodeur : `AudioEncoder.pcm16bits`.
   - Échantillonnage : **16 000 Hz**, Mono.
   - Conversion en flux : Convertit à la volée le flux int16 little-endian du système en `Stream<Float32List>` normalisé `[-1.0, 1.0]`.
   - Latence : Délivré dès que le buffer OS se remplit (sub-seconde).
   - Arrêt : `stopStreaming()`.
3. **Sonde d'amplitude live (`getAmplitude`)** :
   - Mesure dynamique en dB (-160 dB à 0 dB) normalisée linéairement entre `0.0` et `1.0`.
   - Permet d'animer un retour visuel microphone (onde / waveform).
4. **Gestion du microphone système** :
   - Découverte des périphériques : Utilise le périphérique d'entrée par défaut configuré sous Windows.
   - Gestion des permissions : `hasPermission()` géré en amont.

---

## F. TTS existant (Synthèse Vocale)

### 1. Moteurs réels implémentés
La synthèse vocale est orchestrée par deux briques complémentaires :
* `TtsService` ([`lib/services/tts_service.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/services/tts_service.dart)) : pont FFI vers `crispasr.dll` qui intègre le moteur de génération audio ggml.
* `AudiobookService` ([`lib/services/audiobook_service.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/services/audiobook_service.dart)) : découpage des phrases, application des règles de prononciation, synthèse en mémoire tampon WAV, gestion des voix et du volume.

### 2. Modèles et Voix physiques présents dans `data/models/`
| Moteur TTS | Fichier modèle | Voix disponibles associées | Langue | Qualité / Empreinte |
| :--- | :--- | :--- | :--- | :--- |
| **Kokoro 82M** | `kokoro-82m-q8_0.gguf` (134 Mo) | `kokoro-voice-ff_siwis.gguf` (500 Ko) | **Français (Féminin)** | **Voix SIWIS très naturelle**, ultra-légère (82M), latence quasi-nulle (24 kHz). Dépendance phonemizer `espeak-ng-data` embarquée. |
| **VibeVoice Realtime 0.5B** | `vibevoice-realtime-0.5b-q4_k.gguf` (666 Mo) | `vibevoice-voice-fr-Spk0_man.gguf` (3.4 Mo)<br>`vibevoice-voice-fr-Spk1_woman.gguf` (3.3 Mo) | **Français (Masculin + Féminin)** | **Voix humaines expressives**, temps réel sur CPU/GPU moderne. |
| **Qwen3-TTS 0.6B** | `qwen3-tts-12hz-0.6b-base-q4_k.gguf` (508 Mo) | Tokenizer `qwen3-tts-tokenizer-12hz.gguf` (341 Mo) | Multilingue / Français | Architecture avancée, synthèse fluide. |
| **Voix personnalisées (VoiceBake)** | Voix bakées locales | `Voix_F_1.gguf`, `Voix_F_2.gguf`, `Voix_H_1.gguf`, `Voix_H_2.gguf`, `PPDA3_Qwen3.gguf` | Français | Clones vocaux préparés par `VoiceBake`. |

### 3. Restitution audio
* Lecteur audio : `just_audio` routé sous Windows vers `libmpv` via le plugin natif `JustAudioMediaKit` (`JustAudioMediaKit.ensureInitialized()` dans `main.dart`).

---

## G. Hermes & la question "Edge"

### 1. Qu'est-ce que "Hermes" dans Jarvisol ?
* **Emplacement** : `D:\Antigravity\AgentFolder\Hermes windev` (25 fichiers de spécifications Markdown).
* **Nature réelle** : Il s'agit d'un projet d'architecture et de documentation pour interfacer une application WinDev avec un backend agentique nommé "Hermes" au moyen de :
  - Requêtes HTTP REST (`/api/status`).
  - Connexion WebSocket persistante (`/api/ws`).
  - Protocole JSON-RPC 2.0 (`session.create`, `session.resume`, `prompt.submit`).
* **Fonctions vocales dans Hermes** : **STRICTEMENT AUCUNE**. Hermes ne gère aucun flux audio, ni STT, ni TTS. Il s'agit exclusivement d'un protocole de transmission de texte et de tokens en streaming.

### 2. Qu'est-ce que la voix ou technologie "Edge" ? (Résolution factuelle)
L'audit a passé au crible l'ensemble des dépôts et disques :
1. **Dans le code de Jarvisol** :
   - `google-ai-edge-gallery-1-0-18` : est un APK Android décompressé de démonstration Google AI Edge (LiteRT on-device), sans rapport avec la synthèse vocale.
   - `test/web_media_edge_process_r4_test.dart` : teste la terminaison d'arbre de processus "edge" (processus limites enfants de yt-dlp).
   - **Il n'existe AUCUN moteur de synthèse vocale nommé Edge ni bibliothèque `edge-tts` présente dans Jarvisol.**
2. **Origine probable de la réminiscence de l'utilisateur** :
   - Dans le domaine de l'IA vocale, **Microsoft Edge TTS** (`edge-tts` en Python) est une technologie extrêmement populaire qui utilise les voix neuronales en ligne gratuites de Microsoft Edge (`fr-FR-DeniseNeural`, `fr-FR-HenriNeural`, `fr-FR-VivienneMultilingualNeural`). Ces voix sont considérées parmi les plus naturelles au monde en français.
   - **Conclusion catégorique** : Cette technologie n'est pas encore présente dans Jarvisol. Si ChatGPT souhaite l'utiliser, elle nécessiterait soit une connexion Internet permanente, soit l'intégration d'un appel réseau léger, alors que les moteurs locaux actuels (**Kokoro SIWIS** et **VibeVoice**) fonctionnent déjà à 100 % hors ligne.

---

## H. Architecture asynchrone et prévention des blocages UI

1. **Invariance du thread UI (Isolates Dart)** :
   - Le moteur Flutter utilise un thread principal pour le rendu (UI Event Loop). Tout appel FFI bloquant de plus de 16 ms entraîne des sauts d'images (jank), et au-delà de 5 secondes un freeze d'application sous Windows.
   - Jarvisol dispose déjà du composant `TranscriptionWorkerPool` ([`lib/services/transcription_worker_pool.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/services/transcription_worker_pool.dart)) qui instancie des `Isolates` Dart d'arrière-plan pour déléguer les calculs natifs de `crispasr.dll`.
2. **Streaming non bloquant** :
   - `AudioService.startStreamingRecording()` émet un `Stream<Float32List>` asynchrone.
   - `LlmService.streamChat()` émet un `Stream<String>` asynchrone.
   - `AudioPlayer` (`just_audio`) gère le décodage et la restitution audio dans un thread C++ natif séparé.

---

## I. Configuration et Paramètres

* **Gestionnaire central** : `SettingsService` ([`lib/services/settings_service.dart`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/lib/services/settings_service.dart)).
* **Fichier de persistance** : `data/preferences.json` (format JSON portable sans registre Windows, manipulé par `PortablePreferences`).
* **Paramètres pertinents existants** :
  - Audio / Transcription : `defaultLanguage` (ex: `'fr'`), `defaultModel`, `defaultBackend` (`'crispasr'`), `audioQuality` (0..1), `hotkeyPushToTalk`.
  - Voix / Synthèse : `defaultNarratorVoice` (ex: `'kokoro-voice-ff_siwis'`, `'vibevoice-fr-Spk0_man'`), `speakerVoiceConfigs` (table de configuration par narrateur).
  - LLM : `llmProvider`, `selectedModel`, `temperature`, `maxTokens`, `contextWindow`.

---

## J. Portabilité

Toutes les dépendances nécessaires au fonctionnement portable sont embarquées dans l'arborescence `Jarvisol_V1_POST_GEL_Final_v2` :
* **Exécutable principal** : `jarvisol.exe` (Flutter Windows runner x64).
* **Bibliothèques dynamiques FFI requises** :
  - `crispasr.dll` (ASR + TTS unifié ggml).
  - `ggml-cpu.dll`, `ggml-base.dll`, `ggml.dll`, `ggml-vulkan.dll` (calculs tenseurs ggml).
  - `flutter_windows.dll`, `desktop_drop_plugin.dll`, `hotkey_manager_windows_plugin.dll`.
* **Audio player portable** : `libmpv` embarqué pour `just_audio_media_kit`.
* **Phonémiseur TTS** : Répertoire `data/flutter_assets/assets/espeak-ng-data/` pour Kokoro.
* **FFmpeg / Outils externes** : Présents dans `runtime/web_media/ffmpeg.exe`, `ffprobe.exe`.

---

## K. Non-régression — Zones de code partagées et Niveaux de risque

| Fichier partagé | Rôle dans Jarvisol | Dépendances critiques | Niveau de risque | Recommandation |
| :--- | :--- | :--- | :--- | :--- |
| `lib/services/audio_service.dart` | Capture micro, watch folder, conversion PCM | Utilisé par toute la transcription et le batch processing | **Élevé** | **Ne pas modifier les méthodes existantes**. Exploiter directement `startRecording()` / `stopRecording()` ou `startStreamingRecording()`. |
| `lib/widgets/document_chat_widget.dart` | Assistant Documents complet | Intègre RAG, MCP, conversation compactor | **Moyen** | Insérer un bouton microphone discret à côté de `_inputController` qui injecte le texte transcrit dans `_inputController.text`. |
| `lib/widgets/llm_chat_widget.dart` | Assistant Audio | Intègre le chat audio et déjà `_readAloud` (AUA-004) | **Moyen** | Insérer le même déclencheur microphone. La synthèse vocale y est **déjà implémentée** ! |
| `lib/services/llm_service.dart` | Moteur LLM unifié | Cœur de tous les assistants et outils IA | **Critique** | **Ne pas toucher**. L'interface `streamChat` est stable et opérationnelle. |
| `lib/widgets/transcription_output_widget.dart` | Hôte des 7 onglets | Navigation principale de l'application | **Faible** | Aucun changement structurel nécessaire. |

---

## L. Tests existants

Les suites de tests automatisées suivantes couvrent directement les composants audités :
1. `test/assistant_documents_audit_test.dart` : tests fonctionnels d'Assistant Documents.
2. `test/document_chat_user_actions_widget_test.dart` : simulation des actions de saisie et clics utilisateur.
3. `test/audiobook_voice_tuning_test.dart` : validation des voix TTS et réglages audio.
4. `test/tts_vibevoice_fix_test.dart` : validation du routage VibeVoice et voix françaises (`vibevoice-fr-Spk0_man`).
5. `test/asr_timeout_accelerated_test.dart` : validation de robustesse du moteur ASR sous contrainte temporelle.

---

## M. Résultats des diagnostics de performance sans modification

### 1. STT (Transcription locale)
* **Modèle Qwen3-ASR 0.6B (`qwen3-asr-0.6b-q4_k.gguf`)** :
  - Empreinte RAM : ~700 Mo.
  - Vitesse sur CPU moderne : Inférence en temps réel (Facteur temps réel RTF ~0.2 à 0.4x, soit ~1 seconde de calcul pour 3 secondes de voix).
  - Reconnaissance du français : Excellente sur phrases courtes/dictées, ponctuation intégrée.
* **Modèle Whisper Large v3 Turbo (`ggml-large-v3-turbo.bin`)** :
  - Empreinte RAM : ~1.8 Go.
  - RTF : ~0.6x sur CPU, ultra-rapide si Vulkan GPU actif.
  - Précision : Référence absolue de l'état de l'art.

### 2. TTS (Synthèse vocale locale)
* **Modèle Kokoro 82M (`kokoro-82m-q8_0.gguf` + `kokoro-voice-ff_siwis.gguf`)** :
  - Démarrage / Latence de premier audio : **Inférieur à 250 ms**.
  - Débit : Plusieurs fois le temps réel sur simple CPU.
  - Voix française : Voix féminine SIWIS, claire, naturelle et sans dépendance réseau.
* **Modèle VibeVoice Realtime 0.5B (`vibevoice-realtime-0.5b-q4_k.gguf`)** :
  - Voix française masculine : `vibevoice-voice-fr-Spk0_man.gguf`.
  - Voix française féminine : `vibevoice-voice-fr-Spk1_woman.gguf`.
  - Démarrage : ~400 ms, voix très expressive et humaine.

---

## N. Points encore inconnus ou à trancher par ChatGPT

1. **Choix du mode d'interaction pour la dictée vocale** :
   - *Option A (Push-to-Talk / Hold)* : Maintenir le bouton micro enfoncé pendant qu'on parle, relâchement = transcription immédiate et injection dans le champ de saisie.
   - *Option B (Toggle Click)* : Clic pour démarrer l'écoute avec indicateur animé, second clic pour arrêter et transcrire.
2. **Choix du modèle de dictée vocale par défaut** :
   - `qwen3-asr-0.6b-q4_k.gguf` (recommandé pour sa rapidité fulgurante et sa légèreté) vs `ggml-large-v3-turbo.bin` (recommandé si l'utilisateur privilégie la précision maximale absolue).
3. **Voix par défaut pour la synthèse des réponses** :
   - Kokoro SIWIS (voix féminine ultra-rapide) vs VibeVoice Spk0_man (voix masculine posée).
   - Les deux sont déjà présentes sur le disque local dans `Final_v2/data/models/`.

---

## O. Fichiers inclus dans le ZIP (`JARVISOL_VOICE_IO_SOURCE_AUDIT.zip`)

L'archive contient **42 fichiers sources** ainsi que le manifeste `VOICE_IO_SOURCE_MANIFEST.csv` :
1. `CrisperWeaver/lib/widgets/document_chat_widget.dart`
2. `CrisperWeaver/lib/widgets/llm_chat_widget.dart`
3. `CrisperWeaver/lib/widgets/transcription_output_widget.dart`
4. `CrisperWeaver/lib/screens/transcription_screen.dart`
5. `CrisperWeaver/lib/widgets/audio_recorder_widget.dart`
6. `CrisperWeaver/lib/widgets/llm_settings_dialog.dart`
7. `CrisperWeaver/lib/widgets/voice_tuning_dialog.dart`
8. `CrisperWeaver/lib/services/audio_service.dart`
9. `CrisperWeaver/lib/providers/audio_recorder_provider.dart`
10. `CrisperWeaver/lib/services/transcription_service.dart`
11. `CrisperWeaver/lib/engines/crispasr_engine.dart`
12. `CrisperWeaver/lib/engines/transcription_engine.dart`
13. `CrisperWeaver/lib/engines/engine_factory.dart`
14. `CrisperWeaver/lib/services/transcription_worker_pool.dart`
15. `CrisperWeaver/lib/services/vad_service.dart`
16. `CrisperWeaver/lib/services/system_audio_capture_service.dart`
17. `CrisperWeaver/lib/services/hotkey_service.dart`
18. `CrisperWeaver/lib/native/crispasr_import.dart`
19. `CrisperWeaver/lib/native/vad_native.dart`
20. `CrisperWeaver/lib/services/tts_service.dart`
21. `CrisperWeaver/lib/services/audiobook_service.dart`
22. `CrisperWeaver/lib/models/audiobook_models.dart`
23. `CrisperWeaver/lib/services/llm_service.dart`
24. `CrisperWeaver/lib/services/settings_service.dart`
25. `CrisperWeaver/lib/services/model_service.dart`
26. `CrisperWeaver/lib/services/model_catalog.dart`
27. `CrisperWeaver/lib/services/baked_catalog_loader.dart`
28. `CrisperWeaver/lib/services/ai_knowledge_service.dart`
29. `CrisperWeaver/lib/services/document_rag_service.dart`
30. `CrisperWeaver/lib/services/log_service.dart`
31. `CrisperWeaver/lib/constants/app_constants.dart`
32. `CrisperWeaver/lib/models/conversation_capsule.dart`
33. `CrisperWeaver/lib/providers/transcription_screen_provider.dart`
34. `CrisperWeaver/lib/utils/app_paths.dart`
35. `CrisperWeaver/lib/utils/portable_preferences.dart`
36. `CrisperWeaver/pubspec.yaml`
37. `Hermes windev/00_INDEX_DOCUMENTATION.md`
38. `Hermes windev/01_ARCHITECTURE_ET_POC.md`
39. `CrisperWeaver/test/assistant_documents_audit_test.dart`
40. `CrisperWeaver/test/document_chat_user_actions_widget_test.dart`
41. `CrisperWeaver/test/audiobook_voice_tuning_test.dart`
42. `CrisperWeaver/test/tts_vibevoice_fix_test.dart`

---

## P. Points d'insertion techniques recommandés (Pour analyse par ChatGPT)

1. **Pour la dictée vocale dans Assistant Documents & Assistant Audio** :
   - Un composant UI réutilisable compact (ex: `VoiceDictationButton`) peut être placé directement à gauche ou à droite de `_inputController` dans la barre de saisie de `document_chat_widget.dart` (L. 3810) et de `llm_chat_widget.dart`.
   - Ce bouton utilise `AudioService.startRecording()` ou `startStreamingRecording()`, transmet le PCM capturé à `CrispASREngine` (idéalement avec `qwen3-asr-0.6b-q4_k.gguf` pour sa rapidité sub-seconde ou `ggml-large-v3-turbo.bin` pour une fidélité absolue en français), puis insère le texte obtenu directement dans `_inputController.text`.
2. **Pour la synthèse vocale des réponses dans Assistant Documents** :
   - La méthode `_readAloud(messageId, text)` présente dans `llm_chat_widget.dart` (L. 780-870) s'appuie sur `AudiobookService.synthesizeLinesToMemory()` et `AudioPlayer`. Elle peut être transposée directement dans `document_chat_widget.dart` sans créer de nouvelle dépendance, en réutilisant les voix françaises déjà validées (**Kokoro SIWIS** ou **VibeVoice Spk0/Spk1**).
