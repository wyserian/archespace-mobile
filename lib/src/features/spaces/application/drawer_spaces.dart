import 'package:flutter/foundation.dart';

import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';

/// The top-level spaces the drawer lists, held app-wide so the drawer on any
/// screen shows them. The dashboard publishes them as it loads and registers
/// how a space opens; the drawer refreshes them each time it opens.
class DrawerSpaces extends ChangeNotifier {
  DrawerSpaces._();
  static final DrawerSpaces instance = DrawerSpaces._();

  List<Space> spaces = const [];

  /// Opens a space from the dashboard, so it reloads when the space closes.
  ValueChanged<Space>? onOpenSpace;

  bool _loading = false;

  /// Keep the top-level spaces from [all], in their order.
  void publish(List<Space> all) {
    spaces = all.where((s) => s.parentId == null).toList();
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      publish(
        await SpaceRepository(VaultSession.instance.masterKey).listSpaces(),
      );
    } catch (_) {
      // Keep the last known list on failure.
    } finally {
      _loading = false;
    }
  }

  /// Forget the list (the dashboard closed: locked or signed out).
  void clear() {
    spaces = const [];
    onOpenSpace = null;
  }
}
