import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/shared/widgets/tag_chip.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('tag chip: label and x each take taps above the chip', (
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

    // Just above each half's visible chip, inside its 36-tall tap area.
    final label = tester.getRect(find.text('work'));
    await tester.tapAt(Offset(label.center.dx, label.top - 6));
    final x = tester.getRect(find.byIcon(Icons.close));
    await tester.tapAt(Offset(x.center.dx, x.top - 6));

    expect(filtered, 1);
    expect(removed, 1);
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
