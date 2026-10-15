import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
      onReorder: (from, to) => moves.add('$from->$to'),
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

  testWidgets('screen readers can move a card up or down', (tester) async {
    final semantics = tester.ensureSemantics();
    final moves = <String>[];
    const order = ['a', 'b', 'c'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final id in order)
                ReorderCard(
                  list: 'items',
                  id: id,
                  enabled: true,
                  order: order,
                  onReorder: (from, to) => moves.add('$from->$to'),
                  child: SizedBox(height: 80, child: Text(id)),
                ),
            ],
          ),
        ),
      ),
    );

    List<String> actionsOf(String id) {
      final data = tester.getSemantics(find.text(id)).getSemanticsData();
      return [
        for (final a in data.customSemanticsActionIds ?? <int>[])
          CustomSemanticsAction.getAction(a)!.label!,
      ]..sort();
    }

    // The first card can only go down, the last only up.
    expect(actionsOf('a'), ['Move down']);
    expect(actionsOf('b'), ['Move down', 'Move up']);
    expect(actionsOf('c'), ['Move up']);

    final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
    final node = tester.getSemantics(find.text('b'));
    int idOf(String label) => CustomSemanticsAction.getIdentifier(
      CustomSemanticsAction(label: label),
    );
    owner.performAction(node.id, SemanticsAction.customAction, idOf('Move up'));
    owner.performAction(
      node.id,
      SemanticsAction.customAction,
      idOf('Move down'),
    );
    expect(moves, ['b->a', 'b->c']);
    semantics.dispose();
  });
}
