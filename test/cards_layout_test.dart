import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_card.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/widgets/space_card.dart';

// A phone-width screen; any layout overflow fails the test.
Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ListView(children: [child])),
    ),
  );
}

void main() {
  testWidgets('space card lays out with tags and x', (tester) async {
    List<String>? saved;
    await _pump(
      tester,
      SpaceCard(
        space: Space(
          id: 's1',
          name: 'A rather long space name that has to be cut off',
          description: 'Notes',
          pinned: true,
          starred: true,
          tags: const ['work', 'ideas', 'reading list', 'later'],
          color: 'blue',
          itemCount: 3,
        ),
        onTap: () {},
        onTogglePin: () {},
        onEdit: () {},
        onDuplicate: () {},
        onArchive: () {},
        onDelete: () {},
        onSetTags: (tags) async {
          saved = tags;
          return true;
        },
      ),
    );
    expect(find.byTooltip('Remove tag'), findsNWidgets(4));
    expect(find.byType(TextField), findsNothing);

    // Removing shows at once, before the save comes back.
    await tester.tap(find.byTooltip('Remove tag').first);
    await tester.pump();
    expect(saved, ['ideas', 'reading list', 'later']);
    expect(find.text('work'), findsNothing);
  });

  testWidgets('a space with no tags shows none until Add tag', (tester) async {
    List<String>? saved;
    await _pump(
      tester,
      SpaceCard(
        space: Space(id: 's3', name: 'Plain', description: '', pinned: false),
        onTap: () {},
        onTogglePin: () {},
        onEdit: () {},
        onDuplicate: () {},
        onArchive: () {},
        onDelete: () {},
        onSetTags: (tags) async {
          saved = tags;
          return true;
        },
      ),
    );
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byTooltip('Space actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add tag'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'work');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(saved, ['work']);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('work'), findsOneWidget);
  });

  testWidgets('a read-only space shows its tags without editing', (
    tester,
  ) async {
    await _pump(
      tester,
      SpaceCard(
        space: Space(
          id: 's2',
          name: 'Frozen',
          description: '',
          pinned: false,
          readOnly: true,
          tags: const ['work'],
        ),
        onTap: () {},
        onTogglePin: () {},
        onEdit: () {},
        onDuplicate: () {},
        onArchive: () {},
        onDelete: () {},
        onSetTags: (_) async => true,
      ),
    );
    expect(find.text('work'), findsOneWidget);
    expect(find.byTooltip('Remove tag'), findsNothing);
  });

  testWidgets('item card: no collapse arrow, Copy in the menu', (tester) async {
    await _pump(
      tester,
      ItemCard(
        item: SpaceItem(
          id: 'i1',
          type: 'textbox',
          title: 'A note with a long title that needs to be cut off',
          content: const {'text': 'Hello'},
          pinned: true,
          starred: true,
          tags: const ['work'],
        ),
        onTap: () {},
        onTogglePin: () {},
        onDelete: () {},
        onSetTags: (_) {},
      ),
    );
    expect(find.byTooltip('Copy'), findsNothing);
    expect(find.text('Show more'), findsNothing);
    expect(find.text('Hello'), findsOneWidget);

    expect(find.byTooltip('Collapse'), findsNothing);
    expect(find.text('work'), findsOneWidget);

    await tester.tap(find.byTooltip('Item actions'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Add tag'), findsOneWidget);
  });
}
