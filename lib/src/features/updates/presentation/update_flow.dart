import 'dart:async';

import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/updates/application/app_updater.dart';
import 'package:archespace_mobile/src/shared/config/build_info.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/confirm_dialog.dart';

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

/// The daily check found [release]: a banner with Later / Update.
void showUpdateBanner(BuildContext context, UpdateRelease release) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showMaterialBanner(
    MaterialBanner(
      leading: const Icon(Icons.system_update_outlined),
      content: Text('ArcheSpace ${release.version} is available.'),
      actions: [
        TextButton(
          onPressed: messenger.hideCurrentMaterialBanner,
          child: const Text('Later'),
        ),
        TextButton(
          onPressed: () {
            messenger.hideCurrentMaterialBanner();
            installUpdate(context, release);
          },
          child: const Text('Update'),
        ),
      ],
    ),
  );
}

/// Settings > Check for updates: says it's up to date, or offers the update.
Future<void> checkForUpdate(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final scheme = Theme.of(context).colorScheme;
  final UpdateRelease? release;
  try {
    release = await AppUpdater.instance.check();
  } catch (_) {
    showErrorVia(
      messenger,
      scheme,
      "Couldn't check for updates. Check your connection and try again.",
    );
    return;
  }
  if (release == null) {
    showSuccessVia(
      messenger,
      scheme,
      "You're on the latest version (v${BuildInfo.appVersion}).",
    );
    return;
  }
  if (!context.mounted) return;
  final go = await confirmAction(
    context,
    title: 'Update to ${release.version}?',
    message:
        'It downloads from GitHub (${_megabytes(release.size)} MB), is '
        "checked against the release's checksum, then Android asks you to "
        'install it. Your data stays as it is.',
    confirmLabel: 'Update',
  );
  if (go && context.mounted) await installUpdate(context, release);
}

/// Downloads, checks and installs [release], with progress and Cancel. First
/// asks for Android's "Install unknown apps" permission when it's missing.
Future<void> installUpdate(BuildContext context, UpdateRelease release) async {
  final updater = AppUpdater.instance;
  if (!await updater.canInstall()) {
    if (!context.mounted) return;
    final open = await confirmAction(
      context,
      title: 'Allow updates from ArcheSpace',
      message:
          'Android needs your OK before ArcheSpace can install its own '
          'updates. Turn on "Allow from this source", come back, and tap '
          'Update again.',
      confirmLabel: 'Open settings',
    );
    if (open) await updater.openInstallSettings();
    return;
  }
  if (!context.mounted) return;

  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final scheme = Theme.of(context).colorScheme;
  final progress = ValueNotifier<double>(0);
  var cancelled = false;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('Downloading ${release.version}'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, p, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: p == 0 ? null : p),
                const SizedBox(height: 8),
                Text('${(p * 100).round()}% of ${_megabytes(release.size)} MB'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                navigator.pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );

  try {
    final apk = await updater.download(
      release,
      onProgress: (p) => progress.value = p,
      isCancelled: () => cancelled,
    );
    if (cancelled) return;
    navigator.pop();
    await updater.install(apk);
  } on UpdateCancelled {
    // The dialog is already closed.
  } catch (e) {
    if (cancelled) return;
    navigator.pop();
    showErrorVia(
      messenger,
      scheme,
      e is UpdateException
          ? e.message
          : "Couldn't download the update. Check your connection and try "
                'again.',
    );
  }
}
