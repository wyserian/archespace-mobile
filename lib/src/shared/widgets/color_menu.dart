import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/shared/widgets/action_menu.dart';
import 'package:archespace_mobile/src/shared/widgets/tap_area.dart';

/// "No color" plus one dot per space colour preset, [value] marked; for a
/// space (its editor) or an item card (the colour sheet).
class ColorDots extends StatelessWidget {
  const ColorDots({super.key, required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget dot(String? id, Color? color) {
      final isSelected = value == id;
      return Semantics(
        button: true,
        selected: isSelected,
        label: id == null ? 'No colour' : '$id colour',
        child: TapArea(
          onTap: () => onChanged(id),
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(
                color: isSelected ? scheme.onSurface : scheme.outlineVariant,
                width: isSelected ? 3 : 1,
              ),
            ),
            child: color == null
                ? Icon(Icons.block, size: 18, color: scheme.outline)
                : (isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 20)
                      : null),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        dot(null, null),
        for (final entry in kSpaceColors.entries) dot(entry.key, entry.value),
      ],
    );
  }
}

/// [theme] with its surfaces faintly tinted by [tint] (an item's colour), so
/// the input areas inside an item (notes, Cards, Kanban cards) take on its
/// colour as its card does. Unchanged without a colour.
ThemeData tintedTheme(ThemeData theme, Color? tint) {
  if (tint == null) return theme;
  Color t(Color c) => Color.alphaBlend(tint.withValues(alpha: 0.08), c);
  final s = theme.colorScheme;
  return theme.copyWith(
    colorScheme: s.copyWith(
      surface: t(s.surface),
      surfaceContainerLowest: t(s.surfaceContainerLowest),
      surfaceContainerLow: t(s.surfaceContainerLow),
      surfaceContainer: t(s.surfaceContainer),
      surfaceContainerHigh: t(s.surfaceContainerHigh),
      surfaceContainerHighest: t(s.surfaceContainerHighest),
    ),
  );
}

/// The result of the colour sheet: the picked preset id, or null for none.
typedef ColorEdit = ({String? color});

/// Pick an item card's colour; a tap picks and closes. Null when dismissed.
Future<ColorEdit?> showColorSheet(BuildContext context, {String? current}) =>
    showModalBottomSheet<ColorEdit>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Color',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              ColorDots(
                value: current,
                onChanged: (id) =>
                    Navigator.pop<ColorEdit>(sheetContext, (color: id)),
              ),
            ],
          ),
        ),
      ),
    );

/// A card with [color] (if any) as its top border, curved around the top
/// corners to match the web (a coloured top border on a rounded card).
/// [margin] must match the card's own margin, so the strip sits flush on its
/// top edge.
class TopColorBorder extends StatelessWidget {
  const TopColorBorder({
    super.key,
    required this.color,
    required this.margin,
    required this.child,
    this.radius = 16,
  });

  final Color? color;
  final EdgeInsetsGeometry margin;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final strip = color?.withValues(alpha: 0.5);
    if (strip == null) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: Padding(
              padding: margin,
              child: CustomPaint(
                painter: _TopBorderPainter(color: strip, radius: radius),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Fills the colour as a curved top border: [_thickness]px across the top
/// and around the upper part of each corner, then tapering to a gradual point
/// as it curves down toward the sides (rather than ending in a straight cut).
class _TopBorderPainter extends CustomPainter {
  _TopBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const double _thickness = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final r = radius;
    const t = _thickness;
    final ri = r - t;
    const s45 = 0.70710678; // sin/cos 45 deg: the band is full thickness here
    const sTip = 0.92718385; // sin 68 deg: where the band tapers out
    const cTip = 0.37460659; // cos 68 deg
    // Inner edge stays a concentric band down to the 45-degree diagonal; the
    // outer edge continues a little further, and the two meet so each end
    // narrows to a gradual point instead of a straight diagonal cut.
    final iLeft = Offset(r - ri * s45, r - ri * s45);
    final iRight = Offset(w - (r - ri * s45), r - ri * s45);
    final tipLeft = Offset(r * (1 - sTip), r * (1 - cTip));
    final tipRight = Offset(w - r * (1 - sTip), r * (1 - cTip));

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final path = Path()
      ..moveTo(tipLeft.dx, tipLeft.dy)
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..lineTo(w - r, 0)
      ..arcToPoint(tipRight, radius: Radius.circular(r))
      ..lineTo(iRight.dx, iRight.dy)
      ..arcToPoint(
        Offset(w - r, t),
        radius: Radius.circular(ri),
        clockwise: false,
      )
      ..lineTo(r, t)
      ..arcToPoint(iLeft, radius: Radius.circular(ri), clockwise: false)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TopBorderPainter old) =>
      old.color != color || old.radius != radius;
}

/// Menu rows for a Kanban stage's colour: "No color", then one per space
/// colour preset, [current] marked. [onPick] gets a preset id, or null for
/// none.
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

/// A coloured Kanban stage: a faint tint of [color] with a thin, soft strip
/// along the top (like a space card's) over [child]. Without a colour, just
/// [child] on [fill]. Full width; as tall as [child].
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
