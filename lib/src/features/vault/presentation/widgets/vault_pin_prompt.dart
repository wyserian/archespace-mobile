import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/data/biometric_service.dart';
import 'package:archespace_mobile/src/features/vault/data/secure_key_store.dart';
import 'package:archespace_mobile/src/features/vault/data/vault_service.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// Ask for the vault PIN before showing protected content. Resolves
/// true once the right PIN is entered (or, when biometric unlock is on, a
/// fingerprint / face is confirmed), false if cancelled. After
/// [ContentLock.maxAttempts] wrong PINs in a row the vault locks.
///
/// [verify] replaces the check against this vault's PIN (a backup from
/// another vault); it returns false for a wrong PIN. Biometrics and the
/// vault lockout don't apply then.
Future<bool> askVaultPin(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Unlock',
  Future<bool> Function(String pin)? verify,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _VaultPinDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      verify: verify,
    ),
  );
  return ok ?? false;
}

class _VaultPinDialog extends StatefulWidget {
  const _VaultPinDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.verify,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final Future<bool> Function(String pin)? verify;

  @override
  State<_VaultPinDialog> createState() => _VaultPinDialogState();
}

class _VaultPinDialogState extends State<_VaultPinDialog> {
  final TextEditingController _pin = TextEditingController();
  final BiometricService _biometric = BiometricService();
  bool _busy = false;
  bool _obscure = true;
  bool _biometricEnabled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initBiometric();
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  /// Biometric unlock is on when the device supports it and the vault key was
  /// saved for it; then offer (and start) a fingerprint / face check.
  Future<void> _initBiometric() async {
    // Biometrics open this vault only, not another vault's backup.
    if (widget.verify != null) return;
    final enabled =
        await _biometric.isAvailable() && await SecureKeyStore().hasKey();
    if (!mounted || !enabled) return;
    setState(() => _biometricEnabled = true);
    _useBiometrics();
  }

  Future<void> _useBiometrics() async {
    final ok = await _biometric.authenticate(widget.title);
    if (!mounted) return;
    if (ok) {
      ContentLock.instance.failedAttempts = 0;
      Navigator.pop(context, true);
    }
  }

  Future<void> _submit() async {
    final pin = _pin.text.trim();
    final userId = currentUserId();
    if (pin.isEmpty || userId == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final verify = widget.verify;
    if (verify != null) {
      try {
        if (await verify(pin)) {
          if (mounted) Navigator.pop(context, true);
          return;
        }
        _error = 'Incorrect PIN.';
        _pin.clear();
      } catch (_) {
        _error = "Couldn't check the PIN.";
      }
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      await VaultService().unlock(userId, pin);
      ContentLock.instance.failedAttempts = 0;
      if (mounted) Navigator.pop(context, true);
      return;
    } on VaultException catch (e) {
      if (e.message == 'Incorrect PIN.') {
        final lock = ContentLock.instance;
        lock.failedAttempts++;
        if (lock.failedAttempts >= ContentLock.maxAttempts) {
          lock.failedAttempts = 0;
          if (mounted) Navigator.pop(context, false);
          VaultSession.instance.lock();
          return;
        }
        final left = ContentLock.maxAttempts - lock.failedAttempts;
        _error =
            'Incorrect PIN. $left more ${left == 1 ? 'try' : 'tries'} '
            'before the vault locks.';
        _pin.clear();
      } else {
        _error = e.message;
      }
    } catch (_) {
      _error = "Couldn't check the PIN. Check your connection.";
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.lock_outline, color: scheme.primary),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message),
          const SizedBox(height: 16),
          TextField(
            controller: _pin,
            autofocus: !_biometricEnabled,
            obscureText: _obscure,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: 'Vault PIN',
              errorText: _error,
              errorMaxLines: 3,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                tooltip: _obscure ? 'Show PIN' : 'Hide PIN',
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          if (_biometricEnabled) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : _useBiometrics,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Use biometrics'),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
