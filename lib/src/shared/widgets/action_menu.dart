import 'package:flutter/material.dart';

/// One row of an [ActionMenuButton]: an icon and a label, red when [danger].
class ActionMenuEntry {
  const ActionMenuEntry({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool danger;
}

/// A 3-dot button opening a compact menu, styled like the web's: a panel the
/// colour of the cards with a hairline border and soft shadow, icon + label
/// rows, and destructive rows in red. It fades and scales in from the
/// button's corner.
class ActionMenuButton extends StatelessWidget {
  const ActionMenuButton({
    super.key,
    required this.tooltip,
    required this.entries,
    this.iconColor,
  });

  final String tooltip;
  final List<ActionMenuEntry> entries;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    width: 32,
    child: IconButton(
      padding: EdgeInsets.zero,
      tooltip: tooltip,
      icon: Icon(Icons.more_vert, size: 18, color: iconColor),
      onPressed: () => showActionMenu(context, entries),
    ),
  );
}

/// Open the [ActionMenuButton] menu at the widget of [context] (for a control
/// that isn't a 3-dot button, like a table grip).
Future<void> showActionMenu(
  BuildContext context,
  List<ActionMenuEntry> entries,
) async {
  final navigator = Navigator.of(context);
  final button = context.findRenderObject()! as RenderBox;
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final anchor = Rect.fromPoints(
    button.localToGlobal(Offset.zero, ancestor: overlay),
    button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    ),
  );
  final picked = await navigator.push(
    _ActionMenuRoute(
      anchor: anchor,
      entries: entries,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
  // After the menu has closed, so an action can open its own dialog.
  if (picked != null) entries[picked].onSelected();
}

const double _rowHeight = 40;
const double _panelPadding = 4;
const double _gap = 4;
const double _screenMargin = 8;

class _ActionMenuRoute extends PopupRoute<int> {
  _ActionMenuRoute({
    required this.anchor,
    required this.entries,
    required this.themes,
  });

  final Rect anchor;
  final List<ActionMenuEntry> entries;
  final CapturedThemes themes;

  /// Below the button, or above it when there isn't room below.
  bool _below(MediaQueryData media) {
    final height = entries.length * _rowHeight + 2 * _panelPadding;
    final bottomLimit =
        media.size.height - media.padding.bottom - _screenMargin;
    return anchor.bottom + _gap + height <= bottomLimit;
  }

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Close menu';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 100);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    return themes.wrap(
      CustomSingleChildLayout(
        delegate: _MenuLayout(
          anchor: anchor,
          below: _below(media),
          media: media,
        ),
        child: _MenuPanel(entries: entries),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween(begin: 0.94, end: 1.0).animate(curved),
        alignment: _below(MediaQuery.of(context))
            ? Alignment.topRight
            : Alignment.bottomRight,
        child: child,
      ),
    );
  }
}

/// Lines the menu's right edge up with the button's, just below it (or just
/// above), kept inside the screen's safe area.
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout({required this.anchor, required this.below, required this.media});

  final Rect anchor;
  final bool below;
  final MediaQueryData media;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        constraints.biggest,
      ).deflate(const EdgeInsets.all(_screenMargin));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (anchor.right - childSize.width).clamp(
      _screenMargin,
      size.width - childSize.width - _screenMargin,
    );
    final top = below
        ? anchor.bottom + _gap
        : anchor.top - _gap - childSize.height;
    return Offset(
      left,
      top.clamp(
        media.padding.top + _screenMargin,
        size.height - childSize.height - _screenMargin,
      ),
    );
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      anchor != old.anchor || below != old.below;
}

class _MenuPanel extends StatelessWidget {
  const _MenuPanel({required this.entries});

  final List<ActionMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    return Material(
      // Same surface as the cards, set apart by the hairline and the shadow.
      color: light ? Colors.white : scheme.surfaceContainer,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: light ? 0.25 : 0.6),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 176, maxWidth: 280),
        child: IntrinsicWidth(
          child: Padding(
            padding: const EdgeInsets.all(_panelPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < entries.length; i++)
                  _MenuRow(entry: entries[i], index: i),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.entry, required this.index});

  final ActionMenuEntry entry;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = entry.danger ? scheme.error : scheme.onSurfaceVariant;
    return SizedBox(
      height: _rowHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        highlightColor: entry.danger
            ? scheme.error.withValues(alpha: 0.12)
            : null,
        splashColor: entry.danger ? scheme.error.withValues(alpha: 0.12) : null,
        onTap: () => Navigator.of(context).pop(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(entry.icon, size: 18, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
