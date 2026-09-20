// HotkeySettingsScreen — phone-form sub-screen for §5.1.11
// global hotkey configuration. Same shape as the Cloud/Local
// LLM sub-screens.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/hotkey_service.dart';
import '../services/settings_service.dart';
import '../widgets/hotkey_settings_form.dart';

class HotkeySettingsScreen extends ConsumerStatefulWidget {
  const HotkeySettingsScreen({super.key});

  @override
  ConsumerState<HotkeySettingsScreen> createState() =>
      _HotkeySettingsScreenState();
}

class _HotkeySettingsScreenState
    extends ConsumerState<HotkeySettingsScreen> {
  final GlobalKey<HotkeySettingsFormState> _formKey =
      GlobalKey<HotkeySettingsFormState>();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = ref.read(settingsServiceProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.settingsHotkey),
        actions: [
          TextButton(
            onPressed: () async {
              final form = _formKey.currentState;
              if (form == null) return;
              final res = form.save();
              if (!res.ok) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(l.settingsHotkeyInvalid(res.invalidCombo!)),
                ));
                return;
              }
              final messenger = ScaffoldMessenger.of(context);
              final nav = Navigator.of(context);
              final hotkeySvc = ref.read(hotkeyServiceProvider);
              final regResult = await hotkeySvc.registerCandidate(
                enabled: form.enabled,
                combo: form.combo,
                action: form.action,
              );
              if (!mounted) return;
              if (regResult.isConflict) {
                messenger.showSnackBar(SnackBar(
                  content: Text(
                    'Conflit de raccourci : la combinaison "${form.combo}" est déjà réservée par une autre application (Erreur OS 1409).',
                  ),
                  backgroundColor: Colors.red.shade800,
                  duration: const Duration(seconds: 4),
                ));
                return;
              } else if (!regResult.isSuccess && regResult.status != HotkeyRegistrationStatus.disabled) {
                messenger.showSnackBar(SnackBar(
                  content: Text('Échec d\'enregistrement du raccourci : ${regResult.errorMessage}'),
                  backgroundColor: Colors.red.shade800,
                ));
                return;
              }
              nav.pop(true);
            },
            child: Text(l.save.toUpperCase(),
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: HotkeySettingsForm(
          key: _formKey,
          initialEnabled: settings.hotkeyEnabled,
          initialCombo: settings.hotkeyCombo,
          initialAction: settings.hotkeyAction,
          onCommit: (enabled, combo, action) {
            // Handled transactionally via registerCandidate on save
          },
        ),
      ),
    );
  }
}
