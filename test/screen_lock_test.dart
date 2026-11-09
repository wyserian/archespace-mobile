import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:archespace_mobile/src/features/vault/application/auto_lock_controller.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/presentation/inactivity_locker.dart';

/// What MainActivity.kt / AppDelegate.swift send when the device locks.
Future<void> _deviceLocks(WidgetTester tester) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      InactivityLocker.screenLockChannel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('locked')),
      (_) {},
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the device screen locking locks the vault, unless turned off', (
    tester,
  ) async {
    VaultSession.instance.unlock(Uint8List(32));
    await tester.pumpWidget(
      const MaterialApp(home: InactivityLocker(child: SizedBox())),
    );

    await AutoLockController.instance.setLockOnScreenLock(false);
    await _deviceLocks(tester);
    expect(VaultSession.instance.unlocked.value, isTrue);

    await AutoLockController.instance.setLockOnScreenLock(true);
    await _deviceLocks(tester);
    expect(VaultSession.instance.unlocked.value, isFalse);

    await tester.pumpWidget(const SizedBox());
  });
}
