import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/shared/widgets/reorder_card.dart';

void main() {
  String id(String s) => s;

  test('moves an entry into another one\'s place', () {
    expect(moveById(['a', 'b', 'c'], 'a', 'c', id), ['b', 'c', 'a']);
    expect(moveById(['a', 'b', 'c'], 'c', 'a', id), ['c', 'a', 'b']);
    expect(moveById(['a', 'b', 'c'], 'a', 'x', id), ['a', 'b', 'c']);
  });

  testWidgets('a held card drops onto another of its list only', (
    tester,
  ) async {
    final moves = <String>[];
    Widget card(String list, String id) => ReorderCard(
      list: list,
      id: id,
      enabled: true,
      onMove: (from) => moves.add('$from->$id'),
      child: SizedBox(height: 80, child: Text(id)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              card('spaces', 'a'),
              card('spaces', 'b'),
              card('items', 'x'),
            ],
          ),
        ),
      ),
    );

    Future<void> drag(String from, String to) async {
      final g = await tester.startGesture(tester.getCenter(find.text(from)));
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveTo(tester.getCenter(find.text(to).first));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
    }

    await drag('a', 'b');
    await drag('a', 'x');
    expect(moves, ['a->b']);
  });
}
