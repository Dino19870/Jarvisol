# Prérequis Logiciels Windows

Ce document sépare strictement les outils que vous devez **installer sur votre PC** de ceux qui sont **fournis ou gérés automatiquement par Jarvisol**.

---

## 1. À INSTALLER SUR LE PC (Outils Hôte Développeur)

### A. Chaîne de Compilation Principale (C++ & Flutter)

| Logiciel | Obligatoire ? | Pour quel composant ? | Version minimum | Version testée | Lien d'installation | Commande de vérification |
| :--- | :---: | :--- | :--- | :--- | :--- | :--- |
| **Git for Windows** | **OUI** | Clone du code, gestion monorepo | 2.40.0+ | 2.55.0 | [git-scm.com](https://git-scm.com/) | `git --version` |
| **Flutter SDK** | **OUI** | Application Jarvisol (CrisperWeaver) | 3.24.0+ | 3.47.0 | [docs.flutter.dev](https://docs.flutter.dev/get-started/install/windows) | `flutter --version` |
| **Visual Studio 2022** | **OUI** | Compilation native C++ (Runner, CrispASR, CrispEmbed, glint) | 2022 (17.8+) | 17.14 | [visualstudio.microsoft.com](https://visualstudio.microsoft.com/) | `vswhere -latest -products *` |
| **C++ CMake tools** | **OUI** | Compilation CMake (inclus dans VS) | 3.28+ | 3.31.6 | Inclus dans VS (Desktop C++) | `cmake --version` |
| **Ninja** | **OUI** | Générateur de build C++ rapide (inclus dans VS) | 1.10+ | 1.12.1 | Inclus dans VS (Desktop C++) | `ninja --version` |
| **Windows 10/11 SDK** | **OUI** | Headers API Windows (inclus dans VS) | 10.0.19041 | 10.0.26100 | Inclus dans VS (Desktop C++) | Détecté par VS |

### B. Outils Requis pour une Full Release Portable (`-FullRelease`)

Pour produire une Release portable complète incluant la mémoire persistante (`memory_server.exe`), la génération d'images SD locale (`sd_server.exe`) et le lanceur tray (`jarvisol_tray.exe`), Python et PyInstaller sont **OBLIGATOIRES** :

| Logiciel | Statut Full Release | Pour quel composant ? | Version minimum | Version testée | Lien d'installation | Commande de vérification |
| :--- | :---: | :--- | :--- | :--- | :--- | :--- |
| **Python 3.11** | **OBLIGATOIRE (Full Release)** | Compilation des serveurs auxiliaires (`memory_server`, `sd_server`, `jarvisol_tray`) | 3.10+ | 3.11.15 | [python.org](https://www.python.org/) | `python --version` |
| **PyInstaller** | **OBLIGATOIRE (Full Release)** | Packaging standalone des scripts Python en `.exe` | 6.0+ | 6.22.2 | `pip install pyinstaller` | `pyinstaller --version` |

*Note* : Pour un build minimal de développement Flutter seul, Python et PyInstaller sont optionnels.

---

## 2. FOURNI OU TÉLÉCHARGÉ PAR JARVISOL (Non requis sur l'hôte)

Ces composants ne nécessitent **aucune installation système globale**. Ils fonctionnent en mode portable dans le dossier de l'application ou sont téléchargés et vérifiés automatiquement par le script `scripts/bootstrap_runtime.ps1` :

| Composant | Rôle | Statut d'installation hôte | Mode d'intégration |
| :--- | :--- | :---: | :--- |
| **Node.js** | Non requis sur l'hôte | **NON REQUIS** | Remplacé par Deno autonome pour Web Media ; zéro dépendance Node sur le système hôte. |
| **Deno** | Exécution JS sans Node pour extracteurs Web Media | **NON REQUIS** | Binaire autonome dans `runtime/web_media/deno.exe` (v2.9.6). |
| **FFmpeg & ffprobe** | Extraction et conversion audio/vidéo Web Media | **NON REQUIS** | Binaires autonomes dans `runtime/web_media/` (v8.0). |
| **yt-dlp** | Téléchargement et métadonnées Web Media | **NON REQUIS** | Binaire autonome dans `runtime/web_media/yt-dlp.exe` (2026.08.19). |
| **LiteRT LLM** | Moteur LLM local Google | **PORTABLE** | Embarqué sous `runtime/litert_lm/` lors de la publication. |
| **Modèles IA** | Poids ASR, TTS, Embeddings, LLM | **TÉLÉCHARGEMENT À LA DEMANDE** | Téléchargés directement via l'interface de l'application (voir `MODEL_SETUP.md`). |
