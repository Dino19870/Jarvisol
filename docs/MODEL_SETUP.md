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

## 6. Image Generation & Editing — Stable Diffusion / DiT / IP-Adapter

- **ROLE** : Génération d'images haute résolution (Text-to-Image), inpainting/retouche de zones masquées, composition multi-images avec conservation d'identité ou d'objet (IP-Adapter), et détection automatique de visage (ADetailer YOLOv8).
- **OPTIONAL_OR_REQUIRED** : Optionnel (requis uniquement pour le studio d'images et la retouche visuelle).
- **EXPECTED_DIRECTORY** :
  - Modèles et encodeurs : `models/Stable-diffusion/`
  - Encodeur visuel IP-Adapter : `models/image_conditioning/clip_vision/`
  - Adaptateurs d'image : `models/image_conditioning/ip_adapter/`
  - Détecteurs de visage : `models/image_conditioning/detectors/`
- **GUIDE COMPLET ET MANIFESTE DÉTAILLÉ** :
  - Consultez le document dédié : [Guide d'Installation des Modèles d'Images](IMAGE_MODELS_SETUP.md)
  - Manifeste machine-readable : [image_models_manifest.json](image_models_manifest.json)
- **CATALOG_OR_INSTALL_METHOD** :
  Téléchargement automatisé et sécurisé par empreintes SHA-256 via le script PowerShell :
  ```powershell
  # Lister les packs disponibles
  .\scripts\download_image_models.ps1 -List

  # Télécharger le pack Auto Face & Multi-Image (4.85 Go)
  .\scripts\download_image_models.ps1 -Pack IMAGE_AUTO_FACE

  # Télécharger le pack Text-to-Image rapide Chroma Flash (7.94 Go)
  .\scripts\download_image_models.ps1 -Pack IMAGE_BASIC
  ```
- **Packs recommandés** :
  - Génération rapide (DiT) : `IMAGE_BASIC` (`chroma-unlocked-v46-flash-Q4_0.gguf` + `ae.safetensors` + `t5xxl_q4_k.gguf`).
  - Retouche & Multi-Image SD 1.5 : `IMAGE_AUTO_FACE` (`Realistic_Vision_V6.0_NV_B1_inpainting_fp16.safetensors`, `clip_vision_vit_h.safetensors`, `ip-adapter-plus_sd15.safetensors`, `ip-adapter-plus-face_sd15.safetensors`, `face_yolov8n.safetensors`).

