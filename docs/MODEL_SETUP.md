# Guide de Configuration et d'Installation des Modèles IA

Ce guide répertorie l'emplacement attendu, le rôle, le statut (obligatoire ou optionnel) et la méthode d'obtention de chaque famille de modèles IA utilisable par Jarvisol.

---

## 1. ASR — Reconnaissance Vocale (Speech-to-Text)

- **ROLE** : Transcription automatique de fichiers audio/vidéo et dictée vocale temps réel.
- **OPTIONAL_OR_REQUIRED** : **Requis** pour la fonction de transcription (au moins 1 modèle).
- **EXPECTED_DIRECTORY** : `data/models/whisper_cpp/`
- **CATALOG_OR_INSTALL_METHOD** : Téléchargement automatique en 1 clic via l'écran *Gestion des Modèles* de l'application, ou téléchargement direct depuis HuggingFace (`https://huggingface.co/ggerganov/whisper.cpp`).
- **Modèle par défaut recommandé** : `ggml-base.bin` (~148 Mo) ou `ggml-small.bin` (~488 Mo).

---

## 2. TTS — Synthèse Vocale (Text-to-Speech)

- **ROLE** : Lecture à voix haute de textes, génération d'audiobooks et doublage.
- **OPTIONAL_OR_REQUIRED** : Optionnel (requis uniquement pour la synthèse vocale).
- **EXPECTED_DIRECTORY** : `data/models/tts/`
- **CATALOG_OR_INSTALL_METHOD** : Téléchargeable depuis le catalogue interne dans l'UI (ex. Kokoro v1.0, Piper-TTS).
- **Modèle par défaut recommandé** : Kokoro v1.0 GGUF (~85 Mo).

---

## 3. Voice Clone — Clonage Vocal (Qwen3-TTS / Chatterbox)

- **ROLE** : Clonage de voix à partir d'un échantillon audio de référence WAV.
- **OPTIONAL_OR_REQUIRED** : Optionnel.
- **EXPECTED_DIRECTORY** : `data/models/tts/` et `tools/voice_bake/chatterbox_weights/`
- **CATALOG_OR_INSTALL_METHOD** : Téléchargement du modèle de base Qwen3-TTS via l'assistant de clonage.

---

## 4. Embeddings & RAG — Recherche Documentaire Sémantique

- **ROLE** : Indexation et recherche sémantique locale dans vos documents (PDF, Markdown, Notes).
- **OPTIONAL_OR_REQUIRED** : Optionnel (requis pour le RAG documentaire et l'assistant de chat sur documents).
- **EXPECTED_DIRECTORY** : `data/models/embeddings/`
- **CATALOG_OR_INSTALL_METHOD** : Téléchargement automatique via l'écran RAG de Jarvisol.
- **Modèle par défaut recommandé** : `bge-small-en-v1.5.gguf` ou `all-MiniLM-L6-v2.gguf` (~65 Mo).

---

## 5. LiteRT LLM — Assistant Conversationnel Local

- **ROLE** : Génération de réponses, résumé de réunions, restructuration de textes en local sans connexion Internet.
- **OPTIONAL_OR_REQUIRED** : Optionnel (Jarvisol peut aussi se connecter à LM Studio, Ollama ou une API cloud).
- **EXPECTED_DIRECTORY** : Géré par le serveur local LiteRT ou LM Studio.
- **CATALOG_OR_INSTALL_METHOD** : Téléchargement de modèles GGUF ou TFLite (ex. Gemma 2B, Qwen 2.5 3B).

---

## 6. Image Generation — Stable Diffusion

- **ROLE** : Génération d'images locale accélérée par GPU Vulkan / DirectML.
- **OPTIONAL_OR_REQUIRED** : Optionnel.
- **EXPECTED_DIRECTORY** : `models/` dans le dossier de `sd_server`.
- **CATALOG_OR_INSTALL_METHOD** : Fichiers `.safetensors` de modèles Stable Diffusion (SD 1.5, DreamShaper, etc.).
