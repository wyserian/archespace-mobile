import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:archespace_mobile/src/features/spaces/presentation/widgets/app_drawer.dart';
import 'package:archespace_mobile/src/shared/config/build_info.dart';
import 'package:archespace_mobile/src/shared/config/legal.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';

import 'package:archespace_mobile/src/features/auth/data/auth_service.dart';
import 'package:archespace_mobile/src/features/auth/data/mfa_service.dart';
import 'package:archespace_mobile/src/features/backup/data/backup_repository.dart';
import 'package:archespace_mobile/src/features/settings/application/appearance_controller.dart';
import 'package:archespace_mobile/src/features/vault/application/auto_lock_controller.dart';
import 'package:archespace_mobile/src/features/settings/presentation/account_security_screens.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/features/vault/data/biometric_service.dart';
import 'package:archespace_mobile/src/features/vault/data/secure_key_store.dart';
import 'package:archespace_mobile/src/features/vault/data/vault_service.dart';
import 'package:archespace_mobile/src/features/vault/presentation/widgets/vault_pin_prompt.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/cache_store.dart';
import 'package:archespace_mobile/src/shared/data/local_db.dart';

/// Settings, grouped like the web: Account, Vault, Appearance, Backup, About.
/// Each row shows what it is and its current state; forms open on their own
/// screens.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AuthService _auth = AuthService();
  final SecureKeyStore _store = SecureKeyStore();
  final BiometricService _biometric = BiometricService();
  bool _biometricEnabled = false;
  bool _biometricAvailable = false;
  // Null until known (or if it couldn't be checked).
  bool? _twoFactorOn;

  @override
  void initState() {
    super.initState();
    _loadBiometricState();
    if (!AppMode.isLocal) _loadTwoFactorState();
  }

  Future<void> _loadTwoFactorState() async {
    try {
      final factorId = await MfaService().verifiedFactorId();
      if (mounted) setState(() => _twoFactorOn = factorId != null);
    } catch (_) {
      // Offline or unknown: the row just doesn't show a state.
    }
  }

  Future<void> _loadBiometricState() async {
    final available = await _biometric.isAvailable();
    final enabled = await _store.hasKey();
    if (mounted) {
      setState(() {
        _biometricAvailable = available;
        _biometricEnabled = enabled;
      });
    }
  }

  Future<void> _enableBiometric() async {
    final ok = await _biometric.authenticate(
      'Confirm to enable biometric unlock',
    );
    if (!ok) return;
    await _store.saveMasterKey(VaultSession.instance.masterKey);
    if (!mounted) return;
    setState(() => _biometricEnabled = true);
    showSuccessSnack(context, 'Biometric unlock enabled.');
  }

  void _lock() {
    VaultSession.instance.lock();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _pickAutoLock() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Auto-lock after inactivity',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final o in kAutoLockOptions)
              ListTile(
                title: Text(o.label),
                trailing: o.id == AutoLockController.instance.id
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(sheetContext, o.id),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await AutoLockController.instance.setId(selected);
      if (mounted) showSuccessSnack(context, 'Auto-lock updated.');
    }
  }

  Future<void> _disableBiometric() async {
    final ok = await confirmAction(
      context,
      title: 'Turn off biometric unlock?',
      message:
          'The saved key on this device will be forgotten. You will need '
          'your vault PIN to unlock next time.',
      confirmLabel: 'Turn off',
      destructive: true,
    );
    if (!ok) return;
    await _store.clear();
    if (!mounted) return;
    setState(() => _biometricEnabled = false);
    showSuccessSnack(context, 'Biometric unlock disabled.');
  }

  Future<void> _signOut() async {
    final ok = await confirmAction(
      context,
      title: 'Sign out?',
      message:
          'You will need your login password and vault PIN to sign back in.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (!ok) return;
    await _auth.signOut();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Local mode: back to the sign-in screen; the data stays on the device.
  Future<void> _leaveLocalMode() async {
    final ok = await confirmAction(
      context,
      title: SignOutText.title,
      message: SignOutText.message,
      confirmLabel: SignOutText.label,
    );
    if (!ok) return;
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    await AppMode.leave();
  }

  /// Local mode: delete everything kept on this device, then leave the mode.
  Future<void> _eraseLocalData() async {
    final ok = await confirmAction(
      context,
      title: 'Erase local data?',
      message:
          'Every space, item and your vault on this device will be deleted '
          'permanently. Export a backup first if you might want them later.',
      confirmLabel: 'Erase everything',
      destructive: true,
    );
    if (!ok) return;
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    VaultSession.instance.lock();
    await _store.clear();
    await CacheStore.clear();
    await LocalDb.instance.erase();
    await AppMode.leave();
  }

  Future<void> _signOutAll() async {
    final ok = await confirmAction(
      context,
      title: 'Sign out of all devices?',
      message:
          'This ends your session on every device, including this one. You '
          'will need your login password and vault PIN to sign back in.',
      confirmLabel: 'Sign out everywhere',
      destructive: true,
    );
    if (!ok) return;
    await _auth.signOutAllDevices();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  Future<void> _openUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) showErrorSnack(context, "Couldn't open the link.");
  }

  Future<void> _exportBackup() async {
    try {
      final userId = currentUserId();
      if (userId == null) return;
      final json = await BackupRepository(
        VaultSession.instance.masterKey,
      ).exportJson(await VaultService().backupMeta(userId));
      final bytes = Uint8List.fromList(utf8.encode(json));
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save backup',
        fileName: 'archespace-backup-$date.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: bytes,
      );
      if (path != null && mounted) showSuccessSnack(context, 'Backup saved.');
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't export the backup.");
    }
  }

  Future<void> _importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = result?.files.single.path;
      if (path == null) return;
      final text = await File(path).readAsString();
      if (!mounted) return;
      final summary = await BackupRepository(VaultSession.instance.masterKey)
          .importJson(
            text,
            // A backup from another vault (another account, or before a reset).
            askBackupPin: (check) => askVaultPin(
              context,
              title: 'Open backup',
              message:
                  'This backup was made in another vault. Enter the vault PIN '
                  'you had when you exported it.',
              confirmLabel: 'Open',
              verify: check,
            ),
          );
      if (summary == null) return;
      final spacesLabel =
          '${summary.spaces} ${summary.spaces == 1 ? 'space' : 'spaces'}';
      final itemsLabel =
          '${summary.items} ${summary.items == 1 ? 'item' : 'items'}';
      final skippedLabel = summary.skipped > 0
          ? ' (${summary.skipped} skipped)'
          : '';
      if (!mounted) return;
      showSuccessSnack(
        context,
        'Imported $spacesLabel and $itemsLabel$skippedLabel.',
      );
    } on FormatException {
      if (mounted) showErrorSnack(context, "That backup file isn't valid.");
    } catch (_) {
      if (mounted) showErrorSnack(context, "Couldn't import the backup.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = _auth.currentUser?.email;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      drawer: const AppDrawer(current: DrawerPage.settings),
      drawerEdgeDragWidth: AppDrawer.edgeDragWidth(context),
      // Keep Back; the drawer opens with a slide from the left.
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Settings'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            if (AppMode.isLocal) ...[
              // Local mode takes the Account section's place.
              const _SectionTitle(
                'Local mode',
                'No account: everything stays on this device.',
              ),
              _SettingGroup(
                label: 'Your data',
                children: [
                  _SettingTile(
                    icon: Icons.phone_android,
                    title: 'Stored on this device',
                    subtitle:
                        'Encrypted with your vault PIN and kept only here; '
                        'nothing is sent to a server. Uninstalling the app '
                        'deletes it, so export a backup now and then.',
                    onTap: _exportBackup,
                    chevron: false,
                  ),
                ],
              ),
              _SettingGroup(
                label: 'Account',
                children: [
                  _SettingTile(
                    icon: Icons.logout,
                    title: 'Use an account instead',
                    subtitle:
                        'Export a backup, then sign in or create an account '
                        'and import it there. Your local data stays here '
                        'until you erase it.',
                    onTap: _leaveLocalMode,
                    chevron: false,
                  ),
                ],
              ),
              _SettingGroup(
                label: 'Danger zone',
                danger: true,
                children: [
                  _SettingTile(
                    icon: Icons.delete_forever_outlined,
                    title: 'Erase local data',
                    subtitle:
                        'Permanently deletes every space, item and your '
                        "vault from this device. This can't be undone.",
                    onTap: _eraseLocalData,
                    destructive: true,
                  ),
                ],
              ),
            ] else ...[
              // Account
              const _SectionTitle(
                'Account',
                'Your email, login password and sign-in security.',
              ),
              _SettingGroup(
                label: 'Sign-in',
                children: [
                  _SettingTile(
                    icon: Icons.alternate_email,
                    title: 'Email',
                    subtitle: email ?? 'Unknown',
                    onTap: () => _push(const ChangeEmailScreen()),
                  ),
                  _SettingTile(
                    icon: Icons.password_outlined,
                    title: 'Login password',
                    subtitle: 'Used to sign in. Separate from your vault PIN.',
                    onTap: () => _push(const ChangePasswordScreen()),
                  ),
                  _SettingTile(
                    icon: Icons.verified_user_outlined,
                    title: 'Two-factor authentication',
                    subtitle: 'A code from your authenticator app at sign-in.',
                    // Shows that it's on; off, the row opens its set-up.
                    trailing: _twoFactorOn == true
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const _OnPill(),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.chevron_right,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ],
                          )
                        : null,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const TwoFactorScreen(),
                        ),
                      );
                      _loadTwoFactorState();
                    },
                  ),
                ],
              ),
              _SettingGroup(
                label: 'Sessions',
                children: [
                  _SettingTile(
                    icon: Icons.logout,
                    title: 'Sign out',
                    subtitle: 'Sign out on this device.',
                    onTap: _signOut,
                    chevron: false,
                  ),
                  _SettingTile(
                    icon: Icons.devices,
                    title: 'Sign out of all devices',
                    subtitle: 'Ends your session everywhere, including here.',
                    onTap: _signOutAll,
                    chevron: false,
                  ),
                ],
              ),
              _SettingGroup(
                label: 'Danger zone',
                danger: true,
                children: [
                  _SettingTile(
                    icon: Icons.person_remove_outlined,
                    title: 'Delete account',
                    subtitle:
                        'Permanently deletes your account, spaces, items and '
                        "vault. This can't be undone.",
                    onTap: () => _push(const DeleteAccountScreen()),
                    destructive: true,
                  ),
                ],
              ),
            ],

            // Vault
            _SectionTitle(
              'Vault',
              AppMode.isLocal
                  ? 'Your vault PIN encrypts everything you store.'
                  : 'Your vault PIN encrypts everything you store. It is '
                        'separate from your login password.',
            ),
            _SettingGroup(
              label: 'Unlocking',
              children: [
                _SettingTile(
                  icon: Icons.pin_outlined,
                  title: 'Vault PIN',
                  subtitle:
                      'Unlocks your encrypted data. Forgot it? Reset it '
                      'with your recovery code.',
                  onTap: () => _push(const ChangePinScreen()),
                ),
                _SettingTile(
                  icon: Icons.fingerprint,
                  title: 'Biometric unlock',
                  subtitle: _biometricEnabled
                      ? 'On for this device. Your PIN still works.'
                      : _biometricAvailable
                      ? 'Unlock with fingerprint or face instead of typing '
                            'your PIN.'
                      : 'Not available on this device.',
                  trailing: Switch(
                    value: _biometricEnabled,
                    onChanged: _biometricEnabled || _biometricAvailable
                        ? (on) => on ? _enableBiometric() : _disableBiometric()
                        : null,
                  ),
                  onTap: _biometricEnabled
                      ? _disableBiometric
                      : _biometricAvailable
                      ? _enableBiometric
                      : null,
                ),
              ],
            ),
            _SettingGroup(
              label: 'Recovery',
              children: [
                _SettingTile(
                  icon: Icons.vpn_key_outlined,
                  title: 'Recovery code',
                  subtitle:
                      'A one-time code that resets your vault PIN if you '
                      'forget it. Making a new one replaces the old one.',
                  onTap: () => _push(const SetupRecoveryScreen()),
                ),
              ],
            ),
            _SettingGroup(
              label: 'Locking',
              children: [
                ListenableBuilder(
                  listenable: AutoLockController.instance,
                  builder: (context, _) {
                    final option = kAutoLockOptions.firstWhere(
                      (o) => o.id == AutoLockController.instance.id,
                      orElse: () => kAutoLockOptions.last,
                    );
                    return _SettingTile(
                      icon: Icons.lock_clock_outlined,
                      title: 'Auto-lock',
                      subtitle:
                          'Lock the vault after inactivity. This device only.',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            option.label,
                            style: TextStyle(color: scheme.primary),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      onTap: _pickAutoLock,
                    );
                  },
                ),
                _SettingTile(
                  icon: Icons.lock_outline,
                  title: 'Lock now',
                  subtitle:
                      'Your PIN or biometrics will be needed again to see '
                      'your data.',
                  onTap: _lock,
                  chevron: false,
                ),
              ],
            ),

            // Appearance
            const _SectionTitle('Appearance', 'Theme and accent colour.'),
            const _AppearanceGroup(),

            // Backup
            const _SectionTitle(
              'Backup',
              'Download a copy of your data, or restore one.',
            ),
            _SettingGroup(
              children: [
                _SettingTile(
                  icon: Icons.upload_file_outlined,
                  title: 'Export backup',
                  subtitle:
                      'Saves all your spaces and items as an encrypted '
                      'file.',
                  onTap: _exportBackup,
                  chevron: false,
                ),
                _SettingTile(
                  icon: Icons.download_outlined,
                  title: 'Import backup',
                  subtitle:
                      'Adds the spaces and items from a backup file. '
                      'Nothing you already have is replaced.',
                  onTap: _importBackup,
                  chevron: false,
                ),
                const _BackupNote(),
              ],
            ),

            // About
            const _SectionTitle('About', null),
            _SettingGroup(
              children: [
                _SettingTile(
                  icon: Icons.description_outlined,
                  title: 'Terms of Service',
                  trailing: Icon(
                    Icons.open_in_new,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  onTap: () => _openUrl(Legal.termsUrl),
                ),
                _SettingTile(
                  icon: Icons.privacy_tip_outlined,
                  title: 'Privacy Policy',
                  trailing: Icon(
                    Icons.open_in_new,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  onTap: () => _openUrl(Legal.privacyUrl),
                ),
              ],
            ),
            const _BuildFooter(),
          ],
        ),
      ),
    );
  }
}

