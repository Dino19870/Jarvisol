// lib/widgets/audiobook_export_dialog.dart — Multi-format export dialog for audiobook projects.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/audiobook_models.dart';
import '../services/audiobook_service.dart';
import '../services/log_service.dart';

enum AudiobookExportFormat {
  docx('Document Word (.docx)', 'docx', Icons.description, Color(0xFF2B579A)),
  pdf('Document PDF (.pdf)', 'pdf', Icons.picture_as_pdf, Color(0xFFE53935)),
  html('Page Web Interactive (.html)', 'html', Icons.html, Color(0xFFE65100)),
  markdown('Script Markdown (.md)', 'md', Icons.code, Color(0xFF00897B)),
  txt('Scénario Texte (.txt)', 'txt', Icons.text_snippet, Color(0xFF5E35B1)),
  project('Projet Complet Studio (.cwproject)', 'cwproject', Icons.save, Color(0xFF1E88E5));

  final String label;
  final String extension;
  final IconData icon;
  final Color color;

  const AudiobookExportFormat(this.label, this.extension, this.icon, this.color);
}

class AudiobookExportDialog extends ConsumerStatefulWidget {
  final AudiobookProject project;

  const AudiobookExportDialog({super.key, required this.project});

  static Future<void> show(BuildContext context, AudiobookProject project) {
    return showDialog(
      context: context,
      builder: (ctx) => AudiobookExportDialog(project: project),
    );
  }

  @override
  ConsumerState<AudiobookExportDialog> createState() => _AudiobookExportDialogState();
}

class _AudiobookExportDialogState extends ConsumerState<AudiobookExportDialog> {
  AudiobookExportFormat _selectedFormat = AudiobookExportFormat.docx;
  bool _isExporting = false;
  String? _exportedFilePath;

  Future<void> _export() async {
    setState(() => _isExporting = true);
    final svc = ref.read(audiobookServiceProvider);

    try {
      final defaultName = '${widget.project.title.replaceAll(RegExp(r'[^\w\s\-]'), '_')}.${_selectedFormat.extension}';

      String? savePath;
      try {
        savePath = await FilePicker.saveFile(
          dialogTitle: 'Exporter le projet audio',
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: [_selectedFormat.extension],
          bytes: Uint8List(0),
        );
      } catch (_) {}

      if (savePath == null) {
        final docsDir = await getApplicationDocumentsDirectory();
        savePath = p.join(docsDir.path, defaultName);
      }

      switch (_selectedFormat) {
        case AudiobookExportFormat.docx:
          await svc.exportProjectToDocx(widget.project, savePath);
          break;
        case AudiobookExportFormat.pdf:
          await svc.exportProjectToPdf(widget.project, savePath);
          break;
        case AudiobookExportFormat.html:
          final html = svc.exportProjectToHtml(widget.project);
          await File(savePath).writeAsString(html);
          break;
        case AudiobookExportFormat.markdown:
          final md = svc.exportProjectToMarkdown(widget.project);
          await File(savePath).writeAsString(md);
          break;
        case AudiobookExportFormat.txt:
          final txt = svc.exportProjectToPlainText(widget.project);
          await File(savePath).writeAsString(txt);
          break;
        case AudiobookExportFormat.project:
          await svc.saveProjectToFile(widget.project, savePath);
          break;
      }

      setState(() {
        _exportedFilePath = savePath;
        _isExporting = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Fichier exporté avec succès : $savePath'),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e, st) {
      Log.instance.e('audiobook_export', 'Erreur lors de l\'exportation: $e\n$st');
      setState(() => _isExporting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur d\'export : $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 580,
        height: 520,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.file_download, color: cs.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Exporter le Document Découpé',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${widget.project.title} • ${widget.project.chapters.length} chapitres',
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),

            Text(
              'Sélectionnez le format de destination :',
              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            // Format Selection Cards in Scrollable Area
            Expanded(
              child: ListView(
                children: AudiobookExportFormat.values.map((format) {
                  final isSelected = _selectedFormat == format;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: isSelected ? cs.primaryContainer.withValues(alpha: 0.3) : cs.surfaceContainerLowest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: isSelected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.3),
                          width: isSelected ? 1.5 : 1,
                        ),
                      ),
                      child: RadioListTile<AudiobookExportFormat>(
                        value: format,
                        groupValue: _selectedFormat,
                        onChanged: (val) {
                          if (val != null) setState(() => _selectedFormat = val);
                        },
                        secondary: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: format.color.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(format.icon, color: format.color, size: 20),
                        ),
                        title: Text(
                          format.label,
                          style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w500, fontSize: 13),
                        ),
                        subtitle: Text(
                          format == AudiobookExportFormat.project
                              ? 'Conserve 100% des réglages, voix et audio pour réouverture sans perte'
                              : 'Document lisible avec attribution des personnages et dialogues',
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 12),

            // Result Actions if exported
            if (_exportedFilePath != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _exportedFilePath!,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => launchUrl(Uri.file(_exportedFilePath!)),
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: const Text('Ouvrir'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Fermer'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isExporting ? null : _export,
                  icon: _isExporting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download, size: 18),
                  label: Text(_isExporting ? 'Exportation...' : 'Exporter maintenant'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
