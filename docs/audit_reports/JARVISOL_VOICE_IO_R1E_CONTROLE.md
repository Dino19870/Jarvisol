# JARVISOL — VOICE I/O R1e : RAPPORT DE CONTRÔLE ET DÉPLOIEMENT

**Date :** 25 septembre 2026  
**Branche / Source canonique :** `D:\Antigravity\AgentFolder\CrisperWeaver`  
**Cible de déploiement :** `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2_VOICE_IO_R1A_TEST`  
**Instance protégée (Sanctuaire) :** `D:\Antigravity\AgentFolder\Jarvisol_V1_POST_GEL_Final_v2` (STRICTEMENT INTACTE)

---

## 1. Synthèse de l'intervention

L'intervention **Voice I/O R1e** intègre les voix françaises Microsoft (Windows OneCore locales hors-ligne et Microsoft Edge neuronales en ligne) dans **Assistant Audio** et **Assistant Documents** pour la lecture manuelle (bouton haut-parleur) et la lecture automatique des réponses (Auto-TTS).

### Objectifs atteints :
1. **Fluidité et réactivité conversationnelle** :
   - Voix locales Windows OneCore (~250 ms de génération, 0 latence réseau, 100% hors-ligne).
   - Voix neuronales Microsoft Edge (~1.2s de latence, timbre très naturel et expressif).
2. **Trois modes vocaux configurables** :
   - `auto` (Recommandé) : utilise la voix en ligne neuronale ; en cas de coupure réseau ou indisponibilité, bascule instantanément et automatiquement sur la voix locale sans interruption de service.
   - `online_only` : qualité neuronale maximale (requiert une connexion active).
   - `offline_only` : 100% local sur la machine, aucune transmission réseau tentée.
3. **Consentement explicite et confidentialité stricte** :
   - Demande d'accord explicite à l'utilisateur avant la première utilisation d'une voix en ligne.
   - Information claire : seul le texte de la réponse à lire est envoyé, aucun document, prompt système ou donnée personnelle n'est transmis.
   - Choix mémorisé dans les préférences et modifiable à tout moment.
   - Zéro requête réseau en mode hors ligne ou si le consentement n'est pas accordé.
4. **Accès direct et discret aux réglages** :
   - Icône de réglages `tune` intégrée à côté du bouton Auto-TTS dans la barre de saisie des deux assistants.
   - Dialogue complet de sélection du mode, de la voix en ligne, de la voix locale, avec boutons d'écoute/test de chaque voix.
5. **Non-régression absolue** :
   - Les réglages de personnages et de voix d'Audiobook Studio sont rigoureusement intacts.
   - Le moteur de dictée vocale (Whisper) reste inchangé et opérationnel.
   - Fallback de sécurité vers l'ancien narrateur (`legacy_narrator`) conservé.

---

## 2. Fichiers créés et modifiés

| Fichier | Statut | Rôle |
|---|---|---|
| `lib/services/assistant_voice_service.dart` | Créé | Service central TTS : découverte SAPI OneCore, synthèse OneCore & Edge, nettoyage markdown |
| `lib/widgets/assistant_voice_settings_dialog.dart` | Créé | Dialogue de réglages des voix (mode, choix voix, test audio, consentement) |
| `lib/services/settings_service.dart` | Modifié | Nouvelles clés de préférences : `voiceIoMode`, `voiceIoOnlineVoice`, `voiceIoOfflineVoice`, `voiceIoOnlineConsent`, `voiceIoEngine` |
| `lib/widgets/voice_dictation_button.dart` | Modifié | Intégration du bouton d'accès aux réglages de voix dans `AutoTtsToggleButton` |
| `lib/widgets/llm_chat_widget.dart` | Modifié | Câblage d'`AssistantVoiceService` dans l'Assistant Audio pour la lecture manuelle et auto |
| `lib/widgets/document_chat_widget.dart` | Modifié | Câblage d'`AssistantVoiceService` dans l'Assistant Documents pour la lecture manuelle et auto |
| `test/test_voice_io_r1e.dart` | Créé | Suite de tests automatisés unitaire et widgets pour Voice I/O R1e (8/8 réussis) |

---

## 3. Résultats des tests de validation

### Test Suite R1e (`test/test_voice_io_r1e.dart`)
- **1. Default settings for Voice I/O** : ✅ Passé
- **2. Setting and persisting voice modes and choices** : ✅ Passé
- **3. Online and offline voices catalogue definitions** : ✅ Passé
- **4. Text cleaning for speech synthesis** : ✅ Passé
- **5. Mode online_only without consent returns error result** : ✅ Passé
- **6. Mode offline_only executes Windows OneCore without network calls** : ✅ Passé
- **7. AutoTtsToggleButton displays Auto pill and tune settings button** : ✅ Passé
- **8. AssistantVoiceSettingsDialog opens and renders options** : ✅ Passé

### Test Suite Non-Régression (`test/voice_io_r1_test.dart`)
- **12/12 tests passés** (dictée vocale micro, exclusion mutuelle, suppression des fichiers temporaires, persistance Auto-TTS).

**Total : 20/20 tests passés avec succès.**
