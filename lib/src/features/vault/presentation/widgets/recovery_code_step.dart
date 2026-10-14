import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/icon_tile.dart';

/// One-time recovery-code display, shown after creating a vault or resetting the
/// PIN. The code is shown once and must be saved before continuing.
class RecoveryCodeStep extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const IconTile(icon: Icons.vpn_key_outlined),
        const SizedBox(height: 16),
        Text(
          title,
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
                  code,
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
                  Clipboard.setData(ClipboardData(text: code));
                  showSuccessSnack(context, 'Recovery code copied.');
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: onContinue,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('I saved this code'),
          ),
        ),
      ],
    );
  }
}
