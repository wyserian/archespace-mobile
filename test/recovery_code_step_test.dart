import 'package:archespace_mobile/src/features/vault/presentation/widgets/recovery_code_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('continuing waits until the saved box is ticked', (tester) async {
    var continued = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecoveryCodeStep(
              code: 'abcd-efgh-ijkl',
              onContinue: () => continued++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('I saved this code'));
    expect(continued, 0);

    await tester.tap(find.text("I've saved my recovery code somewhere safe."));
    await tester.pump();
    await tester.tap(find.text('I saved this code'));
    expect(continued, 1);
  });
}
