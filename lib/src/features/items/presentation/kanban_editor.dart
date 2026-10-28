import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/domain/kanban.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/shared/widgets/action_menu.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';

/// Editor for the Kanban type (see domain/kanban.dart; stages are stored as
/// `columns`): stages side by side that scroll sideways under an Add stage
/// button, each a list of cards above a pinned Add card button.
///
/// A card moves by dragging its handle (onto another card to go before it, or
/// onto a stage's end), or with its menu's "Move to". Enter on a card's title
/// adds the next card. Stages are renamed in place, and moved, coloured or
/// deleted from their menu. Deleting a stage or a card always asks first.
/// Edits are written back into [content] (the editor screen saves it). With
/// [readOnly] everything is readable and nothing changes.
class KanbanEditor extends StatefulWidget {
  const KanbanEditor({super.key, required this.content, this.readOnly = false});

  final Map<String, dynamic> content;
  final bool readOnly;

  @override
  State<KanbanEditor> createState() => _KanbanEditorState();
}

class _KanbanEditorState extends State<KanbanEditor> {
  late final List<KanbanColumn> _columns = kanbanColumns(widget.content);
  final Map<String, TextEditingController> _text = {};
  final Map<String, FocusNode> _focus = {};
  // Where a dragged card would land: (column id, index).
  (String, int)? _dropAt;
  // The card being edited (one of its fields has focus).
  String? _editing;

  @override
  void initState() {
    super.initState();
    _write();
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  /// Write the columns back into the content the editor screen saves.
  void _write() =>
      widget.content['columns'] = kanbanToJson(_columns)['columns'];

  void _change(VoidCallback edit) {
    setState(edit);
    _write();
  }

  TextEditingController _controller(String key, String text) =>
      _text.putIfAbsent(key, () => TextEditingController(text: text));

  FocusNode _focusFor(String key) => _focus.putIfAbsent(key, FocusNode.new);

  KanbanColumn _columnOf(KanbanCard card) =>
      _columns.firstWhere((col) => col.cards.contains(card));

  void _addCard(KanbanColumn col, [int? index]) {
    final card = KanbanCard();
    _change(() => col.cards.insert(index ?? col.cards.length, card));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focus['t${card.id}']?.requestFocus(),
    );
  }

