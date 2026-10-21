import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_actions.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_card.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_tree.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_destinations_sheet.dart';
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
import 'package:archespace_mobile/src/shared/widgets/reorder_card.dart';
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

  /// The spaces above this one, top first.
  List<Space> _ancestors = const [];
  Object? _error;
  bool _offline = false;
  TableWatcher? _watcher;
  final GlobalKey _focusKey = GlobalKey();
  String? _flashId;
  bool _focusHandled = false;
  bool _selectMode = false;
  // Selected items and sub-spaces (select mode covers both).
  final Set<String> _selected = {};
  final Set<String> _selectedSpaces = {};
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
            _selectedSpaces.clear();
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
          _selectedSpaces.clear();
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
      // All spaces (spaces nest to any depth): this one's sub-spaces, and the
      // spaces above it for the path in the title. They load alongside the
      // items rather than after them.
      final spacesFuture = SpaceRepository(VaultSession.instance.masterKey)
          .listSpaces()
          .then((r) => r.spaces)
          // Non-fatal: items still load without the sub-spaces and path.
          .catchError((Object _) => const <Space>[]);
      final result = await ItemRepository(
        VaultSession.instance.masterKey,
      ).listItems(widget.space.id);
      final spaces = await spacesFuture;
      final byId = {for (final s in spaces) s.id: s};
      // The loaded row knows the parent even when this screen was opened
      // with a bare space (from search).
      String? parentOf(String id) =>
          byId[id]?.parentId ??
          (id == widget.space.id ? widget.space.parentId : null);
      if (mounted) {
        setState(() {
          _items = result.items;
          _subSpaces = [
            for (final s in spaces)
              if (s.parentId == widget.space.id) s,
          ];
          _ancestors = [
            for (final id in ancestorsOf(widget.space.id, parentOf).reversed)
              ?byId[id],
          ];
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
    margin: EdgeInsets.zero,
    selectMode: _selectMode,
    selected: _selectedSpaces.contains(sub.id),
    onSelectToggle: () => _toggleSelectSpace(sub.id),
    activeTags: _activeTags,
    onTagClick: (tag) => setState(() {
      if (!_activeTags.remove(tag)) _activeTags.add(tag);
    }),
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
    onMove: () async {
      if (await moveSpacesTo(context, [sub.id]) && mounted) _load();
    },
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
    _selectedSpaces.clear();
  });

  void _toggleSelect(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _toggleSelectSpace(String id) => setState(() {
    if (!_selectedSpaces.remove(id)) _selectedSpaces.add(id);
  });

  void _selectAll() => setState(() {
    _selected
      ..clear()
      ..addAll((_items ?? const <SpaceItem>[]).map((i) => i.id));
    _selectedSpaces
      ..clear()
      ..addAll(_subSpaces.map((s) => s.id));
  });

  int get _selectedCount => _selected.length + _selectedSpaces.length;

  /// "2 spaces", "3 items", or "2 spaces and 3 items".
  String _selectionLabel(int spaces, int items) => [
    if (spaces > 0) '$spaces ${spaces == 1 ? 'space' : 'spaces'}',
    if (items > 0) '$items ${items == 1 ? 'item' : 'items'}',
  ].join(' and ');

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

  /// Move an item into another's place (drag and drop, in the list or grid).
  void _moveItemById(String fromId, String toId) {
    final list = moveById(
      _items ?? const <SpaceItem>[],
      fromId,
      toId,
      (i) => i.id,
    );
    setState(() => _items = list);
    _persistOrder(list);
  }

  /// Move a sub-space into another's place and save the sub-spaces' order.
  Future<void> _moveSubSpace(String fromId, String toId) async {
    final list = moveById(_subSpaces, fromId, toId, (s) => s.id);
    setState(() => _subSpaces = list);
    try {
      await SpaceRepository(
        VaultSession.instance.masterKey,
      ).reorder([for (final s in list) s.id]);
    } catch (_) {
      _showError("Couldn't save the new order.");
      if (mounted) _load();
    }
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

  /// Run a bulk action on the selected sub-spaces and items, then leave select
  /// mode and refresh.
  Future<bool> _runBulk(
    Future<void> Function(
      SpaceRepository spaces,
      ItemRepository items,
      List<String> spaceIds,
      List<String> itemIds,
    )
    op,
  ) async {
    if (_selectedCount == 0) return false;
    final key = VaultSession.instance.masterKey;
    try {
      await op(
        SpaceRepository(key),
        ItemRepository(key),
        _selectedSpaces.toList(),
        _selected.toList(),
      );
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

  /// Undo an archive or move-to-bin for the given sub-spaces and items.
  Future<void> _restore(List<String> spaceIds, List<String> itemIds) async {
    try {
      await SpaceRepository(
        VaultSession.instance.masterKey,
      ).restoreSpaces(spaceIds);
      await restoreItems(itemIds);
      if (mounted) _load();
    } catch (_) {
      _showError("Couldn't undo that.");
    }
  }

  Future<void> _bulkSetPinned(bool pinned) => _runBulk(
    (spaces, items, spaceIds, itemIds) => Future.wait([
      spaces.bulkSetPinned(spaceIds, pinned),
      items.bulkSetPinned(itemIds, pinned),
    ]),
  );

  Future<void> _bulkArchive() async {
    final spaceIds = _selectedSpaces.toList();
    final itemIds = _selected.toList();
    final ok = await _runBulk(
      (spaces, items, s, i) =>
          Future.wait([spaces.bulkArchive(s), items.bulkArchive(i)]),
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
    final spaceIds = _selectedSpaces.toList();
    final itemIds = _selected.toList();
    final label = _selectionLabel(spaceIds.length, itemIds.length);
    // Spaces take everything inside them along, so they ask first.
    if (spaceIds.isNotEmpty) {
      final ok = await confirmAction(
        context,
        title: 'Move $label to bin?',
        message: 'They and their items go to the recycle bin.',
        confirmLabel: 'Move to bin',
        destructive: true,
      );
      if (!ok) return;
    }
    final ok = await _runBulk(
      (spaces, items, s, i) =>
          Future.wait([spaces.bulkDelete(s), items.bulkDelete(i)]),
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

  Future<void> _bulkMoveItems() async {
    final target = await pickMoveTarget(itemsSpaceId);
    if (target == null) return;
    await _runBulk(
      (_, items, _, itemIds) => items.bulkMove(itemIds, target.id),
    );
  }

  Future<void> _bulkMoveSpaces() async {
    if (await moveSpacesTo(context, _selectedSpaces.toList()) && mounted) {
      _exitSelect();
      _load();
    }
  }

  void _showError(String message) => showItemError(message);

  Future<void> _exportSpace() => exportPdf(
    build: () => PdfExporter.buildSpace(
      widget.space.name,
      _items ?? const [],
      subSpaceNames: [
        for (final s in _subSpaces) s.name.isEmpty ? 'Untitled' : s.name,
      ],
    ),
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
                        hintText: 'Search this space',
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
          // Every bulk action changes something here, so there's no
          // selecting while read-only.
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

  /// The space's name, with the spaces above it on a small line above
  /// ("A › B", or "A › … › D" when deeper).
  Widget _title(BuildContext context) {
    final name = Text(
      widget.space.name.isEmpty ? 'Untitled' : widget.space.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (_ancestors.isEmpty) return name;
    final names = [
      for (final s in _ancestors) s.name.isEmpty ? 'Untitled' : s.name,
    ];
    final path = names.length > 2
        ? '${names.first} › … › ${names.last}'
        : names.join(' › ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        name,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final drawer = AppDrawer(
      current: DrawerPage.space,
      // The drawer lists top-level spaces: mark the one this sits under.
      spaceId: _ancestors.isEmpty ? widget.space.id : _ancestors.first.id,
    );
    if (_hidden) {
      return Scaffold(
        drawer: drawer,
        drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
        appBar: AppBar(
          // Keep Back; the drawer opens with a slide from the left.
          leading: const BackButton(),
          titleSpacing: 0,
          title: _title(context),
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
              title: Text('$_selectedCount selected'),
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
              title: _title(context),
              actions: _buildBarActions(hasItems),
            ),
      floatingActionButton: _selectMode || _readOnly
          ? null
          : CreateFabs(
              onAddItem: openAddItemSheet,
              // A sub-space of this one, at any depth.
              onNewSpace: _items != null ? _createSubSpace : null,
            ),
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
                // Sub-spaces or items move, not both at once (a read-only
                // sub-space stays where it is).
                if (_selected.isNotEmpty && _selectedSpaces.isEmpty)
                  BulkAction(
                    icon: Icons.drive_file_move_outlined,
                    label: 'Move',
                    onPressed: _bulkMoveItems,
                  ),
                if (_selectedSpaces.isNotEmpty &&
                    _selected.isEmpty &&
                    !_subSpaces.any(
                      (s) => _selectedSpaces.contains(s.id) && s.readOnly,
                    ))
                  BulkAction(
                    icon: Icons.drive_file_move_outlined,
                    label: 'Move',
                    onPressed: _bulkMoveSpaces,
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
    if (all.isEmpty && _subSpaces.isEmpty) {
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
    // Search, tags and sort cover the sub-spaces and the items.
    final allTags = <String>{
      for (final s in _subSpaces) ...s.tags,
      for (final i in all) ...i.tags,
    }.toList()..sort();
    // Drop selected tags that nothing carries any more (e.g. the tag was just
    // removed, deleted or moved away). Otherwise the filter would match
    // nothing and the space would look empty, with no pill left to deselect.
    _activeTags.removeWhere((t) => !allTags.contains(t));
    final query = _query.trim().toLowerCase();
    bool matches(String name, List<String> tags) {
      if (_activeTags.isNotEmpty && !tags.any(_activeTags.contains)) {
        return false;
      }
      if (query.isEmpty) return true;
      return name.toLowerCase().contains(query) ||
          tags.any((t) => t.toLowerCase().contains(query));
    }

    final subSpaces = applySort(
      [
        for (final s in _subSpaces)
          if (matches(s.name, s.tags)) s,
      ],
      _sort,
      name: (s) => s.name,
      createdAt: (s) => s.createdAt,
      pinned: (s) => s.pinned,
    );
    final items = applySort(
      [
        for (final i in all)
          if (matches(i.title, i.tags)) i,
      ],
      _sort,
      name: (i) => i.title,
      createdAt: (i) => i.createdAt,
      pinned: (i) => i.pinned,
    );
    // Manual order only applies unfiltered, in the default sort.
    final canReorder =
        !_readOnly &&
        !_selectMode &&
        !_offline &&
        _sort == kSortDefault &&
        _activeTags.isEmpty &&
        query.isEmpty;
    // Sub-spaces render above the items in the same view (matching the web).
    // Hold one to drag it into another's place.
    final subSpaceIds = [for (final s in subSpaces) s.id];
    final subSection = subSpaces.isEmpty
        ? null
        : Column(
            children: [
              for (final s in subSpaces)
                Padding(
                  key: ValueKey('space-${s.id}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: ReorderCard(
                    list: 'sub-spaces',
                    id: s.id,
                    enabled: canReorder,
                    order: subSpaceIds,
                    onReorder: _moveSubSpace,
                    child: _subSpaceCard(s),
                  ),
                ),
            ],
          );
    // Everything except the app bar scrolls: the search/controls bar, the tag
    // filter, any sub-spaces, and a no-match note all ride in the list header.
    final noMatch =
        subSpaces.isEmpty &&
        items.isEmpty &&
        (query.isNotEmpty || _activeTags.isNotEmpty);
    // Sub-spaces and items are separate sections, labelled only when both show.
    final labelSections = subSection != null && items.isNotEmpty;
    final headerChildren = <Widget>[
      if (!_selectMode) _buildItemsHeader(context),
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
    final itemIds = [for (final i in items) i.id];
    return _view == 'grid'
        ? _grid(items, header: header, canReorder: canReorder)
        // Hold a card and drag it onto another to take its place, as in the
        // grid; the header (controls, tags, sub-spaces) scrolls with it.
        : ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 4, bottom: 88),
            itemCount: items.length + (header == null ? 0 : 1),
            itemBuilder: (context, index) {
              if (header != null && index == 0) return header;
              final item = items[index - (header == null ? 0 : 1)];
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
                  child: ReorderCard(
                    list: 'items',
                    id: item.id,
                    enabled: canReorder,
                    order: itemIds,
                    onReorder: _moveItemById,
                    child: _itemCard(item, margin: EdgeInsets.zero),
                  ),
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
            'Nothing matches',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            query.isNotEmpty
                ? 'Nothing here matches "${_query.trim()}".'
                : 'Nothing here has the selected tags.',
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
  /// its natural height. With [canReorder], hold a card and drag it onto
  /// another to take its place.
  Widget _grid(
    List<SpaceItem> items, {
    Widget? header,
    bool canReorder = false,
  }) {
    final columns = <List<Widget>>[<Widget>[], <Widget>[]];
    final itemIds = [for (final i in items) i.id];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final isFocus = item.id == widget.focusItemId;
      columns[i % 2].add(
        AnimatedContainer(
          key: ValueKey(item.id),
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _flashId == item.id
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          child: KeyedSubtree(
            key: isFocus ? _focusKey : null,
            child: ReorderCard(
              list: 'items',
              id: item.id,
              enabled: canReorder,
              order: itemIds,
              onReorder: _moveItemById,
              child: _itemCard(item, margin: EdgeInsets.zero, grid: true),
            ),
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
