import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/presentation/widgets/vault_pin_prompt.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';

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
