/// Self-destruct, as on the web (`src/lib/expiry.js`): a space or item with an
/// `expires_at` time is deleted for good when it passes (schema.sql section
/// 3b). The time is plain, not encrypted, so the server enforces it on every
/// device.
library;

/// Quick choices in the dialog, from now.
const List<(String, Duration)> kExpiryPresets = [
  ('1 hour', Duration(hours: 1)),
  ('1 day', Duration(days: 1)),
  ('1 week', Duration(days: 7)),
  ('30 days', Duration(days: 30)),
];

/// A row's self-destruct time, or null for none (or an unreadable one).
DateTime? expiresAtOf(Map<String, dynamic> row) =>
    DateTime.tryParse((row['expires_at'] ?? '').toString());

/// Whether [row] has expired.
bool isExpired(Map<String, dynamic> row, [DateTime? now]) {
  final at = expiresAtOf(row);
  return at != null && !at.isAfter(now ?? DateTime.now());
}

/// [rows] without the expired ones.
List<Map<String, dynamic>> withoutExpired(
  Iterable<Map<String, dynamic>> rows, [
  DateTime? now,
]) => [
  for (final row in rows)
    if (!isExpired(row, now)) row,
];

/// How long until [at], in short words: "in 45 min", "in 5 h", "in 3 days",
/// or the day ("on 12 Dec 2026") beyond a month; "now" once it's due.
String formatExpiresIn(DateTime at, [DateTime? now]) {
  final left = at.difference(now ?? DateTime.now());
  if (left <= const Duration(minutes: 1)) return 'now';
  if (left < const Duration(hours: 1)) {
    return 'in ${(left.inSeconds / 60).ceil()} min';
  }
  // Rounded first, so a fresh "1 day" (a moment under 24 h) reads as a day.
  final hours = (left.inMinutes / 60).round();
  if (hours < 24) return 'in $hours h';
  if (left < const Duration(days: 31)) {
    final days = (left.inHours / 24).round();
    return 'in $days ${days == 1 ? 'day' : 'days'}';
  }
  final local = at.toLocal();
  return 'on ${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// Less than a day left: shown in red.
bool expiresSoon(DateTime at, [DateTime? now]) =>
    at.difference(now ?? DateTime.now()) < const Duration(days: 1);

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
