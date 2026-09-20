// lib/widgets/context_capsule_dialog.dart
//
// Boîte de dialogue permettant à l'utilisateur de consulter la capsule active
// de contexte conversationnel compacté (sections, métadonnées, tokens économisés).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/conversation_capsule.dart';

class ContextCapsuleDialog extends StatelessWidget {
  final ConversationCapsule capsule;
  final VoidCallback? onTriggerManualCompaction;
  final bool isCompacting;

  const ContextCapsuleDialog({
    super.key,
    required this.capsule,
    this.onTriggerManualCompaction,
    this.isCompacting = false,
  });

  static Future<void> show(
    BuildContext context, {
    required ConversationCapsule capsule,
    VoidCallback? onTriggerManualCompaction,
    bool isCompacting = false,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => ContextCapsuleDialog(
        capsule: capsule,
        onTriggerManualCompaction: onTriggerManualCompaction,
        isCompacting: isCompacting,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.compress_rounded, color: Colors.tealAccent, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Capsule de Contexte v',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Économie : \ tokens (\ → \)',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.tealAccent : Colors.teal.shade800,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            tooltip: 'Copier le texte complet de la capsule',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: capsule.toContextPrompt()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Capsule copiée dans le presse-papier'), duration: Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Bandeau d'information métadonnées
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Modèle : ', style: const TextStyle(fontSize: 11)),
                        Text('Messages couverts : \ à ', style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Générée le : ', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                        Text('Époque : ', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              if (capsule.objective.isNotEmpty)
                _buildSection('🎯 Objectif actif', [capsule.objective], Colors.amberAccent, isDark),

              if (capsule.constraints.isNotEmpty)
                _buildSection('⚠️ Contraintes actives', capsule.constraints, Colors.orangeAccent, isDark),

              if (capsule.decisions.isNotEmpty)
                _buildSection('⚖️ Décisions établies', capsule.decisions, Colors.blueAccent, isDark),

              if (capsule.keyFacts.isNotEmpty)
                _buildSection('📌 Faits importants & données', capsule.keyFacts, Colors.cyanAccent, isDark),

              if (capsule.identifiersAndPaths.isNotEmpty)
                _buildSection('🏷️ Identifiants, Chemins & Nombres', capsule.identifiersAndPaths, Colors.purpleAccent, isDark),

              if (capsule.workDone.isNotEmpty)
                _buildSection('🔨 Travail déjà effectué', capsule.workDone, Colors.greenAccent, isDark),

              if (capsule.results.isNotEmpty)
                _buildSection('📊 Résultats obtenus', capsule.results, Colors.tealAccent, isDark),

              if (capsule.incidents.isNotEmpty)
                _buildSection('🚨 Incidents / Limites connus', capsule.incidents, Colors.redAccent, isDark),

              if (capsule.abandoned.isNotEmpty)
                _buildSection('❌ Éléments rejetés / abandonnés', capsule.abandoned, Colors.grey, isDark),

              if (capsule.openPoints.isNotEmpty)
                _buildSection('❓ Points encore ouverts', capsule.openPoints, Colors.lightBlueAccent, isDark),

              if (capsule.uncertainties.isNotEmpty)
                _buildSection('⚡ Incertitudes / Non confirmés', capsule.uncertainties, Colors.deepOrangeAccent, isDark),

              if (capsule.nextStep.isNotEmpty)
                _buildSection('➡️ Prochaine étape attendue', [capsule.nextStep], Colors.lightGreenAccent, isDark),
            ],
          ),
        ),
      ),
      actions: [
        if (onTriggerManualCompaction != null)
          TextButton.icon(
            icon: isCompacting
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 16),
            label: Text(isCompacting ? 'Compactage en cours...' : 'Recompacter'),
            onPressed: isCompacting ? null : onTriggerManualCompaction,
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }

  Widget _buildSection(String title, List<String> items, Color accentColor, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: isDark ? accentColor : Colors.black87,
                ),
              ),
              const SizedBox(width: 6),
              Text('(\)', style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey.shade900.withValues(alpha: 0.6) : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: accentColor.withValues(alpha: 0.3), width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: items.map((it) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      Expanded(
                        child: SelectableText(
                          it,
                          style: const TextStyle(fontSize: 11.5, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
