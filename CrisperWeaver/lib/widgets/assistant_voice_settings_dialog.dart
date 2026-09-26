import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../services/assistant_voice_service.dart';
import '../services/settings_service.dart';

/// Dialogue modal partagé de configuration des voix de l'assistant (Audio et Documents).
class AssistantVoiceSettingsDialog extends ConsumerStatefulWidget {
  const AssistantVoiceSettingsDialog({super.key});

  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const AssistantVoiceSettingsDialog(),
    );
  }

  /// Demande le consentement pour l'utilisation des voix en ligne Microsoft si pas encore défini.
  /// Retourne true si accordé, false sinon.
  static Future<bool> ensureOnlineConsent(
    BuildContext context,
    SettingsService settings,
  ) async {
    if (settings.voiceIoOnlineConsent != null) {
      return settings.voiceIoOnlineConsent == true;
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.privacy_tip_outlined, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Voix en ligne de l’assistant'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pour une voix fluide, naturelle et expressive, l’assistant peut utiliser la synthèse vocale en ligne Microsoft Edge.\n\n'
              '• Seul le texte de la réponse à lire est envoyé aux serveurs vocaux Microsoft.\n'
              '• Aucun document, prompt système, historique ou donnée personnelle n’est transmis.\n'
              '• Si désactivé ou hors ligne, la voix locale Windows OneCore est utilisée (0 appel réseau).\n'
              '• Vous pouvez modifier ce choix à tout moment dans les réglages de la voix.\n\n'
              'Souhaitez-vous autoriser les voix en ligne ?',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Non (100% hors ligne)'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Oui, autoriser'),
          ),
        ],
      ),
    );

    final agreed = result ?? false;
    await settings.setVoiceIoOnlineConsent(agreed);
    return agreed;
  }

  @override
  ConsumerState<AssistantVoiceSettingsDialog> createState() =>
      _AssistantVoiceSettingsDialogState();
}

