# CrisperWeaver — Leçons Apprises & Notes Techniques

> **LIRE CE FICHIER EN PRIORITÉ** avant de toucher au code.
> Il documente les bugs corrigés, les pièges confirmés, et les décisions architecturales critiques.

---

## ⚠️ NOTE PRIORITAIRE — À LIRE EN DÉBUT DE SESSION (27 août 2026)

**Contexte** : Dans la session du 26 août 2026, le code de `document_chat_widget.dart` a été corrompu lors de l'implémentation de la recherche de mots-clés. Une restauration depuis le backup `bak_20260826_0746` (datant du matin du 26 août) a été nécessaire.

**⚠️ PROBLÈME** : Ce backup ne contient pas forcément toutes les demandes et modifications demandées par l'utilisateur lors des 3-4 derniers jours précédant la session du 26 août.

### Action obligatoire en début de prochaine session

Avant tout travail sur `document_chat_widget.dart`, l'agent DOIT :

1. **Examiner l'historique des conversations** des 3-4 derniers jours (via transcripts de conversation ou NotebookLM)
2. **Lister toutes les demandes** concernant l'Assistant Documents qui ont été implémentées
3. **Vérifier** lesquelles sont présentes dans le fichier actuel restauré (`bak_20260826_0746`)
4. **Réappliquer** les éventuelles modifications manquantes, en les backupant correctement

### Fichier concerné
`D:\Antigravity\AgentFolder\CrisperWeaver\lib\widgets\document_chat_widget.dart`

### Backups disponibles pour comparaison
- `document_chat_widget.dart.bak_20260826_0746` — version du matin du 26 août (celle restaurée)
- `document_chat_widget.dart.bak_20260826_2344` — version avec tentatives de recherche (cassée)
- `document_chat_widget.dart.bak_broken_20260826_2351` — idem

---

## 🚨 RÈGLE ABSOLUE — Backup avant toute modification (26 août 2026)

**Contexte** : Le projet n'a pas de dépôt GitHub actif. Pas de filet de sécurité git disponible en cas d'erreur.

**Règle** : Avant de modifier TOUT fichier source existant, créer un backup horodaté :

```powershell
$ts = Get-Date -Format "yyyyMMdd_HHmm"
Copy-Item "<fichier.dart>" "<fichier.dart>.bak_$ts" -Force
```

Cette règle s'applique à **tous les fichiers**, même pour une modification mineure.

---

## 🐛 BUG CONFIRMÉ — GlobalKey dans SelectionArea → Crash au clic souris (26 août 2026)

**Symptôme** : App plante dès le premier clic souris dans l'**Assistant Documents** après ajout d'une recherche dans la conversation.

**Cause** : `GlobalKey` passé directement à `RepaintBoundary` ou `Align` **à l'intérieur d'un `SelectionArea`**. Flutter interdit le déplacement d'un `GlobalKey` entre positions dans l'arbre d'un `SelectionArea`.

**Fix** dans `document_chat_widget.dart` — utiliser `KeyedSubtree` comme wrapper **externe** dans l'`itemBuilder` :

```dart
Widget msgWidget = _buildUserMessage(...); // sans key dans la méthode
if (isActiveFind) {
  msgWidget = KeyedSubtree(key: _docFindKey, child: msgWidget);
}
return msgWidget;
```

`KeyedSubtree` est neutre vis-à-vis de `SelectionArea`. `Scrollable.ensureVisible` fonctionne toujours.

**Fichier** : `lib/widgets/document_chat_widget.dart`

---

## 📦 Architecture Générale

