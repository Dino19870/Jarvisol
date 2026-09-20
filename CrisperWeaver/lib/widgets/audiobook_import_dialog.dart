// lib/widgets/audiobook_import_dialog.dart — Confirmation dialog proposing RAG indexing and rule profile selection upon file import.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/audiobook_rules.dart';

class AudiobookImportChoice {
  final bool shouldIndexInRag;
  final AudiobookRuleProfile profile;

  const AudiobookImportChoice({
    required this.shouldIndexInRag,
    required this.profile,
  });
}

class AudiobookImportDialog extends StatefulWidget {
  final String filePath;
  final AudiobookRuleProfile initialProfile;
  final List<AudiobookRuleProfile> profiles;

  const AudiobookImportDialog({
    super.key,
    required this.filePath,
    required this.initialProfile,
    required this.profiles,
  });

  static Future<AudiobookImportChoice?> show(
    BuildContext context, {
    required String filePath,
    required AudiobookRuleProfile initialProfile,
    required List<AudiobookRuleProfile> profiles,
  }) {
    return showDialog<AudiobookImportChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AudiobookImportDialog(
        filePath: filePath,
        initialProfile: initialProfile,
        profiles: profiles,
      ),
    );
  }

  @override
  State<AudiobookImportDialog> createState() => _AudiobookImportDialogState();
}

class _AudiobookImportDialogState extends State<AudiobookImportDialog> {
  late AudiobookRuleProfile _selectedProfile;
  late List<AudiobookRuleProfile> _profiles;

  @override
  void initState() {
    super.initState();
    _profiles = List.from(widget.profiles);
    if (!_profiles.any((p) => p.id == widget.initialProfile.id)) {
      _profiles.add(widget.initialProfile);
    }
    _selectedProfile = _profiles.firstWhere(
      (p) => p.id == widget.initialProfile.id,
      orElse: () => widget.initialProfile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fileName = p.basename(widget.filePath);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 580,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title & Icon
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.auto_stories, color: cs.primary, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Importation de Livre',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        fileName,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Profile Picker
            Text(
              'Profil de nettoyage et de découpage :',
              style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _selectedProfile.id,
                  items: _profiles.map((p) {
                    return DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        '${p.name} — ${p.description}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _selectedProfile = _profiles.firstWhere((p) => p.id == val);
                      });
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 18),

            // RAG Option Information Box
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.psychology, color: cs.primary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Indexation dans la Bibliothèque RAG',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Indexer le livre dans le RAG permet de bénéficier de la recherche sémantique, des résumés de chapitres instantanés et de la désambiguïsation IA des locuteurs.',
                          style: TextStyle(fontSize: 11, height: 1.4, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Action Buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('Annuler'),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(
                    AudiobookImportChoice(
                      shouldIndexInRag: false,
                      profile: _selectedProfile,
                    ),
                  ),
                  icon: const Icon(Icons.flash_on, size: 16),
                  label: const Text('Studio Direct (Sans RAG)'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(
                    AudiobookImportChoice(
                      shouldIndexInRag: true,
                      profile: _selectedProfile,
                    ),
                  ),
                  icon: const Icon(Icons.library_add_check, size: 16),
                  label: const Text('Indexer RAG & Ouvrir'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
