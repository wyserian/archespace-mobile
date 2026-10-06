import 'package:flutter/foundation.dart';

import 'package:archespace_mobile/src/features/storage/data/storage_repository.dart';
import 'package:archespace_mobile/src/features/upcoming/application/reminder_notifications.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';

/// Holds the starred, archive and recycle-bin counts app-wide so the drawer
/// can show them instantly (like the spaces count, which is already in memory).
/// Loaded once at launch and refreshed when the drawer opens or storage
/// changes.
class StorageCounts extends ChangeNotifier {
  StorageCounts._();
  static final StorageCounts instance = StorageCounts._();

  int? starred;
  int? archive;
  int? bin;
  bool _loading = false;

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    // Archiving, deleting or restoring changes which reminders are set too,
    // and so does the day (the Upcoming badge).
    ReminderNotifications.instance.sync();
    try {
      final repo = StorageRepository(VaultSession.instance.masterKey);
      final counts = await Future.wait([
        repo.archivedCount(),
        repo.deletedCount(),
      ]);
      archive = counts[0];
      bin = counts[1];
      // Fetched on its own so a failure here can't hide the other counts.
      try {
        starred = await repo.starredCount();
      } catch (_) {}
      notifyListeners();
    } catch (_) {
      // Keep the last known values on failure.
    } finally {
      _loading = false;
    }
  }

  /// Clear the counts (e.g. on lock/sign-out) so a new session reloads them.
  void reset() {
    starred = null;
    archive = null;
    bin = null;
    notifyListeners();
  }
}
