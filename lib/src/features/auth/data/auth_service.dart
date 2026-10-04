import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/config/app_config.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// Thin wrapper over Supabase Auth. The client is resolved lazily so the app
/// only touches `Supabase.instance` after `Supabase.initialize` has run.
class AuthService {
  SupabaseClient get _client => Supabase.instance.client;

  Session? get currentSession => _client.auth.currentSession;
  User? get currentUser => _client.auth.currentUser;
  Stream<AuthState> get onAuthStateChange => _client.auth.onAuthStateChange;

  Future<void> signIn({required String email, required String password}) async {
    await _client.auth.signInWithPassword(email: email, password: password);
  }

  /// Register a new account. When email confirmation is disabled in Supabase,
  /// the response carries a live [Session] and the user is signed in
  /// immediately; otherwise they must confirm via email before signing in.
  ///
  /// [data] is written to the user's metadata; we pass the accepted Terms
  /// version so the server can record consent (see the user_consent trigger).
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) {
    return _client.auth.signUp(email: email, password: password, data: data);
  }

  /// Sign out of this device only (local scope); other devices stay signed
  /// in. Signing out everywhere is for password changes and
  /// [signOutAllDevices].
  Future<void> signOut() async {
    // Local mode has no session: "signing out" leaves the mode (the data
    // stays on the device).
    if (AppMode.isLocal) return AppMode.leave();
    await _client.auth.signOut(scope: SignOutScope.local);
  }

  /// Sign out of every device by revoking all of the user's sessions
  /// server-side (global scope). For an explicit "sign out of all devices".
  Future<void> signOutAllDevices() async {
    await _client.auth.signOut(scope: SignOutScope.global);
  }

  /// Send a password reset email. The link opens the web app's reset page,
  /// where the user sets a new password, then signs in again here.
  Future<void> requestPasswordReset(String email) async {
    await _client.auth.resetPasswordForEmail(
      email,
      redirectTo: '${AppConfig.webUrl}/reset-password',
    );
  }

  /// Send a 6-digit reauthentication code to the user's current email. Required
  /// before changing the account email so we can prove it's really them.
  Future<void> reauthenticate() async {
    await _client.auth.reauthenticate();
  }

  /// Change the account email. [nonce] is the reauthentication code sent to the
  /// current address; a confirmation link then goes to the new address and the
  /// change takes effect once the user opens it (on the web app's sign-in
  /// page, matching the web flow).
  Future<void> updateEmail(String email, String nonce) async {
    await _client.auth.updateUser(
      UserAttributes(email: email, nonce: nonce),
      emailRedirectTo: '${AppConfig.webUrl}/login?email_change=verified',
    );
  }

  /// Change the login password (separate from the vault PIN).
  Future<void> updatePassword(String password) async {
    await _client.auth.updateUser(UserAttributes(password: password));
  }

  /// Permanently delete the signed-in user's account via a database RPC, then
  /// end the local session.
  Future<void> deleteAccount() async {
    await _client.rpc('delete_current_user');
    await _client.auth.signOut(scope: SignOutScope.local);
  }
}
