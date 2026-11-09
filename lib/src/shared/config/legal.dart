/// Single source of truth for the current legal policy version, mirroring the
/// web app's `src/lib/legal.js`. [termsVersion] is sent in the sign-up
/// metadata and recorded server-side against the account's consent (see the
/// `user_consent` table + `log_auth_event` trigger in schema.sql). Bump it -
/// and [termsLastUpdated] - together whenever the Terms or Privacy Policy
/// changes materially. Keep [termsVersion] as a sortable YYYY-MM-DD string and
/// in sync with the web value.
class Legal {
  const Legal._();

  static const String termsVersion = '2026-11-09';
  static const String termsLastUpdated = '9 November 2026';

  static const String termsUrl = 'https://archespace.app/terms';
  static const String privacyUrl = 'https://archespace.app/privacy';
}
