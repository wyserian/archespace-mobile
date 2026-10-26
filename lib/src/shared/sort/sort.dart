import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/shared/widgets/action_icon_button.dart';
import 'package:archespace_mobile/src/shared/widgets/action_menu.dart';

const String kSortDefault = 'default';
const String kSortName = 'name';
const String kSortNewest = 'newest';

/// Sort [list] by [mode]. Pinned entries always stay on top (matching the web),
/// then name (case-insensitive) or newest (created_at descending). `default`
/// keeps the incoming (position) order.
List<T> applySort<T>(
  List<T> list,
  String mode, {
  required String Function(T) name,
  required DateTime? Function(T) createdAt,
  required bool Function(T) pinned,
}) {
  if (mode == kSortDefault) return list;
  final sorted = List<T>.of(list);
  sorted.sort((a, b) {
    final pa = pinned(a);
    final pb = pinned(b);
    if (pa != pb) return pa ? -1 : 1;
    if (mode == kSortName) {
      return name(a).toLowerCase().compareTo(name(b).toLowerCase());
    }
    final ca = createdAt(a);
    final cb = createdAt(b);
    if (ca == null && cb == null) return 0;
    if (ca == null) return 1;
    if (cb == null) return -1;
    return cb.compareTo(ca); // newest first
  });
  return sorted;
}

/// App-bar sort dropdown with a check on the active option.
class SortMenu extends StatelessWidget {
  const SortMenu({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ActionIconButton(
      icon: Icons.sort,
      tooltip: 'Sort',
      onPressed: () => _open(context),
    );
  }

  /// Open the sort menu anchored to the button (the compact menu the cards
  /// use), so the trigger can be the same circular ActionIconButton used by
  /// the other app-bar actions.
  void _open(BuildContext context) => showActionMenu(context, [
    for (final (option, label, icon) in [
      (kSortDefault, 'Default', Icons.swap_vert),
      (kSortName, 'Name', Icons.sort_by_alpha),
      (kSortNewest, 'Newest', Icons.schedule),
    ])
      ActionMenuEntry(
        icon: icon,
        label: label,
        selected: value == option,
        onSelected: () => onChanged(option),
      ),
  ]);
}
