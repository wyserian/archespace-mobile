import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// What a [ReorderCard] carries while it's dragged: its list and its id, so a
/// card only takes drops from its own list.
typedef ReorderRef = ({String list, String id});

/// A card that can be held and dragged onto another card of the same [list]
/// to take its place; every reorderable list and grid in the app uses it, so
/// they all drag the same way. The card it would land on gets a soft accent
/// outline (as a selected card has), and dragging near the top or bottom of
/// the list scrolls it.
///
/// [onReorder] moves the card [fromId] into the place of [toId]. With the
/// list's [order] (its ids, as shown), screen readers also get "Move up" and
/// "Move down" actions, so reordering doesn't need a drag.
class ReorderCard extends StatefulWidget {
  const ReorderCard({
    super.key,
    required this.list,
    required this.id,
    required this.enabled,
    required this.onReorder,
    this.order = const [],
    required this.child,
  });

  final String list;
  final String id;
  final bool enabled;
  final void Function(String fromId, String toId) onReorder;
  final List<String> order;
  final Widget child;

  @override
  State<ReorderCard> createState() => _ReorderCardState();
}

class _ReorderCardState extends State<ReorderCard>
    with AutomaticKeepAliveClientMixin {
  // While it's being dragged the card stays built even when the list scrolls
  // it out of view, so the drag keeps reporting where the finger is.
  bool _dragging = false;

  @override
  bool get wantKeepAlive => _dragging;

  void _setDragging(bool dragging) {
    if (!dragging) _EdgeScroll.stop();
    if (!mounted || _dragging == dragging) return;
    _dragging = dragging;
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final child = widget.child;
    if (!widget.enabled) return child;
    final accent = Theme.of(context).colorScheme.primary;
    final index = widget.order.indexOf(widget.id);
    final previous = index > 0 ? widget.order[index - 1] : null;
    final next = index >= 0 && index < widget.order.length - 1
        ? widget.order[index + 1]
        : null;
    final card = LayoutBuilder(
      builder: (context, constraints) => DragTarget<ReorderRef>(
        onWillAcceptWithDetails: (d) =>
            d.data.list == widget.list && d.data.id != widget.id,
        onAcceptWithDetails: (d) => widget.onReorder(d.data.id, widget.id),
        builder: (context, candidates, _) => LongPressDraggable<ReorderRef>(
          data: (list: widget.list, id: widget.id),
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: constraints.maxWidth,
              child: Opacity(opacity: 0.95, child: child),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: child),
          onDragStarted: () => _setDragging(true),
          onDragUpdate: (d) => _EdgeScroll.update(context, d.globalPosition),
          onDragEnd: (_) => _setDragging(false),
          onDragCompleted: () => _setDragging(false),
          onDraggableCanceled: (_, _) => _setDragging(false),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: candidates.isNotEmpty
                  ? Border.all(color: accent.withValues(alpha: 0.4), width: 1.5)
                  : null,
            ),
            child: child,
          ),
        ),
      ),
    );
    if (previous == null && next == null) return card;
    return Semantics(
      customSemanticsActions: {
        if (previous != null)
          const CustomSemanticsAction(label: 'Move up'): () =>
              widget.onReorder(widget.id, previous),
        if (next != null)
          const CustomSemanticsAction(label: 'Move down'): () =>
              widget.onReorder(widget.id, next),
      },
      child: card,
    );
  }
}

/// Scrolls the list a dragged card is in while it's held near the list's top
/// or bottom edge, faster the closer it is. One drag at a time.
abstract final class _EdgeScroll {
  static const double _edge = 64;
  static const double _maxStep = 14;

  static Timer? _timer;
  static ScrollPosition? _position;
  static RenderBox? _box;
  static double _step = 0;

  static void update(BuildContext context, Offset pointer) {
    // The list the card is in; the last one found stays in use if the card
    // has gone (a list that doesn't keep cards alive).
    if (context.mounted) {
      final scrollable = Scrollable.maybeOf(context, axis: Axis.vertical);
      _position = scrollable?.position;
      _box = scrollable?.context.findRenderObject() as RenderBox?;
    }
    final box = _box;
    if (_position == null || box == null || !box.attached) return stop();
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final y = pointer.dy;
    _step = y < top + _edge
        ? -_maxStep * ((top + _edge - y) / _edge).clamp(0.0, 1.0)
        : y > bottom - _edge
        ? _maxStep * ((y - (bottom - _edge)) / _edge).clamp(0.0, 1.0)
        : 0;
    if (_step == 0) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final position = _position;
      if (position == null || !position.hasPixels) return stop();
      final next = (position.pixels + _step).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next != position.pixels) position.jumpTo(next);
    });
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _position = null;
    _box = null;
    _step = 0;
  }
}

/// [list] with the entry [fromId] moved into the place of [toId] (after it
/// when moving down, before it when moving up). Unchanged if either is
/// missing.
List<T> moveById<T>(
  List<T> list,
  String fromId,
  String toId,
  String Function(T) idOf,
) {
  final from = list.indexWhere((e) => idOf(e) == fromId);
  final to = list.indexWhere((e) => idOf(e) == toId);
  if (from < 0 || to < 0 || from == to) return list;
  final next = List<T>.of(list);
  next.insert(to, next.removeAt(from));
  return next;
}
