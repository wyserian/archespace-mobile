import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_actions.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_card.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_editor_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_lock_actions.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/space_card.dart';
import 'package:archespace_mobile/src/features/storage/application/storage_counts.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/export/pdf_exporter.dart';
import 'package:archespace_mobile/src/shared/realtime/reload_when_shown.dart';
import 'package:archespace_mobile/src/shared/realtime/table_watcher.dart';
import 'package:archespace_mobile/src/shared/sort/sort.dart';
import 'package:archespace_mobile/src/shared/widgets/action_icon_button.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/bulk_action_bar.dart';
import 'package:archespace_mobile/src/shared/widgets/create_fabs.dart';
import 'package:archespace_mobile/src/shared/widgets/locked_view.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';
import 'package:archespace_mobile/src/shared/widgets/offline_banner.dart';
import 'package:archespace_mobile/src/shared/widgets/scrollable_message.dart';
import 'package:archespace_mobile/src/shared/widgets/status_banner.dart';
import 'package:archespace_mobile/src/shared/widgets/tag_filter_bar.dart';

class SpaceDetailScreen extends StatefulWidget {
  const SpaceDetailScreen({super.key, required this.space, this.focusItemId});

  final Space space;

  /// When set, the screen scrolls to this item and briefly highlights it
  /// (used by search's jump-to-item).
  final String? focusItemId;

  @override
  State<SpaceDetailScreen> createState() => _SpaceDetailScreenState();
}

