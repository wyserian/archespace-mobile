import 'package:archespace_mobile/src/shared/widgets/view_toggle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('view toggle shows both sides and picks the tapped one', (
    tester,
  ) async {
    final picked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ViewToggle(value: 'grid', onChanged: picked.add),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.grid_view_outlined), findsOneWidget);
    expect(find.byIcon(Icons.view_list_outlined), findsOneWidget);
    expect(tester.getSize(find.byType(ViewToggle)).height, 48);

    await tester.tap(find.byIcon(Icons.view_list_outlined));
    // Above the visible track still counts as a tap on that side.
    final list = tester.getCenter(find.byIcon(Icons.view_list_outlined));
    await tester.tapAt(list - const Offset(0, 20));
    expect(picked, ['list', 'list']);
  });
}