  Future<void> _removeCard(KanbanCard card) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete this card?',
      message:
          '${quotedOr(card.title.trim().isNotEmpty ? card.title : card.description, 'This empty card')} will be removed.',
    );
    if (!ok || !mounted) return;
    _change(() => _columnOf(card).cards.remove(card));
    _text.remove('t${card.id}')?.dispose();
    _text.remove('d${card.id}')?.dispose();
  }

  /// Move [card] to [to] at [index] (its index before the move).
  void _moveCard(KanbanCard card, KanbanColumn to, int index) {
    final from = _columnOf(card);
    final fromIndex = from.cards.indexOf(card);
    var at = index;
    if (from == to && fromIndex < index) at -= 1;
    if (from == to && fromIndex == at) return;
    _change(() {
      from.cards.remove(card);
      to.cards.insert(at.clamp(0, to.cards.length), card);
    });
  }

  void _addColumn() {
    final col = KanbanColumn();
    _change(() => _columns.add(col));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focus['c${col.id}']?.requestFocus(),
    );
  }

  void _moveColumn(KanbanColumn col, int delta) {
    final index = _columns.indexOf(col);
    final to = index + delta;
    if (to < 0 || to >= _columns.length) return;
    _change(() {
      _columns.removeAt(index);
      _columns.insert(to, col);
    });
  }

  Future<void> _removeColumn(KanbanColumn col) async {
    final n = col.cards.length;
    final ok = await confirmDelete(
      context,
      title: 'Delete this stage?',
      message:
          '${quotedOr(col.title, 'This untitled stage')}'
          '${n > 0 ? ' and its $n ${n == 1 ? 'card' : 'cards'}' : ''} will be removed.',
    );
    if (!ok || !mounted) return;
    _change(() => _columns.remove(col));
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // Wide enough to edit, narrow enough that the next stage peeks in.
    final columnWidth = (width * 0.78).clamp(240.0, 320.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The same button as Add card, with a little room above it.
        if (!widget.readOnly)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _addColumn,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add stage'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ),
        Expanded(
          child: _columns.isEmpty && widget.readOnly
              ? Center(
                  child: Text(
                    'Empty',
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.only(top: widget.readOnly ? 8 : 0),
                  itemCount: _columns.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, i) =>
                      SizedBox(width: columnWidth, child: _column(_columns[i])),
                ),
        ),
      ],
    );
  }

  Widget _column(KanbanColumn col) {
    final scheme = Theme.of(context).colorScheme;
    final index = _columns.indexOf(col);
    final color = spaceColor(col.color);
    return Container(
      // A soft fill sets the stage apart; a colour tints it and adds a thin,
      // soft strip along the top, like a space card's.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color:
            color?.withValues(alpha: 0.08) ??
            scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (color != null)
            Container(height: 2, color: color.withValues(alpha: 0.5)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
              child: _columnBody(col, index),
            ),
          ),
        ],
      ),
    );
  }

  Widget _columnBody(KanbanColumn col, int index) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller('c${col.id}', col.title),
                focusNode: _focusFor('c${col.id}'),
                readOnly: widget.readOnly,
                onChanged: (v) => _change(() => col.title = v),
                style: const TextStyle(fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  hintText: widget.readOnly ? 'Untitled' : 'Stage name',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${col.cards.length}',
                semanticsLabel:
                    '${col.cards.length} '
                    '${col.cards.length == 1 ? 'card' : 'cards'}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (!widget.readOnly)
              _columnMenu(col, index)
            else
              const SizedBox(width: 8),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(right: 6),
            children: [
              for (var i = 0; i < col.cards.length; i++)
                _dropZone(col, i, child: _card(col, col.cards[i])),
              // The stage's end: dropping here adds to the bottom.
              _dropZone(
                col,
                col.cards.length,
                child: const SizedBox(height: 48),
              ),
            ],
          ),
        ),
        // Add card stays at the stage's bottom.
        if (!widget.readOnly)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _addCard(col),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add card'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ),
      ],
    );
  }

  Widget _columnMenu(KanbanColumn col, int index) {
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
    String label(String id) => id[0].toUpperCase() + id.substring(1);
    final canMove = _columns.length > 1;
    // The compact menu the cards use; it stays clear of the keyboard and
    // scrolls if it's taller than the room left.
    return ActionMenuButton(
      tooltip: 'Stage actions',
      entries: [
        if (index > 0)
          ActionMenuEntry(
            icon: Icons.arrow_back,
            label: 'Move left',
            onSelected: () => _moveColumn(col, -1),
          ),
        if (index < _columns.length - 1)
          ActionMenuEntry(
            icon: Icons.arrow_forward,
            label: 'Move right',
            onSelected: () => _moveColumn(col, 1),
          ),
        ActionMenuEntry(
          leading: swatch(null),
          label: 'No color',
          selected: col.color == null,
          dividerBefore: canMove,
          onSelected: () => _change(() => col.color = null),
        ),
        for (final entry in kSpaceColors.entries)
          ActionMenuEntry(
            leading: swatch(entry.value),
            label: label(entry.key),
            selected: col.color == entry.key,
            onSelected: () => _change(() => col.color = entry.key),
          ),
        ActionMenuEntry(
          icon: Icons.delete_outline,
          label: 'Delete stage',
          danger: true,
          dividerBefore: true,
          onSelected: () => _removeColumn(col),
        ),
      ],
    );
  }

  /// A place a dragged card can land: before the card at [index], or at the
  /// end when [index] is the stage's length. Shows a line while hovered.
  Widget _dropZone(KanbanColumn col, int index, {required Widget child}) {
    if (widget.readOnly) return child;
    final hovered = _dropAt == (col.id, index);
    return DragTarget<KanbanCard>(
      onWillAcceptWithDetails: (_) {
        if (_dropAt != (col.id, index)) {
          setState(() => _dropAt = (col.id, index));
        }
        return true;
      },
      onLeave: (_) {
        if (_dropAt == (col.id, index)) setState(() => _dropAt = null);
      },
      onAcceptWithDetails: (details) {
        setState(() => _dropAt = null);
        _moveCard(details.data, col, index);
      },
      builder: (context, _, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: hovered ? 3 : 0,
            margin: EdgeInsets.only(bottom: hovered ? 6 : 0),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _card(KanbanColumn col, KanbanCard card) {
    final scheme = Theme.of(context).colorScheme;
    final body = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.readOnly)
            Draggable<KanbanCard>(
              data: card,
              feedback: _dragFeedback(card),
              childWhenDragging: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.drag_indicator,
                  size: 18,
                  color: scheme.primary,
                ),
              ),
              onDragEnd: (_) => setState(() => _dropAt = null),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.drag_indicator,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                  semanticLabel: 'Drag to move',
                ),
              ),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            // Tracks whether one of this card's fields has focus (the card
            // is being edited), which shows an empty description.
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (focused) => setState(() {
                if (focused) {
                  _editing = card.id;
                } else if (_editing == card.id) {
                  _editing = null;
                }
              }),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _controller('t${card.id}', card.title),
                    focusNode: _focusFor('t${card.id}'),
                    readOnly: widget.readOnly,
                    minLines: 1,
                    maxLines: null,
                    // Enter adds the next card below.
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) =>
                        _addCard(col, col.cards.indexOf(card) + 1),
                    onChanged: (v) => _change(() => card.title = v),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: widget.readOnly ? 'Untitled' : 'Card',
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                  // The description shows when it's set, or while the card is
                  // being edited.
                  if (card.description.isNotEmpty ||
                      (!widget.readOnly && _editing == card.id))
                    TextField(
                      controller: _controller('d${card.id}', card.description),
                      focusNode: _focusFor('d${card.id}'),
                      readOnly: widget.readOnly,
                      minLines: 1,
                      maxLines: null,
                      onChanged: (v) => _change(() => card.description = v),
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Add description',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.only(bottom: 4),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!widget.readOnly) _cardMenu(col, card),
        ],
      ),
    );
    if (widget.readOnly) return body;
    // A tap anywhere on the card edits it (showing an empty description);
    // its fields and buttons still take their own taps.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _focus['t${card.id}']?.requestFocus(),
      child: body,
    );
  }

  Widget _cardMenu(KanbanColumn col, KanbanCard card) {
    final others = _columns.where((c) => c != col).toList();
    return ActionMenuButton(
      tooltip: 'Card actions',
      entries: [
        for (final c in others)
          ActionMenuEntry(
            icon: Icons.arrow_forward,
            label: 'Move to ${c.title.isEmpty ? 'Untitled' : c.title}',
            onSelected: () => _moveCard(card, c, c.cards.length),
          ),
        ActionMenuEntry(
          icon: Icons.delete_outline,
          label: 'Delete',
          danger: true,
          dividerBefore: others.isNotEmpty,
          onSelected: () => _removeCard(card),
        ),
      ],
    );
  }

  /// What follows the finger while a card is dragged.
  Widget _dragFeedback(KanbanCard card) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      color: scheme.surfaceContainerHigh,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(12),
        child: Text(
          card.title.isEmpty ? 'Untitled' : card.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
