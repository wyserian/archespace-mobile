import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/auth/data/auth_service.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';

/// Ask, then sign out; in local mode, leave it (see SignOutText). For the
/// screens before the vault opens: two-factor, unlock and vault setup.
Future<void> confirmSignOut(BuildContext context) async {
  final ok = await confirmAction(
    context,
    title: SignOutText.title,
    message: SignOutText.message,
    confirmLabel: SignOutText.label,
  );
  if (ok) await AuthService().signOut();
}
