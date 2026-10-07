import 'package:flutter/material.dart';

/// How often a reminder goes off: once, repeating until a day, or repeating
/// until turned off.
enum ReminderMode {
  once('Once'),
  repeat('Repeat'),
  permanent('Permanent');

  const ReminderMode(this.label);

  final String label;
}

/// How far apart a repeating reminder's times are.
enum ReminderEvery {
  day('Daily'),
  week('Weekly'),
  month('Monthly'),
  year('Yearly');

  const ReminderEvery(this.label);

  final String label;
}

/// An item's reminder, the same as the web app's (lib/reminder.js).
///
/// Stored encrypted with the item (like its tags), so the server never learns
/// what or when it is:
///   { name, date: 'YYYY-MM-DD', time: 'HH:MM', mode, every, until }
/// The date and time are the first time it goes off, in local (wall-clock)
/// time. A repeat goes off [every] day / week / month / year until [until]; a
/// permanent one until it's removed. A monthly or yearly reminder on a day a
/// month lacks (the 31st, 29 February) goes off on that month's last day.
class Reminder {
  const Reminder({
    this.name = '',
    required this.date,
    this.time = _defaultTime,
    this.mode = ReminderMode.once,
    this.every = ReminderEvery.day,
    this.until,
  });

  /// Shown in the notification; may be empty.
  final String name;

  /// 'YYYY-MM-DD': the first day it goes off.
  final String date;

  /// 'HH:MM'.
  final String time;
  final ReminderMode mode;

  /// For a repeating reminder.
  final ReminderEvery every;

  /// 'YYYY-MM-DD': the last day a repeat goes off.
  final String? until;

  /// A new reminder's time, unless that's already past today.
  static const _defaultTime = '09:00';
  static const maxName = 100;

  static final _dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _timeRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

  static bool _isDay(Object? value) =>
      value is String &&
      _dateRe.hasMatch(value) &&
      dayString(_local(value)) == value;

