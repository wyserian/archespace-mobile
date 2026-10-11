/// Login password strength rules, ported from the web `passwordPolicy.js`.
/// Checked on submit; the server enforces the same rules.
library;

const int passwordMinLength = 8;

// ASCII punctuation, the symbols Supabase Auth counts.
final RegExp _symbol = RegExp(r'[!-/:-@\[-`{-~]');

/// One sentence naming everything the password still lacks ("Password needs
/// at least 8 characters, a number and a symbol."), or null when it's fine.
String? validatePassword(String password) {
  final missing = [
    if (password.length < passwordMinLength)
      'at least $passwordMinLength characters',
    if (!RegExp('[A-Z]').hasMatch(password)) 'an uppercase letter',
    if (!RegExp('[a-z]').hasMatch(password)) 'a lowercase letter',
    if (!RegExp(r'\d').hasMatch(password)) 'a number',
    if (!_symbol.hasMatch(password)) 'a symbol',
  ];
  if (missing.isEmpty) return null;
  final list = missing.length == 1
      ? missing.single
      : '${missing.sublist(0, missing.length - 1).join(', ')} and ${missing.last}';
  return 'Password needs $list.';
}
