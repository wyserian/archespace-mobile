import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Local mode: ArcheSpace without an account. Everything is kept on this
/// device (see LocalDb) and nothing is sent to a server; the data is still
/// encrypted with the vault PIN.
class AppMode {
  AppMode._();

  static const _key = 'local_mode';

  /// The stand-in user every local row belongs to.
  static const localUserId = '00000000-0000-4000-8000-000000000000';

  /// Whether the app runs in local mode; the root gate rebuilds on change.
  static final ValueNotifier<bool> local = ValueNotifier<bool>(false);

  static bool get isLocal => local.value;

  /// Read the saved mode (before the first frame).
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    local.value = prefs.getBool(_key) ?? false;
  }

  /// Switch to local mode.
  static Future<void> enter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
    local.value = true;
  }

  /// Leave local mode; the data stays for next time.
  static Future<void> leave() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    local.value = false;
  }
}

/// How "sign out" reads: in local mode it leaves the mode, and the data stays.
class SignOutText {
  SignOutText._();

  static String get label => AppMode.isLocal ? 'Leave local mode' : 'Sign out';

  static String get title =>
      AppMode.isLocal ? 'Leave local mode?' : 'Sign out?';

  static String get message => AppMode.isLocal
      ? 'Your data stays on this device. Choose "Use without an account" on '
            'the sign-in screen to come back to it.'
      : 'You will need your login password and vault PIN to sign back in.';
}

/// The id of whoever owns the data: the signed-in user, or the local user.
String? currentUserId() => AppMode.isLocal
    ? AppMode.localUserId
    : Supabase.instance.client.auth.currentUser?.id;
