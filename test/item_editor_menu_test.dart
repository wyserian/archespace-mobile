import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/item_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _note = SpaceItem(
  id: 'i1',
  type: 'textbox',
  title: 'Groceries',
  content: const {'text': 'milk'},
  pinned: false,
  tags: const ['home'],
);

/// The editor opened over a host page, as from a card.
Future<void> _open(WidgetTester tester, ItemEditorScreen editor) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<bool>(builder: (_) => editor)),
            child: const Text('host'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('host'));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Item actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Pin runs on the current item and flips to Unpin', (
    tester,
  ) async {
    SpaceItem? pinned;
    await _open(
      tester,
      ItemEditorScreen(
        spaceId: 's1',
        type: 'textbox',
        existing: _note,
        onTogglePin: (item) async {
          pinned = item;
          return true;
        },
      ),
    );
    expect(find.text('home'), findsOneWidget); // tags show in the editor

    await _pick(tester, 'Pin');
    expect(pinned?.id, 'i1');
    expect(pinned?.pinned, isFalse);

    await tester.tap(find.byTooltip('Item actions'));
    await tester.pumpAndSettle();
    expect(find.text('Unpin'), findsOneWidget);
  });

  testWidgets('Archive closes the editor once it worked', (tester) async {
    await _open(
      tester,
      ItemEditorScreen(
        spaceId: 's1',
        type: 'textbox',
        existing: _note,
        onArchive: (_) async => true,
      ),
    );
    await _pick(tester, 'Archive');
    expect(find.byType(ItemEditorScreen), findsNothing);
    expect(find.text('host'), findsOneWidget);
  });

  testWidgets('a failed Delete keeps the editor open', (tester) async {
    await _open(
      tester,
      ItemEditorScreen(
        spaceId: 's1',
        type: 'textbox',
        existing: _note,
        onDelete: (_) async => false,
      ),
    );
    await _pick(tester, 'Delete');
    expect(find.byType(ItemEditorScreen), findsOneWidget);
  });

  testWidgets('a Quick note left untouched saves nothing', (tester) async {
    await _open(
      tester,
      const ItemEditorScreen(
        spaceId: null,
        type: 'textbox',
        initialTitle: 'Quick Note',
      ),
    );
    expect(find.text('Quick Note'), findsOneWidget);

    // Back with nothing typed: closes at once, no save attempted (a save
    // would need a backend and keep the editor open on its error).
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ItemEditorScreen), findsNothing);
  });

  testWidgets('read-only offers no edits, only what the host allows', (
    tester,
  ) async {
    await _open(
      tester,
      ItemEditorScreen(
        spaceId: 's1',
        type: 'textbox',
        existing: _note,
        readOnly: true,
        onToggleStar: (_) async => true,
      ),
    );
    await tester.tap(find.byTooltip('Item actions'));
    await tester.pumpAndSettle();
    expect(find.text('Star'), findsOneWidget);
    expect(find.text('Add tag'), findsNothing);
  });

  testWidgets('a card takes a colour from its menu, none by default', (
    tester,
  ) async {
    final content = <String, dynamic>{
      'items': [
        {'id': 'c1', 'title': 'Card', 'description': ''},
      ],
    };
    await _open(
      tester,
      ItemEditorScreen(
        spaceId: 's1',
        type: 'card_list',
        existing: SpaceItem(
          id: 'i2',
          type: 'card_list',
          title: 'Ideas',
          content: content,
          pinned: false,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Card actions'));
    await tester.pumpAndSettle();
    expect(find.text('No color'), findsOneWidget);
    expect(find.text('Delete card'), findsOneWidget);

    await tester.tap(find.text('Blue'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Card actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No color'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
