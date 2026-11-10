import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/shared/widgets/action_menu.dart';
import 'package:archespace_mobile/src/shared/widgets/tap_area.dart';

/// Tag chips on a card are this tall to tap: shorter than the usual 48 so a
/// row of tags doesn't make every card much taller.
const double kTagTapHeight = 36;

/// Every chip beside a card's tags (tags, the reminder) is this tall, with
/// this corner and text size, so text-only and icon chips share one shape.
const double kChipHeight = 22;
const double kChipRadius = 7;
const double kChipFontSize = 12;

/// A small tag chip: [label] on a [fill], with an optional [edge]. With
/// [onTap] it's tappable (e.g. to filter); with [onRemove] a long press opens
/// a "Remove tag" menu, so a tap can't remove a tag by mistake.
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    required this.color,
    required this.fill,
    this.edge = BorderSide.none,
    this.onTap,
    this.onRemove,
  });

  final String label;

  /// The text colour.
  final Color color;
  final Color fill;
  final BorderSide edge;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  static const BorderRadius _radius = BorderRadius.all(
    Radius.circular(kChipRadius),
  );

  @override
  Widget build(BuildContext context) {
    Widget face = Container(
      height: kChipHeight,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: _radius,
        border: Border.fromBorderSide(edge),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: kChipFontSize,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1,
        ),
      ),
    );
    if (onTap == null && onRemove == null) return face;
    final remove = onRemove;
    final onLongPress = remove == null
        ? null
        : () => showActionMenu(context, [
            ActionMenuEntry(
              icon: Icons.close,
              label: 'Remove tag',
              danger: true,
              onSelected: remove,
            ),
          ]);
    face = InkWell(
      borderRadius: _radius,
      onTap: onTap,
      onLongPress: onLongPress,
      child: face,
    );
    if (remove != null) {
      face = Semantics(onLongPressHint: 'Remove tag', child: face);
    }
    return TapArea(
      onTap: onTap,
      onLongPress: onLongPress,
      minSize: kTagTapHeight,
      minWidth: 0,
      child: face,
    );
  }
}

/// A chip beside a card's tags (its reminder, its self-destruct time), in the
/// tag chips' shape: an [icon] and [text] in [color], tinted and bordered in
/// it when [emphasized], with an optional [trailing] icon. Tappable with
/// [onTap]; read out as [semanticsLabel].
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
    required this.semanticsLabel,
    this.emphasized = false,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String text;
  final Color color;
  final String semanticsLabel;
  final bool emphasized;
  final IconData? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: onTap != null,
      label: semanticsLabel,
      excludeSemantics: true,
      child: TapArea(
        onTap: onTap,
        minSize: kTagTapHeight,
        minWidth: 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(kChipRadius),
          child: Container(
            height: kChipHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: emphasized
                  ? color.withValues(alpha: 0.12)
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(kChipRadius),
              border: Border.all(
                color: emphasized
                    ? color.withValues(alpha: 0.35)
                    : scheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: kChipFontSize,
                      fontWeight: FontWeight.w600,
                      color: color,
                      height: 1,
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 4),
                  Icon(trailing, size: 13, color: color),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The small field "Add tag" opens: Done or tapping away commits the typed
/// tag(s) (comma-separated, possibly none) through [onCommit] once; the host
/// then closes it.
class TagInput extends StatefulWidget {
  const TagInput({super.key, required this.onCommit});

  final ValueChanged<List<String>> onCommit;

  @override
  State<TagInput> createState() => _TagInputState();
}

class _TagInputState extends State<TagInput> {
  final TextEditingController _controller = TextEditingController();
  // Done then a tap away can both fire before the host removes the field.
  bool _committed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    if (_committed) return;
    _committed = true;
    widget.onCommit(
      _controller.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 120,
    child: TextField(
      controller: _controller,
      autofocus: true,
      style: const TextStyle(fontSize: 13),
      textInputAction: TextInputAction.done,
      maxLength: 32,
      decoration: InputDecoration(
        isDense: true,
        counterText: '',
        hintText: 'New tag',
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(7)),
      ),
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) => _commit(),
    ),
  );
}