/// Shows the app version, which links to the exact source commit this build
/// was compiled from on GitHub, so anyone can check the running app against
/// the open-source code.
class _BuildFooter extends StatefulWidget {
  const _BuildFooter();

  @override
  State<_BuildFooter> createState() => _BuildFooterState();
}

class _BuildFooterState extends State<_BuildFooter> {
  TapGestureRecognizer? _tap;

  @override
  void initState() {
    super.initState();
    if (BuildInfo.isStamped) {
      _tap = TapGestureRecognizer()..onTap = _openCommit;
    }
  }

  @override
  void dispose() {
    _tap?.dispose();
    super.dispose();
  }

  Future<void> _openCommit() async {
    await launchUrl(
      Uri.parse(BuildInfo.commitUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.color?.withValues(alpha: 0.7);
    final baseStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: muted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
      child: Center(
        child: Text.rich(
          TextSpan(
            style: baseStyle,
            children: [
              TextSpan(
                text: 'v${BuildInfo.appVersion}',
                style: baseStyle?.copyWith(
                  color: BuildInfo.isStamped
                      ? Theme.of(context).colorScheme.primary
                      : muted,
                ),
                recognizer: _tap,
              ),
            ],
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// A section's title with a one-line explanation (like the web's section
/// header).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.description);

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (description != null) ...[
            const SizedBox(height: 2),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A labelled group of setting rows on one rounded card, split by hairlines.
class _SettingGroup extends StatelessWidget {
  const _SettingGroup({
    this.label,
    this.danger = false,
    required this.children,
  });

  final String? label;
  final bool danger;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Text(
                label!.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: danger ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            ),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            color: scheme.surfaceContainer,
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 56,
                      color: scheme.outlineVariant.withValues(alpha: 0.6),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One setting: icon, title, a short explanation or current state, and what
/// a tap does (a chevron when it opens a screen, or a custom [trailing]).
class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.chevron = true,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Show a chevron (opens another screen) when there's no [trailing].
  final bool chevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? scheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color ?? scheme.onSurfaceVariant),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w600, color: color),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing:
          trailing ??
          (chevron
              ? Icon(Icons.chevron_right, color: scheme.onSurfaceVariant)
              : null),
      onTap: onTap,
    );
  }
}

/// "On", as a small accent pill at the end of a setting row (2FA).
class _OnPill extends StatelessWidget {
  const _OnPill();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 14, color: scheme.primary),
          const SizedBox(width: 4),
          Text(
            'On',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// A note at the foot of the Backup card: what opens an exported file.
class _BackupNote extends StatelessWidget {
  const _BackupNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primary.withValues(alpha: 0.08),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Backups are encrypted. ',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                  const TextSpan(
                    text:
                        'They open in this vault as they are, and anywhere '
                        'else with the vault PIN you had when exporting. After '
                        'a PIN change, older backups still need the earlier '
                        'PIN.',
                  ),
                ],
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Theme mode and accent colour, as two rows on one card.
class _AppearanceGroup extends StatelessWidget {
  const _AppearanceGroup();

  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceController.instance;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) {
        final accent = kAccentOptions.firstWhere(
          (o) => o.id == appearance.accentId,
          orElse: () => kAccentOptions.first,
        );
        return _SettingGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Theme',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('System'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('Light'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('Dark'),
                        ),
                      ],
                      selected: {appearance.themeMode},
                      showSelectedIcon: false,
                      onSelectionChanged: (selection) =>
                          appearance.setThemeMode(selection.first),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Accent colour',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    accent.name,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 14,
                    runSpacing: 10,
                    children: [
                      for (final option in kAccentOptions)
                        Semantics(
                          button: true,
                          selected: appearance.accentId == option.id,
                          label: option.name,
                          child: GestureDetector(
                            onTap: () => appearance.setAccent(option.id),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: option.color,
                                border: Border.all(
                                  color: appearance.accentId == option.id
                                      ? scheme.onSurface
                                      : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                              child: appearance.accentId == option.id
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 20,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
