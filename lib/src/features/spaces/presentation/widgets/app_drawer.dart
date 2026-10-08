import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:archespace_mobile/src/features/spaces/application/drawer_spaces.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/space_detail_screen.dart';
import 'package:archespace_mobile/src/features/settings/application/appearance_controller.dart';
import 'package:archespace_mobile/src/features/settings/presentation/settings_screen.dart';
import 'package:archespace_mobile/src/features/storage/application/storage_counts.dart';
import 'package:archespace_mobile/src/features/storage/presentation/storage_screen.dart';
import 'package:archespace_mobile/src/features/starred/presentation/starred_screen.dart';
import 'package:archespace_mobile/src/features/upcoming/application/reminder_notifications.dart';
import 'package:archespace_mobile/src/features/upcoming/presentation/upcoming_screen.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/widgets/brand_name.dart';

const _spacesOpenKey = 'drawer_spaces_open';

/// The drawer's destinations, to mark the screen it was opened on.
enum DrawerPage {
  dashboard,
  space,
  upcoming,
  starred,
  archive,
  bin,
  settings,
  other,
}

/// The app's navigation drawer: the name and a theme "shuffle" at the top, All
/// spaces and the top-level spaces (folding under their heading), the library
/// (Upcoming, Starred, Archive, Recycle bin) with counts, and Lock vault and
/// Settings at the bottom. Sign out lives in Settings.
///
/// Every main screen has it, opened by sliding from the left edge (the
/// dashboard also has a menu button). Its destinations go back to the
/// dashboard first, so screens don't pile up.
class AppDrawer extends StatefulWidget {
  const AppDrawer({super.key, required this.current, this.spaceId});

  /// The screen it was opened on, shown as selected.
  final DrawerPage current;

  /// The open space, for [DrawerPage.space].
  final String? spaceId;

  /// How far in from the left edge a slide opens the drawer: past the system
  /// back-gesture strip, which would otherwise take the whole default area.
  static double edgeDragWidth(BuildContext context) =>
      MediaQuery.systemGestureInsetsOf(context).left + 32;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  // Kept across drawer opens (the drawer is rebuilt each time) so the list
  // doesn't flash open before the saved choice loads.
  static bool? _spacesOpenCache;
  bool _spacesOpen = _spacesOpenCache ?? true;

  @override
  void initState() {
    super.initState();
    // Built each time the drawer opens: refresh the spaces and counts.
    DrawerSpaces.instance.refresh();
    StorageCounts.instance.refresh();
    if (_spacesOpenCache == null) {
      SharedPreferences.getInstance().then((prefs) {
        final open = prefs.getBool(_spacesOpenKey) ?? true;
        _spacesOpenCache = open;
        if (mounted) setState(() => _spacesOpen = open);
      });
    }
  }

