import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/data/secret_migration.dart';
import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_actions.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_card.dart';
import 'package:archespace_mobile/src/features/search/presentation/search_screen.dart';
import 'package:archespace_mobile/src/features/spaces/application/drawer_spaces.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_detail_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_editor_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_lock_actions.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/space_card.dart';
import 'package:archespace_mobile/src/features/storage/application/storage_counts.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/offline/write_queue.dart';
import 'package:archespace_mobile/src/shared/realtime/reload_when_shown.dart';
import 'package:archespace_mobile/src/shared/realtime/table_watcher.dart';
import 'package:archespace_mobile/src/shared/sort/sort.dart';
import 'package:archespace_mobile/src/shared/widgets/action_icon_button.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/bulk_action_bar.dart';
import 'package:archespace_mobile/src/shared/widgets/create_fabs.dart';
import 'package:archespace_mobile/src/shared/widgets/offline_banner.dart';
import 'package:archespace_mobile/src/shared/widgets/status_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:archespace_mobile/src/shared/widgets/scrollable_message.dart';
import 'package:archespace_mobile/src/shared/widgets/tag_filter_bar.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// The dashboard: the user's top-level spaces, then their dashboard items
/// (items that belong to no space), laid out like the inside of a space and
/// sharing one tag filter, sort, view and selection.
class SpacesScreen extends StatefulWidget {
  const SpacesScreen({super.key});

  @override
  State<SpacesScreen> createState() => _SpacesScreenState();
}

