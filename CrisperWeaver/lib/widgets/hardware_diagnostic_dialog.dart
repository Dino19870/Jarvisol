// lib/widgets/hardware_diagnostic_dialog.dart
import 'package:flutter/material.dart';

import '../models/hardware_profile.dart';
import '../services/hardware_advisor_service.dart';

class FirstRunWelcomeDialog extends StatelessWidget {
  const FirstRunWelcomeDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.memory, color: theme.colorScheme.primary, size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Bienvenue dans Jarvisol',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Jarvisol peut fonctionner avec de nombreux moteurs locaux et propose également certaines fonctions connectées optionnelles.\n\n'
              'Pour vous offrir la meilleure expérience sur cet ordinateur, '
              'Jarvisol peut analyser les principales capacités matérielles de cet ordinateur '
              'et évaluer la compatibilité avec ses différents moteurs IA (LLM local, transcription vocale, génération d\'images).\n\n'
              'Cette analyse est entièrement locale, non intrusive et ne transmet aucune donnée.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withAlpha(128),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 20, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Vous pourrez modifier ou relancer cette analyse à tout moment dans les Paramètres.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await HardwareAdvisorService.instance.markOnboardingSeen();
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: const Text('Continuer sans analyser'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.speed, size: 18),
          label: const Text('Analyser cet ordinateur'),
          onPressed: () async {
            await HardwareAdvisorService.instance.markOnboardingSeen();
            if (context.mounted) {
              Navigator.of(context).pop();
              HardwareDiagnosticDialog.show(context);
            }
          },
        ),
      ],
    );
  }
}

/// Dialogue non bloquant proposé lorsqu'un changement significatif
/// de configuration matérielle est détecté au démarrage suivant.
class HardwareChangedDialog extends StatelessWidget {
  const HardwareChangedDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.devices_other, color: theme.colorScheme.primary, size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Configuration matérielle',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: const Text(
          'Jarvisol semble être utilisé sur une configuration matérielle différente. Actualiser le diagnostic ?',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Plus tard'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Actualiser'),
          onPressed: () {
            Navigator.of(context).pop();
            HardwareDiagnosticDialog.show(context);
          },
        ),
      ],
    );
  }
}

class HardwareDiagnosticDialog extends StatefulWidget {
  const HardwareDiagnosticDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const HardwareDiagnosticDialog(),
    );
  }

  @override
  State<HardwareDiagnosticDialog> createState() => _HardwareDiagnosticDialogState();
}

