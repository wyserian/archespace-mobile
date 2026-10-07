import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:archespace_mobile/src/features/auth/data/auth_service.dart';
import 'package:archespace_mobile/src/features/auth/data/mfa_service.dart';
import 'package:archespace_mobile/src/features/auth/presentation/mfa_challenge_screen.dart';
import 'package:archespace_mobile/src/features/vault/data/secure_key_store.dart';
import 'package:archespace_mobile/src/features/vault/data/vault_service.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/presentation/inactivity_locker.dart';
import 'package:archespace_mobile/src/features/auth/presentation/login_screen.dart';
import 'package:archespace_mobile/src/features/onboarding/presentation/splash_screen.dart';
import 'package:archespace_mobile/src/features/spaces/presentation/spaces_screen.dart';
import 'package:archespace_mobile/src/features/settings/application/appearance_controller.dart';
import 'package:archespace_mobile/src/features/upcoming/application/reminder_notifications.dart';
import 'package:archespace_mobile/src/features/vault/presentation/unlock_screen.dart';
import 'package:archespace_mobile/src/features/vault/presentation/vault_setup_screen.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/cache_store.dart';

class ArcheApp extends StatelessWidget {
  const ArcheApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceController.instance;
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => MaterialApp(
        title: 'ArcheSpace',
        // Lets a tapped reminder open Upcoming.
        navigatorKey: ReminderNotifications.navigatorKey,
        themeMode: appearance.themeMode,
        theme: _theme(appearance.accent, Brightness.light),
        darkTheme: _theme(appearance.accent, Brightness.dark),
        home: const _RootGate(),
      ),
    );
  }

  /// Base theme for a brightness. A global [IconButtonThemeData] with a
  /// [CircleBorder] keeps every icon button's tap splash a circle (Material 3
  /// otherwise draws a stadium-shaped state layer), so all action buttons and
  /// the 3-dot menus look consistent.
  static ThemeData _theme(Color accent, Brightness brightness) {
    final seeded = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    );
    final light = brightness == Brightness.light;
    final scheme = light ? _lightNeutrals(seeded, accent) : seeded;
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: const CircleBorder()),
      ),
      // The add (+) FAB uses the bright accent with a dark icon (primary /
      // onPrimary) rather than the muted default primaryContainer, so it reads
      // as the clear primary action.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        // A slightly smaller rounded square than the M3 default (56 / r16).
        sizeConstraints: const BoxConstraints.tightFor(width: 50, height: 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
      // Pop-up (card action) menus float above the cards: a lighter surface
      // than the cards' surfaceContainer, a real shadow, and a hairline border
      // so the menu is clearly distinguishable from the content behind it.
      popupMenuTheme: PopupMenuThemeData(
        // White on light (cards are white too; shadow + hairline set it off).
        color: light ? Colors.white : scheme.surfaceContainerHighest,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
      ),
      // Standard rounded input boxes app-wide: a smooth-cornered outline with
      // the label sitting inside as a placeholder (never floating into the
      // border as a "legend"), plus compact padding. The item editor keeps the
      // same rounded look but with roomy padding for note/content entry.
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        floatingLabelBehavior: FloatingLabelBehavior.never,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
    );
  }

  /// Deeper light-mode shade of each accent (same hue, about 5:1 on white),
  /// matching the web. The bright accents wash out on a light background.
  static const Map<int, Color> _lightAccents = {
    0xFF32D3AA: Color(0xFF0B7F64), // mint
    0xFF7C6AF7: Color(0xFF5B45E0), // lavender
    0xFFF6B84B: Color(0xFFA35F00), // amber
    0xFF38A5F0: Color(0xFF0A6FB8), // sky
    0xFFF56B8A: Color(0xFFCC2F57), // rose
  };

  /// Light mode on neutral cool greys instead of the seed-tinted surfaces
  /// (which read yellowish / greyish): a grey page with white cards, sheets and
  /// dialogs on it, slate text, and a deeper accent with white on it. Matches
  /// the web's light tokens.
  static ColorScheme _lightNeutrals(ColorScheme seeded, Color accent) {
    const white = Color(0xFFFFFFFF);
    return seeded.copyWith(
      primary: _lightAccents[accent.toARGB32()] ?? seeded.primary,
      onPrimary: white,
      surface: const Color(0xFFEEF1F5),
      onSurface: const Color(0xFF0F172A),
      onSurfaceVariant: const Color(0xFF475569),
      surfaceDim: const Color(0xFFE1E6EC),
      surfaceBright: white,
      surfaceContainerLowest: white,
      surfaceContainerLow: white,
      surfaceContainer: white,
      surfaceContainerHigh: white,
      surfaceContainerHighest: const Color(0xFFE6EAF0),
      surfaceTint: Colors.transparent,
      outline: const Color(0xFF8A94A6),
      outlineVariant: const Color(0xFFD5DBE3),
    );
  }
}

