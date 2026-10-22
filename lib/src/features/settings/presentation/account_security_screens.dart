import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:archespace_mobile/src/features/auth/data/auth_service.dart';
import 'package:archespace_mobile/src/features/auth/data/mfa_service.dart';
import 'package:archespace_mobile/src/features/auth/domain/email.dart';
import 'package:archespace_mobile/src/features/auth/domain/password_policy.dart';
import 'package:archespace_mobile/src/features/auth/domain/totp_code.dart';
import 'package:archespace_mobile/src/features/vault/data/vault_service.dart';
import 'package:archespace_mobile/src/features/vault/domain/vault_pin.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';

/// Returns the signed-in user id, or throws if the session vanished.
String _requireUserId(AuthService auth) {
  final id = auth.currentUser?.id;
  if (id == null) throw StateError('Not signed in');
  return id;
}

String _authMessage(Object error) {
  if (error is AuthException) return error.message;
  if (error is VaultException) return error.message;
  return 'Something went wrong. Check your connection and try again.';
}

// Change email (two steps: password check + code sent to the current address).

class ChangeEmailScreen extends StatefulWidget {
  const ChangeEmailScreen({super.key});

  @override
  State<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<ChangeEmailScreen> {
  final AuthService _auth = AuthService();
  final TextEditingController _newEmail = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _obscure = true;
  bool _loading = false;
  bool _codeStep = false;

  @override
  void dispose() {
    _newEmail.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final nextEmail = _newEmail.text.trim().toLowerCase();
    final current = _auth.currentUser?.email?.toLowerCase();
    final emailError = validateEmail(nextEmail);
    if (emailError != null) {
      showErrorVia(messenger, scheme, emailError);
      return;
    }
    if (nextEmail == current) {
      showErrorVia(
        messenger,
        scheme,
        'New email must be different from your current one.',
      );
      return;
    }
    if (_password.text.isEmpty) {
      showErrorVia(messenger, scheme, 'Enter your login password to continue.');
      return;
    }

    setState(() => _loading = true);
    try {
      // Verify the password, then send a reauthentication code to the old email.
      await _auth.signIn(email: current!, password: _password.text);
      await _auth.reauthenticate();
      if (!mounted) return;
      setState(() => _codeStep = true);
      showInfoVia(
        messenger,
        scheme,
        'We sent a 6-digit code to your current email.',
      );
    } on AuthException catch (e) {
      final invalid = e.message.toLowerCase().contains('invalid');
      showErrorVia(
        messenger,
        scheme,
        invalid ? 'Login password is incorrect.' : e.message,
      );
    } catch (e) {
      showErrorVia(messenger, scheme, _authMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmChange() async {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    final nextEmail = _newEmail.text.trim().toLowerCase();
    if (_code.text.trim().isEmpty) {
      showErrorVia(messenger, scheme, 'Enter the 6-digit code.');
      return;
    }

    setState(() => _loading = true);
    try {
      await _auth.updateEmail(nextEmail, _code.text.trim());
      await _auth.signOut();
      showSuccessVia(
        messenger,
        scheme,
        'Confirmation link sent to your new email. Open it, then sign in again.',
      );
      navigator.popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      showErrorVia(messenger, scheme, _authMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentEmail = _auth.currentUser?.email ?? 'Unknown';
    return Scaffold(
      appBar: AppBar(title: const Text('Change email')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Current email: $currentEmail',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              "We'll email a 6-digit code to your current address to confirm "
              "it's you. After you enter it, a confirmation link is sent to your "
              'new address, and the change takes effect once you open it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            if (!_codeStep) ...[
              TextField(
                controller: _newEmail,
                keyboardType: TextInputType.emailAddress,
                enabled: !_loading,
                decoration: const InputDecoration(labelText: 'New email'),
              ),
              const SizedBox(height: 12),
              _ObscureField(
                controller: _password,
                label: 'Login password',
                obscure: _obscure,
                enabled: !_loading,
                onToggle: () => setState(() => _obscure = !_obscure),
              ),
              const SizedBox(height: 20),
              _SubmitButton(
                label: 'Send code',
                loading: _loading,
                onPressed: _sendCode,
              ),
            ] else ...[
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                enabled: !_loading,
                decoration: const InputDecoration(labelText: '6-digit code'),
              ),
              const SizedBox(height: 20),
              _SubmitButton(
                label: 'Confirm email change',
                loading: _loading,
                onPressed: _confirmChange,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _loading ? null : _sendCode,
                child: const Text('Resend code'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Change login password.

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final AuthService _auth = AuthService();
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _obscure = true;
  bool _loading = false;
  bool _resetLoading = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    final email = _auth.currentUser?.email;

    if (_current.text.isEmpty || email == null) {
      showErrorVia(messenger, scheme, 'Enter your current password.');
      return;
    }
    if (_next.text.isEmpty) {
      showErrorVia(messenger, scheme, 'Enter a new password.');
      return;
    }
    final pwError = validatePassword(_next.text);
    if (pwError != null) {
      showErrorVia(
        messenger,
        scheme,
        pwError.replaceFirst('Password', 'New password'),
      );
      return;
    }
    if (_confirm.text.isEmpty) {
      showErrorVia(messenger, scheme, 'Confirm your new password.');
      return;
    }
    if (_next.text != _confirm.text) {
      showErrorVia(messenger, scheme, 'New passwords do not match.');
      return;
    }

    setState(() => _loading = true);
    try {
      // Verify the current password first, then update and force a re-login.
      await _auth.signIn(email: email, password: _current.text);
      await _auth.updatePassword(_next.text);
      await _auth.signOut();
      showSuccessVia(
        messenger,
        scheme,
        'Login password updated. Sign in again with your new password.',
      );
      navigator.popUntil((route) => route.isFirst);
    } on AuthException catch (e) {
      if (mounted) setState(() => _loading = false);
      final invalid = e.message.toLowerCase().contains('invalid');
      showErrorVia(
        messenger,
        scheme,
        invalid ? 'Current password is incorrect.' : e.message,
      );
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      showErrorVia(messenger, scheme, _authMessage(e));
    }
  }

  Future<void> _sendReset() async {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final email = _auth.currentUser?.email;
    if (email == null) return;
    setState(() => _resetLoading = true);
    try {
      await _auth.requestPasswordReset(email);
      showSuccessVia(
        messenger,
        scheme,
        'Password reset link sent. Check your email.',
      );
    } catch (e) {
      showErrorVia(messenger, scheme, _authMessage(e));
    } finally {
      if (mounted) setState(() => _resetLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change login password')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Used to sign in. Separate from your vault PIN.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            _ObscureField(
              controller: _current,
              label: 'Current password',
              obscure: _obscure,
              enabled: !_loading,
              onToggle: () => setState(() => _obscure = !_obscure),
            ),
            const SizedBox(height: 12),
            _ObscureField(
              controller: _next,
              label: 'New password',
              obscure: _obscure,
              enabled: !_loading,
              onToggle: () => setState(() => _obscure = !_obscure),
            ),
            const SizedBox(height: 12),
            _ObscureField(
              controller: _confirm,
              label: 'Confirm new password',
              obscure: _obscure,
              enabled: !_loading,
              onToggle: () => setState(() => _obscure = !_obscure),
            ),
            const SizedBox(height: 20),
            _SubmitButton(
              label: 'Change login password',
              loading: _loading,
              onPressed: _changePassword,
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: (_loading || _resetLoading) ? null : _sendReset,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: _resetLoading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Forgot current password? Send reset link'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Change vault PIN with the current PIN.

class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key});

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
  final AuthService _auth = AuthService();
  final VaultService _vault = VaultService();
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _changePin() async {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    if (_current.text.isEmpty) {
      showErrorVia(messenger, scheme, 'Enter your current vault PIN.');
      return;
    }
    if (_next.text.isEmpty) {
      showErrorVia(messenger, scheme, 'Enter a new vault PIN.');
      return;
    }
    final pinError = validateVaultPin(_next.text);
    if (pinError != null) {
      showErrorVia(messenger, scheme, pinError);
      return;
    }
    if (_confirm.text.isEmpty) {
      showErrorVia(messenger, scheme, 'Confirm your new vault PIN.');
      return;
    }
    if (_next.text != _confirm.text) {
      showErrorVia(messenger, scheme, 'New PINs do not match.');
      return;
    }

    setState(() => _loading = true);
    try {
      await _vault.changePin(_requireUserId(_auth), _current.text, _next.text);
      showSuccessVia(messenger, scheme, 'Vault PIN updated.');
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      showErrorVia(messenger, scheme, _authMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final warning = validateVaultPin(_next.text) == null
        ? getWeakPinWarning(_next.text)
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Change vault PIN')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Unlocks encrypted data. PIN or passphrase, at least '
              '$vaultPinMinLength characters.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            _PinField(
              controller: _current,
              label: 'Current vault PIN',
              enabled: !_loading,
            ),
            const SizedBox(height: 12),
            _PinField(
              controller: _next,
              label: 'New vault PIN',
              enabled: !_loading,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _PinField(
              controller: _confirm,
              label: 'Confirm new vault PIN',
              enabled: !_loading,
            ),
            if (warning != null) ...[
              const SizedBox(height: 12),
              _WeakPinNote(message: warning),
            ],
            const SizedBox(height: 20),
            _SubmitButton(
              label: 'Change vault PIN',
              loading: _loading,
              onPressed: _changePin,
            ),
            const SizedBox(height: 8),
            // Forgot the current PIN: reset it with the recovery code instead
            // (styled like the login password's reset link).
            OutlinedButton(
              onPressed: _loading
                  ? null
                  : () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(
                        builder: (_) => const ResetPinScreen(),
                      ),
                    ),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Forgot your PIN? Use your recovery code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Generate / replace the recovery code with the current PIN.

class SetupRecoveryScreen extends StatefulWidget {
  const SetupRecoveryScreen({super.key});

  @override
  State<SetupRecoveryScreen> createState() => _SetupRecoveryScreenState();
}

class _SetupRecoveryScreenState extends State<SetupRecoveryScreen> {
  final AuthService _auth = AuthService();
  final VaultService _vault = VaultService();
  final TextEditingController _pin = TextEditingController();

  bool _loading = false;
  String? _code;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    setState(() => _loading = true);
    try {
      final code = await _vault.createRecoveryCode(
        _requireUserId(_auth),
        _pin.text,
      );
      setState(() => _code = code);
      _pin.clear();
      showSuccessVia(messenger, scheme, 'Recovery code created. Save it now.');
    } catch (e) {
      showErrorVia(messenger, scheme, _authMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinReady = _pin.text.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery code')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Use your current vault PIN to create or replace your one-time '
              'recovery code. It can reset your PIN if you forget it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            _PinField(
              controller: _pin,
              label: 'Current vault PIN',
              enabled: !_loading,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            _SubmitButton(
              label: 'Create recovery code',
              loading: _loading,
              onPressed: pinReady ? _create : null,
            ),
            if (_code != null) ...[
              const SizedBox(height: 20),
              _RecoveryCodeCard(code: _code!),
            ],
          ],
        ),
      ),
    );
  }
}

// Reset vault PIN with a recovery code.

class ResetPinScreen extends StatefulWidget {
  const ResetPinScreen({super.key});

  @override
  State<ResetPinScreen> createState() => _ResetPinScreenState();
}

class _ResetPinScreenState extends State<ResetPinScreen> {
  final AuthService _auth = AuthService();
  final VaultService _vault = VaultService();
  final TextEditingController _recoveryCode = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _loading = false;
  String? _newCode;

  @override
  void dispose() {
    _recoveryCode.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_recoveryCode.text.trim().isEmpty) {
      showErrorVia(messenger, scheme, 'Enter your recovery code.');
      return;
    }
    if (_next.text.isEmpty) {
      showErrorVia(messenger, scheme, 'Enter a new vault PIN.');
      return;
    }
    final pinError = validateVaultPin(_next.text);
    if (pinError != null) {
      showErrorVia(messenger, scheme, pinError);
      return;
    }
    if (_confirm.text.isEmpty) {
      showErrorVia(messenger, scheme, 'Confirm your new vault PIN.');
      return;
    }
    if (_next.text != _confirm.text) {
      showErrorVia(messenger, scheme, 'New PINs do not match.');
      return;
    }

    setState(() => _loading = true);
    try {
      final result = await _vault.recoverWithCode(
        _requireUserId(_auth),
        _recoveryCode.text,
        _next.text,
      );
      setState(() => _newCode = result.recoveryCode);
      _recoveryCode.clear();
      _next.clear();
      _confirm.clear();
      showSuccessVia(
        messenger,
        scheme,
        'Vault PIN updated. Save your new recovery code.',
      );
    } catch (e) {
      showErrorVia(messenger, scheme, _authMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final warning = validateVaultPin(_next.text) == null
        ? getWeakPinWarning(_next.text)
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Reset PIN with recovery code')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Use your recovery code to set a new vault PIN.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _recoveryCode,
              enabled: !_loading,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Recovery code'),
            ),
            const SizedBox(height: 12),
            _PinField(
              controller: _next,
              label: 'New vault PIN',
              enabled: !_loading,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _PinField(
              controller: _confirm,
              label: 'Confirm new vault PIN',
              enabled: !_loading,
            ),
            if (warning != null) ...[
              const SizedBox(height: 12),
              _WeakPinNote(message: warning),
            ],
            const SizedBox(height: 20),
            _SubmitButton(
              label: 'Reset PIN with recovery code',
              loading: _loading,
              onPressed: _reset,
            ),
            if (_newCode != null) ...[
              const SizedBox(height: 20),
              _RecoveryCodeCard(code: _newCode!),
            ],
          ],
        ),
      ),
    );
  }
}

// Delete account permanently.

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final AuthService _auth = AuthService();
  final VaultService _vault = VaultService();
  final TextEditingController _confirmText = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _pin = TextEditingController();

  bool _obscure = true;
  bool _loading = false;

  @override
  void dispose() {
    _confirmText.dispose();
    _password.dispose();
    _pin.dispose();
    super.dispose();
  }

  String get _phrase => 'DELETE ${_auth.currentUser?.email ?? ''}';

  Future<void> _delete() async {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    final email = _auth.currentUser?.email;

    if (_confirmText.text != _phrase) {
      showErrorVia(messenger, scheme, 'Type "$_phrase" to confirm.');
      return;
    }
    if (_password.text.isEmpty || _pin.text.isEmpty || email == null) {
      showErrorVia(messenger, scheme, 'Enter your login password and vault PIN.');
      return;
    }

    setState(() => _loading = true);
    try {
      // Re-verify both credentials before the irreversible delete.
      await _auth.signIn(email: email, password: _password.text);
      await _vault.unlock(_requireUserId(_auth), _pin.text);
      await _auth.deleteAccount();
      showSuccessVia(messenger, scheme, 'Your account has been deleted.');
      navigator.popUntil((route) => route.isFirst);
    } on AuthException catch (e) {
      if (mounted) setState(() => _loading = false);
      final invalid = e.message.toLowerCase().contains('invalid');
      showErrorVia(
        messenger,
        scheme,
        invalid ? 'Login password is incorrect.' : e.message,
      );
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      showErrorVia(messenger, scheme, _authMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final danger = Theme.of(context).colorScheme.error;
    return Scaffold(
      appBar: AppBar(title: const Text('Delete account')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: danger.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: danger),
                      const SizedBox(width: 8),
                      Text(
                        'This action is permanent',
                        style: TextStyle(
                          color: danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'All spaces and items are permanently deleted. Your encrypted '
                    'vault cannot be recovered afterward, even with your recovery code.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Type '),
                  TextSpan(
                    text: _phrase,
                    style: TextStyle(
                      color: danger,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const TextSpan(text: ' and re-enter your credentials.'),
                ],
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmText,
              enabled: !_loading,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Confirmation text'),
            ),
            const SizedBox(height: 12),
            _ObscureField(
              controller: _password,
              label: 'Login password',
              obscure: _obscure,
              enabled: !_loading,
              onToggle: () => setState(() => _obscure = !_obscure),
            ),
            const SizedBox(height: 12),
            _PinField(controller: _pin, label: 'Vault PIN', enabled: !_loading),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _loading ? null : _delete,
              style: FilledButton.styleFrom(backgroundColor: danger),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: _loading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Delete account permanently'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Shared widgets.

class _ObscureField extends StatelessWidget {
  const _ObscureField({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.enabled,
    required this.onToggle,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
          onPressed: onToggle,
        ),
      ),
    );
  }
}

class _PinField extends StatelessWidget {
  const _PinField({
    required this.controller,
    required this.label,
    required this.enabled,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: true,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: onChanged,
      decoration: InputDecoration(labelText: label),
    );
  }
}

class _WeakPinNote extends StatelessWidget {
  const _WeakPinNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _RecoveryCodeCard extends StatelessWidget {
  const _RecoveryCodeCard({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'New one-time recovery code',
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  code,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 20,
                    letterSpacing: 3,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  showSuccessSnack(context, 'Recovery code copied.');
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Save this code now. It replaces any previous recovery code.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: loading ? null : onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: loading
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label),
      ),
    );
  }
}

// Two-factor authentication (TOTP): enable with a QR + one-time backup codes,
// disable (login password required), or regenerate backup codes.
class TwoFactorScreen extends StatefulWidget {
  const TwoFactorScreen({super.key});

  @override
  State<TwoFactorScreen> createState() => _TwoFactorScreenState();
}

class _TwoFactorScreenState extends State<TwoFactorScreen> {
  final AuthService _auth = AuthService();
  final MfaService _mfa = MfaService();
  final TextEditingController _code = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  bool _enabled = false;
  int _remaining = 0;
  String? _error;
  MfaEnrollment? _enroll;
  List<String>? _backupCodes;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final factorId = await _mfa.verifiedFactorId();
      final count = factorId != null ? await _mfa.countUnusedBackupCodes() : 0;
      if (!mounted) return;
      setState(() {
        _enabled = factorId != null;
        _remaining = count;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snackError(String message) {
    if (mounted) showErrorSnack(context, message);
  }

  void _snackSuccess(String message) {
    if (mounted) showSuccessSnack(context, message);
  }

  Future<void> _startEnroll() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _mfa.enroll();
      setState(() {
        _enroll = data;
        _code.clear();
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = _authMessage(e);
        _busy = false;
      });
    }
  }

  Future<void> _cancelEnroll() async {
    final factorId = _enroll?.factorId;
    setState(() {
      _enroll = null;
      _code.clear();
      _error = null;
    });
    if (factorId != null) {
      try {
        await _mfa.unenroll(factorId);
      } catch (_) {
        // Ignore: an orphan unverified factor is cleared on the next enrol.
      }
    }
  }

  Future<void> _confirmEnroll() async {
    final validationError = validateTotpCode(_code.text);
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _mfa.verify(_enroll!.factorId, normalizeTotpCode(_code.text));
      final codes = await _mfa.regenerateBackupCodes(_requireUserId(_auth));
      setState(() {
        _enroll = null;
        _backupCodes = codes;
        _busy = false;
      });
      await _refresh();
    } catch (_) {
      setState(() {
        _error = 'That code was not accepted. Try again.';
        _busy = false;
      });
    }
  }

  Future<void> _regenerate() async {
    setState(() => _busy = true);
    try {
      final codes = await _mfa.regenerateBackupCodes(_requireUserId(_auth));
      setState(() {
        _backupCodes = codes;
        _busy = false;
      });
      await _refresh();
    } catch (e) {
      setState(() => _busy = false);
      _snackError(_authMessage(e));
    }
  }

  Future<void> _disable() async {
    final password = await _promptPassword();
    if (password == null) return;
    setState(() => _busy = true);
    try {
      final ok = await _mfa.verifyAccountPassword(
        _auth.currentUser?.email ?? '',
        password,
      );
      if (!ok) {
        setState(() => _busy = false);
        _snackError('Login password is incorrect.');
        return;
      }
      final factorId = await _mfa.verifiedFactorId();
      if (factorId != null) await _mfa.unenroll(factorId);
      await Supabase.instance.client
          .from('mfa_backup_codes')
          .delete()
          .eq('user_id', _requireUserId(_auth));
      await _refresh();
      setState(() => _busy = false);
      _snackSuccess('Two-factor authentication disabled.');
    } catch (e) {
      setState(() => _busy = false);
      _snackError(_authMessage(e));
    }
  }

  Future<String?> _promptPassword() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disable two-factor authentication?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter your login password to confirm. Your account will then be '
              'protected by your password alone.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Login password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Disable'),
          ),
        ],
      ),
    );
    controller.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Two-factor authentication')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _backupCodes != null
                    ? _backupCodesView()
                    : _enroll != null
                    ? _enrollView()
                    : _statusView(),
              ),
      ),
    );
  }

