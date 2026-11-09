import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/shared/widgets/action_menu.dart';

/// Menu rows for a Kanban stage's or a card's colour: "No color", then one
/// per space colour preset, [current] marked. [onPick] gets a preset id, or
/// null for none.
List<ActionMenuEntry> colorMenuEntries(
  BuildContext context, {
  required String? current,
  required ValueChanged<String?> onPick,
}) {
  Widget swatch(Color? c) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      color: c,
      shape: BoxShape.circle,
      border: c == null
          ? Border.all(color: Theme.of(context).colorScheme.outline)
          : null,
    ),
  );
  return [
    ActionMenuEntry(
      leading: swatch(null),
      label: 'No color',
      selected: spaceColor(current) == null,
      group: 'color',
      onSelected: () => onPick(null),
    ),
    for (final entry in kSpaceColors.entries)
      ActionMenuEntry(
        leading: swatch(entry.value),
        label: entry.key[0].toUpperCase() + entry.key.substring(1),
        selected: current == entry.key,
        group: 'color',
        onSelected: () => onPick(entry.key),
      ),
  ];
}

/// A coloured stage or card: a faint tint of [color] with a thin, soft strip
/// along the top (like a space card's) over [child]. Without a colour, just
/// [child] on [fill]. Full width; as tall as [child], so it works in a
/// fixed-height stage and in a scrolling list alike.
Widget colorTinted({
  required Color? color,
  required Color? fill,
  required BorderRadius radius,
  BoxBorder? border,
  required Widget child,
}) => Container(
  width: double.infinity,
  clipBehavior: Clip.antiAlias,
  decoration: BoxDecoration(
    color: color?.withValues(alpha: 0.08) ?? fill,
    borderRadius: radius,
    border: border,
  ),
  child: color == null
      ? child
      : Stack(
          fit: StackFit.passthrough,
          children: [
            child,
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 2,
              child: ColoredBox(color: color.withValues(alpha: 0.5)),
            ),
          ],
        ),
);
