import 'package:flutter/material.dart';

/// A compact icon action button with a guaranteed circular tap splash.
///
/// Material 3 IconButtons can render a stadium-shaped (oval) state layer when
/// they are not square; forcing a [CircleBorder] shape at a fixed square size
/// keeps the touch highlight a consistent circle across every action button in
/// the app.
class ActionIconButton extends StatelessWidget {
  const ActionIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 21,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;

  /// The tap area: the smallest comfortable touch target.
  static const Size _size = Size(48, 48);

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: iconSize),
      style: IconButton.styleFrom(
        shape: const CircleBorder(),
        fixedSize: _size,
        minimumSize: _size,
        maximumSize: _size,
        padding: EdgeInsets.zero,
      ),
    );
  }
}
