import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

class DiarizationSettingsWidget extends StatelessWidget {
  final bool enabled;
  final void Function(bool enabled) onChanged;
  final int? minSpeakers;
  final int? maxSpeakers;
  final ValueChanged<int?> onMinSpeakersChanged;
  final ValueChanged<int?> onMaxSpeakersChanged;

  const DiarizationSettingsWidget({
    super.key,
    required this.enabled,
    required this.onChanged,
    required this.minSpeakers,
    required this.maxSpeakers,
    required this.onMinSpeakersChanged,
    required this.onMaxSpeakersChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.people, size: 20),
                const SizedBox(width: 8),
                Text(l.diarizationTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Switch(value: enabled, onChanged: onChanged),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.diarizationSubtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey.shade600),
            ),
            if (enabled) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _SpeakerBoundField(
                      label: l.minSpeakers,
                      value: minSpeakers,
                      onChanged: (value) {
                        onMinSpeakersChanged(value);
                        if (value != null &&
                            maxSpeakers != null &&
                            maxSpeakers! < value) {
                          onMaxSpeakersChanged(value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _SpeakerBoundField(
                      label: l.maxSpeakers,
                      value: maxSpeakers,
                      onChanged: (value) {
                        onMaxSpeakersChanged(value);
                        if (value != null &&
                            minSpeakers != null &&
                            minSpeakers! > value) {
                          onMinSpeakersChanged(value);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Auto laisse CrispASR estimer le nombre de locuteurs. '
                'Les bornes sont transmises au diariseur natif lorsqu’elles sont renseignées.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SpeakerBoundField extends StatelessWidget {
  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;

  const _SpeakerBoundField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 4),
        DropdownButtonFormField<int?>(
          initialValue: value,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          hint: Text(l.diarizationAuto),
          items: [
            DropdownMenuItem<int?>(
              value: null,
              child: Text(l.diarizationAuto),
            ),
            ...List.generate(10, (i) => i + 1).map(
              (count) => DropdownMenuItem<int?>(
                value: count,
                child: Text(count.toString()),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }
}
