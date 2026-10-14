import 'package:flutter/material.dart';

/// What a [ReorderCard] carries while it's dragged: its list and its id, so a
/// card only takes drops from its own list.
typedef ReorderRef = ({String list, String id});

/// A card that can be held and dragged onto another card of the same [list]
/// to take its place, for grids and short lists that aren't a reorderable list
/// view. [onMove] gets the id of the card dropped here; the one it lands on is
/// outlined while it's over it.
class ReorderCard extends StatelessWidget {
  const ReorderCard({
    super.key,
    required this.list,
    required this.id,
    required this.enabled,
    required this.onMove,
    required this.child,
  });

  final String list;
  final String id;
  final bool enabled;
  final void Function(String fromId) onMove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) => DragTarget<ReorderRef>(
        onWillAcceptWithDetails: (d) => d.data.list == list && d.data.id != id,
        onAcceptWithDetails: (d) => onMove(d.data.id),
        builder: (context, candidates, _) => LongPressDraggable<ReorderRef>(
          data: (list: list, id: id),
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: constraints.maxWidth,
              child: Opacity(opacity: 0.95, child: child),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: child),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: candidates.isNotEmpty
                  ? Border.all(color: accent, width: 2)
                  : null,
            ),
            child: child,
          ),
        ),
      ),
    );
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
