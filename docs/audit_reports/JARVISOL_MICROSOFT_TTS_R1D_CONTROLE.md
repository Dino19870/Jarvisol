# JARVISOL — VOICE I/O R1d : RAPPORT DE CONTRÔLE TECHNIQUE
## Comparaison des Voix Microsoft pour une Conversation Fluide

---

## 1. OBJECTIF & SYNTHÈSE EXÉCUTIVE

Dans le cadre du perfectionnement de la lecture automatique des réponses de Jarvisol (Assistants Audio et Documents), la voix Piper Gilles (GGUF VITS) s'est avérée trop robotique et difficilement compréhensible malgré sa rapidité relative.

L'objectif de cette étude (R1d) est de réaliser un **diagnostic comparatif approfondi et la génération d'échantillons audio réels** parmi deux grandes familles de voix Microsoft :
1. **Les voix locales Windows natives** (SAPI 5 et WinRT OneCore) : 100 % hors ligne, ultra-rapides, intégrées au système.
2. **Les voix neuronales Microsoft Edge** (accessibles via protocole WebSocket Edge/Azure) : qualité quasi-humaine, très réactives, mais dépendantes du réseau.

**Règle d'or respectée** : Aucune modification de la source de production, de l'instance stable protégée `Final_v2`, de l'instance TEST ou des assistants utilisateur n'a été effectuée. Tous les essais et livrables ont été réalisés dans le dossier isolé `scratch/ms_tts_r1d/`.

---

## 2. INVENTAIRE DES VOIX WINDOWS NATIVES

L'audit système révèle une séparation technique fondamentale sous Windows 10 et 11 entre deux sous-systèmes :

### A. Sous-système SAPI 5 classique (`System.Speech.Synthesis` / COM `ISpVoice`)
- **Ruche registre** : `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech\Voices\Tokens`
- **Voix française disponible** :
  - **`Microsoft Hortense Desktop`** (`MSTTS_V110_frFR_HortenseM`)
    - *Langue* : `fr-FR` | *Genre* : Féminin | *Format natif* : 22 050 Hz, 16-bit mono PCM.
    - *Disponibilité* : 100 % hors ligne.
    - *Mécanisme* : COM direct `ISpVoice` ou .NET `System.Speech.Synthesis.SpeechSynthesizer`.
    - *Verdict acoustique* : Voix mécanique de génération Windows 7/8, intonation très monotone et étirée (16 secondes pour la phrase de test).

### B. Sous-système WinRT OneCore moderne (`Windows.Media.SpeechSynthesis`)
- **Ruche registre** : `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens`
- **Voix françaises disponibles et vérifiées sur cette machine** :
  1. **`Microsoft Paul`** (`MSTTS_V110_frFR_PaulM`)
     - *Langue* : `fr-FR` | *Genre* : Masculin | *Format natif* : 16 000 Hz, 16-bit mono PCM.
     - *Disponibilité* : 100 % hors ligne.
     - *Id* : `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_frFR_PaulM`
  2. **`Microsoft Hortense`** (`MSTTS_V110_frFR_HortenseM` - version OneCore)
     - *Langue* : `fr-FR` | *Genre* : Féminin | *Format natif* : 16 000 Hz, 16-bit mono PCM.
     - *Disponibilité* : 100 % hors ligne.
     - *Différence avec Hortense Desktop* : Modèle acoustique ré-échantillonné et ré-articulé par Microsoft pour Windows 10/11, nettement plus dynamique que l'ancienne SAPI.
  3. **`Microsoft Julie`** (`MSTTS_V110_frFR_JulieM`)
     - *Langue* : `fr-FR` | *Genre* : Féminin | *Format natif* : 16 000 Hz, 16-bit mono PCM.
     - *Disponibilité* : 100 % hors ligne.
     - *Id* : `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_frFR_JulieM`

