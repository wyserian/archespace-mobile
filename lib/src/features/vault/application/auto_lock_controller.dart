import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A selectable vault auto-lock duration. `duration == null` means "Never".
class AutoLockOption {
  const AutoLockOption({
    required this.id,
    required this.label,
    required this.duration,
  });

  final String id;
  final String label;
  final Duration? duration;
}

const List<AutoLockOption> kAutoLockOptions = [
  AutoLockOption(id: '5m', label: '5 minutes', duration: Duration(minutes: 5)),
  AutoLockOption(
    id: '15m',
    label: '15 minutes',
    duration: Duration(minutes: 15),
  ),
  AutoLockOption(id: '1h', label: '1 hour', duration: Duration(hours: 1)),
  AutoLockOption(id: '8h', label: '8 hours', duration: Duration(hours: 8)),
  AutoLockOption(id: '24h', label: '24 hours', duration: Duration(hours: 24)),
  AutoLockOption(id: 'never', label: 'Never', duration: null),
];

const String kDefaultAutoLockId = '5m';

/// Holds the vault auto-lock duration, persisted per-device with
/// shared_preferences (a security preference, not synced to the account).
/// Auto-lock is inactivity-based; [InactivityLocker] applies it.
class AutoLockController extends ChangeNotifier {
  AutoLockController._();
  static final AutoLockController instance = AutoLockController._();

  static const String _key = 'vault_auto_lock';

  String _id = kDefaultAutoLockId;
  String get id => _id;

  Duration? get duration => kAutoLockOptions
      .firstWhere(
        (o) => o.id == _id,
        orElse: () =>
            kAutoLockOptions.firstWhere((o) => o.id == kDefaultAutoLockId),
      )
      .duration;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null && kAutoLockOptions.any((o) => o.id == saved)) {
      _id = saved;
      notifyListeners();
    }
  }

  Future<void> setId(String id) async {
    if (!kAutoLockOptions.any((o) => o.id == id) || id == _id) return;
    _id = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, id);
  }
}
