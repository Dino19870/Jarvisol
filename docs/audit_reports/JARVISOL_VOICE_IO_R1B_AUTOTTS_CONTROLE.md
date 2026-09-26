# JARVISOL — RAPPORT DE CONTRÔLE VOICE I/O R1b : LECTURE VOCALE AUTOMATIQUE OPTIONNELLE

**Date :** 24 septembre 2026  
**Auteur :** Assistant Antigravity  
**Statut :** VALIDÉ & DÉPLOYÉ EN INSTANCE TEST  

---

## 1. Diagnostic Formel du TTS Manuel Existant (Section 6)

### Conclusion : CAS A (TTS_MANUEL_OK)
* **Configuration réelle inspectée** :
  - Clé `default_narrator_voice` : `imported_qwen3:Voix_H_1.gguf#Voix_H_1`
  - Fichier voix correspondant : `data/models/tts/voices/Voix_H_1.gguf` (15 456 octets)
  - Modèle TTS de base : `data/models/tts/qwen3-tts-12hz-0.6b-base.gguf` (1 379 813 536 octets)
  - Tokenizer TTS : `data/models/tts/qwen3-tts-tokenizer-12hz.gguf` (3 916 264 octets)
* **Résultat du test en conditions réelles** (`test_manual_tts_diagnosis.dart`) :
  - Synthèse TTS exécutée avec succès via `AudiobookService.synthesizeLinesToMemory`.
  - Sortie générée : **128 640 échantillons PCM, 5.36 secondes d'audio, 274 124 octets WAV**.
  - Durée de synthèse : **10.2 secondes**.
  - Fichier WAV écrit et validé : `data/tmp/assistant_read_aloud_diag.wav`.
* **Origine du ressenti utilisateur** : La synthèse on-device Qwen3-TTS prend environ 10 secondes sur CPU pour générer la voix. Si l'utilisateur clique sans observer le loader circulaire ou si le message est très long, le délai d'attente avant la première émission sonore peut être interprété comme un silence.

---

## 2. Implémentation de la Commande « 🔊 Réponse vocale auto »

### A. Emplacement et Ergonomie
* Widget créé : `AutoTtsToggleButton` (`lib/widgets/voice_dictation_button.dart`).
* Intégré directement dans la barre d'actions inférieure, immédiatement à gauche du bouton microphone `VoiceDictationButton` :
  - **Assistant Audio** (`lib/widgets/llm_chat_widget.dart`)
  - **Assistant Documents** (`lib/widgets/document_chat_widget.dart`)
* Design compact :
  - **État OFF (par défaut)** : Icône `Icons.volume_off_rounded` grisée avec badge discret `"Auto"`. Tooltip : `Réponse vocale auto : DÉSACTIVÉE (cliquer pour activer)`.
  - **État ON** : Icône `Icons.volume_up_rounded` avec couleur d'accent vive, fond teinté et label `"Auto"`. Tooltip : `Réponse vocale auto : ACTIVÉE (cliquer pour désactiver)`.
  - **État Lecture en cours (Dynamique)** : Se transforme automatiquement en bouton Stop clignotant rouge (`Icons.stop_circle_rounded`) ou indicateur de synthèse pour permettre une interruption immédiate en 1 clic.

### B. Synchronisation Globale
* Clé de persistance : `auto_tts_response_enabled` dans `preferences.json`.
* Service centralisé : `SettingsService.autoTtsResponseEnabled` (getter, setter, méthode async).
* Provider réactif Riverpod 3 : `autoTtsResponseEnabledProvider` (`NotifierProvider<AutoTtsResponseNotifier, bool>`).
* Toute modification dans l'Assistant Audio est instantanément reflétée dans l'Assistant Documents et inversement.

### C. Déclenchement Automatique et Garde-fous
1. **Uniquement sur réponse complète** : Le TTS ne se déclenche jamais pendant le streaming de la réponse. Il est appelé à la fin du stream (`onDone`), une fois que tout le texte a été assemblé et affiché.
2. **Jamais si annulation utilisateur** : Si l'utilisateur clique sur « Arrêter / Stop » pendant la génération LLM, la souscription est annulée et aucun TTS n'est déclenché.
3. **Coupure immédiate au micro** : Dès que l'utilisateur clique sur le microphone (`VoiceDictationButton.onRecordingStarted` et `onBusyChanged`), toute synthèse ou lecture audio en cours est immédiatement stoppée (`_stopAndCleanup()` / `_voiceIoStopAndCleanup()`), empêchant toute réinjection dans le micro.

---

## 3. Validation par Tests Automatisés

La suite `test/voice_io_r1_test.dart` a été enrichie et exécutée :
* **Test 1 à 7** : Validation du bouton de dictée vocale, exclusion mutuelle et nettoyage temporaire des WAVs.
* **Test 8** : Vérification que `autoTtsResponseEnabled` est `false` par défaut et persiste dans `preferences.json`.
* **Test 9** : Rendu OFF par défaut du widget `AutoTtsToggleButton` et bascule réactive bidirectionnelle ON/OFF.
* **Test 10** : Apparition du bouton d'arrêt d'urgence Stop lorsque la lecture est active et vérification du callback.
* **Test 11** : Intégration de `AutoTtsToggleButton` dans `LlmChatWidget` (Assistant Audio) et synchronisation des préférences.
* **Test 12** : Intégration de `AutoTtsToggleButton` dans `DocumentChatWidget` (Assistant Documents) et réflexion partagée de l'état.

**Résultat : 12 / 12 tests réussis (100% pass).**  
**Non-régression : 22 / 22 tests d'audit réussis sur `assistant_documents_audit_test.dart`.**

---

## 4. Compilation & Déploiement

### Binaires Release générés
* Commande : `flutter build windows --release`
* Fichiers cibles dans `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST\` :
  - `jarvisol.exe` : SHA-256 `5926F7F93EFF13C864E4B2A0B1000564B156E97FA45B0D854600B8F9ABBCC199`
  - `data/app.so` : SHA-256 `C0A6B12A4B995B9B63CB9A39BFACCE20C9DE722A69426F21E1D3206075DF64EF` (18 940 808 octets)
* Backups locaux créés avant écrasement :
  - `jarvisol.exe.bak_20260924_1532`
  - `data/app.so.bak_20260924_1532`

### Sanctuaire Témoin : INTÉGRITÉ ABSOLUE
* Répertoire : `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2`
* Aucun fichier modifié. 0 octet altéré. Intégrité vérifiée.
