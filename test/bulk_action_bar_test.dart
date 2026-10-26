import 'package:archespace_mobile/src/shared/widgets/bulk_action_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _bar(int count, {required VoidCallback onArchive}) => MaterialApp(
  home: Scaffold(
    bottomNavigationBar: BulkActionBar(
      count: count,
      actions: [
        BulkAction(icon: Icons.push_pin, label: 'Pin', onPressed: () {}),
        BulkAction(
          icon: Icons.push_pin_outlined,
          label: 'Unpin',
          onPressed: () {},
          struck: true,
        ),
        BulkAction(
          icon: Icons.drive_file_move_outlined,
          label: 'Move',
          onPressed: () {},
        ),
        BulkAction(
          icon: Icons.archive_outlined,
          label: 'Archive',
          onPressed: onArchive,
        ),
        BulkAction(
          icon: Icons.delete_outline,
          label: 'Delete',
          onPressed: () {},
          destructive: true,
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets('all five actions fit a phone, Delete in red', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var archived = 0;
    await tester.pumpWidget(_bar(2, onArchive: () => archived++));

    // Delete must be on screen, not scrolled out of reach.
    final delete = tester.getRect(find.byTooltip('Delete'));
    expect(delete.right, lessThanOrEqualTo(360));
    expect(delete.left, greaterThanOrEqualTo(0));

    await tester.tap(find.byTooltip('Archive'));
    expect(archived, 1);

    final context = tester.element(find.byType(BulkActionBar));
    final deleteButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.delete_outline),
        matching: find.byType(IconButton),
      ),
    );
    expect(deleteButton.color, Theme.of(context).colorScheme.error);
  });

  testWidgets('nothing selected leaves the actions disabled', (tester) async {
    var archived = 0;
    await tester.pumpWidget(_bar(0, onArchive: () => archived++));
    await tester.tap(find.byTooltip('Archive'));
    expect(archived, 0);
  });
}
