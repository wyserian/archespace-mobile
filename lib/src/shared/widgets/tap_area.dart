import 'package:flutter/material.dart';

/// Grows a small control's tap area to at least [minSize] square without
/// changing how it looks: [child] stays centred at its own size, and a tap on
/// the margin around it runs [onTap] too (a tap on [child] itself is handled
/// by [child]'s own InkWell, which wins as the deeper target).
class TapArea extends StatelessWidget {
  const TapArea({
    super.key,
    required this.onTap,
    required this.child,
    this.minSize = 48,
    this.minWidth,
  });

  final VoidCallback? onTap;
  final Widget child;
  final double minSize;

  /// The smallest width, when it differs from [minSize] (e.g. 0 for one half
  /// of a split chip, so no gap opens between its halves).
  final double? minWidth;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    // The child's own semantics already describe the tap.
    excludeFromSemantics: true,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minWidth ?? minSize,
        minHeight: minSize,
      ),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    ),
  );
}
