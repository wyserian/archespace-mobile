import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/items/domain/item_clipboard.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/kanban.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';

final board = <String, dynamic>{
  'columns': [
    {
      'id': 'a',
      'title': 'To do',
      'cards': [
        {'id': '1', 'title': 'Buy milk', 'description': '2 litres'},
        {'id': '2', 'title': 'Call Sam', 'description': ''},
      ],
    },
    {'id': 'b', 'title': 'Done', 'cards': <dynamic>[]},
  ],
};

void main() {
  test('starts with To do, Doing and Done', () {
    final columns = kanbanColumns(defaultContentFor('kanban'));
    expect(columns.map((c) => c.title), ['To do', 'Doing', 'Done']);
    expect(columns.map((c) => c.id).toSet().length, 3);
  });

  test('drops anything malformed', () {
    final columns = kanbanColumns({
      'columns': [
        null,
        {
          'title': 7,
          'cards': [
            {'title': 'x'},
            'bad',
          ],
        },
      ],
    });
    expect(columns, hasLength(1));
    expect(columns.single.title, '');
    expect(columns.single.cards.single.title, 'x');
    expect(columns.single.cards.single.description, '');
    expect(kanbanColumns(<String, dynamic>{}), isEmpty);
  });

  test('keeps a known column colour and drops any other', () {
    final columns = kanbanColumns({
      'columns': [
        {'color': 'rose', 'cards': <dynamic>[]},
        {'color': 'neon', 'cards': <dynamic>[]},
      ],
    });
    expect(columns.map((c) => c.color), ['rose', null]);
  });

  test('round-trips through JSON', () {
    final withColors = {
      'columns': [
        for (final col in board['columns'] as List)
          {...col as Map<String, dynamic>, 'color': null},
      ],
    };
    expect(kanbanToJson(kanbanColumns(withColors)), withColors);
  });

  test('copies as text, column by column', () {
    final text = 'To do\n- Buy milk: 2 litres\n- Call Sam\n\nDone';
    expect(kanbanText(board), text);
    final item = SpaceItem(
      id: 'k',
      type: 'kanban',
      title: '',
      content: board,
      pinned: false,
    );
    expect(isCopyableType('kanban'), isTrue);
    expect(itemClipboardText(item), text);
  });

  test('searches column titles, cards and descriptions', () {
    expect(kanbanSearchParts(board), [
      'To do',
      'Buy milk',
      '2 litres',
      'Call Sam',
      '',
      'Done',
    ]);
  });
}
