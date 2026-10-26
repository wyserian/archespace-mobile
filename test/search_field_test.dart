import 'package:archespace_mobile/src/shared/widgets/search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('x shows once typed, clears and reports the empty query', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final queries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchField(
            hint: 'Search',
            controller: controller,
            onChanged: queries.add,
          ),
        ),
      ),
    );
    expect(find.byTooltip('Clear search'), findsNothing);

    await tester.enterText(find.byType(TextField), 'milk');
    await tester.pump();
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(queries.last, '');
    expect(find.byTooltip('Clear search'), findsNothing);
  });
}
