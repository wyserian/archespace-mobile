import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/items/domain/reminder.dart';

// Tuesday 6 October 2026, 10:30 local time.
final now = DateTime(2026, 10, 6, 10, 30);

Reminder once(String date, [String time = '09:00']) =>
    Reminder(date: date, time: time);

Reminder repeat(String date, ReminderEvery every, String until) =>
    Reminder(date: date, mode: ReminderMode.repeat, every: every, until: until);

Reminder permanent(String date, ReminderEvery every, [String time = '09:00']) =>
    Reminder(
      date: date,
      time: time,
      mode: ReminderMode.permanent,
      every: every,
    );

void main() {
  group('fromJson', () {
    test('keeps a valid reminder, its name trimmed', () {
      expect(
        Reminder.fromJson({
          'name': ' Pay rent ',
          'date': '2026-10-07',
          'time': '14:00',
        }),
        const Reminder(name: 'Pay rent', date: '2026-10-07', time: '14:00'),
      );
    });

    test('drops anything malformed', () {
      expect(Reminder.fromJson(null), isNull);
      expect(Reminder.fromJson({'date': '7 Oct'}), isNull);
      expect(Reminder.fromJson({'date': '2026-02-31'}), isNull);
    });

    test('never ends a repeat before it starts', () {
      final r = Reminder.fromJson({
        'date': '2026-10-07',
        'mode': 'repeat',
        'every': 'day',
        'until': '2026-10-01',
      })!;
      expect(r.until, '2026-10-07');
    });

    test('round-trips through JSON', () {
      for (final r in [
        once('2026-10-07', '08:15'),
        repeat('2026-10-07', ReminderEvery.week, '2026-12-01'),
        permanent('2026-10-07', ReminderEvery.month),
      ]) {
        expect(Reminder.fromJson(r.toJson()), r);
      }
    });
  });

  test('a new one is 9:00 today, or the next full hour once that passed', () {
    expect(Reminder.initial(DateTime(2026, 10, 6, 7)), once('2026-10-06'));
    expect(Reminder.initial(now), once('2026-10-06', '11:00'));
    expect(Reminder.initial(DateTime(2026, 10, 6, 23, 10)), once('2026-10-07'));
  });

  group('occurrences', () {
    test('goes off once', () {
      expect(
        once('2026-10-07', '14:00').nextOccurrence(now),
        DateTime(2026, 10, 7, 14),
      );
      expect(once('2026-10-06').nextOccurrence(now), isNull);
      expect(once('2026-10-06').isPast(now), isTrue);
    });

    test('repeats daily until its end day', () {
      final r = repeat('2026-10-01', ReminderEvery.day, '2026-10-08');
      expect(r.nextOccurrence(now), DateTime(2026, 10, 7, 9));
      expect(r.nextOccurrence(DateTime(2026, 10, 8, 10)), isNull);
      expect(r.current(DateTime(2026, 10, 9)), DateTime(2026, 10, 8, 9));
      expect(r.occurrencesFrom(now, 10).length, 2);
    });

    test('repeats weekly, monthly and yearly', () {
      expect(
        permanent('2026-09-01', ReminderEvery.week).nextOccurrence(now),
        DateTime(2026, 10, 13, 9),
      );
      expect(
        permanent('2026-01-15', ReminderEvery.month).nextOccurrence(now),
        DateTime(2026, 10, 15, 9),
      );
      expect(
        permanent('2020-03-01', ReminderEvery.year).nextOccurrence(now),
        DateTime(2027, 3, 1, 9),
      );
    });

    test('goes off on the last day of a shorter month', () {
      final r = permanent('2026-01-31', ReminderEvery.month);
      expect(r.nextOccurrence(DateTime(2026, 2)), DateTime(2026, 2, 28, 9));
      expect(r.nextOccurrence(DateTime(2026, 3)), DateTime(2026, 3, 31, 9));
    });

    test('never ends when permanent', () {
      final r = permanent('2020-01-01', ReminderEvery.day);
      expect(r.isPast(now), isFalse);
      expect(r.nextOccurrence(now), DateTime(2026, 10, 7, 9));
    });
  });

  group('grouping', () {
    test('groups by the next time it goes off', () {
      expect(once('2026-10-05').group(now), ReminderGroup.past);
      expect(once('2026-10-06', '18:00').group(now), ReminderGroup.today);
      expect(
        permanent('2026-01-01', ReminderEvery.day).group(now),
        ReminderGroup.tomorrow,
      );
      expect(once('2026-10-13').group(now), ReminderGroup.week);
      expect(once('2026-10-14').group(now), ReminderGroup.later);
    });

    test('counts past and today as now', () {
      expect(once('2026-10-05').isNow(now), isTrue);
      expect(
        permanent('2026-01-01', ReminderEvery.day, '23:00').isNow(now),
        isTrue,
      );
      expect(once('2026-10-07').isNow(now), isFalse);
    });

    test('describes how it repeats', () {
      expect(once('2026-10-07').describeRepeat(now), 'Once');
      expect(
        repeat(
          '2026-10-07',
          ReminderEvery.day,
          '2026-11-12',
        ).describeRepeat(now),
        'Daily until 12 Nov',
      );
      expect(
        permanent('2026-10-07', ReminderEvery.week).describeRepeat(now),
        'Weekly, until turned off',
      );
    });
  });
}
