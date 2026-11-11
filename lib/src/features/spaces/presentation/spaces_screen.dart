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
import 'package:archespace_mobile/src/features/spaces/presentation/space_destinations_sheet.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_detail_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_editor_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_item_selection.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_lock_actions.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/space_card.dart';
import 'package:archespace_mobile/src/features/storage/application/storage_counts.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/realtime/reload_when_shown.dart';
import 'package:archespace_mobile/src/shared/realtime/table_watcher.dart';
import 'package:archespace_mobile/src/shared/sort/sort.dart';
import 'package:archespace_mobile/src/shared/widgets/action_icon_button.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/bulk_action_bar.dart';
import 'package:archespace_mobile/src/shared/widgets/create_fabs.dart';
import 'package:archespace_mobile/src/shared/widgets/offline_banner.dart';
import 'package:archespace_mobile/src/shared/widgets/reorder_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:archespace_mobile/src/shared/widgets/scrollable_message.dart';
import 'package:archespace_mobile/src/shared/widgets/search_field.dart';
import 'package:archespace_mobile/src/shared/widgets/tag_filter_bar.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

// The space between cards, shared by the list and grid views.
const double _kSpaceGap = 6;
const double _kItemGap = 8;

/// The dashboard: the user's top-level spaces, then their dashboard items
/// (items that belong to no space), laid out like the inside of a space and
/// sharing one tag filter, sort, view and selection.
class SpacesScreen extends StatefulWidget {
  const SpacesScreen({super.key});

  @override
  State<SpacesScreen> createState() => _SpacesScreenState();
}

