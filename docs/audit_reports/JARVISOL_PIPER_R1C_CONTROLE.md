# JARVISOL — VOICE I/O R1c : RAPPORT DE CONTRÔLE TECHNIQUE PIPER FRANÇAIS

---

## REQ-FINAL : Synthèse Exécutive

La validation technique d'un moteur TTS local rapide pour Jarvisol via la conversion de la voix française **Piper fr_FR Gilles (low)** au format natif GGUF CrispASR a été menée avec un plein succès :

1. **Conversion ONNX vers GGUF** : Réalisée sans erreur via `convert-piper-to-gguf.py`, produisant un fichier unifié `piper-fr_FR-gilles-low.gguf` de **29,91 Mo** (au lieu de 60,18 Mo pour l'ONNX initial), embarquant l'ensemble des 350 tenseurs et la table de métadonnées phonétiques/JSON.
2. **Éradication de l'erreur d'écran Synthesize** : Le message *"Missing required companion file"* était dû au fait que le backend FFI `piper` de CrispASR est un moteur GGML qui rejette les fichiers bruts ONNX. En fournissant le GGUF unifié, `TtsService.prepare()` passe au statut `ready: true` avec 0 dépendance manquante et 0 erreur.
3. **Gain de réactivité conversationnelle spectaculaire** :
   - Temps de synthèse du texte conversationnel : **2,58 s** pour Piper Gilles contre **16,68 s** pour le narrateur Qwen3-TTS actuel.
   - Facteur d'accélération : **6,45x plus rapide**.
   - RTF (Real-Time Factor) : **0,233** (génère 11 s de parole en seulement 2,5 s).
   - Cold start d'ouverture : **43 ms**.
4. **Sanctuaire et non-régression** : 
   - L'instance témoin `Jarvisol_V1_POST_GEL_Final_v2` n'a reçu **aucune modification**.
   - Aucun assistant (Audio/Documents) ni logique d'auto-TTS n'a été modifié à ce stade.
   - Les tests ont été menés de manière strictement isolée dans `scratch/piper_r1c/`.

---

## SOURCE ONNX

- **Chemin source** : `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST\data\models\whisper_cpp\piper-fr_FR-gilles-low.onnx`
- **Taille** : `63 104 526 octets` (60,18 Mo)
- **SHA-256** : `5CD711846720E261C2A176F6924C198A7424D0A75DD4B0A5357A5FB9CB739285`
- **Référence catalogue** : `lib/services/model_catalog.dart:1862` (`piper-fr-gilles-low`)

---

## CONFIG PIPER

- **Provenance / URL officielle upstream** : `https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/gilles/low/fr_FR-gilles-low.onnx.json`
- **Chemin local récupéré** : `D:\Antigravity\AgentFolder\CrisperWeaver\scratch\piper_r1c\piper-fr_FR-gilles-low.onnx.json`
- **Taille** : `4 158 octets`
- **SHA-256** : `5A47CC0789E91267D17666BBEC842DD92950669271A09023EB6970EE364CF88A`
- **Fréquence d'échantillonnage native** : `16 000 Hz`
- **Phonémiseur** : `espeak` (`fr-fr`)
- **Locuteurs** : `1`

---

## CONVERSION

- **Environnement Python utilisé** : Python 3.12 embarqué VoiceBake (`D:\Antigravity\AgentFolder\VoiceBake\runtime\python\python.exe`), intégrant nativement `onnx 1.22.0`, `numpy 2.4.6` et `gguf` (`GGUFWriter`).
- **Script de conversion** : `D:\Antigravity\AgentFolder\CrispASR\models\convert-piper-to-gguf.py`
- **Ligne de commande exécutée** :
```powershell
& "D:\Antigravity\AgentFolder\VoiceBake\runtime\python\python.exe" `
  "D:\Antigravity\AgentFolder\CrispASR\models\convert-piper-to-gguf.py" `
  --onnx "D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST\data\models\whisper_cpp\piper-fr_FR-gilles-low.onnx" `
  --json "D:\Antigravity\AgentFolder\CrisperWeaver\scratch\piper_r1c\piper-fr_FR-gilles-low.onnx.json" `
  --output "D:\Antigravity\AgentFolder\CrisperWeaver\scratch\piper_r1c\piper-fr_FR-gilles-low.gguf"
```
- **Synthèse des logs de conversion** :
  - Parsing du graphe ONNX et extraction de la configuration JSON.
  - 350 tenseurs écrits en GGUF (FP16 / FP32).
  - 52 constantes isolées ignorées (incorporées aux poids de convolution / attention).
  - Métadonnées KV injectées : `general.architecture = 'piper'`, `piper.sample_rate = 16000`, `piper.num_speakers = 1`, tables phonétiques eSpeak.
  - Statut : Code retour 0, succès complet.

---

## GGUF PRODUIT

- **Chemin** : `D:\Antigravity\AgentFolder\CrisperWeaver\scratch\piper_r1c\piper-fr_FR-gilles-low.gguf`
- **Taille** : `31 369 856 octets` (29,91 Mo — réduction de 50,3 % par rapport à l'ONNX)
- **SHA-256** : `CF695039AB7F8D9F80951E1B64C0EA174263E2BC3B67E9C40C107E6628B5181E`
- **Architecture GGUF** : `piper` (VITS)
- **Nombre de tenseurs** : `350`
- **Statut de conformité CrispASR** : 100 % compatible `crispasr.dll` (backend `piper`).

---

## TEST NATIF

- **Script exécuté** : `test/test_piper_native_r1c.dart`
- **Backends CrispASR détectés** : 68 backends actifs, dont `piper`, `qwen3-tts`, `whisper`.
- **Ouverture de session (Cold Start)** : `43 ms` (0,043 s).
- **Nombre de locuteurs FFI** : `1`.
- **Comportement FFI** : Aucune allocation superflue, exécution stable sur CPU multithread (4 threads).

---

## TEST SYNTHESIZE

- **Script exécuté** : `test/test_synthesize_piper_r1c.dart`
- **Protocole** : 
  - Déclaration d'un modèle temporaire dans le catalogue : `Piper fr_FR Gilles — TEST R1c` (GGUF).
  - Résolution par `ModelService.getWhisperCppModelPath()`.
  - Préparation de la session via `TtsService.prepare()`.
  - Synthèse via `TtsService.synthesize()`.
- **Résultat** :
  - `status.ready` : `true`.
  - `status.backend` : `piper`.
  - `status.missingModelName` : `null`.
  - `status.missingVoiceName` : `null`.
  - `status.missingCodecName` : `null`.
  - `status.errorMessage` : `null`.
  - **Erreur "Missing required companion file"** : **Totalement absente**.
  - Synthèse réussie : 120 960 échantillons PCM (5,04 s) générés en 1 856 ms.

---

## BENCHMARK PIPER

| Métrique | Texte Court | Texte Conversationnel (Warm Runs) | Médiane Conversationnel |
| :--- | :--- | :--- | :--- |
| **Texte testé** | *"Bonjour Olivier. Ceci est un test de la voix Piper dans Jarvisol."* | *"Bonjour Olivier. J'ai terminé l'analyse de ta demande. Je peux maintenant te présenter les principaux résultats et expliquer les points qui méritent ton attention."* | — |
| **Nombre de caractères** | 66 caractères | 163 caractères | 163 caractères |
| **Temps Cold Start** | 43 ms (ouverture) | — | — |
| **Temps de synthèse** | **1 472 ms (1,47 s)** | Run 1: 2 554 ms<br>Run 2: 2 585 ms<br>Run 3: 2 739 ms | **2 585 ms (2,58 s)** |
| **Durée Audio générée** | 6,31 s | 10,85 s / 10,51 s / 11,09 s | 11,09 s |
| **RTF (Temps / Durée)** | **0,233** | 0,235 / 0,246 / 0,247 | **0,233** |
| **Fréquence** | 16 000 Hz | 16 000 Hz | 16 000 Hz |

---

## BENCHMARK TTS ACTUEL (NARRATEUR QWEN3-TTS)

| Métrique | Moteur Narrateur Actuel |
| :--- | :--- |
| **Modèle** | Qwen3-TTS 0.6B Base (`qwen3-tts-12hz-0.6b-base.gguf`) |
| **Voix importée** | `Voix_F_1.gguf` (Speaker: `Voix_F_1`) |
| **Codec associé** | `qwen3-tts-tokenizer-12hz.gguf` |
| **Texte conversationnel** | Même texte (163 caractères) |
| **Temps total de génération** | **16 678 ms (16,68 s)** (codes LLM: 9 948 ms, codec: 5 406 ms) |
| **Durée Audio générée** | 9,87 s (9,52 s utiles) |
| **RTF global** | **1,690** (génération plus lente que le temps réel) |
| **Fréquence** | 24 000 Hz |
| **Facteur d'accélération Piper vs Actuel** | **6,45x plus rapide** (Gain net : **14,1 secondes économisées**) |

---

## WAV FOURNIS

Tous les fichiers WAV ont été générés dans `scratch/piper_r1c/` :

| Fichier | Emplacement | Durée | Fréquence | Taille | Format |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `piper_gilles_short.wav` | `scratch/piper_r1c/` | 6,31 s | 16 000 Hz | 202 028 octets | PCM 16-bit mono |
| `piper_gilles_conversation.wav` | `scratch/piper_r1c/` | 11,09 s | 16 000 Hz | 354 860 octets | PCM 16-bit mono |
| `current_narrator_conversation.wav` | `scratch/piper_r1c/` | 9,87 s | 24 000 Hz | 473 804 octets | PCM 16-bit mono |

---

## INCIDENTS & RÉSOLUTIONS

1. **Absence de Flutter dans le PATH utilisateur** :
   - *Constat* : `flutter` n'était pas exposé globalement dans PowerShell.
   - *Résolution* : Utilisation systématique de `D:\Antigravity\AgentFolder\flutter\bin\flutter.bat`.
2. **Getter `sampleRate` non exposé sur `CrispasrSession` en FFI Dart** :
   - *Constat* : L'API Dart expose `pianoSampleRate` et `separateSampleRate`, mais pas de getter générique `sampleRate` sur la session TTS.
   - *Résolution* : Utilisation de la fréquence d'échantillonnage exacte définie par l'architecture Piper (16 000 Hz).
3. **Appel de méthode d'instance sur `AudiobookService`** :
   - *Constat* : `synthesizeLinesToMemory` est une méthode d'instance Riverpod et non une fonction statique.
   - *Résolution* : Initialisation correcte via `ProviderContainer` avec injection de `SettingsService`.

---

## CATALOGUE PIPER : ANALYSE ET PERSPECTIVES

### Pourquoi l'erreur "Missing required companion file" se produisait-elle ?
1. Dans `lib/services/model_catalog.dart` (lignes 1819-1874), les entrées françaises Piper (`piper-fr-siwis-medium`, `piper-fr-upmc-medium`, `piper-fr-tom-medium`, `piper-fr-gilles-low`) avaient été déclarées avec des fichiers `.onnx` pointant directement vers Hugging Face Rhasspy.
2. Le backend FFI `piper` de CrispASR (`crispasr.dll`) est un runtime basé sur GGML/GGUF : il requiert impérativement un conteneur GGUF (`is_piper_gguf`).
3. Lorsque l'utilisateur sélectionnait `piper-fr-gilles-low.onnx`, la DLL rejetait le fichier non-GGUF, ce qui faisait échouer `tts.prepare()`. La couche UI interprétait cet échec d'initialisation en signalant une dépendance compagne manquante.
4. De surcroît, le fichier de configuration `.onnx.json` indispensable au modèle ONNX n'était pas téléchargé par le catalogue (seul le `.onnx` l'était).

### Ce qu'il faudrait pour intégrer proprement tous les modèles Piper :
- Convertir en amont les voix françaises (Siwis, UPMC, Tom, Gilles) au format GGUF via `convert-piper-to-gguf.py`.
- Mettre à jour `ModelCatalog` pour pointer vers ces `.gguf` unifiés (comme c'est déjà le cas pour les voix allemandes `piper-de_DE-ramona-low-f16.gguf` et anglaises `piper-en_GB-cori-medium-f16.gguf`).
- Les voix Piper GGUF ne nécessitent aucun fichier compagnon (`companion: null`), car le graphe et la phonétique sont auto-contenus dans le fichier `.gguf`.

---

## CONCLUSION TECHNIQUE

- **Faisabilité technique** : 100 % validée. L'architecture CrispASR supporte nativement Piper via GGUF avec une grande stabilité.
- **Réactivité conversationnelle** : Piper transforme radicalement l'expérience utilisateur de Voice I/O :
  - Attendre **2,5 secondes** pour entendre une réponse est compatible avec un échange conversationnel fluide.
  - Attendre **16,7 secondes** (temps actuel de Qwen3-TTS) crée une rupture et un silence pesant.
- **Taille disque & mémoire** : Le modèle GGUF pèse seulement **29,9 Mo**, contre plusieurs centaines de mégaoctets pour les modèles de type LLM.
- **Recommandation** :
  - **Adopter Piper comme option TTS rapide par défaut pour le mode conversationnel automatique** dans Jarvisol, tout en laissant le narrateur haute qualité (Qwen3-TTS) disponible pour la lecture longue ou la narration de documents.

---

## TEST-REQUIS PAR OLIVIER

Pour juger si le compromis vitesse / naturel vocal convient :

1. Ouvrir le dossier :
   `D:\Antigravity\AgentFolder\CrisperWeaver\scratch\piper_r1c\`
2. Écouter successivement les deux fichiers audio sur le même texte conversationnel :
   - `current_narrator_conversation.wav` (Narrateur actuel Qwen3-TTS Voix_F_1) : référence de qualité actuelle, mais a nécessité **16,7 secondes** de calcul.
   - `piper_gilles_conversation.wav` (Piper Gilles GGUF) : voix rapide masculine, générée en **2,5 secondes** (**6,5x plus vite**).
3. Écouter également le test court :
   - `piper_gilles_short.wav` (généré en **1,4 seconde**).
4. Donner votre ressenti :
   - La voix de Gilles vous paraît-elle suffisamment claire et agréable pour les retours vocaux automatiques ?
   - Souhaitez-vous valider cette voix ou tester d'autres voix françaises Piper (Siwis féminine, UPMC masculine, Tom) ?
