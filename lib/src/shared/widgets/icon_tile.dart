import 'package:flutter/material.dart';

/// A screen's header icon in a soft rounded tile: a faint tint of [color]
/// (the accent by default) with a hairline of it, the icon in the full colour.
/// Matches the web's vault screens.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.primary;
    return Center(
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tint.withValues(alpha: 0.20)),
        ),
        child: Icon(icon, size: 26, color: tint),
      ),
    );
  }
}