- **Mécanismes d'intégration dans Jarvisol** :
  - *Option native C++/WinRT* : Appel direct de l'interface WinRT `Windows.Media.SpeechSynthesis.SpeechSynthesizer` via FFI ou bridge C++/WinRT.
  - *Option micro-helper CLI* : Un binaire compagnon compact (`WinRtTts.exe`, ~150 Ko compilé en AOT / .NET), sans dépendance externe, invoqué par Jarvisol en `Process.run`.
  - *Option package Flutter* : Le plugin `flutter_tts` pilote directement ce sous-système sous Windows.

---

## 3. VOIX MICROSOFT EDGE NEURONALES

### A. Distinction Officielle vs Tierce
1. **API Officielle Azure Cognitive Services Speech** :
   - Service commercial payant dans le cloud Azure.
   - Nécessite la création d'un compte Azure, une clé d'API secrète, une région serveur, et une facturation au caractère au-delà du quota gratuit.
2. **Bibliothèque Tierce `edge-tts` (Endpoint Microsoft Edge Read-Aloud)** :
   - Se connecte au endpoint WebSocket HTTPS/WSS non documenté que le navigateur Microsoft Edge utilise pour sa fonction native "Lecture à voix haute" (`speech.platform.bing.com`).
   - Utilise une clé client publique fixe (`TrustedClientToken`) rotée par Edge.
   - **Avantage** : Gratuit, sans inscription, sans clé API personnelle, voix neuronales complètes à débit élevé.
   - **Limite technique** : Endpoint non garanti par SLA officiel de Microsoft (théoriquement sujet à modification de protocole ou rate-limit). En pratique, très stable depuis plus de 4 ans.

### B. Voix françaises neuronales testées
- **`fr-FR-HenriNeural`** : Voix masculine posée, chaleureuse, naturelle et professionnelle.
- **`fr-FR-DeniseNeural`** : Voix féminine fluide, vivante, engageante et parfaitement intelligible.
- **`fr-FR-RemyMultilingualNeural`** : Voix masculine multilingue à diction précise.
- **`fr-FR-VivienneMultilingualNeural`** : Voix féminine multilingue douce.

### C. Dépendance réseau et confidentialité
- **Connexion requise** : Impérative. Si le PC est hors ligne, la synthèse Edge ne peut pas fonctionner.
- **Confidentialité** : Les requêtes SSML transitent chiffrées en TLS vers les serveurs Azure/Edge. Pour cette étude, **exclusivement** la phrase de test fournie a été transmise (aucune donnée personnelle ou historique).
- **Intégration Jarvisol** : Peut être intégrée sans Python via un client WebSocket Dart natif léger qui envoie le texte au format SSML et récupère le flux audio MP3 en streaming.

---

## 4. ÉCHANTILLONS COMPARATIFS FOURNIS

Tous les fichiers audio ont été générés avec **exactement** le texte d'Olivier :

> *« Bonjour Olivier. J'ai terminé l'analyse de ta demande. Je peux maintenant te présenter les principaux résultats et expliquer les points qui méritent ton attention. »*

