import 'package:flutter/material.dart';

/// The + (and, turned, the x) on the create button: above Material's 24 so it
/// reads clearly in the app's 50px button.
const double _plusSize = 30;

/// The create button. With both actions it is a speed dial: tapping + opens
/// the options above it over a dimmed screen, "New item", "New space" and,
/// nearest the + as the quickest, "Quick note"; the + turns into a close
/// button. Pass no [onNewSpace] to show a plain New item button (e.g. while
/// a space is still loading).
class CreateFabs extends StatefulWidget {
  const CreateFabs({
    super.key,
    required this.onAddItem,
    this.onNewSpace,
    this.onQuickNote,
  });

  final VoidCallback onAddItem;
  final VoidCallback? onNewSpace;

  /// A Rich text note, open and ready to type. Null leaves it out.
  final VoidCallback? onQuickNote;

  @override
  State<CreateFabs> createState() => _CreateFabsState();
}

class _CreateFabsState extends State<CreateFabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _curve;
  late final List<Animation<double>> _stagger;
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _curve = CurvedAnimation(
      parent: _anim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // Each option's entrance, staggered from the + button outwards; the last
    // of the three still ends at 1.0.
    _stagger = [
      for (var i = 0; i < 3; i++)
        CurvedAnimation(
          parent: _curve,
          curve: Interval(i * 0.1, i * 0.1 + 0.8),
        ),
    ];
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _show() {
    setState(() => _open = true);
    _portal.show();
    _anim.forward();
  }

  Future<void> _close() async {
    if (!_open) return;
    setState(() => _open = false);
    await _anim.reverse();
    if (mounted && !_open) _portal.hide();
  }

  /// Close the dial, then run the chosen action.
  void _pick(VoidCallback action) {
    _close();
    action();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onNewSpace == null) {
      return FloatingActionButton(
        heroTag: 'fab-add-item',
        onPressed: widget.onAddItem,
        tooltip: 'New item',
        child: const Icon(Icons.add, size: _plusSize),
      );
    }
    return PopScope(
      // Back closes the open dial instead of leaving the screen.
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildDial,
        child: CompositedTransformTarget(
          link: _link,
          child: FloatingActionButton(
            heroTag: 'fab-create',
            onPressed: _show,
            tooltip: 'Create',
            child: const Icon(Icons.add, size: _plusSize),
          ),
        ),
      ),
    );
  }

  /// The open dial, drawn above the whole screen: a scrim that closes it,
  /// the options, and the close button exactly over the + button.
  Widget _buildDial(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fabColor =
        Theme.of(context).floatingActionButtonTheme.backgroundColor ??
        scheme.primary;
    final fabFg =
        Theme.of(context).floatingActionButtonTheme.foregroundColor ??
        scheme.onPrimary;
    final quick = widget.onQuickNote != null;
    return Stack(
      children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: _curve,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.45)),
            ),
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.bottomRight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _option(
                index: quick ? 2 : 1,
                label: 'New item',
                onTap: () => _pick(widget.onAddItem),
              ),
              const SizedBox(height: 12),
              _option(
                index: quick ? 1 : 0,
                label: 'New space',
                onTap: () => _pick(widget.onNewSpace!),
              ),
              if (quick) ...[
                const SizedBox(height: 12),
                _option(
                  index: 0,
                  label: 'Quick note',
                  onTap: () => _pick(widget.onQuickNote!),
                ),
              ],
              const SizedBox(height: 18),
              AnimatedBuilder(
                animation: _curve,
                builder: (context, child) => FloatingActionButton(
                  heroTag: null,
                  onPressed: _close,
                  tooltip: 'Close',
                  backgroundColor: Color.lerp(
                    fabColor,
                    scheme.surfaceContainerHighest,
                    _curve.value,
                  ),
                  foregroundColor: Color.lerp(
                    fabFg,
                    scheme.onSurface,
                    _curve.value,
                  ),
                  child: child,
                ),
                // + turns an eighth into an x.
                child: RotationTransition(
                  turns: Tween(begin: 0.0, end: 0.125).animate(_curve),
                  child: const Icon(Icons.add, size: _plusSize),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One option: a text pill in the + button's accent. Options nearer the +
  /// button ([index] 0) appear first.
  Widget _option({
    required int index,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final color =
        theme.floatingActionButtonTheme.backgroundColor ??
        theme.colorScheme.primary;
    final fg =
        theme.floatingActionButtonTheme.foregroundColor ??
        theme.colorScheme.onPrimary;
    final anim = _stagger[index];
    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.3),
          end: Offset.zero,
        ).animate(anim),
        child: Semantics(
          button: true,
          child: Material(
            color: color,
            elevation: 2,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                // Keeps the pill 48 tall, like a standard button.
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 13,
                ),
                child: Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: fg,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
