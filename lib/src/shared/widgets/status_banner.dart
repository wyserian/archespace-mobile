import 'package:flutter/material.dart';

/// The tone of a [StatusBanner].
enum StatusTone { info, pending }

/// A thin, full-width status banner pinned at the top of a list (e.g. an
/// offline notice or a pending-sync notice): a persistent state, unlike the
/// transient snackbars. [actionLabel] adds a button at its end ([onAction]
/// null disables it).
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.icon,
    required this.message,
    this.tone = StatusTone.info,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final StatusTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (tone) {
      StatusTone.info => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      StatusTone.pending => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
    };
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: fg, fontSize: 13)),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: fg,
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontWeight: FontWeight.w600),
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}
