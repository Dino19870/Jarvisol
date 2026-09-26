# JARVISOL — VOICE I/O R1a : DÉPLOIEMENT DE L'INSTANCE UTILISATEUR DE TEST

**Date :** 24 septembre 2026  
**Auteur :** Antigravity (WindevBot / Jarvisol Agent)  
**Baseline témoin :** `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2`  
**Instance de test utilisateur :** `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST`  
**Dépôt source :** `D:\Antigravity\AgentFolder\CrisperWeaver`  

---

## 1. IDENTITÉ DE L'INSTANCE DE TEST

| Propriété | Valeur |
|---|---|
| **Chemin absolu** | `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST\` |
| **Exécutable de test** | `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST\jarvisol.exe` |
| **Mode d'isolation** | Jonctions NTFS (dossiers volumineux immuables) + Copies physiques étanches (fichiers mutables) |
| **Taille apparente (logique)** | ~120,5 Go |
| **Espace disque réel consommé** | **655,90 Mo (0,641 Go)** |
| **Économie disque réalisée** | **99,46%** d'économie (119,7 Go épargnés) |

---

## 2. PREUVE FORMELLE DU SANCTUAIRE `Final_v2` (0 MODIFICATION)

Le répertoire de référence témoin `Jarvisol_V1_POST_GEL_Final_v2` a été audité avant et après la création de l'instance TEST :

| Fichier / Métrique | Valeur Baseline Initiale | Valeur Finale Post-Déploiement | Statut d'intégrité |
|---|---|---|:---:|
| **Nombre total de fichiers** | 66 040 fichiers | 66 040 fichiers | **100% INTACT** |
| **Volume total sur disque** | 129 240 293 913 octets | 129 240 293 913 octets | **100% INTACT** |
| `jarvisol.exe` | SHA-256 : `5926f7f93eff13c8...` | SHA-256 : `5926f7f93eff13c8...` | **100% INTACT** |
| `data/app.so` | SHA-256 : `81f100d832684a16...` | SHA-256 : `81f100d832684a16...` | **100% INTACT** |
| `crispasr.dll` | SHA-256 : `b1336c9fcbd3f826...` | SHA-256 : `b1336c9fcbd3f826...` | **100% INTACT** |
| `data/preferences.json` | SHA-256 : `92cd64106eb19518...` | SHA-256 : `92cd64106eb19518...` | **100% INTACT** |
| `granite-speech-4.1-2b-nar-q4_k.gguf` | SHA-256 : `7ffa9fd63b20c72c...` | SHA-256 : `7ffa9fd63b20c72c...` | **100% INTACT** |

> **Conclusion Sanctuaire :** Aucune altération, aucun déplacement, aucune écriture n'a eu lieu sur `Final_v2`.

---

## 3. ARCHITECTURE ET CARTOGRAPHIE DE L'INSTANCE TEST

### 3.1. Répertoires partagés via Jonctions NTFS (Lecture seule / Données immuables)
Les répertoires volumineux suivants pointent directement vers les données de `Final_v2` sans duplication physique :
- `models\` -> `Final_v2\models\`
- `VoiceBake\` -> `Final_v2\VoiceBake\`
- `runtime\` -> `Final_v2\runtime\`
- `google-ai-edge-gallery-1-0-18\` -> `Final_v2\google-ai-edge-gallery-1-0-18\`
- `sd_vulkan\` -> `Final_v2\sd_vulkan\`
- `mcp_servers\` -> `Final_v2\mcp_servers\`
- `memory\` -> `Final_v2\memory\`
- `prompts_library\` -> `Final_v2\prompts_library\`
- `data\models\` -> `Final_v2\data\models\` *(incluant le modèle Granite NAR officiel de 3,18 Go)*
- `data\litert_home\` -> `Final_v2\data\litert_home\`
- `data\fixtures\` -> `Final_v2\data\fixtures\`

### 3.2. Fichiers et Répertoires mutables (Strictement isolés et indépendants)
Pour éviter tout effet de bord sur la session ou l'historique d'Olivier :
- `data\preferences.json` : Copie réelle autonome. Les réglages modifiés dans TEST ne touchent pas `Final_v2`.
- `data\history\` : Dossier réel copié.
- `data\ai_knowledge\` : Dossier réel copié.
- `data\config\` : Dossier réel copié.
- Répertoires dynamiques créés vierges : `logs\`, `tmp\`, `rag_cache\`, `compaction_capsules\`, `chat_exports\`.

### 3.3. Binaires Release Voice I/O R1a mis à jour
- `jarvisol.exe` : Binaire Release Windows fraîchement recompilé (`CrisperWeaver\build\windows\x64\runner\Release\jarvisol.exe`).
- `data\app.so` : Code Dart Release R1a mis à jour (SHA-256: `26d5d1e3d46f38e159769180384f37261a4c1953ce812540a4b4636eb1380d12`).
- `data\flutter_assets\` : Assets et police `MaterialIcons-Regular.otf` à jour.
- Diff exhaustif référencé dans : `D:\Antigravity\AgentFolder\CrisperWeaver\deployment_diff.csv`.

---

## 4. RÉSULTATS DES VALIDATIONS ET TESTS

### 4.1. Suite Voice I/O R1a (`test/voice_io_r1_test.dart`)
Log : `voice_io_tests.log` — **7/7 PASS (100% de succès)**
- **Test 1** : Rendu de `VoiceDictationButton` avec icône micro et infobulle "Dicter le prompt en français" -> **PASS**
- **Test 2** : Désactivation propre quand `enabled: false` à l'état idle -> **PASS**
- **Test 3** : Émission de `onBusyChanged(false)` lors de la destruction (`dispose`) -> **PASS**
- **Test 4** : Priorité au clic d'arrêt pendant l'enregistrement actif -> **PASS**
- **Test 5** : Intégration dans Assistant Audio (`LlmChatWidget`) avec exclusion mutuelle LLM / TTS / STT -> **PASS**
- **Test 6** : Intégration dans Assistant Documents (`DocumentChatWidget`) avec exclusion mutuelle et injection dans le champ de saisie -> **PASS**
- **Test 7** : Nettoyage et suppression automatique des fichiers temporaires `.wav` -> **PASS**

### 4.2. Suite de Non-Régression Globale
Log : `regression_tests.log` — **48/48 PASS (100% de succès)**
- `test/assistant_documents_audit_test.dart` (21 tests) : Sélecteurs, LiteRT 32K, LM Studio 128K, MCP, SQLite -> **PASS**
- `test/document_chat_user_actions_widget_test.dart` (9 tests) : Saisie de note, RAG, modales, prompts, streaming -> **PASS**
- `test/audiobook_voice_tuning_test.dart` (2 tests) : Sliders de voix, clonage, persistance -> **PASS**
- `test/tts_vibevoice_fix_test.dart` (16 tests) : Synthèse VibeVoice Realtime 0.5B, Qwen3-TTS, rééchantillonnage 24 kHz -> **PASS**

---

## 5. STATUT DU MODÈLE GRANITE SPEECH 4.1 NAR

1. **Backend natif :** Confirmé présent dans la DLL `crispasr.dll` (`granite-4.1-nar`).
2. **Fichier présent :** `data\models\whisper_cpp\granite-speech-4.1-2b-nar-q4_k.gguf`
   - Taille exacte : **3 413 252 640 octets** (~3,18 Go)
   - SHA-256 : `7ffa9fd63b20c72cdc72c114631d5f6dfc2d81bf0e1e5255c350a9b6826f2ba4`
3. **Disponibilité :** Immédiate dans l'instance TEST (accessible sans copie supplémentaire via la jonction `data/models`).

---

## 6. CAPTURES D'ÉCRAN DE VALIDATION

Les 3 captures d'écran requises ont été générées avec le moteur de rendu Flutter et les polices système Segoe UI / MaterialIcons :

1. `screenshot_01_assistant_audio.png`
   - **Vue :** Assistant Audio (`LlmChatWidget`).
   - **Éléments visibles :** Champ de prompt, icône micro `VoiceDictationButton` intégrée, bouton d'envoi, barre d'état LLM (Gemma 4 GPU).
2. `screenshot_02_assistant_documents.png`
   - **Vue :** Assistant Documents (`DocumentChatWidget`).
   - **Éléments visibles :** Barre de saisie inférieure, icône micro `VoiceDictationButton`, bouton d'envoi, puces d'état (LiteRT, RAG 128K, Pensée).
3. `screenshot_03_granite_nar.png`
   - **Vue :** Gestion des modèles ASR CrispASR.
   - **Éléments visibles :** Filtre "granite", carte principale **Granite Speech 4.1 2B NAR (q4_k)** avec badges `granite-4.1-nar`, `q4_k`, mention `ACTIF / DÉCODAGE PARALLÈLE` et statut `Installé` (3,18 Go local).

*Emplacements des images :*
- `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST\`
- `D:\Antigravity\AgentFolder\`

---

## 7. PROTOCOLE DE TEST UTILISATEUR PAS-À-PAS (POUR OLIVIER)

### Étape 1 — Lancer l'instance TEST
Ouvrir l'explorateur Windows et double-cliquer sur :
```
D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST\jarvisol.exe
```

### Étape 2 — Tester la Dictée Vocale dans "Assistant Audio"
1. Cliquer sur l'onglet **🤖 Assistant Audio** (3e onglet de la zone de droite).
2. Repérer l'icône de microphone située à droite du champ de saisie *"Posez une question sur cette transcription..."*.
3. Cliquer sur le microphone : le bouton s'anime en rouge / clignotant.
4. Parler clairement dans votre micro (ex: *"Fais-moi un résumé des points clés"*).
5. Cliquer à nouveau sur le bouton micro pour terminer la dictée.
6. **Observation attendue :** La transcription en français s'inscrit automatiquement dans le champ de prompt.
7. Cliquer sur le bouton d'envoi pour interroger le LLM.
8. Une fois la réponse du LLM reçue, cliquer sur l'icône haut-parleur pour vérifier la lecture vocale (TTS).

### Étape 3 — Tester la Dictée Vocale dans "Assistant Documents"
1. Cliquer sur l'onglet **📂 Assistant Documents** (4e onglet de la zone de droite).
2. Dans la barre inférieure *"Importez un document ou posez votre question..."*, repérer le bouton micro.
3. Cliquer sur le micro, dicter une consigne ou une question, puis recliquer pour arrêter.
4. **Observation attendue :** Le texte dicté apparaît instantanément dans la barre de saisie sans conflit avec le mode RAG.
5. Envoyer le message et écouter la réponse audio via TTS.

### Étape 4 — Tester le modèle Granite Speech 4.1 NAR
1. Dans le volet de gauche, déplier **Options avancées** puis la section **Modèle** (ou cliquer sur l'icône de téléchargement dans la barre supérieure pour ouvrir la Gestion des modèles).
2. Sélectionner **Granite Speech 4.1 2B NAR (q4_k)**.
3. Charger un court fichier audio de test et lancer la transcription.
4. **Observation attendue :** Transcription ultra-rapide (décodage parallèle non-autorégressif) sans crash natif.

### Étape 5 — En cas de besoin de retour en arrière
- L'instance témoin `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2` est 100% intacte et prête à être relancée à tout moment.
- Pour supprimer l'instance TEST ultérieurement : supprimer simplement le dossier `Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST` (les jonctions NTFS n'effacent pas les données d'origine).
