import 'package:flutter/foundation.dart';

import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_tree.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';

/// Protected items and spaces. A protected item keeps its title and tags in
/// view and a protected space its name, but the content needs the vault PIN
/// again. An item in a protected space (or in a sub-space of one, at any
/// depth) is hidden too, wherever it's listed. Protect is the `locked` flag
/// on the row; the content is encrypted with the vault key as always.
///
/// What has been opened lives only in memory: restarting the app, or the
/// vault locking, hides it all again.
class ContentLock extends ChangeNotifier {
  ContentLock._() {
    VaultSession.instance.unlocked.addListener(() {
      if (!VaultSession.instance.unlocked.value) hideAll();
    });
  }
  static final ContentLock instance = ContentLock._();

  final Set<String> _revealed = {};
  final Map<String, ({bool locked, String? parentId})> _spaces = {};

  bool isRevealed(String id) => _revealed.contains(id);

  /// A space and every space above it that has been seen.
  Iterable<String> _chain(String? spaceId) => chainOf(
    spaceId,
    (id) => _spaces[id]?.parentId,
  ).where(_spaces.containsKey);

  /// Whether a space's contents must stay hidden: it, or a space above it, is
  /// protected and not opened.
  bool isSpaceHidden(String? spaceId) => _chain(
    spaceId,
  ).any((id) => _spaces[id]!.locked && !_revealed.contains(id));

  /// Whether an item's content must stay hidden.
  bool isItemHidden(SpaceItem item) =>
      (item.locked && !_revealed.contains(item.id)) ||
      isSpaceHidden(item.spaceId);

  void reveal(String id) {
    if (_revealed.add(id)) notifyListeners();
  }

  /// Open everything that hides [item]: its own protection and its spaces'.
  void revealItem(SpaceItem item) {
    var changed = false;
    if (item.locked) changed |= _revealed.add(item.id);
    for (final id in _chain(item.spaceId)) {
      if (_spaces[id]!.locked) changed |= _revealed.add(id);
    }
    if (changed) notifyListeners();
  }

  /// Open a space and any protected space above it.
  void revealSpace(String spaceId) {
    var changed = false;
    for (final id in _chain(spaceId)) {
      if (_spaces[id]!.locked) changed |= _revealed.add(id);
    }
    if (changed) notifyListeners();
  }

  /// A space's protection as last loaded, or null if it hasn't been seen.
  bool? isSpaceLocked(String id) => _spaces[id]?.locked;

  void hide(String id) {
    if (_revealed.remove(id)) notifyListeners();
  }

  void hideAll() {
    if (_revealed.isEmpty) return;
    _revealed.clear();
    notifyListeners();
  }

  /// Record which spaces are protected (called whenever spaces load).
  void setSpaces(Iterable<Space> spaces) {
    var changed = false;
    for (final s in spaces) {
      changed |= _record(s.id, s.locked, s.parentId);
    }
    if (changed) notifyListeners();
  }

  /// Record spaces' protection from raw rows (lists that don't build [Space]s),
  /// with one update for the lot.
  void registerSpaces(
    Iterable<({String id, bool locked, String? parentId})> spaces,
  ) {
    var changed = false;
    for (final s in spaces) {
      changed |= _record(s.id, s.locked, s.parentId);
    }
    if (changed) notifyListeners();
  }

  bool _record(String id, bool locked, String? parentId) {
    final next = (locked: locked, parentId: parentId);
    if (_spaces[id] == next) return false;
    _spaces[id] = next;
    return true;
  }

  /// A space's protection was just changed here (ahead of the next load).
  void setSpaceLocked(String id, bool locked) {
    final current = _spaces[id];
    _spaces[id] = (locked: locked, parentId: current?.parentId);
    if (locked) _revealed.remove(id);
    notifyListeners();
  }

  /// Wrong PINs entered in a row at the protected-content prompt. After
  /// [maxAttempts] the whole vault locks, so the PIN can't be guessed at.
  int failedAttempts = 0;
  static const int maxAttempts = 5;
}
