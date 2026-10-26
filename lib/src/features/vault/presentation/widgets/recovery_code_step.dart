import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/icon_tile.dart';

/// One-time recovery-code display, shown after creating a vault or resetting the
/// PIN. The code is shown once; continuing waits until the user ticks that they
/// saved it (as on the web), since losing it and the PIN loses the data.
class RecoveryCodeStep extends StatefulWidget {
  const RecoveryCodeStep({
    super.key,
    required this.code,
    required this.onContinue,
    this.title = 'Save your recovery code',
  });

  final String code;
  final VoidCallback onContinue;
  final String title;

  @override
  State<RecoveryCodeStep> createState() => _RecoveryCodeStepState();
}

class _RecoveryCodeStepState extends State<RecoveryCodeStep> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const IconTile(icon: Icons.vpn_key_outlined),
        const SizedBox(height: 16),
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'This code is shown once. Use it to reset your PIN if you forget it. '
          'Store it somewhere safe.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  widget.code,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 22,
                    letterSpacing: 3,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.code));
                  showSuccessSnack(context, 'Recovery code copied.');
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Laid out like the sign-up terms checkbox.
        InkWell(
          onTap: () => setState(() => _saved = !_saved),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 24,
                  width: 24,
                  child: Checkbox(
                    value: _saved,
                    onChanged: (v) => setState(() => _saved = v ?? false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      "I've saved my recovery code somewhere safe.",
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saved ? widget.onContinue : null,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('I saved this code'),
          ),
        ),
      ],
    );
  }
}
