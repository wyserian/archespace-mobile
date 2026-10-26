import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:archespace_mobile/src/features/auth/data/auth_service.dart';
import 'package:archespace_mobile/src/features/auth/data/mfa_service.dart';
import 'package:archespace_mobile/src/features/auth/domain/totp_code.dart';
import 'package:archespace_mobile/src/features/vault/domain/recovery_code.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';
import 'package:archespace_mobile/src/shared/widgets/icon_tile.dart';

/// Second-factor step shown after the password and before the vault. Accepts a
/// 6-digit authenticator code, or a one-time backup code (which turns off 2FA so
/// a user who lost their authenticator can get back in).
class MfaChallengeScreen extends StatefulWidget {
  const MfaChallengeScreen({super.key, required this.onVerified});

  final VoidCallback onVerified;

  @override
  State<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends State<MfaChallengeScreen> {
  final AuthService _auth = AuthService();
  final MfaService _mfa = MfaService();
  final TextEditingController _code = TextEditingController();

  bool _useBackup = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Validate format before hitting the network so obvious mistakes get an
    // immediate, specific message instead of a generic rejection.
    final validationError = _useBackup
        ? validateRecoveryCode(_code.text)
        : validateTotpCode(_code.text);
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    final code = _useBackup
        ? normalizeRecoveryCode(_code.text)
        : normalizeTotpCode(_code.text);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_useBackup) {
        final ok = await _mfa.redeemBackupCode(code);
        if (!ok) {
          setState(() {
            _error = 'That backup code is not valid or has already been used.';
            _loading = false;
          });
          return;
        }
        widget.onVerified();
        return;
      }
      final factorId = await _mfa.verifiedFactorId();
      if (factorId == null) {
        widget.onVerified();
        return;
      }
      await _mfa.verify(factorId, code);
      widget.onVerified();
    } catch (e) {
      setState(() {
        _error = 'That code was not accepted. Try again.';
        _loading = false;
      });
    }
  }

  Future<void> _confirmSignOut() async {
    final ok = await confirmAction(
      context,
      title: SignOutText.title,
      message: SignOutText.message,
      confirmLabel: SignOutText.label,
    );
    if (ok) await _auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // As on the vault screens: no title (the form names itself) and a
      // spelled-out way out.
      appBar: AppBar(
        actions: [
          TextButton(
            onPressed: _confirmSignOut,
            child: Text(SignOutText.label),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  IconTile(
                    icon: _useBackup
                        ? Icons.vpn_key_outlined
                        : Icons.verified_user_outlined,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _useBackup
                        ? 'Enter a backup code'
                        : 'Enter your authenticator code',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _useBackup
                        ? 'Using a backup code turns off two-factor authentication so you can sign in. Set it up again afterwards in Settings.'
                        : 'Enter the 6-digit code from your authenticator app.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _code,
                    enabled: !_loading,
                    autofocus: true,
                    keyboardType: _useBackup
                        ? TextInputType.text
                        : TextInputType.number,
                    textAlign: TextAlign.center,
                    autocorrect: false,
                    enableSuggestions: false,
                    inputFormatters: _useBackup
                        ? [LengthLimitingTextInputFormatter(24)]
                        : [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(totpCodeLength),
                          ],
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: _useBackup ? 'Backup code' : '6-digit code',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Verify'),
                    ),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => setState(() {
                            _useBackup = !_useBackup;
                            _code.clear();
                            _error = null;
                          }),
                    child: Text(
                      _useBackup
                          ? 'Use authenticator code'
                          : 'Use a backup code',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
