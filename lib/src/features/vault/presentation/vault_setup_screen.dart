import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/auth/data/auth_service.dart';
import 'package:archespace_mobile/src/features/onboarding/data/welcome_space.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/data/vault_service.dart';
import 'package:archespace_mobile/src/features/vault/domain/vault_pin.dart';
import 'package:archespace_mobile/src/features/vault/presentation/widgets/recovery_code_step.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// First-run vault creation for a freshly registered account (no vault yet).
/// Creates a PIN-wrapped vault, shows the one-time recovery code, then unlocks
/// the in-memory session so the app can proceed.
class VaultSetupScreen extends StatefulWidget {
  const VaultSetupScreen({super.key});

  @override
  State<VaultSetupScreen> createState() => _VaultSetupScreenState();
}

class _VaultSetupScreenState extends State<VaultSetupScreen> {
  final AuthService _auth = AuthService();
  final VaultService _vault = VaultService();
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _loading = false;
  String? _error;

  // Set once setup succeeds; the recovery code is shown until acknowledged.
  Uint8List? _masterKey;
  String? _recoveryCode;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final userId = currentUserId();
    if (userId == null) return;

    if (_pin.text.isEmpty) {
      setState(() => _error = 'Enter a vault PIN.');
      return;
    }
    final pinError = validateVaultPin(_pin.text);
    if (pinError != null) {
      setState(() => _error = pinError);
      return;
    }
    if (_confirm.text.isEmpty) {
      setState(() => _error = 'Confirm your vault PIN.');
      return;
    }
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'PINs do not match.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _vault.setupVault(userId, _pin.text);
      // A brand-new account starts with a short tour (never after a reset).
      await WelcomeSpace.create(userId, result.masterKey);
      if (!mounted) return;
      setState(() {
        _masterKey = result.masterKey;
        _recoveryCode = result.recoveryCode;
      });
    } on VaultException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(
        () => _error = "Couldn't create your vault. Check your connection.",
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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

  void _continue() {
    final key = _masterKey;
    if (key == null) return;
    // Unlocking rebuilds the root gate into the spaces list.
    VaultSession.instance.unlock(key);
  }

  @override
  Widget build(BuildContext context) {
    final recoveryCode = _recoveryCode;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create vault PIN'),
        automaticallyImplyLeading: false,
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
              child: recoveryCode != null
                  ? RecoveryCodeStep(code: recoveryCode, onContinue: _continue)
                  : _buildPinForm(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPinForm(BuildContext context) {
    final warning = validateVaultPin(_pin.text) == null
        ? getWeakPinWarning(_pin.text)
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.shield_outlined, size: 48),
        const SizedBox(height: 16),
        Text(
          'Create your vault PIN',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Choose a PIN or passphrase, at least $vaultPinMinLength characters. '
          'It encrypts your data and is separate from your login password. A '
          'one-time recovery code is shown next.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _pin,
          obscureText: true,
          enabled: !_loading,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _error = null),
          decoration: const InputDecoration(labelText: 'New vault PIN'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirm,
          obscureText: true,
          enabled: !_loading,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _create(),
          decoration: const InputDecoration(labelText: 'Confirm vault PIN'),
        ),
        if (warning != null) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  warning,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading ? null : _create,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create PIN'),
          ),
        ),
      ],
    );
  }
}
