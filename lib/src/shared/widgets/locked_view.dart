import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/shared/widgets/icon_tile.dart';

/// A full-page "Protected" state with an Open button, shown in place of
/// protected content until the vault PIN opens it.
class LockedView extends StatelessWidget {
  const LockedView({super.key, required this.message, required this.onUnlock});

  final String message;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IconTile(icon: Icons.shield_outlined),
            const SizedBox(height: 16),
            Text('Protected', style: textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onUnlock, child: const Text('Open')),
          ],
        ),
      ),
    );
  }
}
