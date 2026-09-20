// lib/widgets/audiobook_rules_dialog.dart — Interactive dialog to configure text cleaning, chapter detection and dialogue diarization profiles.

import 'package:flutter/material.dart';
import '../models/audiobook_rules.dart';

class AudiobookRulesDialog extends StatefulWidget {
  final AudiobookRuleProfile currentProfile;
  final List<AudiobookRuleProfile> profiles;
  final ValueChanged<AudiobookRuleProfile> onProfileSelected;

  const AudiobookRulesDialog({
    super.key,
    required this.currentProfile,
    required this.profiles,
    required this.onProfileSelected,
  });

  static Future<AudiobookRuleProfile?> show(
    BuildContext context, {
    required AudiobookRuleProfile currentProfile,
    required List<AudiobookRuleProfile> profiles,
  }) {
    AudiobookRuleProfile selected = currentProfile;
    return showDialog<AudiobookRuleProfile>(
      context: context,
      builder: (ctx) => AudiobookRulesDialog(
        currentProfile: currentProfile,
        profiles: profiles,
        onProfileSelected: (p) => selected = p,
      ),
    ).then((_) => selected);
  }

  @override
  State<AudiobookRulesDialog> createState() => _AudiobookRulesDialogState();
}

class _AudiobookRulesDialogState extends State<AudiobookRulesDialog> {
  late List<AudiobookRuleProfile> _profiles;
  late AudiobookRuleProfile _selectedProfile;

  final TextEditingController _testTextController = TextEditingController();
  String _previewResult = '';

  @override
  void initState() {
    super.initState();
    _profiles = List.from(widget.profiles);
    if (!_profiles.any((p) => p.id == widget.currentProfile.id)) {
      _profiles.add(widget.currentProfile);
    }
    _selectedProfile = _profiles.firstWhere(
      (p) => p.id == widget.currentProfile.id,
      orElse: () => widget.currentProfile,
    );

    _testTextController.text = '''1. Club de jardinage. (N.d.t.)
*Oraiett Bris, encore sous le coup. Vf1a-w~upae ~, .___ .C
- Merci, docteur. Le témoin est à vous. Jake rassemble ses pet regagna tranquillement sa place.
- Je suis prête, déclara Lucy en souriant.
Il n'agissait pas au hasard, ce n'était pas un « fou ». Wilshire était à gauche.''';

    _runLivePreview();
  }

  @override
  void dispose() {
    _testTextController.dispose();
    super.dispose();
  }

