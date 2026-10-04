import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:archespace_mobile/src/features/auth/data/auth_service.dart';
import 'package:archespace_mobile/src/features/vault/data/biometric_service.dart';
import 'package:archespace_mobile/src/features/vault/data/secure_key_store.dart';
import 'package:archespace_mobile/src/features/vault/data/vault_service.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/presentation/widgets/recovery_code_step.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final AuthService _auth = AuthService();
  final VaultService _vault = VaultService();
  final SecureKeyStore _store = SecureKeyStore();
  final BiometricService _biometric = BiometricService();
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _recoveryCode = TextEditingController();
  final TextEditingController _newPin = TextEditingController();
  final TextEditingController _accountPassword = TextEditingController();
  final TextEditingController _confirmPin = TextEditingController();

  bool _loading = false;
  String? _error;
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;

  // Forgot-PIN (recovery-code) reset flow.
  bool _forgotPin = false;
  Uint8List? _resetMasterKey;
  String? _newRecoveryCode;

  // Destructive "lost recovery code too" reset: wipe data and start fresh.
  bool _resetVaultMode = false;
  bool _resetConfirmed = false;

  @override
  void initState() {
    super.initState();
    _initBiometric();
  }

  @override
  void dispose() {
    _pin.dispose();
    _recoveryCode.dispose();
    _newPin.dispose();
    _accountPassword.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  Future<void> _initBiometric() async {
    final available = await _biometric.isAvailable();
    final enabled = available && await _store.hasKey();
    if (!mounted) return;
    setState(() {
      _biometricAvailable = available;
      _biometricEnabled = enabled;
    });
    if (enabled) {
      _unlockWithBiometrics();
    }
  }

  Future<void> _unlockWithBiometrics() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await _biometric.authenticate('Unlock your ArcheSpace vault');
      if (!ok) return;
      final masterKey = await _store.readMasterKey();
      if (masterKey == null) {
        // Stored key vanished (e.g. cleared) - fall back to PIN.
        setState(() => _biometricEnabled = false);
        return;
      }
      VaultSession.instance.unlock(masterKey);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unlockWithPin() async {
    final userId = currentUserId();
    if (userId == null) return;

    if (_pin.text.trim().isEmpty) {
      setState(() => _error = 'Enter your vault PIN.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final masterKey = await _vault.unlock(userId, _pin.text.trim());

      // Offer to enable biometric unlock for next time, before we navigate away.
      if (_biometricAvailable && !_biometricEnabled && mounted) {
        if (await _askEnableBiometric()) {
          if (await _biometric.authenticate(
            'Confirm to enable biometric unlock',
          )) {
            await _store.saveMasterKey(masterKey);
          }
        }
      }

      VaultSession.instance.unlock(masterKey);
    } on VaultException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not unlock. Check your connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _askEnableBiometric() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enable biometric unlock?'),
        content: const Text(
          'Use your fingerprint or face to unlock the vault next time, '
          'instead of typing your PIN.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Enable'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _enterForgotPin() {
    setState(() {
      _forgotPin = true;
      _error = null;
      _recoveryCode.clear();
      _newPin.clear();
    });
  }

  void _cancelForgotPin() {
    setState(() {
      _forgotPin = false;
      _error = null;
    });
  }

  void _enterResetVault() {
    setState(() {
      _resetVaultMode = true;
      _forgotPin = false;
      _error = null;
      _accountPassword.clear();
      _newPin.clear();
      _confirmPin.clear();
      _resetConfirmed = false;
    });
  }

  void _cancelResetVault() {
    setState(() {
      _resetVaultMode = false;
      _error = null;
    });
  }

  /// Destructive reset for when both the PIN and recovery code are lost:
  /// re-verify the account password, then wipe all data and create a fresh
  /// vault. Old data is unrecoverable (that is the point).
  Future<void> _resetVault() async {
    final userId = currentUserId();
    final email = _auth.currentUser?.email;
    // Local mode has no account, so no account password to re-check.
    final local = AppMode.isLocal;
    if (userId == null || (!local && email == null)) return;

    if (!local && _accountPassword.text.isEmpty) {
      setState(() => _error = 'Enter your account password.');
      return;
    }
    if (_newPin.text.trim().isEmpty) {
      setState(() => _error = 'Enter a new vault PIN.');
      return;
    }
    if (_newPin.text.trim() != _confirmPin.text.trim()) {
      setState(() => _error = 'PINs do not match.');
      return;
    }
    if (!_resetConfirmed) {
      setState(() => _error = 'Tick the box to confirm this deletes your data.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Re-verify the account password before destroying anything.
      if (!local) {
        try {
          await _auth.signIn(email: email!, password: _accountPassword.text);
        } on AuthException {
          setState(() => _error = 'Incorrect account password.');
          return;
        }
      }
      final result = await _vault.resetVault(userId, _newPin.text.trim());
      // The old biometric key wrapped the destroyed master key - clear it.
      await _store.clear();
      setState(() {
        _resetVaultMode = false;
        _biometricEnabled = false;
        _resetMasterKey = result.masterKey;
        _newRecoveryCode = result.recoveryCode;
      });
    } on VaultException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not reset the vault. Check your connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Verify the recovery code, set the new PIN, and rotate the recovery code.
  /// The master key is unchanged, so any saved biometric key still works.
  Future<void> _resetWithRecovery() async {
    final userId = currentUserId();
    if (userId == null) return;

    if (_recoveryCode.text.trim().isEmpty) {
      setState(() => _error = 'Enter your recovery code.');
      return;
    }
    if (_newPin.text.trim().isEmpty) {
      setState(() => _error = 'Enter a new vault PIN.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _vault.recoverWithCode(
        userId,
        _recoveryCode.text.trim(),
        _newPin.text.trim(),
      );
      setState(() {
        _resetMasterKey = result.masterKey;
        _newRecoveryCode = result.recoveryCode;
      });
    } on VaultException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(
        () => _error = 'Could not reset your PIN. Check your connection.',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _continueAfterReset() {
    final key = _resetMasterKey;
    if (key == null) return;
    VaultSession.instance.unlock(key);
  }

  Future<void> _confirmSignOut() async {
    final ok = await confirmAction(
      context,
      title: SignOutText.title,
      message: SignOutText.message,
      confirmLabel: SignOutText.label,
      destructive: true,
    );
    if (ok) await _auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final newRecoveryCode = _newRecoveryCode;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _resetVaultMode
              ? 'Reset vault'
              : _forgotPin
              ? 'Reset vault PIN'
              : 'Unlock vault',
        ),
        actions: [
          IconButton(
            onPressed: _confirmSignOut,
            icon: const Icon(Icons.logout),
            tooltip: SignOutText.label,
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: newRecoveryCode != null
                  ? RecoveryCodeStep(
                      code: newRecoveryCode,
                      onContinue: _continueAfterReset,
                      title: 'Save your new recovery code',
                    )
                  : _resetVaultMode
                  ? _buildResetVaultForm(context)
                  : _forgotPin
                  ? _buildResetForm(context)
                  : _buildUnlockForm(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnlockForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.lock_outline, size: 40),
        const SizedBox(height: 16),
        Text(
          'Enter your vault PIN',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 20),
        if (_biometricEnabled) ...[
          OutlinedButton.icon(
            onPressed: _loading ? null : _unlockWithBiometrics,
            icon: const Icon(Icons.fingerprint),
            label: const Text('Unlock with biometrics'),
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          enabled: !_loading,
          onSubmitted: (_) => _unlockWithPin(),
          decoration: const InputDecoration(labelText: 'PIN or passphrase'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading ? null : _unlockWithPin,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Unlock'),
          ),
        ),
        TextButton(
          onPressed: _loading ? null : _enterForgotPin,
          child: const Text('Forgot your PIN?'),
        ),
      ],
    );
  }

  Widget _buildResetForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.vpn_key_outlined, size: 40),
        const SizedBox(height: 16),
        Text(
          'Reset with recovery code',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Enter the one-time recovery code you saved when creating your vault, '
          'then choose a new PIN. A fresh recovery code will be shown next.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _recoveryCode,
          enabled: !_loading,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _error = null),
          decoration: const InputDecoration(labelText: 'Recovery code'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _newPin,
          obscureText: true,
          enabled: !_loading,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _resetWithRecovery(),
          decoration: const InputDecoration(labelText: 'New vault PIN'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading ? null : _resetWithRecovery,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Reset PIN'),
          ),
        ),
        TextButton(
          onPressed: _loading ? null : _cancelForgotPin,
          child: const Text('Back to unlock'),
        ),
        TextButton(
          onPressed: _loading ? null : _enterResetVault,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('Lost your recovery code too? Reset vault'),
        ),
      ],
    );
  }

  Widget _buildResetVaultForm(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.warning_amber_rounded, size: 40, color: scheme.error),
        const SizedBox(height: 16),
        Text(
          'Reset vault',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Use this only if you have lost both your PIN and recovery code.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'This permanently deletes all your spaces and items. They are '
            'encrypted and cannot be recovered without your PIN or recovery '
            'code. This cannot be undone.',
            style: TextStyle(color: scheme.error, fontSize: 12),
          ),
        ),
        const SizedBox(height: 16),
        if (!AppMode.isLocal) ...[
          TextField(
            controller: _accountPassword,
            obscureText: true,
            enabled: !_loading,
            onChanged: (_) => setState(() => _error = null),
            decoration: const InputDecoration(labelText: 'Account password'),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _newPin,
          obscureText: true,
          enabled: !_loading,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _error = null),
          decoration: const InputDecoration(labelText: 'New vault PIN'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirmPin,
          obscureText: true,
          enabled: !_loading,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _error = null),
          decoration: const InputDecoration(labelText: 'Confirm vault PIN'),
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          value: _resetConfirmed,
          onChanged: _loading
              ? null
              : (v) => setState(() {
                  _resetConfirmed = v ?? false;
                  _error = null;
                }),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'I understand this permanently deletes all my data.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: scheme.error)),
        ],
        const SizedBox(height: 12),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          onPressed: _loading ? null : _resetVault,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Delete data & reset vault'),
          ),
        ),
        TextButton(
          onPressed: _loading ? null : _cancelResetVault,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
