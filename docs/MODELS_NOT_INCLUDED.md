# Modèles IA Non Inclus dans le Dépôt GitHub

Conformément aux bonnes pratiques d'ingénierie et aux quotas de stockage GitHub, **aucun fichier de poids d'Intelligence Artificielle n'est versionné dans ce dépôt**.

Le dépôt Git contient 100% du code source, des algorithmes d'inférence, des scripts de conversion et des bibliothèques d'intégration. Les fichiers de poids volumineux (souvent de 100 Mo à 20 Go par modèle) doivent être obtenus séparément.

---

## Familles de modèles exclues de Git

1. **Modèles ASR (Reconnaissance Vocale)** :
   - Formats : `*.bin`, `*.gguf`
   - Familles : Whisper (tiny, base, small, medium, large-v3), Qwen3-ASR, Canary, Parakeet, Moonshine.
   - Dossier attendu : `data/models/whisper_cpp/` ou `models/asr/`
2. **Modèles TTS (Synthèse Vocale & Clonage)** :
   - Formats : `*.gguf`, `*.safetensors`, `*.pt`
   - Familles : Kokoro, Piper, Qwen3-TTS, Chatterbox, VibeVoice, Orpheus.
   - Dossier attendu : `data/models/tts/` ou `models/tts/`
3. **Modèles d'Embeddings & RAG** :
   - Formats : `*.gguf`
   - Familles : BGE (small-en, small-fr), MiniLM (L6-v2), Nomic, Qwen2-Embed.
   - Dossier attendu : `data/models/embeddings/`
4. **Modèles LLM LiteRT / GGUF** :
   - Formats : `*.tflite`, `*.bin`, `*.gguf`
   - Familles : Gemma 2B, Qwen 2.5, Phi-3, Llama 3.
   - Dossier attendu : géré via LM Studio ou LiteRT local.
5. **Modèles d'Image / Génération Visuelle** :
   - Formats : `*.safetensors`, `*.ckpt`
   - Familles : Stable Diffusion 1.5, SDXL, Turbo, ControlNet.
   - Dossier attendu : `models/` sous le dossier SD Server.
6. **Voicepacks et Voix Personnalisées** :
   - Formats : `*.gguf`
   - Voix créées ou clonées par l'utilisateur.

---

## Comment installer les modèles ?

Jarvisol intègre un **gestionnaire de modèles complet** dans son interface graphique :
1. Démarrez l'application Jarvisol (`crisper_weaver.exe` ou `jarvisol.exe`).
2. Ouvrez le panneau **Gestion des Modèles** (icône d'engrenage ou menu latéral).
3. Cliquez sur le modèle souhaité (ex. *Whisper Base* pour la transcription, ou *Kokoro* pour la voix).
4. Le téléchargement officiel depuis HuggingFace s'effectue automatiquement avec vérification d'intégrité SHA-256.

Pour une configuration manuelle ou hors-ligne, consultez [docs/MODEL_SETUP.md](MODEL_SETUP.md).
