import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/presentation/widgets/vault_pin_prompt.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/tag_chip.dart';

/// Open a protected space with the vault PIN. True when it can be shown.
Future<bool> unlockSpace(BuildContext context, Space space) async {
  final ok = await askVaultPin(
    context,
    title: 'Open protected space',
    confirmLabel: 'Open',
    message:
        'Enter your vault PIN to open '
        '"${space.name.isEmpty ? 'Untitled' : space.name}".',
  );
  if (ok) ContentLock.instance.revealSpace(space.id);
  return ok;
}

/// Protect a space, or remove its protection. Protecting is instant and hides
/// it at once; removing it needs the PIN unless the space is already open.
/// True when it changed (the caller reloads).
Future<bool> toggleSpaceLock(
  BuildContext context,
  Space space, {
  required bool locked,
}) async {
  final lock = ContentLock.instance;
  if (locked && !lock.isRevealed(space.id)) {
    final ok = await askVaultPin(
      context,
      title: 'Remove protection',
      message:
          'Enter your vault PIN to remove protection. The space will open '
          'without the PIN.',
      confirmLabel: 'Remove protection',
    );
    if (!ok) return false;
  }
  try {
    await SpaceRepository(
      VaultSession.instance.masterKey,
    ).setLocked(space.id, !locked);
    if (context.mounted) {
      showSuccessSnack(
        context,
        locked ? 'Protection removed' : 'Space protected',
      );
    }
    return true;
  } catch (_) {
    if (context.mounted) {
      showErrorSnack(
        context,
        locked ? "Couldn't remove protection." : "Couldn't protect the space.",
      );
    }
    return false;
  }
}

/// Save a space's tags (added or removed on its card). True when saved; on a
/// failure it says so, and the card goes back to the old tags.
Future<bool> saveSpaceTags(
  BuildContext context,
  Space space,
  List<String> tags,
) async {
  try {
    await SpaceRepository(
      VaultSession.instance.masterKey,
    ).setTags(space.id, tags);
    return true;
  } catch (_) {
    if (context.mounted) showErrorSnack(context, "Couldn't update the tags.");
    return false;
  }
}

/// Add or remove a space's tags from inside it, in a dialog (its card does
/// this inline). Each change saves at once; true when any did, so the caller
/// reloads.
Future<bool> editSpaceTags(BuildContext context, Space space) async {
  var tags = [...space.tags];
  var changed = false;
  var open = true;
  // A fresh field after each commit (TagInput commits once).
  var inputKey = 0;

  Future<void> save(List<String> next, StateSetter setState) async {
    final before = tags;
    setState(() => tags = next);
    if (await saveSpaceTags(context, space, next)) {
      changed = true;
    } else if (open) {
      setState(() => tags = before);
    }
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: const Text('Tags'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final tag in tags)
                  TagChip(
                    label: tag,
                    color: tagColor(tag),
                    fill: tagColor(tag).withValues(alpha: 0.16),
                    onRemove: () =>
                        save(tags.where((t) => t != tag).toList(), setState),
                  ),
                TagInput(
                  key: ValueKey(inputKey),
                  onCommit: (added) {
                    setState(() => inputKey++);
                    final merged = {...tags, ...added}.toList();
                    if (merged.length != tags.length) save(merged, setState);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Type a tag and tap Done on the keyboard. Separate several with '
              'commas.',
              style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
  open = false;
  return changed;
}
