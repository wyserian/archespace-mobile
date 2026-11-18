import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/shared/error/error_handling.dart';

// Mirrors the web errorReport.test.js.
void main() {
  test('leaves out user content, secrets and where it ran', () {
    final out = redactErrorText(
      [
        'arc1:AbC123.xyz/+=',
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig_part',
        'me@example.com',
        '3f2b8c1e-9a4d-4c6e-8f1a-2b3c4d5e6f70',
        'Unexpected token "my secret note" and \'hunter2\'',
        'key A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7',
        'https://host.example/rest/v1/items?token=x',
        'file:///C:/Users/someone/app/lib/main.dart:10:5',
      ].join(' | '),
    );
    for (final leak in [
      'arc1:',
      'eyJ',
      'me@example.com',
      '3f2b8c1e',
      'secret note',
      'hunter2',
      'A1b2C3d4',
      'host.example',
      'token=x',
      'someone',
    ]) {
      expect(out, isNot(contains(leak)));
    }
    expect(out, contains('[encrypted]'));
    expect(out, contains('main.dart:10:5'));
  });

  test('reports the version and at most 12 redacted frames', () {
    final stack = StackTrace.fromString(
      List.generate(
        20,
        (i) => '#$i      f$i (package:archespace_mobile/src/a.dart:$i:1)',
      ).join('\n'),
    );
    final report = errorReport(
      FormatException('Bad "private words" me@example.com'),
      stack,
      now: DateTime.utc(2026, 11, 18, 10),
    );
    expect(report, contains('Time: 2026-11-18T10:00:00.000Z'));
    expect(report, contains('Error: FormatException: '));
    expect(report, isNot(contains('private words')));
    expect(report, isNot(contains('me@example.com')));
    expect(report.split('\n').where((l) => l.startsWith('#')), hasLength(12));
    expect(report, contains('package:archespace_mobile/src/a.dart:0:1'));
  });
}
