import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_actions.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_card.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_detail_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_editor_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_lock_actions.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/space_card.dart';
import 'package:archespace_mobile/src/features/storage/application/storage_counts.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/realtime/reload_when_shown.dart';
import 'package:archespace_mobile/src/shared/realtime/table_watcher.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';
import 'package:archespace_mobile/src/shared/widgets/offline_banner.dart';
import 'package:archespace_mobile/src/shared/widgets/scrollable_message.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// Quick access to starred spaces and items from anywhere. Starring never
/// moves anything - spaces and items keep their place in their own lists; this
/// screen only gathers what's starred, each item labelled with where it lives.
class StarredScreen extends StatefulWidget {
  const StarredScreen({super.key});

  @override
  State<StarredScreen> createState() => _StarredScreenState();
}

class _StarredScreenState extends State<StarredScreen>
    with ItemActions<StarredScreen>, ReloadWhenShown<StarredScreen> {
  // Realtime changes reload this screen only while it's showing.
  @override
  Future<void> reloadShown() => _load();

  // No single space here.
  @override
  String? get itemsSpaceId => null;

  // Items come from many spaces: always save, duplicate and move each one
  // within its own space (saving writes the space back).
  @override
  String? spaceIdFor(SpaceItem item) => item.spaceId;

  // An item from a read-only space opens as a viewer and offers no edits.
  @override
  bool isItemReadOnly(SpaceItem item) =>
      item.spaceId != null &&
      (_spaces ?? const <Space>[]).any(
        (s) => s.id == item.spaceId && s.readOnly,
      );

  @override
  Future<void> reloadItems() => _load();

  List<Space>? _spaces;
  List<SpaceItem>? _items;
  Object? _error;
  bool _offline = false;
  TableWatcher? _spacesWatcher;
  TableWatcher? _itemsWatcher;

  SpaceRepository get _spaceRepo =>
      SpaceRepository(VaultSession.instance.masterKey);

  @override
  void initState() {
    super.initState();
    _load();
    _spacesWatcher = TableWatcher(
      channelName: 'starred-spaces',
      table: 'spaces',
      onChange: reloadWhenShown,
    );
    final userId = currentUserId();
    if (userId != null) {
      _itemsWatcher = TableWatcher(
        channelName: 'starred-items',
        table: 'space_items',
        filterColumn: 'user_id',
        filterValue: userId,
        onChange: reloadWhenShown,
      );
    }
  }

  @override
  void dispose() {
    _spacesWatcher?.dispose();
    _itemsWatcher?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final key = VaultSession.instance.masterKey;
      final results = await Future.wait([
        SpaceRepository(key).listSpaces(),
        ItemRepository(key).listStarredItems(),
      ]);
      final spaces = results[0] as ({List<Space> spaces, bool fromCache});
      final items = results[1] as ({List<SpaceItem> items, bool fromCache});
      if (mounted) {
        setState(() {
          _spaces = spaces.spaces;
          _items = items.items;
          _offline = spaces.fromCache || items.fromCache;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  // Space actions
  Future<void> _spaceOp(
    Future<void> Function(SpaceRepository) op,
    String errorMsg, {
    String? success,
  }) async {
    try {
      await op(_spaceRepo);
      StorageCounts.instance.refresh();
      if (mounted) {
        _load();
        if (success != null) showSuccessSnack(context, success);
      }
    } catch (_) {
      showItemError(errorMsg);
    }
  }

  Future<void> _restoreSpace(String id) =>
      _spaceOp((r) => r.restoreSpaces([id]), "Couldn't undo that.");

  Future<void> _archiveSpace(Space space) async {
    try {
      await _spaceRepo.archiveSpace(space.id);
      StorageCounts.instance.refresh();
      if (mounted) {
        _load();
        showUndoSnack(context, 'Space archived', () => _restoreSpace(space.id));
      }
    } catch (_) {
      showItemError("Couldn't archive the space.");
    }
  }

  Future<void> _deleteSpace(Space space) async {
    final ok = await confirmAction(
      context,
      title: 'Move space to bin?',
      message:
          '"${space.name.isEmpty ? 'Untitled' : space.name}" and its items '
          'will be moved to the recycle bin.',
      confirmLabel: 'Move to bin',
    );
    if (!ok) return;
    try {
      await _spaceRepo.deleteSpace(space.id);
      StorageCounts.instance.refresh();
      if (mounted) {
        _load();
        showUndoSnack(
          context,
          'Space moved to bin',
          () => _restoreSpace(space.id),
        );
      }
    } catch (_) {
      showItemError("Couldn't delete the space.");
    }
  }

  Future<void> _editSpace(Space space) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SpaceEditorScreen(existing: space)),
    );
    if (saved == true && mounted) _load();
  }

  void _openSpace(Space space) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => SpaceDetailScreen(space: space),
          ),
        )
        .then((_) {
          if (mounted) _load();
        });
  }

  Future<void> _setItemTags(SpaceItem item, List<String> tags) async {
    // Optimistic: reflect the change immediately, then persist.
    setState(() {
      _items = _items
          ?.map((i) => i.id == item.id ? itemWithTags(i, tags) : i)
          .toList();
    });
    await persistItemTags(item, tags);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const AppDrawer(current: DrawerPage.starred),
      drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
      // Keep Back; the drawer opens with a slide from the left.
      appBar: AppBar(leading: const BackButton(), title: const Text('Starred')),
      body: _spaces == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: Column(
                children: [
                  if (_offline) const OfflineBanner(),
                  Expanded(
                    child: RefreshIndicator(onRefresh: _load, child: _body()),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _body() {
    if (_spaces == null && _error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: "Couldn't load starred",
        message: 'Something went wrong. Check your connection and try again.',
        actionLabel: 'Retry',
        actionIcon: Icons.refresh,
        onAction: _load,
        destructiveIcon: true,
      );
    }
    final allSpaces = _spaces ?? const <Space>[];
    final spaces = allSpaces.where((s) => s.starred).toList();
    final items = _items ?? const <SpaceItem>[];
    if (spaces.isEmpty && items.isEmpty) {
      return const StateMessage(
        icon: Icons.star_outline_rounded,
        title: 'Nothing starred yet',
        message:
            'Star a space or an item from its menu to keep it here for '
            'quick access.',
      );
    }
    final names = {
      for (final s in allSpaces) s.id: s.name.isEmpty ? 'Untitled' : s.name,
    };
    final both = spaces.isNotEmpty && items.isNotEmpty;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      children: [
        if (both) _sectionLabel('Spaces'),
        for (final s in spaces) _spaceCard(s),
        if (both) _sectionLabel('Items'),
        for (final i in items)
          _itemCard(
            i,
            i.spaceId == null ? 'Dashboard' : names[i.spaceId] ?? 'Space',
          ),
      ],
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  Widget _spaceCard(Space space) => SpaceCard(
    space: space,
    onTap: () => _openSpace(space),
    onTogglePin: () => _spaceOp(
      (r) => r.setPinned(space.id, !space.pinned),
      "Couldn't update the space.",
    ),
    onToggleStar: () => _spaceOp(
      (r) => r.setStarred(space.id, !space.starred),
      "Couldn't update the star.",
      success: space.starred ? 'Removed from Starred' : 'Added to Starred',
    ),
    onToggleReadOnly: () => _spaceOp(
      (r) => r.setReadOnly(space.id, !space.readOnly),
      "Couldn't change read-only.",
      success: space.readOnly ? 'Editing allowed' : 'Space is now read-only',
    ),
    onToggleLock: () async {
      if (await toggleSpaceLock(context, space, locked: space.locked) &&
          mounted) {
        _load();
      }
    },
    onEdit: () => _editSpace(space),
    onDuplicate: () => _spaceOp(
      (r) => r.duplicateSpace(space),
      "Couldn't duplicate the space.",
      success: 'Space duplicated',
    ),
    onArchive: () => _archiveSpace(space),
    onDelete: () => _deleteSpace(space),
  );

  Widget _itemCard(SpaceItem item, String where) {
    final readOnly = isItemReadOnly(item);
    return ItemCard(
      item: item,
      contextLabel: where,
      readOnly: readOnly,
      onTap: isEditableType(item.type) ? () => editItem(item) : null,
      onTogglePin: readOnly ? null : () => togglePinItem(item),
      onToggleStar: () => toggleStarItem(item),
      onSetReminder: _offline ? null : () => editItemReminder(item),
      onToggleLock: () => toggleLockItem(item),
      onDuplicate: readOnly ? null : () => duplicateItem(item),
      onMove: readOnly ? null : () => moveItem(item),
      onArchive: readOnly ? null : () => archiveItem(item),
      onExport: () => exportItem(item),
      onDelete: readOnly ? null : () => deleteItem(item),
      onSetTags: _offline || readOnly
          ? null
          : (tags) => _setItemTags(item, tags),
    );
  }
}
