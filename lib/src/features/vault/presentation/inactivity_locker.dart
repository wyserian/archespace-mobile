import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:archespace_mobile/src/features/vault/application/auto_lock_controller.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';

/// Wraps the unlocked app and locks the vault after a period of inactivity,
/// using the duration from [AutoLockController]. The idle timer resets on
/// pointer interaction; time spent with the app backgrounded also counts.
/// It also locks at once when the device's screen locks (sent by the native
/// side on [screenLockChannel]) while "Lock when screen locks" is on.
class InactivityLocker extends StatefulWidget {
  const InactivityLocker({super.key, required this.child});

  final Widget child;

  /// MainActivity.kt (screen off) and AppDelegate.swift (device locked) send
  /// "locked" here.
  static const screenLockChannel = MethodChannel('archespace/screen_lock');

  @override
  State<InactivityLocker> createState() => _InactivityLockerState();
}

class _InactivityLockerState extends State<InactivityLocker>
    with WidgetsBindingObserver {
  Timer? _timer;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AutoLockController.instance.addListener(_reset);
    InactivityLocker.screenLockChannel.setMethodCallHandler((call) async {
      if (call.method == 'locked' &&
          AutoLockController.instance.lockOnScreenLock) {
        _lock();
      }
    });
    _reset();
  }

  @override
  void dispose() {
    InactivityLocker.screenLockChannel.setMethodCallHandler(null);
    _timer?.cancel();
    AutoLockController.instance.removeListener(_reset);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _reset() {
    _timer?.cancel();
    final d = AutoLockController.instance.duration;
    if (d == null) return; // "Never"
    _timer = Timer(d, _lock);
  }

  void _lock() {
    if (VaultSession.instance.unlocked.value) VaultSession.instance.lock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final d = AutoLockController.instance.duration;
      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (d != null &&
          pausedAt != null &&
          DateTime.now().difference(pausedAt) >= d) {
        _lock();
      } else {
        _reset();
      }
    } else {
      // Backgrounded: stop the timer and remember when, so time away counts
      // toward the idle duration on resume.
      _pausedAt = DateTime.now();
      _timer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _reset(),
      onPointerSignal: (_) => _reset(),
      child: widget.child,
    );
  }
}