class _AssistantVoiceSettingsDialogState
    extends ConsumerState<AssistantVoiceSettingsDialog> {
  late String _selectedMode;
  late String _selectedOnlineVoice;
  late String _selectedOfflineVoice;
  bool? _onlineConsent;

  List<AssistantVoiceInfo> _offlineVoices = [];
  bool _isLoadingVoices = true;

  final AudioPlayer _testPlayer = AudioPlayer();
  bool _isTestingOnline = false;
  bool _isTestingOffline = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsServiceProvider);
    _selectedMode = settings.voiceIoMode;
    _selectedOnlineVoice = settings.voiceIoOnlineVoice;
    _selectedOfflineVoice = settings.voiceIoOfflineVoice;
    _onlineConsent = settings.voiceIoOnlineConsent;

    _loadVoices();
  }

  @override
  void dispose() {
    _testPlayer.stop().catchError((_) {});
    _testPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadVoices() async {
    final svc = ref.read(assistantVoiceServiceProvider);
    final voices = await svc.getInstalledOfflineVoices();
    if (mounted) {
      setState(() {
        _offlineVoices = voices;
        _isLoadingVoices = false;
        // Vérifier si la voix sélectionnée existe toujours
        if (!voices.any((v) => v.id == _selectedOfflineVoice) && voices.isNotEmpty) {
          _selectedOfflineVoice = voices.first.id;
        }
      });
    }
  }

  Future<void> _testVoice({required bool isOnline}) async {
    setState(() {
      if (isOnline) {
        _isTestingOnline = true;
      } else {
        _isTestingOffline = true;
      }
      _statusMessage = null;
    });

    try {
      await _testPlayer.stop();
      final svc = ref.read(assistantVoiceServiceProvider);
      const testText = "Bonjour, ceci est un test de la voix sélectionnée pour Jarvisol.";

      final res = await svc.synthesize(
        text: testText,
        onFallback: (msg) {
          if (mounted) {
            setState(() => _statusMessage = msg);
          }
        },
      );

      if (res.success && res.filePath != null) {
        await _testPlayer.setFilePath(res.filePath!);
        await _testPlayer.play();
      } else {
        throw Exception(res.error ?? 'Fichier audio non généré.');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Erreur lors du test : $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTestingOnline = false;
          _isTestingOffline = false;
        });
      }
    }
  }

  Future<void> _saveSettings() async {
    final settings = ref.read(settingsServiceProvider);
    await settings.setVoiceIoMode(_selectedMode);
    await settings.setVoiceIoOnlineVoice(_selectedOnlineVoice);
    await settings.setVoiceIoOfflineVoice(_selectedOfflineVoice);
    await settings.setVoiceIoOnlineConsent(_onlineConsent);

    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Réglages de voix de l’assistant enregistrés.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Titre et icône
              Row(
                children: [
                  Icon(Icons.record_voice_over, color: colorScheme.primary, size: 28),
                  const SizedBox(width: 12),
                  Text(
                    'Voix de l’Assistant',
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Configuration partagée pour l’Assistant Audio et l’Assistant Documents',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
              const Divider(height: 24),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // --- MODE VOCAL ---
                      Text(
                        'Mode vocal',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      _buildModeOption(
                        mode: 'auto',
                        title: 'Automatique (Recommandé)',
                        subtitle: 'En ligne avec secours hors ligne automatique',
                        theme: theme,
                      ),
                      const SizedBox(height: 4),
                      _buildModeOption(
                        mode: 'online_only',
                        title: 'En ligne uniquement',
                        subtitle: 'Qualité neuronale maximale (Connexion Internet requise)',
                        theme: theme,
                      ),
                      const SizedBox(height: 4),
                      _buildModeOption(
                        mode: 'offline_only',
                        title: 'Hors ligne uniquement',
                        subtitle: '100 % local sur votre machine (0 appel réseau)',
                        theme: theme,
                      ),
                      const SizedBox(height: 16),

                      // --- VOIX EN LIGNE (DÉSACTIVÉE EN HORS-LIGNE PUR) ---
                      Opacity(
                        opacity: _selectedMode == 'offline_only' ? 0.4 : 1.0,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Voix en ligne (Microsoft Edge / Azure)',
                              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: _selectedOnlineVoice,
                              decoration: InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                              items: AssistantVoiceService.onlineVoices.map((v) {
                                return DropdownMenuItem<String>(
                                  value: v.id,
                                  child: Row(
                                    children: [
                                      Icon(
                                        v.gender == 'Homme' ? Icons.male : Icons.female,
                                        size: 18,
                                        color: v.gender == 'Homme' ? Colors.blue : Colors.pink,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '${v.displayName} (${v.gender}) — ${v.description}',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: _selectedMode == 'offline_only'
                                  ? null
                                  : (val) {
                                      if (val != null) setState(() => _selectedOnlineVoice = val);
                                    },
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: (_selectedMode == 'offline_only' || _isTestingOnline)
                                    ? null
                                    : () => _testVoice(isOnline: true),
                                icon: _isTestingOnline
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.volume_up, size: 18),
                                label: const Text('Tester la voix en ligne'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // --- VOIX HORS LIGNE (WINDOWS ONECORE) ---
                      Text(
                        'Voix hors ligne (Windows OneCore locale)',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      if (_isLoadingVoices)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8.0),
                          child: LinearProgressIndicator(),
                        )
                      else if (_offlineVoices.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Aucune voix française Windows n’a été détectée. Veuillez installer le pack de voix français dans les paramètres Windows.',
                            style: TextStyle(color: Colors.black87, fontSize: 13),
                          ),
                        )
                      else
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _selectedOfflineVoice,
                          decoration: InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          items: _offlineVoices.map((v) {
                            return DropdownMenuItem<String>(
                              value: v.id,
                              child: Row(
                                children: [
                                  Icon(
                                    v.gender == 'Homme' ? Icons.male : Icons.female,
                                    size: 18,
                                    color: v.gender == 'Homme' ? Colors.blue : Colors.pink,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      v.displayName,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedOfflineVoice = val);
                          },
                        ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: (_offlineVoices.isEmpty || _isTestingOffline)
                              ? null
                              : () => _testVoice(isOnline: false),
                          icon: _isTestingOffline
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.volume_up, size: 18),
                          label: const Text('Tester la voix hors ligne'),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // --- CONSENTEMENT ET CONFIDENTIALITÉ ---
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.security, size: 18, color: colorScheme.primary),
                                const SizedBox(width: 8),
                                const Text(
                                  'Confidentialité des voix en ligne',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Seul le texte de la réponse à lire est transmis aux serveurs vocaux Microsoft. Aucun document, prompt système ou donnée personnelle n’est envoyé.',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 8),
                            Material(
                              color: Colors.transparent,
                              child: SwitchListTile(
                                value: _onlineConsent ?? false,
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: const Text('Activer l’autorisation pour les voix en ligne'),
                                onChanged: (val) => setState(() => _onlineConsent = val),
                              ),
                            ),
                          ],
                        ),
                      ),

                      if (_statusMessage != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _statusMessage!,
                            style: TextStyle(color: Colors.blue.shade900, fontSize: 12),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const Divider(height: 24),
              // Boutons d'action
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annuler'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _saveSettings,
                    child: const Text('Enregistrer les réglages'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeOption({
    required String mode,
    required String title,
    required String subtitle,
    required ThemeData theme,
  }) {
    final isSelected = _selectedMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _selectedMode = mode),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
