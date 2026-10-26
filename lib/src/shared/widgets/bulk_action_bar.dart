import 'package:flutter/material.dart';

class BulkAction {
  const BulkAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.struck = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Deletes or otherwise can't be undone easily: shown in red.
  final bool destructive;

  /// The icon with a slash through it, for an "un-" action with no icon of its
  /// own (Unpin).
  final bool struck;
}

/// The bar shown in selection mode, like the web's: a floating rounded card
/// (no outline) with the batch actions as quiet round icon buttons
/// (destructive ones in red). The app bar above shows the count and ends the
/// selection.
class BulkActionBar extends StatelessWidget {
  const BulkActionBar({super.key, required this.count, required this.actions});

  /// How many are selected; none leaves the actions disabled.
  final int count;
  final List<BulkAction> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        // Sized to its content and centred, not stretched across the screen.
        child: Align(
          heightFactor: 1,
          child: Material(
            // Set off by its raised colour and shadow, no outline.
            color: scheme.surfaceContainerHighest,
            elevation: 8,
            shadowColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              // Many actions on a narrow phone scroll sideways.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final action in actions)
                      IconButton(
                        onPressed: count == 0 ? null : action.onPressed,
                        icon: action.struck
                            ? _Struck(action.icon)
                            : Icon(action.icon, size: 21),
                        tooltip: action.label,
                        color: action.destructive
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon with a diagonal slash, in the button's current icon colour.
class _Struck extends StatelessWidget {
  const _Struck(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Icon(icon, size: 21),
      Transform.rotate(
        angle: -0.785, // 45 degrees
        child: Container(
          width: 24,
          height: 2,
          color: IconTheme.of(context).color,
        ),
      ),
    ],
  );
}
