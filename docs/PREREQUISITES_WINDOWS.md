# Prérequis Logiciels Windows

Ce document sépare strictement les outils que vous devez **installer sur votre PC** de ceux qui sont **fournis ou gérés automatiquement par Jarvisol**.

---

## 1. À INSTALLER SUR LE PC (Outils Hôte Développeur)

| Logiciel | Obligatoire ? | Pour quel composant ? | Version minimum | Version testée | Lien d'installation | Commande de vérification |
| :--- | :---: | :--- | :--- | :--- | :--- | :--- |
| **Git for Windows** | **OUI** | Clone du code, gestion monorepo | 2.40.0+ | 2.55.0 | [git-scm.com](https://git-scm.com/) | `git --version` |
| **Flutter SDK** | **OUI** | Application Jarvisol (CrisperWeaver) | 3.24.0+ | 3.47.0 | [docs.flutter.dev](https://docs.flutter.dev/get-started/install/windows) | `flutter --version` |
| **Visual Studio 2022** | **OUI** | Compilation native C++ (Runner, CrispASR, CrispEmbed, glint) | 2022 (17.8+) | 17.14 | [visualstudio.microsoft.com](https://visualstudio.microsoft.com/) | `vswhere -latest -products *` |
| **C++ CMake tools** | **OUI** | Compilation CMake (inclus dans VS) | 3.28+ | 3.31.6 | Inclus dans VS (Desktop C++) | `cmake --version` |
| **Windows 10/11 SDK** | **OUI** | Headers API Windows (inclus dans VS) | 10.0.19041 | 10.0.26100 | Inclus dans VS (Desktop C++) | Détecté par VS |
| **Python 3.11** | **OPTIONNEL** | Seulement si recompilation des serveurs auxiliaires (`sd_server.exe`, `memory_server.exe`) | 3.10+ | 3.11.15 | [python.org](https://www.python.org/) | `python --version` |

---

## 2. FOURNI OU TÉLÉCHARGÉ PAR JARVISOL (Non requis sur l'hôte)

Ces composants ne nécessitent **aucune installation système globale**. Ils fonctionnent en mode portable dans le dossier de l'application ou sont téléchargés par le script `scripts/bootstrap_runtime.ps1` :

| Composant | Rôle | Statut d'installation hôte | Mode d'intégration |
| :--- | :--- | :---: | :--- |
| **Node.js** | Non requis sur l'hôte | **NON REQUIS** | Non utilisé ou embarqué localement si un serveur MCP l'exige. |
| **Deno** | Exécution JS sans Node pour extracteurs Web Media | **NON REQUIS** | Binaire autonome dans `runtime/web_media/deno.exe`. |
| **FFmpeg & ffprobe** | Extraction et conversion audio/vidéo Web Media | **NON REQUIS** | Binaires autonomes dans `runtime/web_media/`. |
| **yt-dlp** | Téléchargement et métadonnées Web Media | **NON REQUIS** | Binaire autonome dans `runtime/web_media/yt-dlp.exe`. |
| **LiteRT LLM** | Moteur LLM local Google | **PORTABLE** | Embarqué sous `runtime/litert_lm/` lors de la publication. |
| **Modèles IA** | Poids ASR, TTS, Embeddings, LLM | **TÉLÉCHARGEMENT À LA DEMANDE** | Téléchargés directement via l'interface de l'application (voir `MODEL_SETUP.md`). |