  Widget _statusView() {
    if (_enabled) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.verified_user, size: 48, color: Colors.green),
          const SizedBox(height: 16),
          Text(
            'Two-factor authentication is enabled',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            "You'll enter a code from your authenticator app when you sign in."
            "${_remaining == 0 ? ' No backup code left - regenerate one so you can get back in if you lose your authenticator.' : ''}",
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _busy ? null : _regenerate,
            icon: const Icon(Icons.refresh),
            label: const Text('Regenerate backup code'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _disable,
            icon: const Icon(Icons.gpp_bad_outlined),
            label: const Text('Disable'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.gpp_maybe_outlined, size: 48),
        const SizedBox(height: 16),
        Text(
          'Add two-factor authentication',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Require a one-time code from an authenticator app (Google '
          'Authenticator, Authy, 1Password) each time you sign in, on top of '
          'your password.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _startEnroll,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Enable'),
          ),
        ),
      ],
    );
  }

  Widget _enrollView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Scan this with your authenticator app, then enter the 6-digit code '
          'it shows.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: _enroll!.uri,
              size: 200,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Or enter this key manually:',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        SelectableText(
          _enroll!.secret,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.5),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _code,
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(totpCodeLength),
          ],
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _confirmEnroll(),
          decoration: const InputDecoration(labelText: '6-digit code'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _cancelEnroll,
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _confirmEnroll,
                child: Text(_busy ? 'Verifying...' : 'Verify & enable'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _backupCodesView() {
    final scheme = Theme.of(context).colorScheme;
    final codes = _backupCodes!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.vpn_key_outlined, size: 48),
        const SizedBox(height: 16),
        Text(
          'Save your backup code',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Keep this somewhere safe. It works once to sign in if you lose your '
          'authenticator, which turns off two-factor authentication so you can '
          'set it up again.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: SelectableText(
            codes.first,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 20,
              letterSpacing: 3,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: codes.first));
                  _snackSuccess('Backup code copied.');
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => setState(() => _backupCodes = null),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
