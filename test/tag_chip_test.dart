import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/items/domain/reminder.dart';
import 'package:archespace_mobile/src/features/reminders/presentation/reminder_widgets.dart';
import 'package:archespace_mobile/src/shared/widgets/tag_chip.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('tag chip: tap filters, long press offers Remove, above too', (
    tester,
  ) async {
    var filtered = 0;
    var removed = 0;
    await tester.pumpWidget(
      _host(
        TagChip(
          label: 'work',
          color: Colors.teal,
          fill: Colors.teal.shade50,
          onTap: () => filtered++,
          onRemove: () => removed++,
        ),
      ),
    );

    expect(find.byIcon(Icons.close), findsNothing);

    // Just above the visible chip, inside its 36-tall tap area.
    final label = tester.getRect(find.text('work'));
    final above = Offset(label.center.dx, label.top - 6);
    await tester.tapAt(above);
    expect(filtered, 1);
    expect(removed, 0);

    await tester.longPressAt(above);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove tag'));
    await tester.pumpAndSettle();
    expect(filtered, 1);
    expect(removed, 1);
  });

  testWidgets('tag and reminder chips share one height', (tester) async {
    await tester.pumpWidget(
      _host(
        Wrap(
          children: [
            ReminderChip(reminder: Reminder.initial(), onTap: () {}),
            TagChip(
              label: 'work',
              color: Colors.teal,
              fill: Colors.teal.shade50,
              onTap: () {},
              onRemove: () {},
            ),
          ],
        ),
      ),
    );
    double faceHeight(Finder inner) => tester
        .getSize(
          find.ancestor(of: inner, matching: find.byType(Container)).first,
        )
        .height;

    expect(faceHeight(find.text('work')), kChipHeight);
    expect(
      faceHeight(find.byIcon(Icons.notifications_none_rounded)),
      kChipHeight,
    );
  });

  testWidgets('tag input commits comma-separated tags once', (tester) async {
    final commits = <List<String>>[];
    await tester.pumpWidget(_host(TagInput(onCommit: commits.add)));

    await tester.enterText(find.byType(TextField), 'ideas, , work ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    // A tap away after Done doesn't commit again.
    await tester.tapAt(Offset.zero);
    await tester.pump();

    expect(commits, [
      ['ideas', 'work'],
    ]);
  });
}