Les fichiers sont localisés dans :
`D:\Antigravity\AgentFolder\CrisperWeaver\scratch\ms_tts_r1d\`

| Fichier Audio | Moteur / Famille | Voix | Genre | Format | Fréquence | Durée | Taille |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`windows_onecore_paul.wav`** | Windows OneCore | Microsoft Paul | Homme | WAV (PCM 16-bit) | 16 000 Hz | 10,14 s | 324 Ko |
| **`windows_onecore_hortense.wav`** | Windows OneCore | Microsoft Hortense | Femme | WAV (PCM 16-bit) | 16 000 Hz | 11,47 s | 367 Ko |
| **`windows_onecore_julie.wav`** | Windows OneCore | Microsoft Julie | Femme | WAV (PCM 16-bit) | 16 000 Hz | 10,55 s | 338 Ko |
| **`windows_sapi_hortense_desktop.wav`** | Windows SAPI 5 | Hortense Desktop | Femme | WAV (PCM 16-bit) | 22 050 Hz | 16,16 s | 713 Ko |
| **`edge_neural_henri.wav`** | Edge Neural | fr-FR-HenriNeural | Homme | WAV (converti) | 24 000 Hz | 10,01 s | 480 Ko |
| `edge_neural_henri.mp3` | Edge Neural | fr-FR-HenriNeural | Homme | MP3 (original) | 24 000 Hz | 10,01 s | 60 Ko |
| **`edge_neural_denise.wav`** | Edge Neural | fr-FR-DeniseNeural | Femme | WAV (converti) | 24 000 Hz | 10,92 s | 524 Ko |
| `edge_neural_denise.mp3` | Edge Neural | fr-FR-DeniseNeural | Femme | MP3 (original) | 24 000 Hz | 10,92 s | 66 Ko |
| `edge_neural_remy.wav` / `.mp3` | Edge Neural | RemyMultilingual | Homme | WAV / MP3 | 24 000 Hz | 9,12 s | 438 Ko |
| `edge_neural_vivienne.wav` / `.mp3` | Edge Neural | VivienneMultilingual | Femme | WAV / MP3 | 24 000 Hz | 8,09 s | 388 Ko |

---

## 5. MESURES DE PERFORMANCE DÉTAILLÉES

### Tableau Comparatif des Performances

| Voix | API | Préparation (Cold) | 1er Segment Audio (TTFB) | Synthèse Totale (Cold) | Synthèse Totale (Warm Médiane) | Durée Audio | Facteur RTF (Warm) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Microsoft Paul** | WinRT OneCore | 65 ms | **~10 ms** | 50 ms | **44 ms** | 10,14 s | **0,0043** |
| **Microsoft Hortense** | WinRT OneCore | 29 ms | **~5 ms** | 14 ms | **12 ms** | 11,47 s | **0,0010** |
| **Microsoft Julie** | WinRT OneCore | 29 ms | **~10 ms** | 46 ms | **43 ms** | 10,55 s | **0,0041** |
| **Hortense Desktop** | SAPI 5 | 352 ms | ~50 ms | 141 ms | **40 ms** | 16,16 s | **0,0025** |
| **Edge Henri** | WebSocket Edge | ~30 ms | **182 ms** | 418 ms | **399 ms** | 10,01 s | **0,0398** |
| **Edge Denise** | WebSocket Edge | ~30 ms | **174 ms** | 371 ms | **410 ms** | 10,92 s | **0,0375** |
| *Rappel : Piper Gilles* | *Local GGUF* | *43 ms* | *~1 400 ms* | *2 554 ms* | *2 585 ms* | *11,09 s* | *0,2330* |
| *Rappel : Qwen3-TTS* | *Local LLM* | *~400 ms* | *~9 900 ms* | *16 678 ms* | *16 678 ms* | *9,87 s* | *1,6900* |

### Analyse des Délais et de la Restitution Progressive :
1. **Voix Windows OneCore** :
   - Le délai de synthèse totale est quasi instantané : **entre 12 et 44 millisecondes** pour générer 10 secondes de parole !
   - Aucun streaming n'est même nécessaire : le fichier ou flux WAV complet est prêt avant même que l'oreille humaine ne perçoive le moindre clic.
2. **Voix Edge Neural** :
   - En mode streaming WebSocket, le **Time To First Chunk (TTFC)** est compris entre **174 et 182 ms** (délai de négociation TLS + latence réseau vers Azure).
   - L'audio commence à être joué en moins de **0,2 seconde**, pendant que le reste de la phrase est reçu en arrière-plan.
   - La génération totale est terminée en ~400 ms.
3. **Gain par rapport aux solutions précédentes** :
   - Les voix WinRT sont **60x plus rapides que Piper** et **400x plus rapides que Qwen3-TTS**.
   - Les voix Edge Neural avec streaming démarrent la lecture **8x plus vite que Piper** et **55x plus vite que Qwen3-TTS**.

---

## 6. PORTABILITÉ SUR UN AUTRE PC WINDOWS

| Critère | Windows OneCore (`Microsoft Paul/Hortense/Julie`) | Microsoft Edge Neural (`Henri/Denise`) |
| :--- | :--- | :--- |
| **Système requis** | Windows 10 (toutes versions) ou Windows 11 | Windows 10 ou 11 (navigateur Edge préinstallé par défaut sur Windows) |
| **Voix préinstallées** | `Microsoft Hortense` est présente sur 100 % des Windows français. `Paul` et `Julie` sont disponibles via le pack de voix français gratuit de Windows. | Les voix résident sur les serveurs Edge/Azure ; aucune voix à installer sur le PC client. |
| **Connexion Internet** | **Aucune (100 % autonome hors ligne)** | **Obligatoire (accès réseau sortant HTTPS/WSS)** |
| **Empreinte disque** | **0 Mo supplémentaire** (utilise les bibliothèques système déjà présentes) | **0 Mo supplémentaire** (streaming léger) |
| **Poids pour Jarvisol** | Aucun modèle lourd à distribuer dans le zip de Jarvisol | Aucun modèle lourd |
| **Conditions d'utilisation** | Composant système Windows officiel sans restriction | Service Edge Read-Aloud (usage standard d'assistance) |

---

## 7. DISTINCTION AVEC LES VOIX DE WORD

Les voix intégrées à Microsoft Word (Office 365) reposent sur le moteur interne C++ d'Office (`Office Speech Engine` / `mso.dll`) connecté aux voix cloud Azure de Microsoft. 
Elles partagent les mêmes modèles acoustiques sous-jacents que les voix Edge Neural (`DeniseNeural` et `HenriNeural`), mais ne sont pas accessibles par une API Windows locale pour des logiciels tiers sans passer par l'API Office ou le service Edge/Azure.

---

## 8. GUIDE D'ÉCOUTE ET TEST REQUIS PAR OLIVIER

Les échantillons audio sont immédiatement disponibles dans le dossier :
`D:\Antigravity\AgentFolder\CrisperWeaver\scratch\ms_tts_r1d\`

### Protocole d'écoute recommandé pour Olivier :

1. **Test n° 1 — Voix Féminines (Face-à-face)** :
   - Écouter `windows_onecore_hortense.wav` (Windows native, 100 % locale, 12 ms de délai).
   - Écouter `edge_neural_denise.wav` (Edge neuronale, 174 ms de premier son, qualité studio).
   - *Question* : La voix d'Hortense OneCore est-elle acceptable pour du 100 % hors-ligne, ou la voix Denise est-elle nettement plus agréable ?

2. **Test n° 2 — Voix Masculines (Face-à-face)** :
   - Écouter `windows_onecore_paul.wav` (Windows native, 100 % locale, 44 ms de délai).
   - Écouter `edge_neural_henri.wav` (Edge neuronale, 182 ms de premier son, voix posée).
   - *Question* : La voix Paul OneCore vous paraît-elle convaincante face au naturel d'Henri ?

3. **Stratégie hybride possible pour Jarvisol** :
   - **Mode Edge Neural (Denise / Henri)** en priorité pour une conversation fluide, humaine et naturelle lorsque Internet est connecté.
   - **Basculement automatique sur Windows OneCore (Hortense / Paul)** si le PC est hors ligne ou si le réseau est indisponible (latence quasi-nulle, 0 échec).

---

## 9. CONTENU DE L'ARCHIVE DE CONTRÔLE

L'archive [`JARVISOL_MICROSOFT_TTS_R1D_CONTROLE.zip`](file:///D:/Antigravity/AgentFolder/CrisperWeaver/JARVISOL_MICROSOFT_TTS_R1D_CONTROLE.zip) regroupe l'intégralité des éléments de l'étude :
- Le rapport technique complet (`JARVISOL_MICROSOFT_TTS_R1D_CONTROLE.md`)
- Le fichier JSON de mesures (`benchmark_microsoft_tts.json`)
- Les 8 fichiers WAV comparatifs
- Les 4 fichiers originaux MP3 Edge
- Les scripts de diagnostic et de benchmark (`probe_voices.ps1`, `test_windows_sapi.ps1`, `test_edge_tts.ps1`, `measure_streaming.py`, `probe_wavs.ps1`, et le projet console C# `WinRtTts/`)
