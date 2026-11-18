import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// Best-effort audit entry for [action], one of those the server's
/// log_client_event allows (as the web's auditLog.js). Who and when are added
/// by the server; only the action and this app's platform are sent. Local mode
/// has no server, so nothing is logged. Never throws: auditing must not block
/// what the user is doing.
Future<void> logAudit(String action) async {
  if (AppMode.isLocal) return;
  try {
    await Supabase.instance.client
        .rpc(
          'log_client_event',
          params: {
            'p_action': action,
            'p_client': Platform.isIOS ? 'ios' : 'android',
          },
        )
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    if (kDebugMode) debugPrint('[audit] $action not logged: $e');
  }
}
