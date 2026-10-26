/// Login password strength rules, ported from the web `passwordPolicy.js`.
/// Shown as a checklist while typing and checked on submit; the server
/// enforces the same rules.
library;

const int passwordMinLength = 8;

// ASCII punctuation, the symbols Supabase Auth counts.
final RegExp _symbol = RegExp(r'[!-/:-@\[-`{-~]');

/// Each rule: its checklist [label], how a sentence names it when missing
/// ([need]), and whether [password] meets it ([ok]).
List<({String label, String need, bool ok})> passwordChecks(String password) =>
    [
      (
        label: '$passwordMinLength+ chars',
        need: 'at least $passwordMinLength characters',
        ok: password.length >= passwordMinLength,
      ),
      (
        label: 'Uppercase',
        need: 'an uppercase letter',
        ok: RegExp('[A-Z]').hasMatch(password),
      ),
      (
        label: 'Lowercase',
        need: 'a lowercase letter',
        ok: RegExp('[a-z]').hasMatch(password),
      ),
      (label: 'Number', need: 'a number', ok: RegExp(r'\d').hasMatch(password)),
      (label: 'Symbol', need: 'a symbol', ok: _symbol.hasMatch(password)),
    ];

/// One sentence naming everything the password still lacks ("Password needs
/// at least 8 characters, a number and a symbol."), or null when it's fine.
String? validatePassword(String password) {
  final missing = [
    for (final check in passwordChecks(password))
      if (!check.ok) check.need,
  ];
  if (missing.isEmpty) return null;
  final list = missing.length == 1
      ? missing.single
      : '${missing.sublist(0, missing.length - 1).join(', ')} and ${missing.last}';
  return 'Password needs $list.';
}
