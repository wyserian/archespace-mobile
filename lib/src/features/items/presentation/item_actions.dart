import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_editor_screen.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_destinations_sheet.dart';
import 'package:archespace_mobile/src/features/storage/application/storage_counts.dart';
import 'package:archespace_mobile/src/features/reminders/application/reminder_notifications.dart';
import 'package:archespace_mobile/src/features/reminders/presentation/reminder_widgets.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/presentation/widgets/vault_pin_prompt.dart';
import 'package:archespace_mobile/src/shared/export/pdf_exporter.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';

/// Item actions shared by a space's screen and the dashboard: open to edit,
/// pin, duplicate, move (to another space or the dashboard), archive and
/// move-to-bin with undo, tags, PDF export, and the add-item sheet.
///
/// The host says which items it shows ([itemsSpaceId]: a space, or null for
/// the dashboard's items that belong to no space) and how to refresh after a
/// change ([reloadItems]).
mixin ItemActions<T extends StatefulWidget> on State<T> {
  /// The space whose items this screen shows, or null for the dashboard.
  String? get itemsSpaceId;

  /// Reload the screen's data after an item changed.
  Future<void> reloadItems();

  /// The space [item] belongs to, used when saving, duplicating or moving it.
  /// Defaults to the screen's own space; a screen that lists items from many
  /// spaces (Starred) overrides it to use each item's own `spaceId`. Saving
  /// writes the space back, so getting this wrong would move the item.
  String? spaceIdFor(SpaceItem item) => itemsSpaceId;

  /// Whether [item] sits in a read-only space: it opens as a viewer, and the
  /// host offers no edits for it.
  bool isItemReadOnly(SpaceItem item) => false;

  ItemRepository get _repo => ItemRepository(VaultSession.instance.masterKey);

  void showItemError(String message) {
    if (mounted) showErrorSnack(context, message);
  }

  Future<void> editItem(SpaceItem item) async {
    // A protected item (or one in a protected space) opens after the PIN.
    if (!await unlockItem(item) || !mounted) return;
    final readOnly = isItemReadOnly(item);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ItemEditorScreen(
          spaceId: spaceIdFor(item),
          type: item.type,
          existing: item,
          readOnly: readOnly,
          // The card's actions, with the same read-only limits.
          onTogglePin: readOnly ? null : togglePinItem,
          onToggleStar: toggleStarItem,
          onSetReminder: editItemReminder,
          onToggleLock: toggleLockItem,
          onDuplicate: readOnly ? null : duplicateItem,
          onMove: readOnly ? null : moveItem,
          onExport: exportItem,
          onArchive: readOnly ? null : archiveItem,
          onDelete: readOnly ? null : deleteItem,
        ),
      ),
    );
    if (saved == true && mounted) reloadItems();
  }

  Future<void> addItem(String type) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ItemEditorScreen(spaceId: itemsSpaceId, type: type),
      ),
    );
    if (saved == true && mounted) reloadItems();
  }

  /// Quick note: a Rich text item titled "Quick Note", opened with the
  /// cursor in the body. Leaving without typing saves nothing.
  Future<void> addQuickNote() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ItemEditorScreen(
          spaceId: itemsSpaceId,
          type: 'richtext',
          initialTitle: 'Quick Note',
          autofocusBody: true,
        ),
      ),
    );
    if (saved == true && mounted) reloadItems();
  }

  /// The add sheet: every item type offered there.
  void openAddItemSheet() {
    // Scroll-controlled with a fixed ~70% height so it opens taller than the
    // default half sheet but not full screen; the list scrolls within it. The
    // tiles are dense to keep the menu compact.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.7,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              for (final def in kItemTypes.where((d) => d.addable))
                ListTile(
                  visualDensity: VisualDensity.compact,
                  leading: Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: def
                          .colorFor(Theme.of(sheetContext).brightness)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      def.icon,
                      color: def.colorFor(Theme.of(sheetContext).brightness),
                      size: 20,
                    ),
                  ),
                  title: Text(
                    def.label,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(def.description),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    addItem(def.type);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Star / unstar. Starring never moves the item; it adds it to Starred.
  /// True when it changed.
  Future<bool> toggleStarItem(SpaceItem item) async {
    try {
      await _repo.setStarred(item.id, !item.starred);
      StorageCounts.instance.refresh();
      if (mounted) {
        reloadItems();
        showSuccessSnack(
          context,
          item.starred ? 'Removed from Starred' : 'Added to Starred',
        );
      }
      return true;
    } catch (_) {
      showItemError("Couldn't update the star.");
      return false;
    }
  }

  /// Set, change or remove [item]'s reminder. Asks to show notifications the
  /// first time one is saved, then reschedules them. The saved change, or null
  /// when cancelled or it failed.
  Future<ReminderEdit?> editItemReminder(SpaceItem item) async {
    final edit = await showReminderSheet(context, initial: item.reminder);
    if (edit == null) return null;
    final notifications = ReminderNotifications.instance;
    if (edit.reminder != null) await notifications.requestPermission();
    try {
      await _repo.setReminder(item.id, edit.reminder);
      notifications.sync();
      if (mounted) {
        reloadItems();
        showSuccessSnack(
          context,
          edit.reminder == null ? 'Reminder removed' : 'Reminder saved',
        );
      }
      return edit;
    } catch (_) {
      showItemError("Couldn't save the reminder.");
      return null;
    }
  }

  /// Open [item] with the vault PIN if its content is hidden. True when it
  /// can be shown (it already was, or the PIN was right).
  Future<bool> unlockItem(SpaceItem item) async {
    final lock = ContentLock.instance;
    if (!lock.isItemHidden(item)) return true;
    final ok = await askVaultPin(
      context,
      title: 'Open protected item',
      confirmLabel: 'Open',
      message:
          'Enter your vault PIN to open '
          '"${item.title.isEmpty ? 'Untitled' : item.title}".',
    );
    if (ok) lock.revealItem(item);
    return ok;
  }

  /// Protecting is instant and hides the content at once. Removing it needs
  /// the PIN, unless the item was already opened with it. True when it changed.
  Future<bool> toggleLockItem(SpaceItem item) async {
    final lock = ContentLock.instance;
    if (item.locked && !lock.isRevealed(item.id)) {
      final ok = await askVaultPin(
        context,
        title: 'Remove protection',
        message:
            'Enter your vault PIN to remove protection. The content will show '
            'without the PIN.',
        confirmLabel: 'Remove protection',
      );
      if (!ok) return false;
    }
    try {
      await _repo.setLocked(item.id, !item.locked);
      if (!item.locked) lock.hide(item.id);
      if (mounted) {
        reloadItems();
        showSuccessSnack(
          context,
          item.locked ? 'Protection removed' : 'Item protected',
        );
      }
      return true;
    } catch (_) {
      showItemError(
        item.locked
            ? "Couldn't remove protection."
            : "Couldn't protect the item.",
      );
      return false;
    }
  }

  /// True when it changed.
  Future<bool> togglePinItem(SpaceItem item) async {
    try {
      await _repo.setPinned(item.id, !item.pinned);
      if (mounted) reloadItems();
      return true;
    } catch (_) {
      showItemError("Couldn't update the item.");
      return false;
    }
  }

  Future<void> duplicateItem(SpaceItem item) async {
    try {
      await _repo.duplicateItem(spaceIdFor(item), item);
      if (mounted) {
        reloadItems();
        showSuccessSnack(context, 'Item duplicated');
      }
    } catch (_) {
      showItemError("Couldn't duplicate the item.");
    }
  }

  /// Ask where to move items now in [fromSpaceId] (null = the dashboard):
  /// another space, or - from inside a space - the dashboard. Null when
  /// cancelled or there's nowhere to go.
  Future<MoveTarget?> pickMoveTarget(String? fromSpaceId) async {
    List<Space> spaces;
    try {
      spaces = (await SpaceRepository(
        VaultSession.instance.masterKey,
      ).listSpaces()).spaces;
    } catch (_) {
      showItemError("Couldn't load spaces.");
      return null;
    }
    final exclude = {?fromSpaceId};
    final canMoveToDashboard = fromSpaceId != null;
    if (!mounted) return null;
    if (moveDestinations(spaces, exclude).isEmpty && !canMoveToDashboard) {
      showItemError('No space to move to.');
      return null;
    }
    return showSpaceDestinations(
      context,
      spaces: spaces,
      exclude: exclude,
      dashboardSubtitle: canMoveToDashboard ? 'Outside any space' : null,
    );
  }

  /// True when it moved.
  Future<bool> moveItem(SpaceItem item) async {
    final target = await pickMoveTarget(spaceIdFor(item));
    if (target == null) return false;
    try {
      await _repo.moveItem(item.id, target.id);
      if (mounted) {
        reloadItems();
        showSuccessSnack(context, 'Moved to ${target.name}');
      }
      return true;
    } catch (_) {
      showItemError("Couldn't move the item.");
      return false;
    }
  }

  /// Undo an archive or move-to-bin for the given items.
  Future<void> restoreItems(List<String> ids) async {
    try {
      await _repo.restoreItems(ids);
      StorageCounts.instance.refresh();
      if (mounted) reloadItems();
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't undo that.");
    }
  }

  /// True when it was archived.
  Future<bool> archiveItem(SpaceItem item) async {
    try {
      await _repo.archiveItem(item.id);
      StorageCounts.instance.refresh();
      if (mounted) {
        reloadItems();
        showUndoSnack(context, 'Item archived', () => restoreItems([item.id]));
      }
      return true;
    } catch (_) {
      showItemError("Couldn't archive the item.");
      return false;
    }
  }

  /// True when it went to the bin.
  Future<bool> deleteItem(SpaceItem item) async {
    final name = item.title.isEmpty ? 'this item' : '"${item.title}"';
    final ok = await confirmAction(
      context,
      title: 'Move item to bin?',
      message: '$name will be moved to the bin.',
      confirmLabel: 'Move to bin',
      destructive: true,
    );
    if (!ok) return false;
    try {
      await _repo.deleteItem(item.id);
      StorageCounts.instance.refresh();
      if (mounted) {
        reloadItems();
        showUndoSnack(
          context,
          'Item moved to bin',
          () => restoreItems([item.id]),
        );
      }
      return true;
    } catch (_) {
      showItemError("Couldn't delete the item.");
      return false;
    }
  }

  /// Save an item's tags. The host updates its list optimistically first; on
  /// failure this reloads to revert to the server's truth.
  Future<void> persistItemTags(SpaceItem item, List<String> tags) async {
    try {
      await _repo.setTags(item.id, tags);
    } catch (_) {
      if (mounted) reloadItems();
    }
  }

  /// A copy of [item] with new [tags] (for the optimistic tags update).
  SpaceItem itemWithTags(SpaceItem item, List<String> tags) => SpaceItem(
    id: item.id,
    type: item.type,
    title: item.title,
    content: item.content,
    pinned: item.pinned,
    starred: item.starred,
    locked: item.locked,
    spaceId: item.spaceId,
    tags: tags,
    reminder: item.reminder,
    createdAt: item.createdAt,
  );

  String pdfFileName(String name) {
    final safe = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    return '${safe.isEmpty ? 'export' : safe}.pdf';
  }

  Future<void> exportItem(SpaceItem item) => exportPdf(
    build: () => PdfExporter.buildItem(item),
    filename: pdfFileName(item.title),
    label: 'item',
  );

  /// Build the PDF behind a progress spinner (so a large space doesn't look
  /// like a frozen screen), then hand it to the share sheet. Any failure is
  /// surfaced instead of silently doing nothing.
  Future<void> exportPdf({
    required Future<Uint8List> Function() build,
    required String filename,
    required String label,
  }) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      // Yield a frame so the spinner paints before the (synchronous) PDF build.
      await Future<void>.delayed(Duration.zero);
      final bytes = await build();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      await Printing.sharePdf(bytes: bytes, filename: filename);
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      showItemError("Couldn't export the $label: $e");
    }
  }
}