  void _setSelectedProfile(AudiobookRuleProfile profile) {
    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      _profiles[idx] = profile;
    } else {
      _profiles.add(profile);
    }
    _selectedProfile = profile;
    widget.onProfileSelected(profile);
  }

  void _runLivePreview() {
    final input = _testTextController.text;
    final cleaned = _selectedProfile.applyCleaning(input);

    final lines = cleaned.split('\n');
    final buffer = StringBuffer();
    buffer.writeln('=== TEXTE NETTOYÉ ===\n');
    buffer.writeln(cleaned);
    buffer.writeln('\n=== DÉTECTION DIALOGUES / LOCUTEURS ===\n');

    final dialogueRegex = RegExp(_selectedProfile.dialogueMarkerRegex);
    final femaleRegex = RegExp(_selectedProfile.femaleKeywordsRegex, caseSensitive: false);

    for (final line in lines) {
      final lTrim = line.trim();
      if (lTrim.isEmpty) continue;

      if (dialogueRegex.hasMatch(lTrim)) {
        final isFemale = femaleRegex.hasMatch(lTrim);
        buffer.writeln('[${isFemale ? 'FEMME' : 'HOMME'}] $lTrim');
      } else {
        buffer.writeln('[NARRATEUR] $lTrim');
      }
    }

    setState(() {
      _previewResult = buffer.toString();
    });
  }

  Future<void> _showAddRuleDialog() async {
    final descController = TextEditingController();
    final patternController = TextEditingController();
    final replController = TextEditingController();

    final result = await showDialog<TextCleaningRule>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.add_circle, color: Colors.blue),
            SizedBox(width: 8),
            Text('Ajouter une Règle Personnalisée', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 450,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: descController,
                decoration: const InputDecoration(
                  labelText: 'Description de la règle',
                  hintText: 'Ex: Remplacer nom mal scanné',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: patternController,
                decoration: const InputDecoration(
                  labelText: 'Motif recherché (Texte ou Regex)',
                  hintText: r'Ex: J[a4]ke ou - ',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: replController,
                decoration: const InputDecoration(
                  labelText: 'Remplacement',
                  hintText: 'Ex: Jake ou — ',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              if (patternController.text.trim().isNotEmpty) {
                Navigator.of(ctx).pop(
                  TextCleaningRule(
                    id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                    description: descController.text.trim().isNotEmpty
                        ? descController.text.trim()
                        : patternController.text.trim(),
                    pattern: patternController.text.trim(),
                    replacement: replController.text,
                  ),
                );
              }
            },
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );

    if (result != null) {
      final updatedRules = List<TextCleaningRule>.from(_selectedProfile.cleaningRules)..add(result);
      setState(() {
        _setSelectedProfile(
          _selectedProfile.copyWith(cleaningRules: updatedRules),
        );
      });
      _runLivePreview();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 850, maxHeight: 650),
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.85,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.tune, color: cs.primary, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Règles de Découpage & Nettoyage des Livres',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(_selectedProfile),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Profile Selector Dropdown / Cards
            Text(
              'Profil de traitement actif :',
              style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
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
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      final found = _profiles.firstWhere((p) => p.id == val);
                      setState(() => _setSelectedProfile(found));
                      _runLivePreview();
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Tabs / Main Body: Rules List vs Live Test
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left: Active Rules in profile
                  Expanded(
                    flex: 4,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.cleaning_services, size: 18, color: cs.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Filtres de Nettoyage (${_selectedProfile.cleaningRules.length})',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add_circle, size: 20),
                                tooltip: 'Ajouter une règle personnalisée',
                                onPressed: _showAddRuleDialog,
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          const Divider(height: 16),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _selectedProfile.cleaningRules.length,
                              itemBuilder: (ctx, i) {
                                final r = _selectedProfile.cleaningRules[i];
                                return Material(
                                  color: Colors.transparent,
                                  child: ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Checkbox(
                                      value: r.enabled,
                                      onChanged: (val) {
                                        if (val != null) {
                                          final updatedRules = List<TextCleaningRule>.from(_selectedProfile.cleaningRules);
                                          updatedRules[i] = r.copyWith(enabled: val);
                                          setState(() {
                                            _setSelectedProfile(
                                              _selectedProfile.copyWith(
                                                cleaningRules: updatedRules,
                                              ),
                                            );
                                          });
                                          _runLivePreview();
                                        }
                                      },
                                    ),
                                    title: Text(r.description, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                    subtitle: Text(
                                      r.replacement.isNotEmpty ? '${r.pattern} ➔ "${r.replacement}"' : r.pattern,
                                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: cs.onSurfaceVariant),
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete_outline, size: 16),
                                      tooltip: 'Supprimer',
                                      onPressed: () {
                                        final updatedRules = List<TextCleaningRule>.from(_selectedProfile.cleaningRules)..removeAt(i);
                                        setState(() {
                                          _setSelectedProfile(
                                            _selectedProfile.copyWith(
                                              cleaningRules: updatedRules,
                                            ),
                                          );
                                        });
                                        _runLivePreview();
                                      },
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),

                  // Right: Live Test Preview
                  Expanded(
                    flex: 5,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.preview, size: 18, color: cs.secondary),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Test & Prévisualisation en direct',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 90,
                            child: TextField(
                              controller: _testTextController,
                              maxLines: null,
                              expands: true,
                              style: const TextStyle(fontSize: 11),
                              decoration: const InputDecoration(
                                hintText: 'Collez un extrait de livre ici pour tester...',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (_) => _runLivePreview(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  _previewResult,
                                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Footer Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(_selectedProfile),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Appliquer le profil'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
