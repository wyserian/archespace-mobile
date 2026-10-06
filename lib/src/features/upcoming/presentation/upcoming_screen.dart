import 'dart:async';

import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/reminder.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_actions.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_card.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/realtime/reload_when_shown.dart';
import 'package:archespace_mobile/src/shared/realtime/table_watcher.dart';
import 'package:archespace_mobile/src/shared/widgets/offline_banner.dart';
import 'package:archespace_mobile/src/shared/widgets/scrollable_message.dart';

/// Every item with a reminder, from anywhere, grouped by when it next goes
/// off (Today, Tomorrow, Next 7 days, Later), earliest first, and Past for
/// those that have gone off for the last time. Each item is labelled with
/// where it lives; removing its reminder takes it off.
class UpcomingScreen extends StatefulWidget {
  const UpcomingScreen({super.key});

  @override
  State<UpcomingScreen> createState() => _UpcomingScreenState();
}

class _UpcomingScreenState extends State<UpcomingScreen>
    with ItemActions<UpcomingScreen>, ReloadWhenShown<UpcomingScreen> {
  // Realtime changes reload this screen only while it's showing.
  @override
  Future<void> reloadShown() => _load();

  // No single space here.
  @override
  String? get itemsSpaceId => null;

  // Items come from many spaces: save, duplicate and move each one within its
  // own space.
  @override
  String? spaceIdFor(SpaceItem item) => item.spaceId;

  // An item from a read-only space opens as a viewer and offers no edits
  // (its reminder can still change).
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
  TableWatcher? _itemsWatcher;
  // Regroup as time passes: a reminder moves on to its next time, or to Past
  // once it has gone off for the last time.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _load();
    final userId = currentUserId();
    if (userId != null) {
      _itemsWatcher = TableWatcher(
        channelName: 'upcoming-items',
        table: 'space_items',
        filterColumn: 'user_id',
        filterValue: userId,
        onChange: reloadWhenShown,
      );
    }
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _itemsWatcher?.dispose();
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final key = VaultSession.instance.masterKey;
      final results = await Future.wait([
        SpaceRepository(key).listSpaces(),
        ItemRepository(key).listUpcomingItems(),
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
    final past = (_items ?? const <SpaceItem>[])
        .where((i) => i.reminder?.isPast() ?? false)
        .length;
    final total = (_items ?? const <SpaceItem>[])
        .where((i) => i.reminder != null)
        .length;
    return Scaffold(
      drawer: const AppDrawer(current: DrawerPage.upcoming),
      drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
      // Keep Back; the drawer opens with a slide from the left.
      appBar: AppBar(
        leading: const BackButton(),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Upcoming'),
            if (total > 0)
              Text(
                '$total ${total == 1 ? 'reminder' : 'reminders'}'
                '${past > 0 ? ' - $past past' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
      body: _items == null && _error == null
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
    if (_items == null && _error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: "Couldn't load Upcoming",
        message: 'Something went wrong. Check your connection and try again.',
        actionLabel: 'Retry',
        actionIcon: Icons.refresh,
        onAction: _load,
        destructiveIcon: true,
      );
    }
    final now = DateTime.now();
    final items =
        (_items ?? const <SpaceItem>[])
            .where((i) => i.reminder != null)
            .toList()
          ..sort((a, b) => a.reminder!.compareTo(b.reminder!));
    if (items.isEmpty) {
      return const StateMessage(
        icon: Icons.notifications_none_rounded,
        title: 'No reminders',
        message: 'Add a reminder to an item from its menu to see it here.',
      );
    }
    final names = {
      for (final s in _spaces ?? const <Space>[])
        s.id: s.name.isEmpty ? 'Untitled' : s.name,
    };
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      children: [
        for (final group in ReminderGroup.values)
          ..._group(
            group,
            items.where((i) => i.reminder!.group(now) == group).toList(),
            names,
          ),
      ],
    );
  }

  /// A group's heading (with its count) and cards; nothing when empty.
  List<Widget> _group(
    ReminderGroup group,
    List<SpaceItem> items,
    Map<String, String> names,
  ) {
    if (items.isEmpty) return const [];
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.titleMedium;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: group.label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: group == ReminderGroup.past ? scheme.error : null,
                ),
              ),
              TextSpan(
                text: '  ${items.length}',
                style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          style: style,
        ),
      ),
      for (final i in items)
        _itemCard(
          i,
          i.spaceId == null ? 'Dashboard' : names[i.spaceId] ?? 'Space',
        ),
    ];
  }

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
