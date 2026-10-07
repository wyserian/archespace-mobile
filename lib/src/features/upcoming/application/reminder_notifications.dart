import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/reminder.dart';
import 'package:archespace_mobile/src/features/upcoming/presentation/upcoming_screen.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';

/// Item reminders as local notifications.
///
/// The reminders are encrypted, so no server can send them: after the vault
/// is unlocked (and whenever a reminder changes) this reads them and
/// schedules their coming times on the device itself. They go off even when
/// the app is closed or the vault locked, showing the reminder's name (or
/// generic text without one). Tapping one opens Upcoming.
class ReminderNotifications {
  ReminderNotifications._();

  static final ReminderNotifications instance = ReminderNotifications._();

  /// The app's navigator, for opening Upcoming from a notification.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static const _text = 'You have a reminder in ArcheSpace';
  static const _channel = AndroidNotificationDetails(
    'reminders',
    'Reminders',
    channelDescription: 'Item reminders',
    importance: Importance.high,
    priority: Priority.high,
  );

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _init;
  bool _openPending = false;

  /// How many reminders are for today or past (the drawer badge).
  final ValueNotifier<int> nowCount = ValueNotifier<int>(0);
  Map<String, Reminder> _reminders = const {};

  /// Recount [nowCount] from the last reminders read.
  void _refreshBadge() =>
      nowCount.value = _reminders.values.where((r) => r.isNow()).length;

  Future<void> _ensureInit() => _init ??= _initialize();

  Future<void> _initialize() async {
    tzdata.initializeTimeZones();
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
    } catch (_) {
      // Unknown zone: tz.local stays UTC, and times are converted from the
      // device's own clock below, so reminders still go off on time.
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (_) => _requestOpen(),
    );
    // Opened by tapping a reminder while the app was closed.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) _requestOpen();
  }

  /// Ask (from a user action) to show notifications, on Android 13 and later.
  Future<bool> requestPermission() async {
    await _ensureInit();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.requestNotificationsPermission() ?? true;
  }

  /// Read every reminder and schedule the ones still to come. Called after
  /// unlock and whenever a reminder changes; offline it keeps what's already
  /// scheduled.
  Future<void> sync() async {
    if (!VaultSession.instance.unlocked.value) return;
    final Map<String, Reminder> reminders;
    try {
      reminders = await ItemRepository(
        VaultSession.instance.masterKey,
      ).listReminders().timeout(const Duration(seconds: 8));
    } catch (_) {
      return;
    }
    _reminders = reminders;
    _refreshBadge();
    try {
      await _ensureInit();
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final exact = await android?.canScheduleExactNotifications() ?? false;
      // Pending ones only: a reminder already showing stays.
      await _plugin.cancelAllPendingNotifications();
      final now = DateTime.now();
      final plans = [
        for (final entry in reminders.entries)
          ..._plan(entry.key, entry.value, now),
      ]..sort((a, b) => a.at.compareTo(b.at));
      // Android allows an app only so many alarms: the soonest go first, and
      // the rest are set on a later sync.
      for (final plan in plans.take(_maxScheduled)) {
        await _plugin.zonedSchedule(
          id: plan.id,
          scheduledDate: tz.TZDateTime.from(plan.at, tz.local),
          notificationDetails: const NotificationDetails(android: _channel),
          androidScheduleMode: exact
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexactAllowWhileIdle,
          title: 'ArcheSpace',
          body: plan.reminder.name.isEmpty ? _text : plan.reminder.name,
          matchDateTimeComponents: plan.repeat,
        );
      }
    } catch (_) {
      // Notifications unavailable on this device; Upcoming still shows them.
    }
    _openIfReady();
  }

  /// Cancel every reminder (signing out, or switching between local mode
  /// and an account); the next unlock schedules the right ones again.
  Future<void> clear() async {
    _reminders = const {};
    nowCount.value = 0;
    try {
      await _ensureInit();
      await _plugin.cancelAll();
    } catch (_) {}
  }

  void _requestOpen() {
    _openPending = true;
    _openIfReady();
  }

  /// Open Upcoming for a tapped reminder, once the vault is unlocked.
  void _openIfReady() {
    final navigator = navigatorKey.currentState;
    if (!_openPending ||
        navigator == null ||
        !VaultSession.instance.unlocked.value) {
      return;
    }
    _openPending = false;
    navigator.popUntil((route) => route.isFirst);
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const UpcomingScreen()),
    );
  }

  /// The notifications to set for one reminder. A permanent one that Android
  /// can repeat by itself is one notification repeating forever; otherwise
  /// each time is its own notification, up to [_perReminder] of them (later
  /// ones are set on a later sync, after unlock).
  static List<_Plan> _plan(String itemId, Reminder reminder, DateTime now) {
    final repeat = _androidRepeat(reminder);
    if (repeat != null) {
      final next = reminder.nextOccurrence(now);
      return [
        if (next != null)
          (id: _idFor(itemId), at: next, reminder: reminder, repeat: repeat),
      ];
    }
    var n = 0;
    return [
      for (final at in reminder.occurrencesFrom(now, _perReminder))
        (
          id: _idFor('$itemId#${n++}'),
          at: at,
          reminder: reminder,
          repeat: null,
        ),
    ];
  }

  /// How Android repeats a permanent reminder, or null when it can't do it
  /// exactly (a monthly one after the 28th, or a yearly one on 29 February,
  /// goes off on short months' last day, which Android doesn't).
  static DateTimeComponents? _androidRepeat(Reminder reminder) {
    if (reminder.mode != ReminderMode.permanent) return null;
    final day = int.parse(reminder.date.substring(8));
    final month = int.parse(reminder.date.substring(5, 7));
    return switch (reminder.every) {
      ReminderEvery.day => DateTimeComponents.time,
      ReminderEvery.week => DateTimeComponents.dayOfWeekAndTime,
      ReminderEvery.month =>
        day <= 28 ? DateTimeComponents.dayOfMonthAndTime : null,
      ReminderEvery.year =>
        month == 2 && day == 29 ? null : DateTimeComponents.dateAndTime,
    };
  }

  static const _perReminder = 30;
  static const _maxScheduled = 400;

  /// A stable notification id (FNV-1a over a string).
  static int _idFor(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }
}

/// One notification to set: when, for which reminder, and how Android
/// repeats it (null for a single one).
typedef _Plan = ({
  int id,
  DateTime at,
  Reminder reminder,
  DateTimeComponents? repeat,
});