  /// A valid reminder, or null (anything malformed counts as none).
  static Reminder? fromJson(Object? value) {
    if (value is! Map || !_isDay(value['date'])) return null;
    final date = value['date'] as String;
    final rawName = value['name'];
    final name = rawName is String ? rawName.trim() : '';
    final time = value['time'];
    final mode = ReminderMode.values.firstWhere(
      (m) => m.name == value['mode'],
      orElse: () => ReminderMode.once,
    );
    final every = ReminderEvery.values.firstWhere(
      (e) => e.name == value['every'],
      orElse: () => ReminderEvery.day,
    );
    final until = value['until'];
    return Reminder(
      name: name.length > maxName ? name.substring(0, maxName) : name,
      date: date,
      time: time is String && _timeRe.hasMatch(time) ? time : _defaultTime,
      mode: mode,
      every: every,
      // A repeat ends on its until day (never before it starts).
      until: mode != ReminderMode.repeat
          ? null
          : _isDay(until) && (until as String).compareTo(date) >= 0
          ? until
          : date,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'date': date,
    'time': time,
    'mode': mode.name,
    'every': mode == ReminderMode.once ? null : every.name,
    'until': mode == ReminderMode.repeat ? until : null,
  };

  /// A new reminder: once, today at 9:00, or at the next full hour once
  /// that's past (tomorrow at 9:00 late in the evening).
  static Reminder initial([DateTime? now]) {
    now ??= DateTime.now();
    final today = dayString(now);
    if (_local(today, _defaultTime).isAfter(now)) return Reminder(date: today);
    if (now.hour < 23) {
      return Reminder(
        date: today,
        time: '${(now.hour + 1).toString().padLeft(2, '0')}:00',
      );
    }
    return Reminder(date: addDays(today, 1));
  }

  bool get repeats => mode != ReminderMode.once;

  /// The [index]th time it goes off (0 = the first), ignoring its end.
  DateTime _occurrence(int index) {
    final d = date.split('-').map(int.parse).toList();
    final t = time.split(':').map(int.parse).toList();
    DateTime clamped(int year, int month) {
      final last = DateTime(year, month + 1, 0).day;
      return DateTime(year, month, d[2] < last ? d[2] : last, t[0], t[1]);
    }

    if (!repeats) return DateTime(d[0], d[1], d[2], t[0], t[1]);
    return switch (every) {
      ReminderEvery.day => DateTime(d[0], d[1], d[2] + index, t[0], t[1]),
      ReminderEvery.week => DateTime(d[0], d[1], d[2] + 7 * index, t[0], t[1]),
      ReminderEvery.month => clamped(d[0], d[1] + index),
      ReminderEvery.year => clamped(d[0] + index, d[1]),
    };
  }

  /// The index of the first time at or after [from], ignoring its end.
  int _indexAtOrAfter(DateTime from) {
    final start = _occurrence(0);
    if (!start.isBefore(from)) return 0;
    if (!repeats) return 1;
    // Start just before [from], then step to it.
    final months = (from.year - start.year) * 12 + from.month - start.month;
    final days = from.difference(start).inDays;
    var index = switch (every) {
      ReminderEvery.day => days - 1,
      ReminderEvery.week => days ~/ 7 - 1,
      ReminderEvery.month => months - 1,
      ReminderEvery.year => months ~/ 12 - 1,
    };
    if (index < 0) index = 0;
    while (_occurrence(index).isBefore(from)) {
      index++;
    }
    return index;
  }

  bool _withinEnd(int index) => switch (mode) {
    ReminderMode.once => index == 0,
    ReminderMode.repeat => dayString(_occurrence(index)).compareTo(until!) <= 0,
    ReminderMode.permanent => true,
  };

  /// The next time it goes off at or after [from], or null when it's over.
  DateTime? nextOccurrence([DateTime? from]) {
    final index = _indexAtOrAfter(from ?? DateTime.now());
    return _withinEnd(index) ? _occurrence(index) : null;
  }

  /// The times it goes off from [from], up to [limit] of them.
  Iterable<DateTime> occurrencesFrom(DateTime from, int limit) sync* {
    var index = _indexAtOrAfter(from);
    for (var n = 0; n < limit && _withinEnd(index); n++, index++) {
      yield _occurrence(index);
    }
  }

  /// The last time it went off (for a finished reminder).
  DateTime _lastOccurrence() {
    if (mode != ReminderMode.repeat) return _occurrence(0);
    final index = _indexAtOrAfter(_local(addDays(until!, 1)));
    return _occurrence(index > 0 ? index - 1 : 0);
  }

  /// The time to show: the next one, or the last once it's over.
  DateTime current([DateTime? now]) => nextOccurrence(now) ?? _lastOccurrence();

  /// Over: it has gone off for the last time.
  bool isPast([DateTime? now]) => nextOccurrence(now) == null;

  /// Over, or going off today (the badge).
  bool isNow([DateTime? now]) {
    now ??= DateTime.now();
    return dayString(current(now)).compareTo(dayString(now)) <= 0;
  }

  /// Earliest (next) first.
  int compareTo(Reminder other, [DateTime? now]) {
    now ??= DateTime.now();
    return current(now).compareTo(other.current(now));
  }

  /// Which Upcoming group it falls in (by its next time).
  ReminderGroup group([DateTime? now]) {
    now ??= DateTime.now();
    final next = nextOccurrence(now);
    if (next == null) return ReminderGroup.past;
    final today = dayString(now);
    final day = dayString(next);
    if (day == today) return ReminderGroup.today;
    if (day == addDays(today, 1)) return ReminderGroup.tomorrow;
    if (day.compareTo(addDays(today, 7)) <= 0) return ReminderGroup.week;
    return ReminderGroup.later;
  }

  /// When it goes off next (or last went off): "Today 9:00".
  String label(BuildContext context, [DateTime? now]) {
    now ??= DateTime.now();
    return '${formatDay(dayString(current(now)), now)} '
        '${formatTime(context, time)}';
  }

  /// How it repeats: "Once", "Daily until 12 Nov", "Weekly, until turned
  /// off".
  String describeRepeat([DateTime? now]) => switch (mode) {
    ReminderMode.once => 'Once',
    ReminderMode.repeat => '${every.label} until ${formatDate(until!, now)}',
    ReminderMode.permanent => '${every.label}, until turned off',
  };

  @override
  bool operator ==(Object other) =>
      other is Reminder &&
      other.name == name &&
      other.date == date &&
      other.time == time &&
      other.mode == mode &&
      (!repeats || other.every == every) &&
      other.until == until;

  @override
  int get hashCode =>
      Object.hash(name, date, time, mode, repeats ? every : null, until);

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// A local DateTime for a 'YYYY-MM-DD' day, at 'HH:MM'.
  static DateTime _local(String day, [String time = '00:00']) {
    final d = day.split('-').map(int.parse).toList();
    final t = time.split(':').map(int.parse).toList();
    return DateTime(d[0], d[1], d[2], t[0], t[1]);
  }

  /// A DateTime's local calendar day as 'YYYY-MM-DD'.
  static String dayString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// The day [days] after a 'YYYY-MM-DD' day.
  static String addDays(String day, int days) {
    final d = _local(day);
    return dayString(DateTime(d.year, d.month, d.day + days));
  }

  /// A day as "12 Oct", or "12 Oct 2027" when it isn't this year.
  static String formatDate(String day, [DateTime? now]) {
    final d = _local(day);
    final text = '${d.day} ${_months[d.month - 1]}';
    return d.year == (now ?? DateTime.now()).year ? text : '$text ${d.year}';
  }

  /// A day as "Today", "Tomorrow", "Yesterday", "Fri", or as [formatDate].
  static String formatDay(String day, [DateTime? now]) {
    now ??= DateTime.now();
    final today = dayString(now);
    if (day == today) return 'Today';
    if (day == addDays(today, 1)) return 'Tomorrow';
    if (day == addDays(today, -1)) return 'Yesterday';
    if (day.compareTo(today) > 0 && day.compareTo(addDays(today, 6)) <= 0) {
      return _weekdays[_local(day).weekday - 1];
    }
    return formatDate(day, now);
  }

  /// A time as the device shows times ("14:30" or "2:30 PM").
  static String formatTime(BuildContext context, String time) {
    final t = time.split(':').map(int.parse).toList();
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay(hour: t[0], minute: t[1]),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }
}

/// Upcoming's groups, in order.
enum ReminderGroup {
  past('Past'),
  today('Today'),
  tomorrow('Tomorrow'),
  week('Next 7 days'),
  later('Later');

  const ReminderGroup(this.label);

  final String label;
}