class _SpacesScreenState extends State<SpacesScreen>
    with
        ItemActions<SpacesScreen>,
        SpaceItemSelection<SpacesScreen>,
        ReloadWhenShown<SpacesScreen> {
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
  TableWatcher? _watcher;
  TableWatcher? _itemsWatcher;
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
      !selectMode && _sort == kSortDefault && _activeTags.isEmpty;

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
        .then<List<SpaceItem>?>((r) => r)
        .catchError((Object _) => null);
    try {
      final spaces = await _spaceRepo.listSpaces();
      DrawerSpaces.instance.publish(spaces);
      final items = await itemsFuture;
      if (mounted) {
        setState(() {
          _spaces = spaces;
          if (items != null) _items = items;
          _items ??= const [];
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

  // Selection (spaces and dashboard items together): SpaceItemSelection.
  // Select all takes the top-level spaces and every dashboard item.
  void _selectAll() => selectOnly(
    [
      for (final s in _spaces ?? const <Space>[])
        if (s.parentId == null) s.id,
    ],
    [for (final i in _items ?? const <SpaceItem>[]) i.id],
  );

  void _snack(String message) {
    if (mounted) showErrorSnack(context, message);
  }

  Future<void> _persistOrder(List<Space> list) async {
    try {
      await _spaceRepo.reorder(list.map((s) => s.id).toList());
    } catch (_) {
      _snack("Couldn't save the new order.");
      if (mounted) _load();
    }
  }

  Future<void> _persistItemOrder(List<SpaceItem> list) async {
    try {
      await _itemRepo.reorder(list.map((i) => i.id).toList());
    } catch (_) {
      _snack("Couldn't save the new order.");
      if (mounted) _load();
    }
  }

  /// Reorder by id (drag and drop, in the list or the grid): move [fromId]
  /// into [toId]'s place and persist the new order. [_spaces] also holds the
  /// sub-spaces, which keep their places.
  void _moveSpaceById(String fromId, String toId) {
    final list = moveById(
      _spaces ?? const <Space>[],
      fromId,
      toId,
      (s) => s.id,
    );
    setState(() => _spaces = list);
    _persistOrder(list);
  }

  void _moveItemById(String fromId, String toId) {
    final list = moveById(
      _items ?? const <SpaceItem>[],
      fromId,
      toId,
      (i) => i.id,
    );
    setState(() => _items = list);
    _persistItemOrder(list);
  }

  /// Move spaces into another space (with everything in them).
  Future<void> _moveSpaces(List<String> ids) async {
    if (await moveSpacesTo(context, ids) && mounted) {
      if (selectMode) exitSelect();
      _load();
    }
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

  Future<bool> _setSpaceTags(Space space, List<String> tags) async {
    final ok = await saveSpaceTags(context, space, tags);
    if (ok && mounted) _load();
    return ok;
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
      drawer: selectMode
          ? null
          : const AppDrawer(current: DrawerPage.dashboard),
      drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
      appBar: selectMode
          ? AppBar(
              leading: IconButton(
                onPressed: exitSelect,
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
              ),
              title: Text('$selectedCount selected'),
              actions: [
                ActionIconButton(
                  icon: Icons.select_all,
                  tooltip: 'Select all',
                  onPressed: _selectAll,
                ),
              ],
            )
          : null,
      floatingActionButton: selectMode
          ? null
          : CreateFabs(
              onNewSpace: _createSpace,
              onAddItem: openAddItemSheet,
              onQuickNote: addQuickNote,
            ),
      bottomNavigationBar: selectMode
          ? BulkActionBar(
              count: selectedCount,
              actions: [
                BulkAction(
                  icon: Icons.push_pin,
                  label: 'Pin',
                  onPressed: () => bulkSetPinned(true),
                ),
                BulkAction(
                  icon: Icons.push_pin_outlined,
                  label: 'Unpin',
                  struck: true,
                  onPressed: () => bulkSetPinned(false),
                ),
                // Spaces or items move, not both at once (a read-only space
                // stays where it is).
                if (selectedItems.isNotEmpty && selectedSpaces.isEmpty)
                  BulkAction(
                    icon: Icons.drive_file_move_outlined,
                    label: 'Move',
                    onPressed: bulkMoveItems,
                  ),
                if (selectedSpaces.isNotEmpty &&
                    selectedItems.isEmpty &&
                    !(_spaces ?? const <Space>[]).any(
                      (s) => selectedSpaces.contains(s.id) && s.readOnly,
                    ))
                  BulkAction(
                    icon: Icons.drive_file_move_outlined,
                    label: 'Move',
                    onPressed: () => _moveSpaces(selectedSpaces.toList()),
                  ),
                BulkAction(
                  icon: Icons.archive_outlined,
                  label: 'Archive',
                  onPressed: bulkArchive,
                ),
                BulkAction(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  onPressed: bulkDelete,
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
              top: !selectMode,
              child: Column(
                children: [
                  // The search bar is the fixed top bar (with the drawer
                  // toggle); the "Spaces" count/actions header and tag filter
                  // scroll with the list (see _body).
                  if (!selectMode) _buildSearchBar(context),
                  const OfflineBanner(),
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
      child: SearchField(
        hint: 'Search spaces and items',
        onTap: _openSearch,
        // The drawer toggle lives inside the search bar; Builder gives it a
        // context under this Scaffold so openDrawer() can find it.
        leading: Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.menu, color: scheme.onSurfaceVariant),
            tooltip: 'Menu',
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
    );
  }

  /// The controls row, titled with the first section's name ([title]).
  Widget _buildSpacesHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
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
          ),
          SortMenu(value: _sort, onChanged: _setSort),
          ActionIconButton(
            icon: Icons.checklist,
            tooltip: 'Select',
            onPressed: enterSelect,
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
        actionLabel: 'New item',
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
    if (!selectMode) {
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
    // List view: spaces, then items, with the "Items" label between them.
    // Hold a card and drag it onto another of its section to take its place,
    // as in the grid.
    final canReorder = _canReorder;
    final spaceIds = [for (final s in spaces) s.id];
    final itemIds = [for (final i in items) i.id];
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (header != null) SliverToBoxAdapter(child: header),
        const SliverToBoxAdapter(child: SizedBox(height: 4)),
        SliverList.builder(
          itemCount: spaces.length,
          itemBuilder: (context, index) {
            final space = spaces[index];
            return Padding(
              key: ValueKey('space-${space.id}'),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: _kSpaceGap / 2,
              ),
              child: ReorderCard(
                list: 'spaces',
                id: space.id,
                enabled: canReorder,
                order: spaceIds,
                onReorder: _moveSpaceById,
                child: _spaceCard(space, margin: EdgeInsets.zero),
              ),
            );
          },
        ),
        if (bothSections)
          SliverToBoxAdapter(child: _sectionLabel(context, 'Items')),
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _highlightable(
              item,
              key: ValueKey('item-${item.id}'),
              margin: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: _kItemGap / 2,
              ),
              child: ReorderCard(
                list: 'items',
                id: item.id,
                enabled: canReorder,
                order: itemIds,
                onReorder: _moveItemById,
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
  /// distribution); when reordering is allowed a card can be held and dragged
  /// onto another of its section to take its place, as in the list view.
  Widget _grid(
    List<Space> spaces,
    List<SpaceItem> items, {
    Widget? header,
    bool labelItems = false,
  }) {
    final canReorder = _canReorder;
    final spaceIds = [for (final s in spaces) s.id];
    final itemIds = [for (final i in items) i.id];
    // Same top and header as the list view, so switching views only changes
    // the cards (see [_masonry] for their edge).
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          const SizedBox(height: 4),
          if (spaces.isNotEmpty)
            _masonry(gap: _kSpaceGap, [
              for (final s in spaces)
                Padding(
                  key: ValueKey('space-${s.id}'),
                  padding: const EdgeInsets.all(_kSpaceGap / 2),
                  child: ReorderCard(
                    list: 'spaces',
                    id: s.id,
                    enabled: canReorder,
                    order: spaceIds,
                    onReorder: _moveSpaceById,
                    child: _spaceCard(s, margin: EdgeInsets.zero),
                  ),
                ),
            ]),
          if (labelItems) _sectionLabel(context, 'Items'),
          if (items.isNotEmpty)
            _masonry(gap: _kItemGap, [
              for (final i in items)
                _highlightable(
                  i,
                  key: ValueKey('item-${i.id}'),
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(_kItemGap / 2),
                    child: ReorderCard(
                      list: 'items',
                      id: i.id,
                      enabled: canReorder,
                      order: itemIds,
                      onReorder: _moveItemById,
                      child: _itemCard(i, margin: EdgeInsets.zero, grid: true),
                    ),
                  ),
                ),
            ]),
        ],
      ),
    );
  }

  /// Two columns, cards distributed round-robin. Each card pads itself by
  /// half the [gap] (the list view's gap for its section), and the columns
  /// make up the rest of the list view's 12 edge.
  Widget _masonry(List<Widget> cards, {required double gap}) {
    final columns = <List<Widget>>[<Widget>[], <Widget>[]];
    for (var i = 0; i < cards.length; i++) {
      columns[i % 2].add(cards[i]);
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12 - gap / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Column(children: columns[0])),
          Expanded(child: Column(children: columns[1])),
        ],
      ),
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
    selectMode: selectMode,
    selected: selectedSpaces.contains(space.id),
    onSelectToggle: () => toggleSelectedSpace(space.id),
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
    onEdit: () async {
      if (await editSpace(context, space) && mounted) _load();
    },
    onDuplicate: () => _duplicateSpace(space),
    onMove: () => _moveSpaces([space.id]),
    onExport: () => exportSpace(space),
    onSetExpiry: () async {
      if (await editSpaceExpiry(context, space) && mounted) _load();
    },
    onArchive: () => archiveSpace(context, space, _load),
    onDelete: () => deleteSpace(context, space, _load),
    onSetTags: (tags) => _setSpaceTags(space, tags),
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
    selectMode: selectMode,
    selected: selectedItems.contains(item.id),
    onSelectToggle: () => toggleSelectedItem(item.id),
    onTap: isEditableType(item.type) ? () => editItem(item) : null,
    onTogglePin: () => togglePinItem(item),
    onToggleStar: () => toggleStarItem(item),
    onSetReminder: () => editItemReminder(item),
    onSetExpiry: () => editItemExpiry(item),
    onSetColor: () => editItemColor(item),
    onToggleLock: () => toggleLockItem(item),
    onDuplicate: () => duplicateItem(item),
    onMove: () => moveItem(item),
    onArchive: () => archiveItem(item),
    onExport: () => exportItem(item),
    onDelete: () => deleteItem(item),
    onSetTags: (tags) => _setItemTags(item, tags),
  );
}
