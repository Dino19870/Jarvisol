# Jarvisol — corrections issues de l'audit

Date: 2026-08-31
Base: `lib.zip` fourni par l'utilisateur.

## Corrections intégrées

- Transcription: filtrage strict des modèles ASR dans les sélecteurs et garde défensive dans `CrispasrEngine` contre le chargement d'un modèle non-ASR.
- Batch: déduplication par empreinte également depuis le bouton `+`; snapshot modèle/backend/langue lors de l'ajout; abandon explicite d'un job si son modèle demandé ne peut pas être chargé; pas de fallback silencieux vers la session précédente.
- Diarisation: câblage des bornes min/max de locuteurs jusqu'au service natif.
- Full Text: persistance d'un `fullTextOverride` dans l'historique afin qu'une édition du texte complet ne soit pas perdue au profit des segments d'origine; préservation des métadonnées d'historique lors des mises à jour.
- Clonage vocal: le wizard recherche explicitement un Qwen3-TTS Base téléchargé et le transmet à l'écran Synthèse; garde TTS contre l'usage d'un WAV de référence avec CustomVoice/VoiceDesign.
- Voix clonées: conservation des profils même si le WAV manque; résolution de chemins relatifs au Release; copie des WAV dans `data/voices/cloned` lors de l'enregistrement; support de la relocalisation après déplacement du dossier portable.
- Studio Livre Audio: persistance des profils/règles de nettoyage modifiés et réutilisation des profils sauvegardés.
- Qwen3: remplacement des valeurs par défaut historiques `qwen3-ethan` par `qwen3-ryan` avec migration de la préférence ancienne.
- Assistant Documents: drag-and-drop de fichiers traité comme import documentaire; les images passent par `DocumentSourceService.parseFile()` donc OCR/source/RAG; `Ctrl+V` image déclenche le flux Vision sans casser le collage texte normal.
- Voice Bake: résolution par défaut vers une Python portable et un script sous Release; l'ancien checkout CrispASR voisin ne reste qu'en fallback de développement.

## Non modifié volontairement

- HTDemucs, Mel-Band-Roformer, CREPE, Beat-This, BTC-Chords et Piano-Transcription: le test historique CrisperWeaver les classe `engineOnly` / CLI-only. Ils ne sont donc pas réintroduits comme régression UI.
- Secrets présents dans `audit_runtime_config.zip`: aucune valeur sensible n'a été copiée ni réécrite dans ce lot. Une migration de configuration devra être traitée séparément.

## Dépendance encore nécessaire pour Voice Bake

Le code vise désormais les emplacements portables suivants sous le répertoire de l'exécutable/Release:

- `tools/voice_bake/bake-chatterbox-voice-from-wav.py`
- `python/python.exe` ou `runtime/python/python.exe` (Windows)

Ces composants ne sont pas contenus dans `lib.zip`. Antigravity devra les embarquer dans le Release ou adapter le packaging au moment de la recompilation.

## Vérifications effectuées ici

- Diff complet produit entre la base et les fichiers corrigés.
- Validation JSON des fichiers ARB modifiés.
- Contrôle statique des APIs/classes utilisées par les corrections (catalogue Qwen3 Base, OCR documentaire, profils de règles).

## Vérifications non réalisables dans cet environnement

Flutter/Dart SDK n'est pas disponible dans l'environnement de correction; `flutter analyze`, compilation Windows et tests runtime n'ont donc pas été exécutés ici. Ils doivent être lancés par Antigravity après intégration.
