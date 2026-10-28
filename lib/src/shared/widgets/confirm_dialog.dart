import 'package:flutter/material.dart';

/// Shows a yes/no confirmation dialog and resolves to true only when the user
/// taps the confirm action. [destructive] tints the confirm button with the
/// theme's error color for irreversible or sensitive actions.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Asks before a delete inside an item's editor (a list row, a card, a table
/// row or column, a Kanban stage or card), as the web does.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
}) => confirmAction(
  context,
  title: title,
  message: message,
  confirmLabel: 'Delete',
  destructive: true,
);

/// A short quote of what's being deleted, for the dialog's message, or
/// [fallback] when there's no text.
String quotedOr(String? text, String fallback) {
  final t = (text ?? '').trim();
  if (t.isEmpty) return fallback;
  return '"${t.length > 60 ? '${t.substring(0, 60)}...' : t}"';
}
