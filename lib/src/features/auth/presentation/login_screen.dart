import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:archespace_mobile/src/features/auth/data/auth_service.dart';
import 'package:archespace_mobile/src/features/auth/domain/email.dart';
import 'package:archespace_mobile/src/features/auth/domain/password_policy.dart';
import 'package:archespace_mobile/src/shared/config/app_config.dart';
import 'package:archespace_mobile/src/shared/config/legal.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

enum _Mode { signIn, signUp }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _auth = AuthService();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  _Mode _mode = _Mode.signIn;
  bool _loading = false;
  bool _resetLoading = false;
  bool _obscure = true;
  // Explicit consent to the Terms and Privacy Policy, required before an account
  // can be created (GDPR/DPDP: record affirmative agreement at sign-up).
  bool _acceptedTerms = false;
  String? _error;
  String? _info;

  final TapGestureRecognizer _termsTap = TapGestureRecognizer();
  final TapGestureRecognizer _privacyTap = TapGestureRecognizer();

  bool get _isSignUp => _mode == _Mode.signUp;

  @override
  void initState() {
    super.initState();
    _termsTap.onTap = () => _openLegal(Legal.termsUrl);
    _privacyTap.onTap = () => _openLegal(Legal.privacyUrl);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  Future<void> _openLegal(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _switchMode(_Mode mode) {
    // Clear the form when switching, so nothing carries between sign-in and
    // create-account.
    _password.clear();
    _confirm.clear();
    setState(() {
      _mode = mode;
      _error = null;
      _info = null;
      _acceptedTerms = false;
    });
  }

  Future<void> _submit() async {
    if (_loading) return;
    final emailError = validateEmail(_email.text.trim());
    if (emailError != null) {
      setState(() => _error = emailError);
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    if (_isSignUp) {
      await _createAccount();
    } else {
      await _signIn();
    }
  }

  Future<void> _forgotPassword() async {
    if (_loading || _resetLoading) return;
    final email = _email.text.trim();
    final emailError = validateEmail(email);
    if (emailError != null) {
      setState(() => _error = emailError);
      return;
    }
    setState(() {
      _resetLoading = true;
      _error = null;
      _info = null;
    });
    try {
      await _auth.requestPasswordReset(email);
      // Same confirmation whether or not the email is registered, so the reply
      // can't be used to enumerate accounts (Supabase also succeeds silently
      // for unknown emails).
      setState(
        () => _info =
            "If an account exists for that email, we've sent a password "
            'reset link. Check your inbox and spam folder.',
      );
    } catch (_) {
      setState(
        () => _error = "Couldn't send the reset link. Check your connection.",
      );
    } finally {
      if (mounted) setState(() => _resetLoading = false);
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      await _auth.signIn(email: _email.text.trim(), password: _password.text);
      // Commit the autofill session on success so the password manager offers
      // to save the working credential.
      TextInput.finishAutofillContext();
      // On success the auth stream rebuilds the root gate -> unlock screen.
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = "Couldn't sign in. Check your connection.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createAccount() async {
    final pwError = validatePassword(_password.text);
    if (pwError != null) {
      setState(() => _error = pwError);
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    if (!_acceptedTerms) {
      setState(
        () => _error =
            'Please accept the Terms of Service and Privacy Policy to continue.',
      );
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      final response = await _auth.signUp(
        email: _email.text.trim(),
        password: _password.text,
        // Record which policy version was accepted. The server stamps the
        // authoritative accepted-at time; the client timestamp is for
        // reference only (see the user_consent trigger in schema.sql).
        data: {
          'terms_version': Legal.termsVersion,
          'terms_accepted_at': DateTime.now().toUtc().toIso8601String(),
        },
      );
      // Account created (session or pending email confirmation) - commit the
      // autofill session so the password manager offers to save it.
      TextInput.finishAutofillContext();
      if (response.session != null) {
        // Signed in immediately; the root gate takes over to set up the vault.
        return;
      }
      // Email confirmation required before the account can sign in. This
      // message is shown identically whether the email is new or already
      // registered, so it never reveals which - preventing account enumeration.
      setState(() {
        _mode = _Mode.signIn;
        _password.clear();
        _confirm.clear();
        _info =
            'Check your email to confirm your address and finish signing up. '
            'Already have an account? Sign in instead.';
      });
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(
        () => _error = "Couldn't create your account. Check your connection.",
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Password requirements on sign-up: a 2x2 grid of rules that tick green as
  /// the password meets each one.
  Widget _buildPasswordChecklist(BuildContext context) {
    final pw = _password.text;
    final checks = <(String, bool)>[
      ('At least $passwordMinLength characters', pw.length >= passwordMinLength),
      ('An uppercase letter', RegExp('[A-Z]').hasMatch(pw)),
      ('A lowercase letter', RegExp('[a-z]').hasMatch(pw)),
      ('A number', RegExp(r'\d').hasMatch(pw)),
    ];
    Widget row(int a, int b) => Row(
      children: [
        Expanded(child: _checkItem(context, checks[a].$1, checks[a].$2)),
        Expanded(child: _checkItem(context, checks[b].$1, checks[b].$2)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [row(0, 1), const SizedBox(height: 4), row(2, 3)],
      ),
    );
  }

  Widget _checkItem(BuildContext context, String label, bool ok) {
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.color?.withValues(alpha: 0.6);
    final color = ok ? scheme.primary : muted;
    return Row(
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.circle_outlined,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 11, color: color),
          ),
        ),
      ],
    );
  }

  /// Live "passwords match" feedback under the confirm field on sign-up.
  Widget _buildMatchIndicator(BuildContext context) {
    if (_confirm.text.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final matches = _password.text == _confirm.text;
    final color = matches ? scheme.primary : scheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            matches ? Icons.check_circle : Icons.error_outline,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            matches ? 'Passwords match' : 'Passwords do not match',
            style: TextStyle(fontSize: 11, color: color),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Text(
                        _isSignUp
                            ? 'Sign up for ArcheSpace'
                            : 'Sign in to ArcheSpace',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      // Username first so the field is recognized as the login
                      // identifier and paired with the password credential.
                      autofillHints: const [
                        AutofillHints.username,
                        AutofillHints.email,
                      ],
                      enabled: !_loading,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: _obscure,
                      enabled: !_loading,
                      autofillHints: _isSignUp
                          ? const [AutofillHints.newPassword]
                          : const [AutofillHints.password],
                      // Live-refresh the requirements checklist as they type.
                      onChanged: _isSignUp ? (_) => setState(() {}) : null,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                        suffixIcon: IconButton(
                          iconSize: 20,
                          icon: Icon(
                            _obscure ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    if (_isSignUp) ...[
                      _buildPasswordChecklist(context),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirm,
                        obscureText: _obscure,
                        enabled: !_loading,
                        autofillHints: const [AutofillHints.newPassword],
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                          labelText: 'Confirm password',
                        ),
                      ),
                      _buildMatchIndicator(context),
                      const SizedBox(height: 10),
                      InkWell(
                        onTap: _loading
                            ? null
                            : () => setState(
                                () => _acceptedTerms = !_acceptedTerms,
                              ),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: 24,
                                width: 24,
                                child: Checkbox(
                                  value: _acceptedTerms,
                                  onChanged: _loading
                                      ? null
                                      : (v) => setState(
                                          () => _acceptedTerms = v ?? false,
                                        ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text.rich(
                                    TextSpan(
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                      children: [
                                        const TextSpan(text: 'I agree to the '),
                                        TextSpan(
                                          text: 'Terms of Service',
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          recognizer: _termsTap,
                                        ),
                                        const TextSpan(text: ' and '),
                                        TextSpan(
                                          text: 'Privacy Policy',
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          recognizer: _privacyTap,
                                        ),
                                        const TextSpan(text: '.'),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (_info != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _info!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: (_loading || (_isSignUp && !_acceptedTerms))
                          ? null
                          : _submit,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: _loading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(_isSignUp ? 'Create account' : 'Sign in'),
                      ),
                    ),
                    if (!_isSignUp) ...[
                      TextButton(
                        style: TextButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                        onPressed: (_loading || _resetLoading)
                            ? null
                            : _forgotPassword,
                        child: _resetLoading
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Forgot password?'),
                      ),
                    ],
                    if (AppConfig.allowSignup) ...[
                      const SizedBox(height: 6),
                      Center(
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _isSignUp
                                  ? 'Already have an account?'
                                  : 'New to ArcheSpace?',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color
                                        ?.withValues(alpha: 0.7),
                                  ),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: Size.zero,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                              ),
                              onPressed: _loading
                                  ? null
                                  : () => _switchMode(
                                      _isSignUp ? _Mode.signIn : _Mode.signUp,
                                    ),
                              child: Text(
                                _isSignUp ? 'Sign in' : 'Create an account',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    // Local mode: no account; everything stays on this device.
                    const SizedBox(height: 20),
                    const Row(
                      children: [
                        Expanded(child: Divider()),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('or'),
                        ),
                        Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : AppMode.enter,
                      icon: const Icon(Icons.phone_android, size: 18),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('Use without an account'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your data stays encrypted on this device only; nothing '
                      'is sent to a server.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