class _SpaceDetailScreenState extends State<SpaceDetailScreen>
    with ItemActions<SpaceDetailScreen>, ReloadWhenShown<SpaceDetailScreen> {
  // Realtime changes reload this screen only while it's showing.
  @override
  Future<void> reloadShown() => _load();

  @override
  String? get itemsSpaceId => widget.space.id;

  @override
  Future<void> reloadItems() => _load();

  // Read-only (stored on the server): items open as viewers and nothing in
  // the space can be added or changed. Seeded from the passed space, then kept
  // in sync with the server (another device may toggle it).
  late bool _readOnly = widget.space.readOnly;
  TableWatcher? _spaceWatcher;

  @override
  bool isItemReadOnly(SpaceItem item) => _readOnly;

  List<SpaceItem>? _items;
  List<Space> _subSpaces = const [];
  Object? _error;
  bool _offline = false;
  TableWatcher? _watcher;
  final GlobalKey _focusKey = GlobalKey();
  String? _flashId;
  bool _focusHandled = false;
  bool _selectMode = false;
  final Set<String> _selected = {};
  String _sort = kSortDefault;
  String _view = 'list';
  final Set<String> _activeTags = {};
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    ContentLock.instance.addListener(_onLockChanged);
    // A protected space asks for the PIN as it opens.
    if (_hidden) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    _load();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('sort_items');
      final view = prefs.getString('items_view');
      if (!mounted) return;
      setState(() {
        if (saved != null) _sort = saved;
        if (view == 'grid') _view = 'grid';
      });
    });
    _watcher = TableWatcher(
      channelName: 'items-${widget.space.id}',
      table: 'space_items',
      filterColumn: 'space_id',
      filterValue: widget.space.id,
      onChange: reloadWhenShown,
    );
    _spaceWatcher = TableWatcher(
      channelName: 'space-${widget.space.id}',
      table: 'spaces',
      filterColumn: 'id',
      filterValue: widget.space.id,
      onChange: _refreshReadOnly,
    );
  }

  /// Opened or hidden again (or protection changed): show or cover the space.
  void _onLockChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ContentLock.instance.removeListener(_onLockChanged);
    _watcher?.dispose();
    _spaceWatcher?.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Pick up the read-only flag from the server. Non-fatal: offline keeps the
  /// last known value.
  Future<void> _refreshReadOnly() async {
    try {
      final readOnly = await SpaceRepository(
        VaultSession.instance.masterKey,
      ).fetchReadOnly(widget.space.id);
      if (mounted && readOnly != _readOnly) {
        setState(() {
          _readOnly = readOnly;
          if (readOnly) {
            _selectMode = false;
            _selected.clear();
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleReadOnly() async {
    final next = !_readOnly;
    try {
      await SpaceRepository(
        VaultSession.instance.masterKey,
      ).setReadOnly(widget.space.id, next);
      if (!mounted) return;
      setState(() {
        _readOnly = next;
        if (next) {
          _selectMode = false;
          _selected.clear();
        }
      });
      showSuccessSnack(
        context,
        next ? 'Space is now read-only' : 'Editing allowed',
      );
    } catch (_) {
      _showError("Couldn't change read-only.");
    }
  }

  Future<void> _load() async {
    _refreshReadOnly();
    try {
      // Sub-spaces (one-level nesting): only a top-level space can have them.
      // They load alongside the items rather than after them.
      final subsFuture = widget.space.parentId == null
          ? SpaceRepository(VaultSession.instance.masterKey)
                .listSubSpaces(widget.space.id)
                // Non-fatal: items still load without the sub-space list.
                .catchError((Object _) => const <Space>[])
          : Future.value(const <Space>[]);
      final result = await ItemRepository(
        VaultSession.instance.masterKey,
      ).listItems(widget.space.id);
      final subs = await subsFuture;
      if (mounted) {
        setState(() {
          _items = result.items;
          _subSpaces = subs;
          _offline = result.fromCache;
          _error = null;
        });
      }
      if (widget.focusItemId != null && !_focusHandled && mounted) {
        _focusHandled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocus());
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _revealFocus() {
    final ctx = _focusKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 400),
        alignment: 0.1,
      );
    }
    setState(() => _flashId = widget.focusItemId);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _flashId = null);
    });
  }

  Future<void> _createSubSpace() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SpaceEditorScreen(parentId: widget.space.id),
      ),
    );
    if (created == true && mounted) _load();
  }

  void _openSubSpace(Space sub) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => SpaceDetailScreen(space: sub),
          ),
        )
        .then((_) {
          if (mounted) _load();
        });
  }

  Future<void> _subSpaceOp(
    Future<void> Function(SpaceRepository) op,
    String errorMsg,
  ) async {
    try {
      await op(SpaceRepository(VaultSession.instance.masterKey));
      if (mounted) _load();
    } catch (_) {
      _showError(errorMsg);
    }
  }

  Future<void> _editSubSpace(Space sub) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SpaceEditorScreen(existing: sub)),
    );
    if (saved == true && mounted) _load();
  }

  Future<void> _deleteSubSpace(Space sub) async {
    final ok = await confirmAction(
      context,
      title: 'Move space to recycle bin?',
      message: 'This space and all its items will be moved to the recycle bin.',
      confirmLabel: 'Move to recycle bin',
      destructive: true,
    );
    if (ok) {
      await _subSpaceOp(
        (r) => r.deleteSpace(sub.id),
        "Couldn't delete the space.",
      );
    }
  }

  Widget _subSpaceCard(Space sub) => SpaceCard(
    space: sub,
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    onTap: () => _openSubSpace(sub),
    onTogglePin: () => _subSpaceOp(
      (r) => r.setPinned(sub.id, !sub.pinned),
      "Couldn't update the space.",
    ),
    onToggleStar: () => _subSpaceOp((r) async {
      await r.setStarred(sub.id, !sub.starred);
      StorageCounts.instance.refresh();
    }, "Couldn't update the star."),
    onToggleReadOnly: () => _subSpaceOp(
      (r) => r.setReadOnly(sub.id, !sub.readOnly),
      "Couldn't change read-only.",
    ),
    onToggleLock: () async {
      if (await toggleSpaceLock(context, sub, locked: sub.locked) && mounted) {
        _load();
      }
    },
    onEdit: () => _editSubSpace(sub),
    onDuplicate: () => _subSpaceOp(
      (r) => r.duplicateSpace(sub),
      "Couldn't duplicate the space.",
    ),
    onArchive: () => _subSpaceOp(
      (r) => r.archiveSpace(sub.id),
      "Couldn't archive the space.",
    ),
    onDelete: () => _deleteSubSpace(sub),
  );

  // Selection mode
  void _enterSelect() => setState(() => _selectMode = true);

  void _exitSelect() => setState(() {
    _selectMode = false;
    _selected.clear();
  });

  void _toggleSelect(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _selectAll() => setState(() {
    _selected
      ..clear()
      ..addAll((_items ?? const <SpaceItem>[]).map((i) => i.id));
  });

  void _setSort(String value) {
    setState(() => _sort = value);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('sort_items', value),
    );
  }

  void _setView(String value) {
    setState(() => _view = value);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('items_view', value),
    );
  }

  /// `newIndex` arrives already adjusted for the removed item (onReorderItem).
  void _onReorder(int oldIndex, int newIndex) {
    final list = List<SpaceItem>.of(_items ?? const []);
    list.insert(newIndex, list.removeAt(oldIndex));
    setState(() => _items = list);
    _persistOrder(list);
  }

  Future<void> _persistOrder(List<SpaceItem> list) async {
    try {
      await ItemRepository(
        VaultSession.instance.masterKey,
      ).reorder(list.map((i) => i.id).toList());
    } catch (_) {
      _showError("Couldn't save the new order.");
      if (mounted) _load();
    }
  }

  Future<bool> _runBulk(Future<void> Function(ItemRepository) op) async {
    if (_selected.isEmpty) return false;
    try {
      await op(ItemRepository(VaultSession.instance.masterKey));
      if (mounted) {
        _exitSelect();
        _load();
      }
      return true;
    } catch (_) {
      _showError("Couldn't complete that action.");
      return false;
    }
  }

  Future<void> _bulkArchiveItems() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await _runBulk((r) => r.bulkArchive(ids));
    StorageCounts.instance.refresh();
    if (ok && mounted) {
      showUndoSnack(
        context,
        '${ids.length} ${ids.length == 1 ? 'item' : 'items'} archived',
        () => restoreItems(ids),
      );
    }
  }

  Future<void> _bulkDeleteItems() async {
    final ids = _selected.toList();
    final ok = await _runBulk((r) => r.bulkDelete(ids));
    StorageCounts.instance.refresh();
    if (ok && mounted) {
      showUndoSnack(
        context,
        '${ids.length} ${ids.length == 1 ? 'item' : 'items'} moved to bin',
        () => restoreItems(ids),
      );
    }
  }

  Future<void> _bulkMoveItems() async {
    final target = await pickMoveTarget(itemsSpaceId);
    if (target == null) return;
    final ids = _selected.toList();
    await _runBulk((r) => r.bulkMove(ids, target.id));
  }

  void _showError(String message) => showItemError(message);

  Future<void> _exportSpace() => exportPdf(
    build: () => PdfExporter.buildSpace(widget.space.name, _items ?? const []),
    filename: pdfFileName(widget.space.name),
    label: 'space',
  );

  /// A compact app-bar icon action with a consistent circular tap splash.
  Widget _barAction(
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    double size = 40,
  }) => ActionIconButton(
    icon: icon,
    tooltip: tooltip,
    onPressed: onPressed,
    size: size,
  );

  /// The normal-mode app-bar actions: the space-level export, shown directly.
  /// The list controls (view, sort, select) live in the body header instead
  /// (see [_buildItemsHeader]).
  List<Widget> _buildBarActions(bool hasItems) {
    // New sub-space is in the create button's dial with Add item (see
    // CreateFabs).
    return [
      ActionIconButton(
        icon: Icons.shield_outlined,
        tooltip: _locked ? 'Protected - tap to remove protection' : 'Protect',
        onPressed: _toggleLock,
        selected: _locked,
      ),
      ActionIconButton(
        icon: Icons.edit_off_outlined,
        tooltip: _readOnly ? 'Read-only - tap to allow editing' : 'Read-only',
        onPressed: _toggleReadOnly,
        selected: _readOnly,
      ),
      if (hasItems)
        _barAction(Icons.picture_as_pdf_outlined, 'Export PDF', _exportSpace),
      const SizedBox(width: 4),
    ];
  }

  /// A fixed row (not scrolling) with a compact in-space search field and the
  /// list controls (view, sort, select) inline, in place of an "Items" label.
  Widget _buildItemsHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 2),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 34,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(Icons.search, size: 17, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      onChanged: (v) => setState(() => _query = v),
                      style: const TextStyle(fontSize: 13.5),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration.collapsed(
                        hintText: 'Search items',
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.close,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          _barAction(
            _view == 'grid'
                ? Icons.view_agenda_outlined
                : Icons.grid_view_outlined,
            _view == 'grid' ? 'List view' : 'Grid view',
            () => _setView(_view == 'grid' ? 'list' : 'grid'),
            size: 36,
          ),
          SortMenu(value: _sort, onChanged: _setSort, size: 36),
          // Every bulk action changes items, so there's no selecting while
          // read-only.
          if (!_readOnly)
            _barAction(Icons.checklist, 'Select', _enterSelect, size: 36),
        ],
      ),
    );
  }

  /// Protected (itself or its parent) and not opened with the PIN.
  bool get _hidden {
    final lock = ContentLock.instance;
    return lock.isSpaceHidden(widget.space.id) ||
        (widget.space.locked && !lock.isRevealed(widget.space.id));
  }

  /// This space's own protection: as last loaded, else as it was passed in.
  bool get _locked =>
      ContentLock.instance.isSpaceLocked(widget.space.id) ??
      widget.space.locked;

  Future<void> _unlock() => unlockSpace(context, widget.space);

  Future<void> _toggleLock() async {
    await toggleSpaceLock(context, widget.space, locked: _locked);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final drawer = AppDrawer(
      current: DrawerPage.space,
      spaceId: widget.space.id,
    );
    if (_hidden) {
      return Scaffold(
        drawer: drawer,
        drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
        appBar: AppBar(
          // Keep Back; the drawer opens with a slide from the left.
          leading: const BackButton(),
          titleSpacing: 0,
          title: Text(
            widget.space.name.isEmpty ? 'Untitled' : widget.space.name,
          ),
        ),
        body: LockedView(
          message: 'Enter your vault PIN to open this space.',
          onUnlock: _unlock,
        ),
      );
    }
    final hasItems = (_items ?? const <SpaceItem>[]).isNotEmpty;
    return Scaffold(
      drawer: _selectMode ? null : drawer,
      drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(
                onPressed: _exitSelect,
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
              ),
              title: Text('${_selected.length} selected'),
              actions: [
                ActionIconButton(
                  icon: Icons.select_all,
                  tooltip: 'Select all',
                  onPressed: _selectAll,
                ),
              ],
            )
          : AppBar(
              leading: const BackButton(),
              titleSpacing: 0,
              title: Text(
                widget.space.name.isEmpty ? 'Untitled' : widget.space.name,
              ),
              actions: _buildBarActions(hasItems),
            ),
      floatingActionButton: _selectMode || _readOnly
          ? null
          : CreateFabs(
              onAddItem: openAddItemSheet,
              // Sub-spaces are one level deep, so only a top-level space can
              // create them.
              onNewSpace: _items != null && widget.space.parentId == null
                  ? _createSubSpace
                  : null,
            ),
      bottomNavigationBar: _selectMode
          ? BulkActionBar(
              count: _selected.length,
              onClear: _exitSelect,
              actions: [
                BulkAction(
                  icon: Icons.push_pin,
                  label: 'Pin',
                  onPressed: () {
                    final ids = _selected.toList();
                    _runBulk((r) => r.bulkSetPinned(ids, true));
                  },
                ),
                BulkAction(
                  icon: Icons.push_pin_outlined,
                  label: 'Unpin',
                  onPressed: () {
                    final ids = _selected.toList();
                    _runBulk((r) => r.bulkSetPinned(ids, false));
                  },
                ),
                BulkAction(
                  icon: Icons.drive_file_move_outlined,
                  label: 'Move',
                  onPressed: _bulkMoveItems,
                ),
                BulkAction(
                  icon: Icons.archive_outlined,
                  label: 'Archive',
                  onPressed: _bulkArchiveItems,
                ),
                BulkAction(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  onPressed: _bulkDeleteItems,
                  destructive: true,
                ),
              ],
            )
          : null,
      body: _items == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: Column(
                children: [
                  if (_offline) const OfflineBanner(),
                  if (_readOnly)
                    const StatusBanner(
                      icon: Icons.edit_off_outlined,
                      message: 'Read-only - view, copy and export only',
                    ),
                  Expanded(
                    child: RefreshIndicator(onRefresh: _load, child: _body()),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _body() {
    if (_items == null && _error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: "Couldn't load items",
        message: 'Something went wrong. Check your connection and try again.',
        actionLabel: 'Retry',
        actionIcon: Icons.refresh,
        onAction: _load,
        destructiveIcon: true,
      );
    }
    final all = _items ?? const <SpaceItem>[];
    // Sub-spaces render above the items in the same view (matching the web),
    // hidden while selecting items.
    final subSection = (_subSpaces.isEmpty || _selectMode)
        ? null
        : Column(children: [for (final s in _subSpaces) _subSpaceCard(s)]);
    if (all.isEmpty && subSection == null) {
      if (_readOnly) {
        return const StateMessage(
          icon: Icons.edit_off_outlined,
          title: 'No items yet',
          message: 'This space is read-only.',
        );
      }
      return StateMessage(
        icon: Icons.note_add_outlined,
        title: 'No items yet',
        message: 'Add notes, lists, tables, and more to this space.',
        actionLabel: 'Add item',
        actionIcon: Icons.add,
        onAction: openAddItemSheet,
      );
    }
    final allTags = <String>{for (final i in all) ...i.tags}.toList()..sort();
    // Drop selected tags that no item carries any more (e.g. the tag was just
    // removed, deleted or moved away with its item). Otherwise the filter
    // would match nothing and the space would look empty, with no pill left
    // to deselect.
    _activeTags.removeWhere((t) => !allTags.contains(t));
    final query = _query.trim().toLowerCase();
    final filtered = all.where((i) {
      if (_activeTags.isNotEmpty && !i.tags.any(_activeTags.contains)) {
        return false;
      }
      if (query.isNotEmpty) {
        final inTitle = i.title.toLowerCase().contains(query);
        final inTags = i.tags.any((t) => t.toLowerCase().contains(query));
        if (!inTitle && !inTags) return false;
      }
      return true;
    }).toList();
    final items = applySort(
      filtered,
      _sort,
      name: (i) => i.title,
      createdAt: (i) => i.createdAt,
      pinned: (i) => i.pinned,
    );
    // Everything except the app bar scrolls: the search/controls bar, the tag
    // filter, any sub-spaces, and a no-match note all ride in the list header.
    final noMatch =
        items.isEmpty && (query.isNotEmpty || _activeTags.isNotEmpty);
    // Sub-spaces and items are separate sections, labelled only when both show.
    final labelSections = subSection != null && items.isNotEmpty;
    final headerChildren = <Widget>[
      if (!_selectMode && all.isNotEmpty) _buildItemsHeader(context),
      if (!_selectMode && allTags.isNotEmpty) _tagFilterBar(allTags),
      if (labelSections) _sectionLabel('Spaces'),
      ?subSection,
      if (labelSections) _sectionLabel('Items'),
      if (noMatch) _noMatchNote(query),
    ];
    final header = headerChildren.isEmpty
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: headerChildren,
          );
    return _view == 'grid'
        ? _grid(items, header: header)
        : ReorderableListView.builder(
            header: header,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 4, bottom: 88),
            buildDefaultDragHandles:
                !_readOnly &&
                !_selectMode &&
                !_offline &&
                _sort == kSortDefault &&
                _activeTags.isEmpty &&
                query.isEmpty,
            onReorderItem: _onReorder,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final isFocus = item.id == widget.focusItemId;
              return AnimatedContainer(
                key: ValueKey(item.id),
                duration: const Duration(milliseconds: 300),
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _flashId == item.id
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.12)
                      : Colors.transparent,
                ),
                child: KeyedSubtree(
                  key: isFocus ? _focusKey : null,
                  child: _itemCard(item, margin: EdgeInsets.zero),
                ),
              );
            },
          );
  }

  /// A section title (sub-spaces / items) in the scrolling header.
  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  /// A compact inline note shown in the scrolling header when a search or tag
  /// filter matches nothing (keeps the search bar above it accessible).
  Widget _noMatchNote(String query) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'No matching items',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            query.isNotEmpty
                ? 'No items match "${_query.trim()}".'
                : 'No items have the selected tags.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
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

  Future<void> _setTags(SpaceItem item, List<String> tags) async {
    // Optimistic: reflect the change immediately, then persist.
    setState(() {
      _items = _items
          ?.map((i) => i.id == item.id ? itemWithTags(i, tags) : i)
          .toList();
    });
    await persistItemTags(item, tags);
  }

  /// Two-column masonry grid: items are distributed round-robin so each keeps
  /// its natural height (no reordering in this view).
  Widget _grid(List<SpaceItem> items, {Widget? header}) {
    final columns = <List<Widget>>[<Widget>[], <Widget>[]];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final isFocus = item.id == widget.focusItemId;
      columns[i % 2].add(
        AnimatedContainer(
          key: ValueKey(item.id),
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _flashId == item.id
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          child: KeyedSubtree(
            key: isFocus ? _focusKey : null,
            child: _itemCard(item, margin: const EdgeInsets.all(4), grid: true),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 88),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(children: columns[0])),
              Expanded(child: Column(children: columns[1])),
            ],
          ),
        ],
      ),
    );
  }

  Widget _itemCard(
    SpaceItem item, {
    EdgeInsetsGeometry? margin,
    bool grid = false,
  }) => ItemCard(
    item: item,
    margin: margin,
    grid: grid,
    selectMode: _selectMode,
    selected: _selected.contains(item.id),
    onSelectToggle: () => _toggleSelect(item.id),
    // Read-only: the card opens a viewer, and only star, reminder, copy and
    // export stay.
    onTap: isEditableType(item.type) ? () => editItem(item) : null,
    onTogglePin: _readOnly ? null : () => togglePinItem(item),
    onToggleStar: () => toggleStarItem(item),
    onSetReminder: _offline ? null : () => editItemReminder(item),
    onToggleLock: () => toggleLockItem(item),
    onDuplicate: _readOnly ? null : () => duplicateItem(item),
    onMove: _readOnly ? null : () => moveItem(item),
    onArchive: _readOnly ? null : () => archiveItem(item),
    onExport: () => exportItem(item),
    onDelete: _readOnly ? null : () => deleteItem(item),
    onSetTags: _offline || _readOnly ? null : (tags) => _setTags(item, tags),
  );
}
