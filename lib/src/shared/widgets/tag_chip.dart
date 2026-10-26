import 'package:flutter/material.dart';

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
/// [onTap] the label is tappable (e.g. to filter); with [onRemove] an x at
/// its end removes the tag. Label and x are two halves of one chip, each with
/// its own [kTagTapHeight] tap area, so neither tap lands on the other.
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

  /// The text and x colour.
  final Color color;
  final Color fill;
  final BorderSide edge;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  static const Radius _r = Radius.circular(kChipRadius);

  Widget _half({
    required Widget child,
    required VoidCallback? onTap,
    required BorderRadius radius,
    required Border border,
    required EdgeInsets padding,
    String? tooltip,
  }) {
    // A fixed height, content centred: both halves line up whatever the text.
    Widget face = Container(
      height: kChipHeight,
      alignment: Alignment.center,
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: border,
      ),
      child: child,
    );
    if (onTap == null) return face;
    face = InkWell(borderRadius: radius, onTap: onTap, child: face);
    if (tooltip != null) face = Tooltip(message: tooltip, child: face);
    return TapArea(
      onTap: onTap,
      minSize: kTagTapHeight,
      minWidth: 0,
      child: face,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        fontSize: kChipFontSize,
        fontWeight: FontWeight.w600,
        color: color,
        height: 1,
      ),
    );
    if (onRemove == null) {
      return _half(
        child: text,
        onTap: onTap,
        radius: const BorderRadius.all(_r),
        border: Border.fromBorderSide(edge),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _half(
          child: text,
          onTap: onTap,
          radius: const BorderRadius.horizontal(left: _r),
          border: Border(top: edge, left: edge, bottom: edge),
          padding: const EdgeInsets.only(left: 8, right: 3),
        ),
        _half(
          child: Icon(
            Icons.close,
            size: 13,
            color: color,
            semanticLabel: 'Remove tag $label',
          ),
          onTap: onRemove,
          tooltip: 'Remove tag',
          radius: const BorderRadius.horizontal(right: _r),
          border: Border(top: edge, right: edge, bottom: edge),
          padding: const EdgeInsets.only(left: 2, right: 6),
        ),
      ],
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
