# Jarvisol

[![Windows Build](https://github.com/Dino19870/Jarvisol/actions/workflows/build-windows.yml/badge.svg)](https://github.com/Dino19870/Jarvisol/actions)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](CrisperWeaver/LICENSE)

**Jarvisol** est un environnement complet d'intelligence artificielle locale pour Windows, combinant :
- **Reconnaissance vocale (ASR)** ultra-rapide sur GPU/CPU via Whisper et modèles compacts ggml.
- **Synthèse vocale (TTS) & Clonage vocal** (Kokoro, Piper, Qwen3-TTS, Chatterbox).
- **RAG sémantique sur documents personnels** (recherche hybride vectorielle et BM25 avec embeddings locaux).
- **Génération d'images locale** accélérée par Vulkan (Stable Diffusion).
- **Outils Web Media** pour la transcription, l'extraction de sous-titres et l'analyse de flux en ligne.

Ce dépôt GitHub est un **monorepo autonome reproductible** : il contient l'intégralité du code source nécessaire pour recompiler l'application sur un poste Windows vierge, sans dépendre de dossiers de développement locaux.

---

## Sommaire

1. [Architecture du dépôt](#1-architecture-du-dépôt)
2. [Prérequis Windows](#2-prérequis-windows)
3. [Clonage du dépôt](#3-clonage-du-dépôt)
4. [Installation de Flutter](#4-installation-de-flutter)
5. [Installation de Visual Studio / C++](#5-installation-de-visual-studio--c)
6. [Vérification de l'environnement](#6-vérification-de-lenvironnement)
7. [Résolution des dépendances (flutter pub get)](#7-résolution-des-dépendances-flutter-pub-get)
8. [Compilation de l'application Windows](#8-compilation-de-lapplication-windows)
9. [Où installer les modèles IA](#9-où-installer-les-modèles-ia)
10. [Reconstruction des runtimes auxiliaires](#10-reconstruction-des-runtimes-auxiliaires)
11. [Ce qui n'est volontairement pas dans GitHub](#11-ce-qui-nest-volontairement-pas-dans-github)
12. [Résolution des erreurs fréquentes](#12-résolution-des-erreurs-fréquentes)
13. [Licences et mentions tierces](#13-licences-et-mentions-tierces)

---

## 1. Architecture du dépôt

Le monorepo regroupe le client Flutter et l'ensemble de ses dépendances natives directes sous une arborescence préservant les chemins relatifs :

```text
Jarvisol/
├── CrisperWeaver/               # Application Flutter principale (UI, services, state)
│   ├── lib/                     # Code source Dart (écrans, providers, services)
│   ├── packages/                # Plugins locaux (hotkey_manager_windows)
│   ├── scripts/                 # Scripts internes de packaging et de bundling de DLLs
│   ├── windows/                 # Runner Windows et configuration CMake du client
│   └── pubspec.yaml             # Manifeste des dépendances Dart/Flutter
├── CrispASR/                    # Moteur natif ASR/TTS (C++ / ggml) -> produit whisper.dll
│   ├── src/                     # Code C++ (Whisper, Qwen3-TTS, Kokoro, VAD, etc.)
│   └── flutter/crispasr/        # Bindings Dart FFI pour CrispASR
├── CrispEmbed/                  # Moteur natif d'embeddings & OCR -> produit crispembed.dll
│   ├── src/                     # Code C++ (BGE, MiniLM, ColBERT, DeiT math OCR)
│   └── flutter/crispembed/      # Plugin Flutter FFI pour CrispEmbed
├── glint/                       # Suite native de codecs audio légers -> produit glint.dll
│   ├── src/                     # Code C (décodeurs et encodeurs MP3, AAC, Opus, FLAC)
│   └── bindings/dart/           # Bindings Dart FFI pour glint
├── scripts/                     # Scripts d'automatisation racine
│   ├── verify_environment.ps1   # Diagnostic de la chaîne d'outils
│   ├── bootstrap.ps1            # Résolution des dépendances publiques
│   ├── build_windows.ps1        # Compilation complète native + Flutter
│   └── bootstrap_runtime.ps1    # Téléchargement optionnel des outils Web Media
├── docs/                        # Documentation détaillée
│   ├── PREREQUISITES_WINDOWS.md # Tableau exhaustif des prérequis
│   ├── TOOLCHAIN_VERSIONS.md    # Versions exactes testées
│   ├── MODEL_SETUP.md           # Guide de configuration des modèles IA
│   ├── MODELS_NOT_INCLUDED.md   # Justification de l'exclusion des poids
│   ├── SOURCE_MANIFEST.csv      # Inventaire complet des composants
│   └── THIRD_PARTY_NOTICES.md   # Licences et copyrights tiers
└── README.md                    # Ce document
```

---

## 2. Prérequis Windows

Pour compiler Jarvisol depuis les sources, les outils suivants sont requis sur votre machine :

- **Windows 10 ou 11 (64-bit)**.
- **Git for Windows** (v2.40+).
- **Flutter SDK** (v3.24+ sur canal `stable`, testé avec 3.47.0).
- **Visual Studio 2022** (Community ou supérieur) avec la charge **"Développement Desktop en C++"** (incluant MSVC v143, CMake et Windows 10/11 SDK).
- **PowerShell 5.1 ou PowerShell 7 (pwsh)**.

Pour les détails précis des versions, consultez [docs/PREREQUISITES_WINDOWS.md](docs/PREREQUISITES_WINDOWS.md) et [docs/TOOLCHAIN_VERSIONS.md](docs/TOOLCHAIN_VERSIONS.md).

---

## 3. Clonage du dépôt

Clonez le dépôt avec Git :

```powershell
git clone https://github.com/Dino19870/Jarvisol.git
cd Jarvisol
```

---

## 4. Installation de Flutter

Si Flutter n'est pas encore installé sur votre système :
1. Téléchargez Flutter sur [flutter.dev](https://docs.flutter.dev/get-started/install/windows).
2. Extrayez l'archive dans un dossier sans espace ni privilèges restreints (ex: `C:\src\flutter`).
3. Ajoutez le dossier `bin` de Flutter à votre variable d'environnement système `PATH`.
4. Exécutez `flutter doctor` pour valider l'installation.

---

## 5. Installation de Visual Studio / C++

1. Téléchargez et lancez le programme d'installation de Visual Studio 2022 Community.
2. Dans l'onglet **Charges de travail**, cochez **Développement Desktop en C++**.
3. Dans le panneau de droite, assurez-vous que les options suivantes sont cochées :
   - *Outils MSVC v143 - VS 2022 C++ x64/x86 build tools*
   - *SDK Windows 10 ou 11*
   - *Outils CMake C++ pour Windows*
4. Finalisez l'installation.

---

## 6. Vérification de l'environnement

À la racine du dépôt cloné, exécutez le script PowerShell de diagnostic :

```powershell
pwsh scripts/verify_environment.ps1
```

Ce script analyse votre PATH et votre registre Visual Studio pour confirmer que tous les compilateurs nécessaires sont prêts.

---

## 7. Résolution des dépendances (flutter pub get)

Exécutez le script d'initialisation :

```powershell
pwsh scripts/bootstrap.ps1
```

Ce script résout l'ensemble des paquets Dart/Flutter pour l'application principale et les plugins locaux du monorepo.

---

## 8. Compilation de l'application Windows

### A. Build Complet Portable (Recommandé)

Pour compiler l'intégralité du projet en mode Release complet (incluant les moteurs C++, l'application Flutter, les serveurs auxiliaires Python empaquetés et le runtime Web Media) :

```powershell
pwsh scripts/build_windows.ps1 release -FullRelease
```

Ce script automatise toutes les étapes nécessaires :
1. Configure et compile le moteur C++ **CrispASR** (`whisper.dll`, `crispasr.dll`).
2. Configure et compile le moteur C++ **CrispEmbed** (`crispembed.dll`).
3. Configure et compile la suite de codecs **glint** (`glint.dll`).
4. Compile l'application Flutter Windows (`crisper_weaver.exe` / `jarvisol.exe`).
5. Copie l'ensemble des bibliothèques dynamiques natives aux côtés de l'exécutable.
6. Compile et package les serveurs auxiliaires Python avec PyInstaller (`memory_server.exe`, `sd_server.exe`, `jarvisol_tray.exe`) et intègre le runtime Web Media portable (`yt-dlp`, `deno`, `ffmpeg`, `ffprobe`).

L'ensemble de la Release portable autonome est produit dans :
`CrisperWeaver\build\windows\x64\runner\Release\`

Vous pouvez démarrer l'application immédiatement :
```powershell
& "CrisperWeaver\build\windows\x64\runner\Release\jarvisol.exe"
```

### B. Build Minimal Développement (C++ & Flutter uniquement)

Si vous ne souhaitez pas recompiler les serveurs Python (qui peuvent être lancés directement via `python script.py`) :

```powershell
pwsh scripts/build_windows.ps1 release
```

---

## 9. Où installer les modèles IA

Jarvisol fonctionne sans connexion Internet grâce à des modèles locaux.
Pour éviter de saturer le dépôt GitHub, aucun modèle volumineux n'est versionné.

### 9.1 Modèles Audio & Langage (Whisper, TTS, Embeddings, LLM)
- **Option automatique (Recommandée)** : Lancez l'application et ouvrez l'écran **Gestion des Modèles**. Cliquez sur *Télécharger* en face du modèle désiré.
- **Option manuelle** : Consultez le guide général [docs/MODEL_SETUP.md](docs/MODEL_SETUP.md) pour connaître les répertoires cibles et les liens de chaque modèle.

### 9.2 Modèles d'Images & Retouche (Text-to-Image, Inpainting, IP-Adapter, Auto Face)
Le sous-système de génération et d'édition d'images utilise des modèles dédiés (`models/Stable-diffusion/` et `models/image_conditioning/`).
- **Guide complet & compatibilité** : Consultez [docs/IMAGE_MODELS_SETUP.md](docs/IMAGE_MODELS_SETUP.md) et le manifeste [docs/image_models_manifest.json](docs/image_models_manifest.json).
- **Téléchargement automatisé en 1 commande** :
  ```powershell
  # Afficher la liste des packs et modèles avec leur état local
  .\scripts\download_image_models.ps1 -List

  # Pack 1 : Génération rapide Text-to-Image Chroma Flash DiT (~7.94 Go)
  .\scripts\download_image_models.ps1 -Pack IMAGE_BASIC

  # Pack 2 : Retouche Inpainting simple SD 1.5 (~2.30 Go)
  .\scripts\download_image_models.ps1 -Pack IMAGE_INPAINT

  # Pack 3 : Composition Multi-Images & Transfert de Visage/Objet SD 1.5 (~4.85 Go)
  .\scripts\download_image_models.ps1 -Pack IMAGE_AUTO_FACE
  ```
  *Chaque fichier téléchargé est automatiquement validé par son empreinte cryptographique SHA-256 avant promotion.*

---

## 10. Reconstruction des runtimes auxiliaires

Les serveurs auxiliaires suivants sont écrits en Python et peuvent fonctionner directement en script ou compilés avec PyInstaller :
- **Serveur Stable Diffusion (`sd_server.py`)** : situé dans `CrisperWeaver/sd_server.py`.
- **Serveur Mémoire ChromaDB (`memory_server.py`)** : situé dans `CrisperWeaver/memory_server.py`.
- **Lanceur Tray (`jarvisol_tray.py`)** : situé dans `scripts/jarvisol_tray.py`.

Pour recompiler l'un de ces serveurs sous forme d'exécutable autonome :
```powershell
pip install pyinstaller -r requirements.txt
pyinstaller memory_server.spec
```

---

## 11. Ce qui n'est volontairement pas dans GitHub

Le dépôt GitHub a été purgé de tout élément confidentiel, temporaire ou lourd :
- Aucun poids de modèle IA (`*.gguf`, `*.safetensors`, `*.bin`, `*.pt`).
- Aucune donnée utilisateur privée (historiques de conversation, bases de documents RAG).
- Aucun secret, token d'accès ou mot de passe.
- Aucun fichier de build temporaire (`build/`, `.dart_tool/`, `*.pdb`).
- Aucun fichier de sauvegarde locale (`*.bak_*`).

Consultez [docs/MODELS_NOT_INCLUDED.md](docs/MODELS_NOT_INCLUDED.md) pour plus d'informations.

---

## 12. Résolution des erreurs fréquentes

- **Erreur `whisper.dll not found` ou code 126** :
  Assurez-vous que `scripts/build_windows.ps1` a été exécuté jusqu'au bout. Ce script copie les DLLs nécessaires dans le dossier du runner.
- **CMake introuvable** :
  Vérifiez que les composants C++ CMake sont bien installés dans Visual Studio Installer.
- **Dépendances Dart non résolues** :
  Exécutez `pwsh scripts/bootstrap.ps1` pour actualiser les packages locaux et distants.

---

## 13. Licences et mentions tierces

Jarvisol est distribué sous licence **GNU Affero General Public License v3 (AGPL-3.0)** pour son client principal, et ses bibliothèques sous licence **MIT**.
Consultez [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md) pour l'ensemble des notices de copyright.