/// Decides which screen to show: login (no session), unlock (session but locked
/// vault), or the spaces list (session + unlocked). Locks the vault on sign-out.
/// Local mode (AppMode) needs no session: it goes straight to the vault.
class _RootGate extends StatefulWidget {
  const _RootGate();

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  final AuthService _auth = AuthService();
  late final StreamSubscription<AuthState> _sub;

  // Show the app-open splash once per launch, before the login screen. A brand
  // new (or signed-out) user taps continue to reach login / create account.
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    AppMode.local.addListener(_onModeChanged);
    VaultSession.instance.unlocked.addListener(_onUnlockChanged);
    _sub = _auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut) {
        VaultSession.instance.lock();
        // Don't leave a stored key, cached data or reminders behind for the
        // next account.
        SecureKeyStore().clear();
        CacheStore.clear();
        ReminderNotifications.instance.clear();
      }
      if (mounted) setState(() {});
    });
  }

  /// Entering or leaving local mode; leaving locks the vault. The other
  /// mode's reminders are set again on its next unlock.
  void _onModeChanged() {
    if (!AppMode.isLocal) VaultSession.instance.lock();
    ReminderNotifications.instance.clear();
    if (mounted) setState(() {});
  }

  /// Unlocked: schedule the reminders (readable only now), and open Upcoming
  /// for one tapped while locked.
  void _onUnlockChanged() {
    if (!VaultSession.instance.unlocked.value) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ReminderNotifications.instance.sync(),
    );
  }

  @override
  void dispose() {
    AppMode.local.removeListener(_onModeChanged);
    VaultSession.instance.unlocked.removeListener(_onUnlockChanged);
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppMode.isLocal && _auth.currentSession == null) {
      // Cross-fade + slide from the splash to the login screen on continue.
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 450),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: _splashDone
            ? const LoginScreen(key: ValueKey('login'))
            : SplashScreen(
                key: const ValueKey('splash'),
                onContinue: () => setState(() => _splashDone = true),
              ),
      );
    }
    // 2FA (if enabled) must pass before the vault: password -> 2FA -> vault PIN.
    return _MfaGate(
      child: ValueListenableBuilder<bool>(
        valueListenable: VaultSession.instance.unlocked,
        builder: (context, unlocked, _) => unlocked
            ? const InactivityLocker(child: SpacesScreen())
            : const _VaultGate(),
      ),
    );
  }
}

/// Requires the session to reach AAL2 before showing [child], when the account
/// has 2FA enabled. Accounts without 2FA fall straight through.
class _MfaGate extends StatefulWidget {
  const _MfaGate({required this.child});

  final Widget child;

  @override
  State<_MfaGate> createState() => _MfaGateState();
}

class _MfaGateState extends State<_MfaGate> {
  final MfaService _mfa = MfaService();
  bool _passed = false;

  @override
  Widget build(BuildContext context) {
    if (AppMode.isLocal || _passed || !_mfa.needsChallenge()) {
      return widget.child;
    }
    return MfaChallengeScreen(onVerified: () => setState(() => _passed = true));
  }
}

/// A signed-in but locked user either has an existing vault (show the unlock
/// screen) or is brand new (show first-run vault setup). Checks once per gate.
class _VaultGate extends StatefulWidget {
  const _VaultGate();

  @override
  State<_VaultGate> createState() => _VaultGateState();
}

class _VaultGateState extends State<_VaultGate> {
  late final Future<bool> _hasVault;

  @override
  void initState() {
    super.initState();
    final userId = currentUserId();
    _hasVault = userId == null
        ? Future<bool>.value(true)
        : VaultService().hasVault(userId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _hasVault,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        // On error, assume a vault exists and fall back to the unlock screen
        // rather than risk overwriting one with a fresh setup.
        final needsSetup = snapshot.data == false;
        return needsSetup ? const VaultSetupScreen() : const UnlockScreen();
      },
    );
  }
}
