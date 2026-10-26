import 'package:archespace_mobile/src/shared/widgets/create_fabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget fab) => MaterialApp(
  home: Scaffold(body: const SizedBox.expand(), floatingActionButton: fab),
);

void main() {
  testWidgets('opens the dial, runs the picked action and closes', (
    tester,
  ) async {
    var added = 0;
    var spaces = 0;
    await tester.pumpWidget(
      _host(CreateFabs(onAddItem: () => added++, onNewSpace: () => spaces++)),
    );
    expect(find.text('New space'), findsNothing);

    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();
    expect(find.text('New space'), findsOneWidget);
    expect(find.text('New item'), findsOneWidget);

    await tester.tap(find.text('New space'));
    await tester.pumpAndSettle();
    expect(spaces, 1);
    expect(added, 0);
    expect(find.text('New space'), findsNothing);
  });

  testWidgets('the close button and the scrim close it', (tester) async {
    await tester.pumpWidget(
      _host(CreateFabs(onAddItem: () {}, onNewSpace: () {})),
    );
    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('New item'), findsNothing);

    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('New item'), findsNothing);
  });

  testWidgets('with only New item, the button adds directly', (tester) async {
    var added = 0;
    await tester.pumpWidget(_host(CreateFabs(onAddItem: () => added++)));
    await tester.tap(find.byTooltip('New item'));
    await tester.pump();
    expect(added, 1);
  });
}
