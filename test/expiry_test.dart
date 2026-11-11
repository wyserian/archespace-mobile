import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/shared/data/expiry.dart';

void main() {
  final now = DateTime.utc(2026, 11, 10, 12);
  String at(Duration d) => now.add(d).toIso8601String();

  test('counts a passed time as expired, and none or a bad one as not', () {
    expect(
      isExpired({'expires_at': at(-const Duration(seconds: 1))}, now),
      isTrue,
    );
    expect(isExpired({'expires_at': at(Duration.zero)}, now), isTrue);
    expect(
      isExpired({'expires_at': at(const Duration(seconds: 1))}, now),
      isFalse,
    );
    expect(isExpired({'expires_at': null}, now), isFalse);
    expect(isExpired({'expires_at': 'soon'}, now), isFalse);
    expect(isExpired({}, now), isFalse);
  });

  test('says how long is left in short words', () {
    DateTime after(Duration d) => now.add(d);
    expect(formatExpiresIn(after(const Duration(seconds: 30)), now), 'now');
    expect(
      formatExpiresIn(after(const Duration(minutes: 45)), now),
      'in 45 min',
    );
    expect(formatExpiresIn(after(const Duration(hours: 5)), now), 'in 5 h');
    expect(formatExpiresIn(after(const Duration(days: 1)), now), 'in 1 day');
    expect(
      formatExpiresIn(after(const Duration(hours: 23, minutes: 59)), now),
      'in 1 day',
    );
    expect(formatExpiresIn(after(const Duration(days: 3)), now), 'in 3 days');
    expect(
      formatExpiresIn(after(const Duration(days: 60)), now),
      startsWith('on '),
    );
    expect(expiresSoon(after(const Duration(hours: 23)), now), isTrue);
    expect(expiresSoon(after(const Duration(days: 2)), now), isFalse);
  });
}
