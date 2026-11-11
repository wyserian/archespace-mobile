import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_actions.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_destinations_sheet.dart';
import 'package:archespace_mobile/src/features/storage/application/storage_counts.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';

/// "2 spaces", "3 items", or "2 spaces and 3 items".
String describeSelection(int spaces, int items) => [
  if (spaces > 0) '$spaces ${spaces == 1 ? 'space' : 'spaces'}',
  if (items > 0) '$items ${items == 1 ? 'item' : 'items'}',
].join(' and ');

/// Selecting spaces and items together, and the bulk actions on them, for the
/// screens that list both: the home screen (spaces and dashboard items) and a
/// space's page (its sub-spaces and items). A bulk action leaves select mode
/// and reloads the screen ([ItemActions.reloadItems]).
mixin SpaceItemSelection<T extends StatefulWidget> on ItemActions<T> {
  bool selectMode = false;
  final Set<String> selectedSpaces = {};
  final Set<String> selectedItems = {};

  int get selectedCount => selectedSpaces.length + selectedItems.length;

  SpaceRepository get _spaceRepo =>
      SpaceRepository(VaultSession.instance.masterKey);
  ItemRepository get _itemRepo =>
      ItemRepository(VaultSession.instance.masterKey);

  void enterSelect() => setState(() => selectMode = true);

  void exitSelect() => setState(() {
    selectMode = false;
    selectedSpaces.clear();
    selectedItems.clear();
  });

  void toggleSelectedSpace(String id) => setState(() {
    if (!selectedSpaces.remove(id)) selectedSpaces.add(id);
  });

  void toggleSelectedItem(String id) => setState(() {
    if (!selectedItems.remove(id)) selectedItems.add(id);
  });

  /// Select exactly [spaceIds] and [itemIds] (Select all).
  void selectOnly(Iterable<String> spaceIds, Iterable<String> itemIds) =>
      setState(() {
        selectedSpaces
          ..clear()
          ..addAll(spaceIds);
        selectedItems
          ..clear()
          ..addAll(itemIds);
      });

  /// Run [op] on the selection, then leave select mode and reload. Whether it
  /// worked; a failure is shown.
  Future<bool> runBulk(
    Future<void> Function(List<String> spaceIds, List<String> itemIds) op,
  ) async {
    final spaceIds = selectedSpaces.toList();
    final itemIds = selectedItems.toList();
    if (spaceIds.isEmpty && itemIds.isEmpty) return false;
    try {
      await op(spaceIds, itemIds);
      if (mounted) {
        exitSelect();
        reloadItems();
      }
      return true;
    } catch (_) {
      showItemError("Couldn't complete that action.");
      return false;
    }
  }

  /// Undo an archive or a move to the bin of these spaces and items.
  Future<void> undoRemove(List<String> spaceIds, List<String> itemIds) async {
    try {
      await Future.wait([
        _spaceRepo.restoreSpaces(spaceIds),
        _itemRepo.restoreItems(itemIds),
      ]);
      StorageCounts.instance.refresh();
      if (mounted) reloadItems();
    } catch (_) {
      showItemError("Couldn't undo that.");
    }
  }

  Future<void> bulkSetPinned(bool pinned) => runBulk(
    (spaceIds, itemIds) => Future.wait([
      _spaceRepo.bulkSetPinned(spaceIds, pinned),
      _itemRepo.bulkSetPinned(itemIds, pinned),
    ]),
  );

  Future<void> bulkArchive() async {
    final spaceIds = selectedSpaces.toList();
    final itemIds = selectedItems.toList();
    final ok = await runBulk(
      (s, i) =>
          Future.wait([_spaceRepo.bulkArchive(s), _itemRepo.bulkArchive(i)]),
    );
    StorageCounts.instance.refresh();
    if (ok && mounted) {
      showUndoSnack(
        context,
        '${describeSelection(spaceIds.length, itemIds.length)} archived',
        () => undoRemove(spaceIds, itemIds),
      );
    }
  }

  /// Move the selection to the bin, after asking, as for a single item.
  Future<void> bulkDelete() async {
    final spaceIds = selectedSpaces.toList();
    final itemIds = selectedItems.toList();
    final label = describeSelection(spaceIds.length, itemIds.length);
    final confirmed = await confirmAction(
      context,
      title: 'Move $label to bin?',
      message: spaceIds.isNotEmpty
          ? 'They and their items go to the bin.'
          : 'They go to the bin.',
      confirmLabel: 'Move to bin',
      destructive: true,
    );
    if (!confirmed) return;
    final ok = await runBulk(
      (s, i) =>
          Future.wait([_spaceRepo.bulkDelete(s), _itemRepo.bulkDelete(i)]),
    );
    StorageCounts.instance.refresh();
    if (ok && mounted) {
      showUndoSnack(
        context,
        '$label moved to bin',
        () => undoRemove(spaceIds, itemIds),
      );
    }
  }

  /// Move the selected items into another space, or to the dashboard.
  Future<void> bulkMoveItems() async {
    final target = await pickMoveTarget(itemsSpaceId);
    if (target == null) return;
    await runBulk((_, itemIds) => _itemRepo.bulkMove(itemIds, target.id));
  }

  /// Move the selected spaces into another space, with everything in them.
  Future<void> bulkMoveSpaces() async {
    if (await moveSpacesTo(context, selectedSpaces.toList()) && mounted) {
      exitSelect();
      reloadItems();
    }
  }
}
