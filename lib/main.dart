import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:archespace_mobile/src/app.dart';
import 'package:archespace_mobile/src/features/settings/application/appearance_controller.dart';
import 'package:archespace_mobile/src/features/vault/application/auto_lock_controller.dart';
import 'package:archespace_mobile/src/shared/config/app_config.dart';
import 'package:archespace_mobile/src/shared/error/error_handling.dart';
import 'package:archespace_mobile/src/shared/offline/write_queue.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

Future<void> main() async {
  // Run everything inside a guarded zone so uncaught async errors are reported
  // instead of crashing silently. Binding init must share this zone with
  // runApp, so it lives inside the callback.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    installErrorHandling();

    if (!AppConfig.isConfigured) {
      runApp(const _ConfigErrorApp());
      return;
    }

    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      // Supabase renamed the anon key to "publishable key"; the value is the
      // same one the web app uses (SUPABASE_ANON_KEY).
      publishableKey: AppConfig.supabaseAnonKey,
      // Email links requested here (password reset, email change) open and
      // finish in the web app, not in this app. The default PKCE flow ties
      // them to a verifier stored on this device, so the web page can't
      // complete them. The implicit flow (the web app's own) puts the session
      // in the link, so any browser can finish them.
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.implicit,
      ),
    );
    await AppMode.load();
    await AppearanceController.instance.load();
    await AutoLockController.instance.load();
    await WriteQueue.instance.init();
    WriteQueue.instance.flush(); // replay any writes queued while offline

    runApp(const ArcheApp());
  }, reportZoneError);
}

/// Shown when SUPABASE_URL / SUPABASE_ANON_KEY were not provided at build time.
class _ConfigErrorApp extends StatelessWidget {
  const _ConfigErrorApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text(
              'Missing Supabase configuration.\n\n'
              'Run with:\n'
              'flutter run --dart-define-from-file=env.json\n\n'
              '(see env.example.json)',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