class _HardwareDiagnosticDialogState extends State<HardwareDiagnosticDialog> {
  bool _loading = true;
  HardwareProfile? _profile;
  Map<EngineCategory, CapabilityEvaluation>? _capabilities;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _runInspection();
  }

  Future<void> _runInspection() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final profile = await HardwareAdvisorService.instance.inspectHost();
      final caps = await HardwareAdvisorService.instance.evaluateHostCapabilities(profile);
      await HardwareAdvisorService.instance.saveProfileState(profile);

      if (mounted) {
        setState(() {
          _profile = profile;
          _capabilities = caps;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Erreur lors du diagnostic : $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.speed, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Diagnostic Matériel & Capacités IA'),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 520),
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Inspection matérielle en cours...'),
                  ],
                ),
              )
            : _errorMessage != null
                ? Text(_errorMessage!, style: TextStyle(color: theme.colorScheme.error))
                : _buildContent(context),
      ),
      actions: [
        if (!_loading)
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Relancer l\'analyse'),
            onPressed: _runInspection,
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final profile = _profile!;
    final caps = _capabilities ?? {};

    final ramTotal = profile.ramTotalBytes.value;
    final ramAvail = profile.ramAvailableBytes.value;
    final ramStr = ramTotal != null
        ? '${(ramTotal / (1024 * 1024 * 1024)).toStringAsFixed(1)} Go'
        : 'Inconnu';
    final ramAvailStr = ramAvail != null
        ? '${(ramAvail / (1024 * 1024 * 1024)).toStringAsFixed(1)} Go'
        : 'Inconnu';

    final gpu = profile.primaryGpu;
    final vram = gpu?.dedicatedVideoMemoryBytes;
    final vramStr = vram != null && vram > 0
        ? '${(vram / (1024 * 1024 * 1024)).toStringAsFixed(1)} Go'
        : (gpu != null ? 'Mémoire partagée' : 'Aucun');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(100),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow('Processeur', profile.cpuModel.value ?? 'Non détecté'),
                _buildInfoRow('Threads logiques', '${profile.logicalProcessors.value ?? "Inconnu"}'),
                _buildInfoRow('Cœurs physiques', profile.physicalCores.value != null ? '${profile.physicalCores.value}' : 'Indéterminé (non mesuré)'),
                _buildInfoRow('Mémoire vive (RAM)', '$ramStr ($ramAvailStr disponible)'),
                _buildInfoRow('Carte graphique (GPU)', gpu?.name ?? 'Non détectée'),
                _buildInfoRow('Mémoire vidéo (VRAM)', vramStr),
                _buildInfoRow('Support Vulkan', profile.vulkanInfo.loaderPresent ? 'Chargeur système présent' : 'Chargeur non détecté'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('Évaluation des Moteurs IA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          ...caps.entries.map((e) => _buildCapItem(context, e.key, e.value)),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String val) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(val, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _buildCapItem(BuildContext context, EngineCategory cat, CapabilityEvaluation eval) {
    IconData icon;
    Color color;
    String statusLabel;

    switch (eval.status) {
      case CapabilityStatus.compatible:
        icon = Icons.check_circle_outline;
        color = Colors.green;
        statusLabel = 'Compatible';
        break;
      case CapabilityStatus.probablyCompatible:
        icon = Icons.help_outline;
        color = Colors.teal;
        statusLabel = 'Probablement compatible';
        break;
      case CapabilityStatus.limited:
        icon = Icons.warning_amber_rounded;
        color = Colors.orange;
        statusLabel = 'Capacité restreinte';
        break;
      case CapabilityStatus.notRecommended:
        icon = Icons.error_outline;
        color = Colors.redAccent;
        statusLabel = 'Non recommandé';
        break;
      case CapabilityStatus.unavailable:
        icon = Icons.block;
        color = Colors.red;
        statusLabel = 'Indisponible';
        break;
      case CapabilityStatus.unknown:
        icon = Icons.help_outline;
        color = Colors.grey;
        statusLabel = 'Indéterminé';
        break;
    }

    String catTitle;
    switch (cat) {
      case EngineCategory.liteRt:
        catTitle = 'Moteur LLM Intégré (LiteRT)';
        break;
      case EngineCategory.lmStudio:
        catTitle = 'LLM Avancé (LM Studio Local)';
        break;
      case EngineCategory.asr:
        catTitle = 'Transcription Vocale (CrispASR)';
        break;
      case EngineCategory.tts:
        catTitle = 'Synthèse Vocale (CrispTTS)';
        break;
      case EngineCategory.imageGen:
        catTitle = 'Génération d\'Images (SD Vulkan)';
        break;
      case EngineCategory.imageInpaint:
        catTitle = 'Retouche d\'Images (Inpainting)';
        break;
      case EngineCategory.portableStorage:
        catTitle = 'Espace de Stockage Portable';
        break;
    }

    final headerStatusText = cat == EngineCategory.portableStorage
        ? 'Stockage : $statusLabel'
        : 'Matériel : $statusLabel';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(80),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(catTitle, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ),
                Text(headerStatusText, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            _buildDimensionBadges(context, cat, eval, statusLabel),
            const SizedBox(height: 4),
            Text(eval.humanMessage, style: const TextStyle(fontSize: 12, color: Colors.black87)),
          ],
        ),
      ),
    );
  }

  Widget _buildDimensionBadges(BuildContext context, EngineCategory cat, CapabilityEvaluation eval, String statusLabel) {
    if (cat == EngineCategory.portableStorage) {
      return const SizedBox.shrink();
    }

    if (cat == EngineCategory.lmStudio) {
      final isOnline = eval.serviceState == ServiceReachability.reachable;
      final serviceColor = isOnline ? Colors.green : Colors.orange;
      final serviceText = isOnline ? 'Service joignable' : 'Service non joignable';

      return Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          _badge('Service local : $serviceText', serviceColor),
          _badge('Matériel : $statusLabel', Colors.teal),
          _badge('Modèle précis : Inconnu (LM Studio)', Colors.blueGrey),
        ],
      );
    }

    // Autres moteurs : Matériel, Runtime, Modèle
    final runtimeStr = switch (eval.runtimeAvailable) {
      RuntimeAvailability.available => 'Disponible',
      RuntimeAvailability.unavailable => 'Indisponible',
      RuntimeAvailability.unknown => 'Indéterminé',
      RuntimeAvailability.notApplicable => 'N/A',
    };
    final runtimeColor = switch (eval.runtimeAvailable) {
      RuntimeAvailability.available => Colors.green,
      RuntimeAvailability.unavailable => Colors.redAccent,
      RuntimeAvailability.unknown => Colors.grey,
      RuntimeAvailability.notApplicable => Colors.blueGrey,
    };

    final modelStr = switch (eval.modelInstalled) {
      ModelInstallationState.installed => 'Installé',
      ModelInstallationState.notInstalled => 'Non installé',
      ModelInstallationState.unknown => 'Indéterminé',
      ModelInstallationState.notApplicable => 'N/A',
    };
    final modelColor = switch (eval.modelInstalled) {
      ModelInstallationState.installed => Colors.green,
      ModelInstallationState.notInstalled => Colors.orange,
      ModelInstallationState.unknown => Colors.grey,
      ModelInstallationState.notApplicable => Colors.blueGrey,
    };

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _badge('Matériel : $statusLabel', Colors.teal),
        _badge('Runtime : $runtimeStr', runtimeColor),
        _badge('Modèle : $modelStr', modelColor),
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(120), width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