| Composant | Technologie | Chemin |
|---|---|---|
| UI | Flutter (Dart) | `lib/` |
| TTS on-device | CrispASR / CrispEmbed (DLL native) | `lib/native/crispembed_*.dart` |
| Modèles TTS | Qwen3-TTS, Kokoro, VibevoiceTTS, Clonage vocal | `lib/services/tts_service.dart` |
| Embeddings RAG | LM Studio (`text-embedding-qwen3-embedding-4b`) ou LiteRT | `lib/services/document_rag_service.dart` |
| Stockage | PortablePreferences (JSON), plus SharedPreferences | `lib/services/portable_preferences.dart` |
| Chemins app | AppPaths (portable, relatif à l'exe) | `lib/utils/app_paths.dart` |

---

## 🗂️ Système de Fichiers Portable

### Migration SharedPreferences → PortablePreferences (23 août 2026)

**Contexte** : L'app utilisait `shared_preferences` (registre Windows). Elle a été migrée vers `PortablePreferences` qui lit/écrit dans `Release\data\preferences.json` pour une portabilité totale.

**Fichier clé** : `lib/services/portable_preferences.dart`

**Règle absolue** : Ne jamais utiliser `SharedPreferences.getInstance()` directement. Toujours passer par `PortablePreferences` ou `SettingsService`.

**Structure de déploiement** :
```
Release\
├── crisper_weaver.exe          ← shell Flutter (petit, inchangé entre builds)
├── crispasr.dll, ggml.dll...   ← DLLs natives CrispASR
└── data\
    ├── app.so                  ← CODE DART compilé (mis à jour à chaque build)
    ├── preferences.json        ← TOUTES les préférences utilisateur
    ├── rag_cache\              ← Fichiers JSON d'embeddings indexés
    ├── models\                 ← Modèles TTS/STT locaux
    ├── history\                ← Historique des conversations
    ├── audiobooks\             ← Projets audiobooks
    ├── logs\                   ← crisperweaver.log, session.log
    └── flutter_assets\         ← Assets Flutter
```

**AppPaths** (à utiliser partout pour les chemins) :
```dart
AppPaths.dataDir        // → Release\data\
AppPaths.ragCacheDir    // → Release\data\rag_cache\
AppPaths.logsDir        // → Release\data\logs\
AppPaths.modelsDir      // → Release\data\models\
AppPaths.historyDir     // → Release\data\history\
AppPaths.audiobooksDir  // → Release\data\audiobooks\
AppPaths.imagesDir      // → Release\data\GeneratedImages\   ← images générées par Image MCP
```

> ⚠️ **Pièges de nommage AppPaths** :
> - `AppPaths.imagesDir` (PAS `generatedImagesDir` ni `imgDir`)
> - `AppPaths.ragCacheDir` (PAS `ragDir` ni `cacheDir`)

---

## 🐛 Bugs Corrigés — À Ne Pas Réintroduire

### BUG 1 — RAG cache path fantôme (23 août 2026)
**Fichier** : `lib/services/document_rag_service.dart` → `getEffectiveCacheDir()`

**Symptôme** : Document importé et indexé (LM Studio traite les embeddings) mais invisible dans la Bibliothèque RAG.

**Cause** : Quand `settings.ragCacheDirectory` est vide (cas normal après migration), le fallback construisait :
```dart
// AVANT (BUGUÉ) — créait un dossier fantôme
p.join(AppPaths.dataDir.path, 'CrisperWeaver', 'rag_cache')
// → Release\data\CrisperWeaver\rag_cache  ❌
```

**Fix** :
```dart
// APRÈS (CORRECT)
return AppPaths.ragCacheDir;  // → Release\data\rag_cache  ✅
```

**Vérification** : Après indexation, un fichier `<hash>_<model>.json` doit apparaître dans `Release\data\rag_cache\`.

---

### BUG 2 — Clone vocal sans WAV path dans le projet (23 août 2026)
**Fichier** : `lib/widgets/audiobook_studio_widget.dart` → `_initSampleProject()`

**Symptôme** : Erreur "Modèle non téléchargé : clone_1787502309975" lors de la prévisualisation audio dans le Studio Audiobook.

**Cause** : `_initSampleProject()` créait les speakers avec `voiceModelName = 'clone_xxx'` mais sans `customVoiceWavPath`. `_prepareSpeaker()` tombait dans le `else` final et cherchait un fichier `clone_xxx.gguf` inexistant.

**Fix** : Ajout de `_resolveClone(speaker)` dans `_initSampleProject()` qui cherche le profil `ClonedVoiceProfile` dans `settings.customClonedVoices` et injecte `customVoiceWavPath` + `customVoiceRefText`.

**Règle** : Les voix `clone_*` dans l'audiobook studio doivent TOUJOURS avoir `customVoiceWavPath` renseigné.

**Guard** dans `audiobook_service.dart` → `_prepareSpeaker()` : si `clone_*` sans WAV → `TtsLoadStatus.error()` explicite.

---

### BUG 3 — Dialogue de tuning vocal bloquant
**Fichier** : `lib/widgets/voice_tuning_dialog.dart`

**Symptôme** : UI figée après validation d'un profil de voix clonée.

**Fix** : `Navigator.pop()` immédiat avant `await saveClonedVoice()`. Sauvegarde en arrière-plan.

---

### BUG 4 — Clear context ne réinitialisait pas `_isStreaming`
**Fichier** : `lib/widgets/document_chat_widget.dart` → `_clearAllContext()`

**Symptôme** : Après un clear, l'UI restait dans l'état "en cours de génération".

**Fix** : Ajout de `_isStreaming = false` + `_streamSub?.cancel()` dans `_clearAllContext()`.

---

## 🎙️ Système de Clonage Vocal

### Stockage des profils
Clé `custom_cloned_voices` dans `preferences.json` (liste JSON de `ClonedVoiceProfile`).

Chaque profil :
- `id` : timestamp unique (ex: `1787502309975`)
- `name` : nom affiché (ex: `Melenchon_2`)
- `wavPath` : chemin absolu vers le `.wav` de référence
- `refText` : texte dit dans le WAV
- `defaultSpeed`, `defaultPitch`, `defaultVolume`

### Nomenclature voix → moteur TTS
```
clone_<id>   → customVoiceWavPath obligatoire → qwen3-tts-12hz-0.6b-base (zero-shot)
kokoro-*     → kokoro-82m-q8_0
vibevoice-*  → vibevoice-1.5b-tts-q4_k
qwen3-*      → qwen3-tts-12hz-0.6b-customvoice-q8_0 + qwenSpeakerMap
```

### Fonctionnalité relocalisation WAV (ajoutée 23 août 2026)
`_relocateClonedVoiceWav()` dans `audiobook_studio_widget.dart` :
- Bouton ✏️ dans le badge WAV du panneau Distribution
- Chemin rouge + icône 🔇 si le fichier est introuvable
- Met à jour `ClonedVoiceProfile.wavPath` dans prefs ET `customVoiceWavPath` du speaker

---

## 🏗️ Providers Riverpod importants

| Provider | Fichier |
|---|---|
| `settingsServiceProvider` | `services/settings_service.dart` |
| `ttsServiceProvider` | `services/tts_service.dart` |
| `documentRagServiceProvider` | `services/document_rag_service.dart` |
| `modelServiceProvider` | `services/model_service.dart` |

---

## ⚙️ Configuration Embeddings RAG

- **Modèle** : `text-embedding-qwen3-embedding-4b` via LM Studio sur `http://localhost:1234/v1`
- **Clé prefs** : `llm_embedding_model`
- L'autocomplete dans Settings peut proposer des modèles TTS à la place — entrer le nom manuellement.

---

## 📝 Notes pour la prochaine IA

1. **Lire ce fichier en premier**, puis `CHANGELOG.md`
2. **Ne pas ré-introduire SharedPreferences** : tout passe par `PortablePreferences`
3. **Toujours utiliser `AppPaths.*`** — ne jamais coder de chemin absolu ni `getApplicationDocumentsDirectory()`
4. **Tests** : 80 tests dans `test/` — lancer avant toute refacto
5. **Build** : `flutter build windows --release` depuis `CrisperWeaver/` → `build\windows\x64\runner\Release\`

---

## 🎨 Image MCP — sd_server.py (24 août 2026)

### Bugs résolus

| # | Bug | Fix |
|---|---|---|
| 1 | Dossier images fantôme `data\CrisperWeaver\GeneratedImages\` | → `AppPaths.imagesDir` = `data\GeneratedImages\` |
| 2 | PyInstaller `--onefile` : `SCRIPT_DIR` → `Temp\_MEIxxxxx\` | → `sys.executable` si `getattr(sys,'frozen',False)` |
| 3 | VAE Vulkan OOM (`ErrorOutOfDeviceMemory`) | → Retry adaptatif GPU→CPU via `--vae-on-cpu` |
| 4 | Chemins hardcodés `D:\Antigravity\...` dans `find_file()` | → Supprimés, `SCRIPT_DIR` seulement |

### Architecture sd_server.py

- **`find_file(name)`** : cherche dans `SCRIPT_DIR/models/Stable-diffusion/`, `SCRIPT_DIR/models/`, `SCRIPT_DIR/sd_vulkan/`
- **`_run_sd_cli(cmd, ...)`** : helper qui lance sd-cli et retourne `(bytes|None, log_str)`
- **`_is_vram_oom(log)`** : détecte `ErrorOutOfDeviceMemory`, `vae alloc compute buffer failed`, etc.
- **Logique retry** : FLUX → `--vae-on-cpu` permanent | SD1.x/SD3 → GPU d'abord, CPU si OOM détecté

### Recompilation PyInstaller

```powershell
# Toujours tuer sd_server.exe avant de recompiler !
Get-Process -Name "sd_server" | ForEach-Object { $_.Kill() }
pyinstaller --onefile --name sd_server --hidden-import PIL ... --distpath Release\ sd_server.py
```

### Temps de génération (AMD Ryzen AI 890M, VAE CPU)
- SD 1.5 Q4_0 (512×512, 4 steps) : ~52s (GPU sampling 5s + CPU VAE 46s)
- Sur GPU discret avec 8+ GB VRAM : ~8s (tout GPU, pas de retry)

---

## ⚠️ §15 — `flutter clean` DÉTRUIT tout le dossier Release

**Date :** 25 août 2026

### Problème
`flutter clean` supprime **entièrement** `build/windows/x64/runner/Release/`, y compris :
- `memory_server.exe`, `sd_server.exe` (exes tiers non versionnés)
- `jarvisol_tray.exe`, `windev_indexer.exe` (exes Python compilés)
- `launch_servers.vbs`, `windev_indexer.ini` (configs)
- `memory/memory_store.json` (données mémoire de l'assistant)

### Règle obligatoire avant tout `flutter clean`
```powershell
# TOUJOURS sauvegarder avant flutter clean !
$src = "D:\Antigravity\AgentFolder\CrisperWeaver\build\windows\x64\runner\Release"
$bak = "D:\Antigravity\AgentFolder\_release_backup_$(Get-Date -f yyyyMMdd_HHmm)"
Copy-Item $src $bak -Recurse
Write-Host "Backup : $bak"
```

### Rebuild après flutter clean
1. `flutter build windows --release` → recrée `jarvisol.exe` + DLLs Flutter
2. Recompiler `jarvisol_tray.exe` (PyInstaller depuis `jarvisol_tray.py`)
3. Recompiler `windev_indexer.exe` (PyInstaller depuis `windev_indexer.py`)
4. Recréer `launch_servers.vbs` et `windev_indexer.ini`
5. **Recopier manuellement** `memory_server.exe` et `sd_server.exe` depuis leur source

### Renommage app (crisper_weaver → jarvisol)
- Nécessite `flutter clean` + rebuild complet (CMake cache incompatible sinon)
- `windows/CMakeLists.txt` : `set(BINARY_NAME "jarvisol")`
- `pubspec.yaml` : `name: jarvisol`
- `lib/main.dart` : `title: 'Jarvisol'`

*Dernière mise à jour : 25 août 2026 (soir) — Session Antigravity/Gemini*

---

## 🔴 §16 — Post-flutter clean : Fichiers corrompus / manquants (25 août 2026 — soir)

> **Contexte :** Suite à un `flutter clean` + rebuild, plusieurs fichiers DLL et de config étaient 0 KB ou manquants.
> Récupérés via Autopsy (export forensique) dans :
> - `C:\Users\lansa\Downloads\AUTOPSYE\CAS 1\Export\`
> - `C:\Users\lansa\Downloads\AUTOPSYE\CAS 2\Export\`

### 🐛 BUG A — `sd_server.exe` corrompu (PyInstaller PKG archive manquante)

**Symptôme :** `[PYI-4312:ERROR] Could not load PyInstaller's embedded PKG archive`

**Cause :** Le fichier `sd_server.exe` récupéré par Autopsy était tronqué (~11 MB au lieu de 27 MB).

**Fix :** Recompiler depuis le source `sd_server.py` (toujours présent) :
```powershell
python -m PyInstaller --onefile --console --name sd_server `
    --hidden-import=PIL --hidden-import=PIL.Image `
    --distpath "$rel" sd_server.py
```

---

### 🐛 BUG B — `ggml-vulkan.dll` version incompatible → crash ACCESS VIOLATION

**Symptôme :**
```
Module défaillant : ggml-vulkan.dll
Exception code: 0xc0000005 (ACCESS VIOLATION)
Fault offset: 0x0000000000007dcd
```
L'app (`jarvisol.exe`) crashait **systématiquement ~15 secondes** après le démarrage, lors du chargement du modèle Whisper par `crispasr.dll`.

**Cause :** La `ggml-vulkan.dll` copiée depuis `sd_vulkan/` (version Stable Diffusion, 48 MB) est **incompatible** avec `whisper.dll` (APIs GGML différentes).

**Fix :** Remplacer par la version whisper.cpp depuis le cache lemonade :
```powershell
$src = "C:\Users\lansa\.cache\lemonade\bin\whispercpp\vulkan\ggml-vulkan.dll"  # 54 MB
Copy-Item $src "$rel\ggml-vulkan.dll" -Force
# Garder l'ancienne en .sd_version pour sd_server si besoin
```

> ⚠️ **Règle :** Ne JAMAIS copier `sd_vulkan\ggml-vulkan.dll` dans le root Release.
> CrispASR/Whisper a besoin de la version `lemonade\bin\whispercpp\vulkan\ggml-vulkan.dll`.

---

### 🐛 BUG C — `default_model` réinitialisé à `vibevoice-voice-emma` → transcription échoue

**Symptôme :**
```
ERR [crispasr] Transcription failed :: crispasr_session_transcribe_chunked returned null
INF [crispasr] transcribe start model=vibevoice-voice-emma backend=session
```

**Cause :** `preferences.json` `default_model` était `vibevoice-voice-emma` (TTS) au lieu de `large-v3-turbo` (ASR Whisper). Le Studio Audiobook avait chargé la session vibevoice en dernier, et elle a été réutilisée pour la transcription.

**Fix :**
```powershell
$p = Get-Content "$rel\data\preferences.json" -Raw | ConvertFrom-Json
$p.default_model = "large-v3-turbo"
$p | ConvertTo-Json -Depth 20 | Set-Content "$rel\data\preferences.json" -Encoding UTF8
```
**Valeur correcte :** `default_model = "large-v3-turbo"`, `default_backend = "whisper"`

**Source vérité :** Autopsy `CAS 2\Export\CrisperWeaver\build\windows\x64\runner\Debug\data\preferences.json`

---

### 🐛 BUG D — `credentials.json` Gmail = 0 KB → Gmail silencieusement vide

**Symptôme :** L'outil Gmail semble "activé" (logs "token rafraîchi") mais le LLM répond qu'il ne peut pas lire les mails. Aucun log `[mcp_tools] Gmail:` pour les résultats.

**Cause :** `mcp_servers/gmail/credentials.json` vidé à 0 octets par flutter clean. Le `gcp-oauth.keys.json` existait encore (client_id/secret), d'où les faux "token rafraîchi". Mais sans `refresh_token` dans `credentials.json`, aucun email n'était récupérable.

**Fix :** Restaurer depuis Autopsy :
```powershell
$src = "C:\Users\lansa\Downloads\AUTOPSYE\CAS 2\Export\CrisperWeaver\build\windows\x64\runner\Release\mcp_servers\gmail\credentials.json"
# Restaurer dans les 3 emplacements :
Copy-Item $src "$rel\mcp_servers\gmail\credentials.json" -Force
Copy-Item $src "$rel\data\mcp_servers\gmail\credentials.json" -Force
Copy-Item $src "D:\Antigravity\AgentFolder\CrisperWeaver\mcp_servers\gmail\credentials.json" -Force
```

**Structure correcte credentials.json** : doit contenir `access_token`, `refresh_token`, `scope`, `token_type`, `expiry_date`.

> ⚠️ `mcp_servers/` est dans **Release root** (pas dans `data/`). `AppPaths` ne le gère pas — versionner ces fichiers séparément !

---

### 📁 Emplacements Autopsy de référence (à conserver jusqu'au ~1er septembre 2026)

| Fichier | Source Autopsy |
|---|---|
| `credentials.json` Gmail | `CAS 2\Export\...\Release\mcp_servers\gmail\credentials.json` |
| `preferences.json` (original) | `CAS 2\Export\...\Debug\data\preferences.json` |
| `ggml-vulkan.dll` whisper | `C:\Users\lansa\.cache\lemonade\bin\whispercpp\vulkan\` |
| Sources Python (`sd_server.py`) | Toujours dans `Release\` → recompiler si exe corrompu |

---

*Dernière mise à jour : 25 août 2026 (22h07) — Session Antigravity/Gemini*

---

## 🖼️ LiteRT — Vision, Chemin Portable, Sélecteur (26 août 2026)

### Modèles LiteRT installés et capacités vision

| ID | Vision | Audio | GB |
|---|---|---|---|
| `gemma-3n-e2b-it` | ✅ vision_adapter + vision_encoder | ✅ audio_adapter | 3.4 |
| `gemma-4-e4b-it` | ❌ (isMultimodal dans allowlist mais pas de vision_encoder) | ❌ | 2.8 |
| `gemma-4-12B-it-gpu` | ❌ | ❌ | 5.6 |
| `gemma-4-gpu` | ❌ | ❌ | 1.9 |
| `deepseek-r1-distill-qwen-1.5b` | ❌ | ❌ | 1.7 |
| `qwen-2.5-1.5b-instruct` | ❌ | ❌ | 1.5 |
| `tiny-garden-270m` | ❌ | ❌ | 0.28 |

**→ Seul `gemma-3n-e2b-it` supporte vraiment la vision** (et l'audio).

Vérification : `~/.litert-lm/models/<id>/` — chercher les fichiers `vision_adapter.xnnpack_cache`.

### Chemin Portable LiteRT — USERPROFILE Override

**Technique** : litert-lm v0.16.0 utilise `$USERPROFILE/.litert-lm/` pour tout.
En surchargeant `USERPROFILE` au lancement, on redirige vers le dossier portable.

**Chemin portable** : `Release/data/litert_home/` (géré par `AppPaths.litertHomeDir`)

**Structure** :
```
Release/data/litert_home/
└── .litert-lm/
    └── models/
        ├── gemma-3n-e2b-it/model.litertlm   ← vision + audio
        ├── gemma-4-e4b-it/model.litertlm
        └── ...
```

**Code clé** (dans `llm_service.dart → _ensureWindowsServerRunning()`) :
```dart
final env = Map<String, String>.from(Platform.environment)
  ..['USERPROFILE'] = AppPaths.litertHomeDir.path;
_litertProcess = await Process.start(exe, ['serve', '--port', '9379'], environment: env);
```

**Helper** : `LlmService.runLitertCli(['list'])` lance litert-lm avec le bon USERPROFILE pour les commandes CLI (import, list, etc.).

**Migration des modèles** : Copie unique de `C:\Users\lansa\.litert-lm\models\` → `Release\data\litert_home\.litert-lm\models\`. Effectuée le 26/08/2026.

### Sélecteur de Modèles LiteRT

**Bug** : `syncWithSelectedProvider('local_litert_windows')` ne vidait pas `dialogModels` → les modèles LM Studio/cloud restaient dans la liste.

**Fix** (dans `llm_settings_dialog.dart → syncWithSelectedProvider`) :
```dart
dialogModels
  ..clear()
  ..addAll(LiteRtModelRegistry().models.where((m) => m.isDownloaded).map((m) => m.id));
```

### refreshLocalStatus() — Détection des modèles installés

**Bug original** : scan `recursive: false` → les modèles dans leurs sous-dossiers (`models/<id>/model.litertlm`) n'étaient JAMAIS détectés.

**Fix** : utilisation de `LlmService.runLitertCli(['list'])` (avec USERPROFILE portable) pour obtenir la liste canonique des modèles installés. Fallback : scan des sous-dossiers de `AppPaths.litertModelsDir`.

**Clé de matching** : désormais par `entry.id` (ex: `gemma-3n-e2b-it`) et non par `entry.filename` (`model.litertlm`).

### Téléchargement de nouveaux modèles

Les téléchargements via `startDownload()` dans `litert_model_registry.dart` utilisent maintenant le chemin portable. À vérifier que `targetDir` pour Windows pointe vers `AppPaths.litertModelsDir`.

---

*Dernière mise à jour : 26 août 2026 (09h00) — Session Antigravity/Gemini*

---

## 🔴 §17 — ProcessStartMode.detachedWithStdio → "Bad state: Process is detached" (31 août 2026)

### Symptôme
```
LiteRT runtime source=portable
LiteRT PID=<pid>
Bad state: Process is detached
```
Crash immédiat à chaque première requête LiteRT, depuis le Release original et depuis C:\Temp\JarvisolPortableTest.

### Cause
`_ensureWindowsServerRunning()` dans `llm_service.dart` utilisait :
```dart
mode: ProcessStartMode.detachedWithStdio,
```
Sur Windows, ce mode expose `stdout`/`stderr` via pipes **mais interdit l'accès à `.exitCode` et `.pid`** — ils lèvent `StateError: Process is detached`.

La ligne fautive était **L461** :
```dart
_litertProcess!.exitCode.then((code) { ... }).ignore(); // ← StateError ici
```

### Fix (L432 dans llm_service.dart)
```dart
// AVANT (BUGUÉ)
mode: ProcessStartMode.detachedWithStdio,

// APRÈS (CORRECT)
mode: ProcessStartMode.normal,
```

**Pas de fenêtre console** : Jarvisol est compilé en subsystème `WINDOWS_GUI` (vérifié sur le PE header). `ProcessStartMode.normal` depuis un processus GUI ne déclenche pas `CREATE_NEW_CONSOLE`. Aucune fenêtre parasite pour l'utilisateur.

**Ownership préservé** : PID, stdout, stderr, exitCode, taskkill /T /F — tout fonctionne avec `.normal`.

### Test de non-régression
`T7` dans `test/litert_server_windows_test.dart` — vérifie que `.pid` et `.exitCode.then()` sont accessibles sans `StateError` avec `ProcessStartMode.normal`.

### Règle
Ne JAMAIS utiliser `ProcessStartMode.detachedWithStdio` pour un process dont on a besoin de superviser le cycle de vie (exitCode, PID, kill) sur Windows.

---

*Dernière mise à jour : 31 août 2026 (22h30) — Session Antigravity/Gemini*

---

## 🔴 §18 — Vision LiteRT Windows — B1 Routing + B3 Guard + B4 Badge (1er septembre 2026)

### Symptôme

```
RuntimeError: INVALID_ARGUMENT: Vision executor should not be null,
please TryLoadingVisionExecutor() first.
```
Se reproduisait systématiquement avec `gemma-3n-e4b-it` dans Assistant Documents → Ctrl+V image.

### B1 — Routing Vision (CRITIQUE)
**Fichier** : `lib/services/llm_service.dart`  
**Cause** : `contains('e4b')` catch-all routait `gemma-3n-e4b-it` → `gemma-4-e4b-it` (modèle texte sans vision).  
**Fix** : Extraction de `resolveWindowsModelId()` static — clauses `startsWith('gemma-3n-')` prioritaires.  
**Preuve log avant** : `résolu="gemma-4-e4b-it"` / **après** : `résolu="gemma-3n-E4B-IT"` ✅  
**Tests** : `test/litert_routing_test.dart` — 18/18 PASS  
**Backup** : `llm_service.dart.bak_20260901_1127`

> ⚠️ **Modèles Vision installés** (mise à jour) :
> - `gemma-3n-e4b-it` ✅ vision (4,6 GB) — résolu en `gemma-3n-E4B-IT`
> - `gemma-3n-e2b-it` ✅ vision (3,4 GB)
> - `gemma-4-e4b-it` ❌ texte seul
> - `gemma-4-gpu` ❌ texte seul

### B2 — Cold-start Vision
**Conclusion** : Faux problème — conséquence directe de B1. Une fois le routing corrigé, le serveur
charge le bon modèle multimodal et génère les caches vision automatiquement.  
**Caches** : `vision_adapter.xnnpack_cache` + `vision_encoder_*_mldrift_program_cache.bin` → générés en ~5 min.

### B3 — Garde Vision pré-envoi
**Fichier** : `lib/widgets/document_chat_widget.dart` → méthode `_sendVisionMessage()`  
**Fix** : Vérification `LiteRtModelEntry.hasVisionEncoder(resolvedId)` avant tout `setState` ou appel serveur.  
Si false → SnackBar orange *"⚠️ Le modèle X ne supporte pas Vision"* + `return` immédiat.  
**Backup** : `document_chat_widget.dart.bak_20260901_1142`

### B4 — Badge "Actif" dans le Catalogue
**Fichier** : `lib/widgets/llm_settings_dialog.dart`  
**Fix 1** : Badge teal "⚡ Actif" conditionnel sur `m.id == settings.llmModel` dans la liste Catalogue.  
**Fix 2** : Ordre `setDialogState → Navigator.pop → onModelChanged` pour synchronisation immédiate.  
**Backup** : `llm_settings_dialog.dart.bak_20260901_1146`

### Test 2 — OCR Image Importée (séparation Importer / Ctrl+V)
**Résultat** : PASS — deux chemins 100% distincts confirmés par log.
```
Importer .png → [ocr] Windows.Media.Ocr (WinRT offline) → DocumentSource → RAG
Ctrl+V image  → _sendVisionMessage() → Vision LiteRT (avec garde B3 si modèle non-vision)
```
**Log preuve** : `INF [ocr] OCR Windows réussi sur "test_ocr_jarvisol.png" (372 caractères extraits)` — zéro `[llm]` pendant l'import.

---

## 🔧 NotebookLM — Méthode d'archivage + ré-authentification (1er septembre 2026)

### Séquence correcte si token expiré (erreur 401 / stale)

**Étape 1 — Utilisateur** (terminal ouvert manuellement, PAS via l'agent) :
```powershell
nlm login
# Chrome s'ouvre → connexion Google → tokens écrits dans ~\.config\nlm\
```

**Étape 2 — Agent** (après confirmation de l'utilisateur) :
```
mcp_NotebookLM_refresh_auth   ← recharge les tokens depuis le disque
```

> ⚠️ `refresh_auth` seul ne suffit pas — il recharge depuis le disque mais ne peut pas
> renouveler un token expiré sans que `nlm login` ait d'abord écrit de nouveaux tokens.
> Les deux étapes sont obligatoires dans cet ordre.

### Upload d'archive

**Script** : `upload_memories.py` ou directement :
```powershell
$uvx = "c:\users\lansa\.local\bin\uvx.exe"
& $uvx --from notebooklm-mcp-cli nlm source add <notebook_id> `
    --file <fichier.md> --title "<titre>"
```

**Carnets** :
- Antigravity Mémoire : `c57d5503-eaba-4300-8436-92dfb1b4ed19`
- MyAutonomousAgent  : `d39378c4-4fdd-4a44-8678-59a3d542fd64`

---

*Dernière mise à jour : 1er septembre 2026 (17h30) — Session Antigravity/Gemini*

---

## ✅ BLOC VALIDÉ — Vision / OCR / Image / Inpainting (01/09/2026 — 19h46)

> **CE BLOC EST GELÉ.** Ne pas modifier sauf nouvelle anomalie de non-régression confirmée.

### Périmètre validé

- `sd_server.py` + `sd_server.exe` (recompilé 01/09 18:23)
- `inpaint_editor_dialog.dart`
- `mcp_tools_service.dart` (`listAvailableImageModels`)
- `settings_service.dart` (`activeInpaintModel`)
- `document_chat_widget.dart` (2 call-sites InpaintEditorDialog)

### Corrections de la session

#### P0 — Suppression fallback PIL silencieux (`sd_server.py`)
- `generate_fallback_art()` → `RuntimeError` explicite dans 3 sites de `run_inpaint_sd_cpp()`
- **Règle** : ne JAMAIS retourner une image PIL muette sans signaler l'erreur

#### P1 — Scan `sd_vulkan/` (`sd_server.py`)
- `scan_available_models()` et `find_vae_for_sd1x()` cherchent maintenant aussi dans `sd_vulkan/`
- Résultat : 7 modèles détectés (dont 3 INPAINT, 4 T2I)

#### P2 — Sélecteur dual modèle + persistance
- Nouveau endpoint `GET /v1/models/image` → `[{name, type, is_inpainting}]`
- `InpaintEditorDialog` : 2 dropdowns distincts, `savedInpaintModel`/`savedGenModel`, `onModelChanged`
- `SettingsService` : clé `active_inpaint_model` (indépendante de `active_image_model`)
- SharedPreferences : `flutter.active_image_model` ≠ `flutter.active_inpaint_model`

#### P3/P4 — Dialogs natifs file_picker v12 ⚠️ BREAKING CHANGE
- **file_picker v12** : classe `abstract final`, **méthodes statiques directes**
- `FilePicker.platform.pickFiles()` → **supprimé** → utiliser `FilePicker.pickFile()`
- `FilePicker.platform.saveFile()` → **supprimé** → `FilePicker.saveFile(bytes: required)`
- `saveFile` v12 écrit le fichier lui-même — NE PAS écrire manuellement après

#### listAvailableImageModels v2 (`mcp_tools_service.dart`)
- `/sdapi/v1/sd-models` → `/v1/models/image` avec filtre `is_inpainting == false`
- Le serveur fait autorité (`discovered.clear()` avant d'ajouter les résultats)
- Filtre lexical `inpaint` sur le scan dossier (filet de secours si serveur injoignable)
- Guard stale `active_image_model` : si la valeur sauvegardée n'est plus dans la liste filtrée → reset sur `imageModels.first` (déjà présent dans `llm_settings_dialog.dart` lignes 122-123 et 207-208)

### Architecture résultante

```
Sélecteur Settings "Modèle Image (.safetensors actif)"
    → listAvailableImageModels() → /v1/models/image (is_inpainting==false)
    → 4 modèles : flux1-schnell, sd3.5_turbo, sd_turbo, sd1.5
    → persiste dans flutter.active_image_model

Éditeur Inpainting — dropdown "Inpainting"
    → _fetchAvailableModels() → /v1/models/image (is_inpainting==true)
    → 3 modèles : RV6_inpainting, RV6_inpainting_fp16, sd1.5-inpainting
    → persiste dans flutter.active_inpaint_model

Les deux clés sont INDÉPENDANTES.
```

### Preuves de validation (log sd_server)

```
[Neural Image Engine] [4a8e00c3] Modele : "sd1.5-Q4_0.gguf" (type:sd1x) → OK SD1X VAE GPU
[Inpaint] [5db7e28b] Modele : stable-diffusion-v1-5-inpainting-Q4_0.gguf → OK (GPU)
```
Aucun `generate_fallback_art` dans les logs de session.

### Test de non-régression

Script : `brain/.../scratch/test_model_filter.py`
```
TEST 1 PASS : /v1/models/image retourne 7 modeles (attendu 7)
TEST 2 PASS : 4 modeles text-to-image apres filtre (attendu 4)
TEST 3 PASS : Aucun modele inpainting expose dans text-to-image
TEST 4 PASS : Les 4 modeles text-to-image attendus sont exactement presents
TEST 5 PASS : Guard stale active_image_model → reset sur flux1-schnell-Q4_K_S.gguf
```

---

## RAG Phase 1 — Clôture avec réserve mineure (02/09/2026)

### ✅ Livraison validée

- Nouveau fichier : `lib/services/embedding_provider.dart` (EmbeddingProvider, EmbeddingProviderConfig, RagRetrievalMode)
- Cache v2 : clé `<hash>_<provider>_<model>_d<dim>_v2.json` (dim=0 → sans _dNNN au premier run)
- Métadonnées JSON : cacheVersion, embeddingProvider, embeddingModel, embeddingDimension
- Double validation dimension au chargement : config-side ET metadata-side
- Quarantaine FormatException/FileSystemException → `.corrupt`
- Écriture atomique tmp→flush→rename (loadFromCache, saveChunksToCache, updateCachedDocumentCategory)
- Barre statut RAG : badge mode adaptatif (Hybride/Sémantique/BM25/Positionnel + orange si dégradé)
- Probe /v1/embeddings dans les settings (bloquant si incompatible, warning si unreachable)
- 21/21 tests ✅ · Build Release ✅ (82s)

### Format de clé v2 — règle exacte

```
dimension == 0  →  <hash>_<provider>_<model>_v2.json           (run 0, dim inconnue)
dimension > 0   →  <hash>_<provider>_<model>_d<dim>_v2.json    (run 1+, après persistence)
```

Test utilisateur confirmé : les nouveaux documents produisent bien `..._d2560_v2.json`.

---

### INC-RAG-MIGRATION-LEGACY — Mineur / Non bloquant

**Symptôme observé :** la migration automatique `..._v2.json` → `..._d2560_v2.json`
(étape 1b du fallback dimension-agnostic dans `loadFromCache`) n'a pas été observée
lors de la réouverture du document de test initial.

**Cause probable :** le fichier sans `_d2560` a été produit dans une session de test et
`settings.embeddingDimension` n'était pas encore persisté au moment du test de migration.
Le fallback est présent dans le code et les tests passent, mais n'a pas pu être confirmé
en conditions réelles lors de cette session.

**Décision :** CLASSÉ SANS SUITE pour cette phase.

**Raisons :**
- Les caches concernés sont des données de test, pas des données utilisateur
- Les nouvelles indexations utilisent déjà le format canonique `_d2560_v2.json`
- L'utilisateur prévoit de vider entièrement le cache RAG à la stabilisation de l'app
- Aucune dégradation du nouveau format n'est observée
- Aucune donnée source utilisateur affectée

**Action future :** si nécessaire, un `flutter test --update-goldens` de bout en bout
avec fichier de préférences pré-rempli (`embeddingDimension=2560`) permettrait de
valider le chemin de migration. À traiter en Phase 2 si le comportement est encore
observable après nettoyage du cache.

**Fichiers concernés :**
- `lib/services/document_rag_service.dart` — méthode `loadFromCache`, étape 1b
- `build/windows/x64/runner/Release/data/rag_cache/f4adf920..._lmStudio_..._v2.json`