  void _toggleSpaces() {
    final open = !_spacesOpen;
    setState(() => _spacesOpen = open);
    _spacesOpenCache = open;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_spacesOpenKey, open),
    );
  }

  bool _isCurrent(DrawerPage page, [String? spaceId]) =>
      widget.current == page && widget.spaceId == spaceId;

  /// Close the drawer and, unless it's [here] already, go back to the
  /// dashboard and [then] open the destination from there.
  void _go(
    BuildContext context, {
    required bool here,
    void Function(NavigatorState navigator)? then,
  }) {
    final navigator = Navigator.of(context);
    navigator.pop(); // close the drawer
    if (here) return;
    navigator.popUntil((route) => route.isFirst);
    then?.call(navigator);
  }

  void _open(BuildContext context, DrawerPage page, Widget screen) => _go(
    context,
    here: _isCurrent(page),
    then: (navigator) =>
        navigator.push(MaterialPageRoute<void>(builder: (_) => screen)),
  );

  void _openSpace(BuildContext context, Space space) => _go(
    context,
    here: _isCurrent(DrawerPage.space, space.id),
    then: (navigator) {
      final open = DrawerSpaces.instance.onOpenSpace;
      if (open != null) return open(space);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => SpaceDetailScreen(space: space),
        ),
      );
    },
  );

  void _lock(BuildContext context) {
    VaultSession.instance.lock();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 8, 0),
              child: Row(
                children: [
                  const Expanded(child: BrandName(fontSize: 20)),
                  IconButton(
                    icon: const Icon(Icons.palette_outlined),
                    tooltip: 'Shuffle accent and theme',
                    onPressed: () => AppearanceController.instance.randomize(
                      Theme.of(context).brightness,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: DrawerSpaces.instance,
                builder: (context, _) =>
                    _destinations(context, DrawerSpaces.instance.spaces),
              ),
            ),
            const SizedBox(height: 12),
            _tile(
              context,
              icon: Icons.lock_outline,
              label: 'Lock vault',
              onTap: () => _lock(context),
            ),
            _tile(
              context,
              icon: Icons.settings_outlined,
              label: 'Settings',
              selected: _isCurrent(DrawerPage.settings),
              onTap: () =>
                  _open(context, DrawerPage.settings, const SettingsScreen()),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// All spaces, the folding space list and the library.
  Widget _destinations(BuildContext context, List<Space> spaces) {
    return Column(
      children: [
        _tile(
          context,
          icon: Icons.grid_view_rounded,
          label: 'All spaces',
          selected: _isCurrent(DrawerPage.dashboard),
          count: spaces.length,
          onTap: () => _go(context, here: _isCurrent(DrawerPage.dashboard)),
        ),
        if (spaces.isNotEmpty) ...[
          _sectionLabel(
            context,
            'Spaces',
            expanded: _spacesOpen,
            onTap: _toggleSpaces,
          ),
          // Only the space list scrolls; the library below stays.
          if (_spacesOpen)
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final space in spaces)
                    _tile(
                      context,
                      label: space.name.isEmpty ? 'Untitled' : space.name,
                      protected: space.locked,
                      selected: _isCurrent(DrawerPage.space, space.id),
                      onTap: () => _openSpace(context, space),
                    ),
                ],
              ),
            ),
        ],
        _sectionLabel(context, 'Library'),
        // Reminders for today or past, as an accent badge.
        ValueListenableBuilder<int>(
          valueListenable: ReminderNotifications.instance.nowCount,
          builder: (context, nowCount, _) => _tile(
            context,
            icon: Icons.event_outlined,
            label: 'Upcoming',
            badge: nowCount,
            selected: _isCurrent(DrawerPage.upcoming),
            onTap: () =>
                _open(context, DrawerPage.upcoming, const UpcomingScreen()),
          ),
        ),
        ListenableBuilder(
          listenable: StorageCounts.instance,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _tile(
                context,
                icon: Icons.star_outline_rounded,
                label: 'Starred',
                count: StorageCounts.instance.starred,
                selected: _isCurrent(DrawerPage.starred),
                onTap: () =>
                    _open(context, DrawerPage.starred, const StarredScreen()),
              ),
              _tile(
                context,
                icon: Icons.archive_outlined,
                label: 'Archive',
                count: StorageCounts.instance.archive,
                selected: _isCurrent(DrawerPage.archive),
                onTap: () => _open(
                  context,
                  DrawerPage.archive,
                  const StorageScreen(mode: StorageMode.archive),
                ),
              ),
              _tile(
                context,
                icon: Icons.delete_outline,
                label: 'Recycle bin',
                count: StorageCounts.instance.bin,
                selected: _isCurrent(DrawerPage.bin),
                onTap: () => _open(
                  context,
                  DrawerPage.bin,
                  const StorageScreen(mode: StorageMode.bin),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A faint section heading. With [onTap] it folds its section, with a
  /// chevron showing which way.
  Widget _sectionLabel(
    BuildContext context,
    String label, {
    bool expanded = true,
    VoidCallback? onTap,
  }) {
    final color = Theme.of(
      context,
    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7);
    final text = Row(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: color,
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: 2),
          AnimatedRotation(
            turns: expanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(Icons.chevron_right, size: 16, color: color),
          ),
        ],
      ],
    );
    final padded = Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
      child: text,
    );
    if (onTap == null) return padded;
    return Semantics(
      button: true,
      expanded: expanded,
      child: InkWell(onTap: onTap, child: padded),
    );
  }

  /// A drawer row. Without an [icon] it's a space under the Spaces heading:
  /// smaller, tighter, and indented a step past the heading.
  Widget _tile(
    BuildContext context, {
    IconData? icon,
    required String label,
    required VoidCallback onTap,
    bool selected = false,
    bool protected = false,
    int? count,
    int badge = 0,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final nested = icon == null;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: nested ? 0 : 1),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        minTileHeight: nested ? 36 : null,
        minVerticalPadding: nested ? 0 : null,
        minLeadingWidth: 0,
        horizontalTitleGap: 10,
        // A nested row starts a step (12) past its heading's text (22).
        contentPadding: EdgeInsets.fromLTRB(nested ? 26 : 14, 0, 14, 0),
        // The current page reads through a soft fill and an accent icon, not
        // an accent-tinted row.
        leading: nested
            ? null
            : Icon(
                icon,
                size: 22,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: nested ? 13 : 15,
            color: selected ? scheme.onSurface : null,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        trailing: protected
            ? Icon(
                Icons.lock_outline,
                size: 14,
                color: scheme.onSurfaceVariant,
                semanticLabel: 'Protected',
              )
            : badge > 0
            ? Container(
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  textAlign: TextAlign.center,
                  semanticsLabel: '$badge for today or past',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimary,
                  ),
                ),
              )
            : count == null
            ? null
            : Text(
                '$count',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
        selected: selected,
        selectedColor: scheme.onSurface,
        selectedTileColor: scheme.onSurface.withValues(alpha: 0.07),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        onTap: onTap,
      ),
    );
  }
}