class _SpacesScreenState extends State<SpacesScreen>
    with ItemActions<SpacesScreen>, ReloadWhenShown<SpacesScreen> {
  // Realtime changes reload this screen only while it's showing.
  @override
  Future<void> reloadShown() => _load();

  // Dashboard items belong to no space.
  @override
  String? get itemsSpaceId => null;

  @override
  Future<void> reloadItems() => _load();

  List<Space>? _spaces;
  List<SpaceItem>? _items;
  Object? _error;
  bool _offline = false;
  TableWatcher? _watcher;
  TableWatcher? _itemsWatcher;
  bool _selectMode = false;
  final Set<String> _selected = {};
  final Set<String> _selectedItems = {};
  String _sort = kSortDefault;
  String _view = 'list';
  final Set<String> _activeTags = {};
  // A dashboard item opened from search: scrolled to and briefly highlighted.
  final GlobalKey _focusKey = GlobalKey();
  String? _focusItemId;
  String? _flashId;

  @override
  void initState() {
    super.initState();
    // The drawer on other screens opens spaces through here.
    DrawerSpaces.instance.onOpenSpace = _openSpace;
    _load();
    // The Secret type was removed: turn any existing secrets into Notes once
    // per session (only an unlocked device can open them), then refresh.
    SecretMigration.runOnce(VaultSession.instance.masterKey).then((converted) {
      if (converted == 0 || !mounted) return;
      _load();
      showSuccessSnack(
        context,
        '$converted ${converted == 1 ? 'secret was' : 'secrets were'} '
        'turned into Notes.',
      );
    });
    // Warm the drawer's archive/bin counts at launch so they're ready before
    // the drawer is opened (mirrors the always-in-memory spaces count).
    StorageCounts.instance.refresh();
    SharedPreferences.getInstance().then((prefs) {
      final sort = prefs.getString('sort_spaces');
      final view = prefs.getString('spaces_view');
      if (!mounted) return;
      setState(() {
        if (sort != null) _sort = sort;
        if (view == 'grid') _view = 'grid';
      });
    });
    _watcher = TableWatcher(
      channelName: 'spaces-realtime',
      table: 'spaces',
      onChange: reloadWhenShown,
    );
    // Realtime filters can't express "space_id is null", so the dashboard
    // listens to all of the user's item changes (the watcher debounces).
    final userId = currentUserId();
    if (userId != null) {
      _itemsWatcher = TableWatcher(
        channelName: 'items-dashboard',
        table: 'space_items',
        filterColumn: 'user_id',
        filterValue: userId,
        onChange: reloadWhenShown,
      );
    }
  }

  void _setSort(String value) {
    setState(() => _sort = value);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('sort_spaces', value),
    );
  }

  void _setView(String value) {
    setState(() => _view = value);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('spaces_view', value),
    );
  }

  bool get _canReorder =>
      !_selectMode && !_offline && _sort == kSortDefault && _activeTags.isEmpty;

  @override
  void dispose() {
    _watcher?.dispose();
    _itemsWatcher?.dispose();
    DrawerSpaces.instance.clear();
    super.dispose();
  }

  SpaceRepository get _spaceRepo =>
      SpaceRepository(VaultSession.instance.masterKey);

  ItemRepository get _itemRepo =>
      ItemRepository(VaultSession.instance.masterKey);

  Future<void> _load() async {
    // Dashboard items load alongside the spaces; a failure there shouldn't
    // hide the spaces.
    final itemsFuture = _itemRepo
        .listItems(null)
        .then<({List<SpaceItem> items, bool fromCache})?>((r) => r)
        .catchError((Object _) => null);
    try {
      final result = await _spaceRepo.listSpaces();
      DrawerSpaces.instance.publish(result.spaces);
      final itemsResult = await itemsFuture;
      if (mounted) {
        setState(() {
          _spaces = result.spaces;
          if (itemsResult != null) _items = itemsResult.items;
          _items ??= const [];
          _offline = result.fromCache || (itemsResult?.fromCache ?? false);
          _error = null;
        });
      }
      if (_focusItemId != null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocus());
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _revealFocus() {
    final target = _focusItemId;
    if (target == null || !mounted) return;
    _focusItemId = null;
    final ctx = _focusKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 400),
        alignment: 0.1,
      );
    }
    setState(() => _flashId = target);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _flashId = null);
    });
  }

  Future<void> _openSearch() async {
    // A dashboard item picked in search comes back here to be highlighted.
    final focusId = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const SearchScreen()));
    if (focusId == null || !mounted) return;
    setState(() {
      _focusItemId = focusId;
      _activeTags.clear(); // so a tag filter can't hide it
    });
    _load();
  }

  Future<void> _createSpace() async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const SpaceEditorScreen()));
    if (saved == true && mounted) _load();
  }

  /// Star / unstar a space. It stays in place; Starred lists it.
  Future<void> _toggleStarSpace(Space space) async {
    try {
      await _spaceRepo.setStarred(space.id, !space.starred);
      StorageCounts.instance.refresh();
      if (mounted) {
        _load();
        showSuccessSnack(
          context,
          space.starred ? 'Removed from Starred' : 'Added to Starred',
        );
      }
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't update the star.");
    }
  }

  /// Read-only on / off: freezes the space's details and items, not the space.
  Future<void> _toggleReadOnlySpace(Space space) async {
    try {
      await _spaceRepo.setReadOnly(space.id, !space.readOnly);
      if (mounted) {
        _load();
        showSuccessSnack(
          context,
          space.readOnly ? 'Editing allowed' : 'Space is now read-only',
        );
      }
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't change read-only.");
    }
  }

  Future<void> _togglePinSpace(Space space) async {
    try {
      await _spaceRepo.setPinned(space.id, !space.pinned);
      if (mounted) _load();
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't update the space.");
    }
  }

  // Selection mode (spaces and dashboard items together)
  int get _selectedCount => _selected.length + _selectedItems.length;

  void _enterSelect() => setState(() => _selectMode = true);

  void _exitSelect() => setState(() {
    _selectMode = false;
    _selected.clear();
    _selectedItems.clear();
  });

  void _toggleSelect(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _toggleSelectItem(String id) => setState(() {
    if (!_selectedItems.remove(id)) _selectedItems.add(id);
  });

  void _selectAll() => setState(() {
    _selected
      ..clear()
      ..addAll(
        (_spaces ?? const <Space>[])
            .where((s) => s.parentId == null)
            .map((s) => s.id),
      );
    _selectedItems
      ..clear()
      ..addAll((_items ?? const <SpaceItem>[]).map((i) => i.id));
  });

  /// "2 spaces", "3 items", or "2 spaces and 3 items".
  String _selectionLabel(int spaces, int items) => [
    if (spaces > 0) '$spaces ${spaces == 1 ? 'space' : 'spaces'}',
    if (items > 0) '$items ${items == 1 ? 'item' : 'items'}',
  ].join(' and ');

  void _snack(String message) {
    if (mounted) showErrorSnack(context, message);
  }

  /// `newIndex` arrives already adjusted for the removed item (onReorderItem).
  void _onReorder(int oldIndex, int newIndex) {
    final list = List<Space>.of(_spaces ?? const []);
    list.insert(newIndex, list.removeAt(oldIndex));
    setState(() => _spaces = list);
    _persistOrder(list);
  }

  Future<void> _persistOrder(List<Space> list) async {
    try {
      await _spaceRepo.reorder(list.map((s) => s.id).toList());
    } catch (_) {
      _snack("Couldn't save the new order.");
      if (mounted) _load();
    }
  }

  /// Reorder the dashboard items (list view), persisting the new order.
  void _onReorderItems(int oldIndex, int newIndex) {
    final list = List<SpaceItem>.of(_items ?? const []);
    list.insert(newIndex, list.removeAt(oldIndex));
    setState(() => _items = list);
    _persistItemOrder(list);
  }

  Future<void> _persistItemOrder(List<SpaceItem> list) async {
    try {
      await _itemRepo.reorder(list.map((i) => i.id).toList());
    } catch (_) {
      _snack("Couldn't save the new order.");
      if (mounted) _load();
    }
  }

  /// Reorder by space id (used by the grid's drag-and-drop): move [fromId] into
  /// [toId]'s slot and persist the new order.
  void _moveSpaceById(String fromId, String toId) {
    if (fromId == toId) return;
    final list = List<Space>.of(_spaces ?? const []);
    final from = list.indexWhere((s) => s.id == fromId);
    final to = list.indexWhere((s) => s.id == toId);
    if (from < 0 || to < 0) return;
    final moved = list.removeAt(from);
    list.insert(from < to ? to - 1 : to, moved);
    setState(() => _spaces = list);
    _persistOrder(list);
  }

  /// Run a bulk action on the selected spaces and items, then leave select
  /// mode and refresh.
  Future<bool> _runBulk(
    Future<void> Function(List<String> spaceIds, List<String> itemIds) op,
  ) async {
    final spaceIds = _selected.toList();
    final itemIds = _selectedItems.toList();
    if (spaceIds.isEmpty && itemIds.isEmpty) return false;
    try {
      await op(spaceIds, itemIds);
      if (mounted) {
        _exitSelect();
        _load();
      }
      return true;
    } catch (_) {
      _snack("Couldn't complete that action.");
      return false;
    }
  }

  /// Undo an archive or move-to-bin for the given spaces and items.
  Future<void> _restore(List<String> spaceIds, List<String> itemIds) async {
    try {
      await Future.wait([
        _spaceRepo.restoreSpaces(spaceIds),
        _itemRepo.restoreItems(itemIds),
      ]);
      StorageCounts.instance.refresh();
      if (mounted) _load();
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't undo that.");
    }
  }

  Future<void> _bulkSetPinned(bool pinned) => _runBulk(
    (spaceIds, itemIds) => Future.wait([
      _spaceRepo.bulkSetPinned(spaceIds, pinned),
      _itemRepo.bulkSetPinned(itemIds, pinned),
    ]),
  );

  Future<void> _bulkArchive() async {
    final spaceIds = _selected.toList();
    final itemIds = _selectedItems.toList();
    final ok = await _runBulk(
      (s, i) =>
          Future.wait([_spaceRepo.bulkArchive(s), _itemRepo.bulkArchive(i)]),
    );
    StorageCounts.instance.refresh();
    if (ok && mounted) {
      showUndoSnack(
        context,
        '${_selectionLabel(spaceIds.length, itemIds.length)} archived',
        () => _restore(spaceIds, itemIds),
      );
    }
  }

  Future<void> _bulkDelete() async {
    final spaceIds = _selected.toList();
    final itemIds = _selectedItems.toList();
    final label = _selectionLabel(spaceIds.length, itemIds.length);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Move $label to bin?'),
        content: Text(
          spaceIds.isNotEmpty
              ? 'They and their items go to the recycle bin.'
              : 'They go to the recycle bin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Move to bin'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await _runBulk(
      (s, i) =>
          Future.wait([_spaceRepo.bulkDelete(s), _itemRepo.bulkDelete(i)]),
    );
    StorageCounts.instance.refresh();
    if (ok && mounted) {
      showUndoSnack(
        context,
        '$label moved to bin',
        () => _restore(spaceIds, itemIds),
      );
    }
  }

  /// Move the selected dashboard items into a space (items only).
  Future<void> _bulkMoveItems() async {
    final target = await pickMoveTarget(null);
    if (target == null) return;
    await _runBulk((_, itemIds) => _itemRepo.bulkMove(itemIds, target.id));
  }

  Future<void> _duplicateSpace(Space space) async {
    try {
      await _spaceRepo.duplicateSpace(space);
      if (mounted) {
        _load();
        showSuccessSnack(context, 'Space duplicated');
      }
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't duplicate the space.");
    }
  }

  Future<void> _archiveSpace(Space space) async {
    try {
      await _spaceRepo.archiveSpace(space.id);
      StorageCounts.instance.refresh();
      if (mounted) {
        _load();
        showUndoSnack(
          context,
          'Space archived',
          () => _restore([space.id], const []),
        );
      }
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't archive the space.");
    }
  }

  Future<void> _editSpace(Space space) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SpaceEditorScreen(existing: space)),
    );
    if (saved == true && mounted) _load();
  }

  Future<void> _deleteSpace(Space space) async {
    final name = space.name.isEmpty ? 'Untitled' : space.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Move space to bin?'),
        content: Text(
          '"$name" and its items will be moved to the recycle bin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Move to bin'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _spaceRepo.deleteSpace(space.id);
      StorageCounts.instance.refresh();
      if (mounted) {
        _load();
        showUndoSnack(
          context,
          'Space moved to bin',
          () => _restore([space.id], const []),
        );
      }
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't delete the space.");
    }
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
      drawer: _selectMode
          ? null
          : const AppDrawer(current: DrawerPage.dashboard),
      drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(
                onPressed: _exitSelect,
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
              ),
              title: Text('$_selectedCount selected'),
              actions: [
                ActionIconButton(
                  icon: Icons.select_all,
                  tooltip: 'Select all',
                  onPressed: _selectAll,
                ),
              ],
            )
          : null,
      floatingActionButton: _selectMode
          ? null
          : CreateFabs(onNewSpace: _createSpace, onAddItem: openAddItemSheet),
      bottomNavigationBar: _selectMode
          ? BulkActionBar(
              count: _selectedCount,
              onClear: _exitSelect,
              actions: [
                BulkAction(
                  icon: Icons.push_pin,
                  label: 'Pin',
                  onPressed: () => _bulkSetPinned(true),
                ),
                BulkAction(
                  icon: Icons.push_pin_outlined,
                  label: 'Unpin',
                  onPressed: () => _bulkSetPinned(false),
                ),
                // Only items move (into a space); spaces can't.
                if (_selectedItems.isNotEmpty && _selected.isEmpty)
                  BulkAction(
                    icon: Icons.drive_file_move_outlined,
                    label: 'Move',
                    onPressed: _bulkMoveItems,
                  ),
                BulkAction(
                  icon: Icons.archive_outlined,
                  label: 'Archive',
                  onPressed: _bulkArchive,
                ),
                BulkAction(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  onPressed: _bulkDelete,
                  destructive: true,
                ),
              ],
            )
          : null,
      body: _spaces == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              // No AppBar in normal mode, so this must take the top inset;
              // select mode still has an AppBar handling it.
              top: !_selectMode,
              child: Column(
                children: [
                  // The search bar is the fixed top bar (with the drawer
                  // toggle); the "Spaces" count/actions header and tag filter
                  // scroll with the list (see _body).
                  if (!_selectMode) _buildSearchBar(context),
                  if (_offline) const OfflineBanner(),
                  ValueListenableBuilder<int>(
                    valueListenable: WriteQueue.instance.pending,
                    builder: (context, count, _) => count == 0
                        ? const SizedBox.shrink()
                        : StatusBanner(
                            icon: Icons.sync,
                            tone: StatusTone.pending,
                            message:
                                '$count change${count == 1 ? '' : 's'} waiting to sync',
                          ),
                  ),
                  Expanded(
                    child: RefreshIndicator(onRefresh: _load, child: _body()),
                  ),
                ],
              ),
            ),
    );
  }

  /// Shown in the scrolling header when a tag filter matches nothing.
  Widget _noMatchNote(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'Nothing matches',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'No spaces or items have the selected tags.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            // The drawer toggle lives inside the search bar; Builder gives it
            // a context under this Scaffold so openDrawer() can find it.
            Builder(
              builder: (context) => IconButton(
                icon: Icon(Icons.menu, color: scheme.onSurfaceVariant),
                tooltip: 'Menu',
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: _openSearch,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    'Search spaces and items',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),
            // Balances the leading menu button so the placeholder reads centred.
            const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }

  /// The controls row, titled with the first section's name ([title]).
  Widget _buildSpacesHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 2, bottom: 4),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          ActionIconButton(
            icon: _view == 'grid'
                ? Icons.view_agenda_outlined
                : Icons.grid_view_outlined,
            tooltip: _view == 'grid' ? 'List view' : 'Grid view',
            onPressed: () => _setView(_view == 'grid' ? 'list' : 'grid'),
            size: 36,
          ),
          SortMenu(value: _sort, onChanged: _setSort, size: 36),
          ActionIconButton(
            icon: Icons.checklist,
            tooltip: 'Select',
            onPressed: _enterSelect,
            size: 36,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_spaces == null && _error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: "Couldn't load your spaces",
        message: 'Something went wrong. Check your connection and try again.',
        actionLabel: 'Retry',
        actionIcon: Icons.refresh,
        onAction: _load,
        destructiveIcon: true,
      );
    }
    // Only top-level spaces on the dashboard; sub-spaces live inside their parent.
    final all = (_spaces ?? const <Space>[])
        .where((s) => s.parentId == null)
        .toList();
    final allItems = _items ?? const <SpaceItem>[];
    if (all.isEmpty && allItems.isEmpty) {
      return StateMessage(
        icon: Icons.workspaces_outline,
        title: 'Nothing here yet',
        message:
            'Create a space to group related items, or add an item '
            'right here.',
        actionLabel: 'Add item',
        actionIcon: Icons.add,
        onAction: openAddItemSheet,
      );
    }
    final allTags = <String>{
      for (final s in all) ...s.tags,
      for (final i in allItems) ...i.tags,
    }.toList()..sort();
    // Drop selected tags that nothing carries any more, so a removed tag can't
    // leave the dashboard looking empty with no pill left to deselect.
    _activeTags.removeWhere((t) => !allTags.contains(t));
    final filtered = _activeTags.isEmpty
        ? all
        : all.where((s) => s.tags.any(_activeTags.contains)).toList();
    final filteredItems = _activeTags.isEmpty
        ? allItems
        : allItems.where((i) => i.tags.any(_activeTags.contains)).toList();
    final spaces = applySort(
      filtered,
      _sort,
      name: (s) => s.name,
      createdAt: (s) => s.createdAt,
      pinned: (s) => s.pinned,
    );
    final items = applySort(
      filteredItems,
      _sort,
      name: (i) => i.title,
      createdAt: (i) => i.createdAt,
      pinned: (i) => i.pinned,
    );
    // The count/actions header and tag filter scroll with the list, and are
    // hidden while selecting (the app bar shows the selection state instead).
    final headerChildren = <Widget>[];
    // Spaces and items are separate sections under the shared controls: the
    // header names the first section, and an "Items" label starts the second
    // only when both show.
    final bothSections = spaces.isNotEmpty && items.isNotEmpty;
    final firstLabel = spaces.isNotEmpty || items.isEmpty ? 'Spaces' : 'Items';
    if (!_selectMode) {
      headerChildren.add(_buildSpacesHeader(context, firstLabel));
      if (allTags.isNotEmpty) headerChildren.add(_tagFilterBar(allTags));
      // A tag filter that matches nothing gets a clear note (keeping the tag
      // bar above it reachable), matching the space detail screen.
      if (_activeTags.isNotEmpty && spaces.isEmpty && items.isEmpty) {
        headerChildren.add(_noMatchNote(context));
      }
    }
    final header = headerChildren.isEmpty
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: headerChildren,
          );

    if (_view == 'grid') {
      return _grid(spaces, items, header: header, labelItems: bothSections);
    }
    // List view: two reorderable lists (spaces, then items), each reordering
    // within itself on long press, with the "Items" label between them.
    final canReorder = _canReorder;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (header != null) SliverToBoxAdapter(child: header),
        const SliverToBoxAdapter(child: SizedBox(height: 4)),
        SliverReorderableList(
          itemCount: spaces.length,
          onReorderItem: _onReorder,
          proxyDecorator: _proxyDecorator,
          itemBuilder: (context, index) => ReorderableDelayedDragStartListener(
            key: ValueKey('space-${spaces[index].id}'),
            index: index,
            enabled: canReorder,
            child: _spaceCard(spaces[index]),
          ),
        ),
        if (bothSections)
          SliverToBoxAdapter(child: _sectionLabel(context, 'Items')),
        SliverReorderableList(
          itemCount: items.length,
          onReorderItem: _onReorderItems,
          proxyDecorator: _proxyDecorator,
          itemBuilder: (context, index) {
            final item = items[index];
            return ReorderableDelayedDragStartListener(
              key: ValueKey('item-${item.id}'),
              index: index,
              enabled: canReorder,
              child: _highlightable(
                item,
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: _itemCard(item, margin: EdgeInsets.zero),
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 88)),
      ],
    );
  }

  /// A section title between spaces and items, styled like the header title.
  Widget _sectionLabel(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  /// Lifts the card being dragged, as ReorderableListView does.
  Widget _proxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) => Material(
      elevation: 6 * Curves.easeInOut.transform(animation.value),
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: child,
    ),
    child: child,
  );

  /// Wraps an item card so it can be scrolled to and briefly highlighted
  /// after being picked in search.
  Widget _highlightable(
    SpaceItem item, {
    Key? key,
    required EdgeInsetsGeometry margin,
    required Widget child,
  }) {
    return AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 300),
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _flashId == item.id
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
      ),
      child: KeyedSubtree(
        key: item.id == _focusItemId ? _focusKey : null,
        child: child,
      ),
    );
  }

  Widget _tagFilterBar(List<String> allTags) {
    return compactTagFilterBar(
      context: context,
      allTags: allTags,
      activeTags: _activeTags,
      onChanged: () => setState(() {}),
    );
  }

  /// Two-column masonry grid: a spaces section, then an items section (each
  /// starts on its own row). Cards keep their natural height (round-robin
  /// distribution); when reordering is allowed each space is a long-press
  /// draggable and a drop target, persisting the new order like the list view.
  /// Items don't reorder here (as inside a space).
  Widget _grid(
    List<Space> spaces,
    List<SpaceItem> items, {
    Widget? header,
    bool labelItems = false,
  }) {
    final canReorder = _canReorder;
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 88),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          if (spaces.isNotEmpty)
            _masonry([for (final s in spaces) _gridCard(s, canReorder)]),
          if (labelItems) _sectionLabel(context, 'Items'),
          if (items.isNotEmpty)
            _masonry([
              for (final i in items)
                _highlightable(
                  i,
                  key: ValueKey('item-${i.id}'),
                  margin: EdgeInsets.zero,
                  child: _itemCard(
                    i,
                    margin: const EdgeInsets.all(2),
                    grid: true,
                  ),
                ),
            ]),
        ],
      ),
    );
  }

  /// Two columns, cards distributed round-robin.
  Widget _masonry(List<Widget> cards) {
    final columns = <List<Widget>>[<Widget>[], <Widget>[]];
    for (var i = 0; i < cards.length; i++) {
      columns[i % 2].add(cards[i]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(children: columns[0])),
        Expanded(child: Column(children: columns[1])),
      ],
    );
  }

  Widget _gridCard(Space space, bool canReorder) {
    final card = _spaceCard(space, margin: const EdgeInsets.all(2));
    if (!canReorder) {
      return KeyedSubtree(key: ValueKey('space-${space.id}'), child: card);
    }
    return DragTarget<String>(
      key: ValueKey('space-${space.id}'),
      onWillAcceptWithDetails: (d) => d.data != space.id,
      onAcceptWithDetails: (d) => _moveSpaceById(d.data, space.id),
      builder: (context, candidate, rejected) {
        final over = candidate.isNotEmpty;
        return LongPressDraggable<String>(
          data: space.id,
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: MediaQuery.of(context).size.width / 2 - 16,
              child: Opacity(opacity: 0.95, child: card),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: card),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: over
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    )
                  : null,
            ),
            child: card,
          ),
        );
      },
    );
  }

  // Reload on return: items may have moved between the space and here.
  void _openSpace(Space space) => Navigator.of(context)
      .push(
        MaterialPageRoute<void>(
          builder: (_) => SpaceDetailScreen(space: space),
        ),
      )
      .then((_) {
        if (mounted) _load();
      });

  Widget _spaceCard(Space space, {EdgeInsetsGeometry? margin}) => SpaceCard(
    space: space,
    margin: margin,
    selectMode: _selectMode,
    selected: _selected.contains(space.id),
    onSelectToggle: () => _toggleSelect(space.id),
    onTap: () => _openSpace(space),
    onTogglePin: () => _togglePinSpace(space),
    onToggleStar: () => _toggleStarSpace(space),
    onToggleReadOnly: () => _toggleReadOnlySpace(space),
    onToggleLock: () async {
      if (await toggleSpaceLock(context, space, locked: space.locked) &&
          mounted) {
        _load();
      }
    },
    onEdit: () => _editSpace(space),
    onDuplicate: () => _duplicateSpace(space),
    onArchive: () => _archiveSpace(space),
    onDelete: () => _deleteSpace(space),
    activeTags: _activeTags,
    onTagClick: (tag) => setState(() {
      if (!_activeTags.remove(tag)) _activeTags.add(tag);
    }),
  );

  Widget _itemCard(
    SpaceItem item, {
    EdgeInsetsGeometry? margin,
    bool grid = false,
  }) => ItemCard(
    item: item,
    margin: margin,
    grid: grid,
    selectMode: _selectMode,
    selected: _selectedItems.contains(item.id),
    onSelectToggle: () => _toggleSelectItem(item.id),
    onTap: isEditableType(item.type) ? () => editItem(item) : null,
    onTogglePin: () => togglePinItem(item),
    onToggleStar: () => toggleStarItem(item),
    onToggleLock: () => toggleLockItem(item),
    onDuplicate: () => duplicateItem(item),
    onMove: () => moveItem(item),
    onArchive: () => archiveItem(item),
    onExport: () => exportItem(item),
    onDelete: () => deleteItem(item),
    onSetTags: _offline ? null : (tags) => _setItemTags(item, tags),
  );
}
