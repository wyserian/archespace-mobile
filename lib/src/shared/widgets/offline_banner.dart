import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/offline_db.dart';
import 'package:archespace_mobile/src/shared/widgets/status_banner.dart';

/// A thin banner shown while the server can't be reached: everything keeps
/// working on this device's offline copy, and changes sync once it's back
/// (OfflineDb). Says how many wait. Nothing in local mode, which needs no
/// server.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (AppMode.isLocal) return const SizedBox.shrink();
    final db = OfflineDb.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([db.reachable, db.pending]),
      builder: (context, _) {
        if (db.reachable.value) return const SizedBox.shrink();
        final count = db.pending.value;
        return StatusBanner(
          icon: Icons.cloud_off,
          message: count == 0
              ? "Offline - changes are saved here and sync when you're back"
              : "Offline - $count change${count == 1 ? '' : 's'} waiting to sync",
        );
      },
    );
  }
}
