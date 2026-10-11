import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/auth/domain/password_policy.dart';

void main() {
  test('accepts a password that meets every rule', () {
    expect(validatePassword('Abcdef1!'), isNull);
  });

  test('names only what is missing, in one sentence', () {
    expect(
      validatePassword('abcdefgh1!'),
      'Password needs an uppercase letter.',
    );
    expect(
      validatePassword('Abcdefgh'),
      'Password needs a number and a symbol.',
    );
    expect(
      validatePassword('ab'),
      'Password needs at least 8 characters, an uppercase letter, a number '
      'and a symbol.',
    );
  });

  test('counts any ASCII punctuation as a symbol', () {
    for (final symbol in ['!', '@', '#', '-', '_', '.', '~', '[', r'\']) {
      expect(validatePassword('Abcdefg1$symbol'), isNull);
    }
    expect(validatePassword('Abcdefg1 '), 'Password needs a symbol.');
  });
}
