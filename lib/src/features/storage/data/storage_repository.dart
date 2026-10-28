import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_lifecycle.dart';
import 'package:archespace_mobile/src/features/spaces/data/space_repository.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';

/// A space or item that is archived or in the bin, decrypted in full for its
/// read-only card.
class StoredEntry {
  StoredEntry.space(Space this.space, {this.at}) : item = null;
  StoredEntry.item(SpaceItem this.item, {this.at}) : space = null;

  final Space? space;
  final SpaceItem? item;

  /// When it was archived or put in the bin.
  final DateTime? at;

  bool get isSpace => space != null;
  String get id => space?.id ?? item!.id;
  String get label => space?.name ?? item!.title;
}

/// Lists and manages archived / soft-deleted spaces and items. Transitions:
/// active -> archived (archived_at), active -> bin (deleted_at); restore clears
/// the relevant column; purge hard-deletes.
class StorageRepository {
  StorageRepository(this._masterKey);

  final List<int> _masterKey;

  Db get _client => Db.instance;

  String _now() => DateTime.now().toUtc().toIso8601String();

  Future<List<StoredEntry>> loadArchived() async {
    final spaceRows = await _client
        .from('spaces')
        .select('*')
        .not('archived_at', 'is', null)
        .isFilter('deleted_at', null)
        .order('archived_at', ascending: false);
    final itemRows = await _client
        .from('space_items')
        .select('*')
        .not('archived_at', 'is', null)
        .isFilter('deleted_at', null)
        .order('archived_at', ascending: false);
    return _decode(spaceRows, itemRows, 'archived_at');
  }

  /// Number of archived entries (spaces + items). Selects only ids so nothing
  /// is decrypted - much faster than [loadArchived] when only the count is
  /// needed (e.g. the drawer badge).
  Future<int> archivedCount() async {
    final results = await Future.wait([
      _client
          .from('spaces')
          .select('id')
          .not('archived_at', 'is', null)
          .isFilter('deleted_at', null),
      _client
          .from('space_items')
          .select('id')
          .not('archived_at', 'is', null)
          .isFilter('deleted_at', null),
    ]);
    return results[0].length + results[1].length;
  }

  /// Number of starred active entries (spaces + items), for the drawer count;
  /// ids only, so nothing is decrypted.
  Future<int> starredCount() async {
    final results = await Future.wait([
      _client
          .from('spaces')
          .select('id')
          .eq('starred', true)
          .isFilter('deleted_at', null)
          .isFilter('archived_at', null),
      _client
          .from('space_items')
          .select('id')
          .eq('starred', true)
          .isFilter('deleted_at', null)
          .isFilter('archived_at', null),
    ]);
    return results[0].length + results[1].length;
  }

  /// Number of entries in the bin (spaces + items); ids only, so
  /// nothing is decrypted.
  Future<int> deletedCount() async {
    final results = await Future.wait([
      _client.from('spaces').select('id').not('deleted_at', 'is', null),
      _client.from('space_items').select('id').not('deleted_at', 'is', null),
    ]);
    return results[0].length + results[1].length;
  }

  Future<List<StoredEntry>> loadDeleted() async {
    final spaceRows = await _client
        .from('spaces')
        .select('*')
        .not('deleted_at', 'is', null)
        .order('deleted_at', ascending: false);
    final itemRows = await _client
        .from('space_items')
        .select('*')
        .not('deleted_at', 'is', null)
        .order('deleted_at', ascending: false);
    return _decode(spaceRows, itemRows, 'deleted_at');
  }

  /// Decrypt the rows as the dashboard does, with when each was stored
  /// ([atColumn]). A space's count is the items stored here with it.
  Future<List<StoredEntry>> _decode(
    List<dynamic> spaceRows,
    List<dynamic> itemRows,
    String atColumn,
  ) async {
    final counts = <String, int>{};
    for (final r in itemRows) {
      final sid = r['space_id'] as String?;
      if (sid != null) counts[sid] = (counts[sid] ?? 0) + 1;
    }
    for (final r in spaceRows) {
      final m = r as Map<String, dynamic>;
      m['_item_count'] = counts[m['id']] ?? 0;
    }
    final at = {
      for (final r in [...spaceRows, ...itemRows])
        r['id'] as String: DateTime.tryParse((r[atColumn] ?? '').toString()),
    };
    final spaces = await SpaceRepository(_masterKey).decodeRows(spaceRows);
    final items = await ItemRepository(_masterKey).decodeRows(itemRows);
    // Their protection still holds here: a protected space's items stay
    // hidden until the PIN opens it.
    ContentLock.instance.setSpaces(spaces);
    return [
      for (final s in spaces) StoredEntry.space(s, at: at[s.id]),
      for (final i in items) StoredEntry.item(i, at: at[i.id]),
    ];
  }

  String _table(StoredEntry e) => e.isSpace ? 'spaces' : 'space_items';

  // Spaces restore and move with what went along with them, and restoring
  // anything brings back the removed spaces above it (see SpaceLifecycle).

  Future<void> restoreArchived(StoredEntry e) => restoreArchivedMany([e]);

  Future<void> restoreDeleted(StoredEntry e) => restoreDeletedMany([e]);

  /// Move an archived entry to the bin.
  Future<void> moveToBin(StoredEntry e) => moveManyToBin([e]);

  /// Permanently delete (hard delete). For spaces, the DB cascade removes items.
  Future<void> purge(StoredEntry e) async {
    await _client.from(_table(e)).delete().eq('id', e.id);
  }

  // Bulk operations (multi-select)

  /// Split entries into (spaceIds, itemIds) for batched table updates.
  (List<String>, List<String>) _split(Iterable<StoredEntry> entries) => (
    entries.where((e) => e.isSpace).map((e) => e.id).toList(),
    entries.where((e) => !e.isSpace).map((e) => e.id).toList(),
  );

  Future<void> restoreDeletedMany(Iterable<StoredEntry> entries) async {
    final (spaceIds, itemIds) = _split(entries);
    if (spaceIds.isNotEmpty) await SpaceLifecycle().restore(spaceIds);
    if (itemIds.isNotEmpty) {
      await _client
          .from('space_items')
          .update({'deleted_at': null})
          .inFilter('id', itemIds);
      await SpaceLifecycle().reviveItemSpaces(itemIds);
    }
  }

  Future<void> restoreArchivedMany(Iterable<StoredEntry> entries) async {
    final (spaceIds, itemIds) = _split(entries);
    if (spaceIds.isNotEmpty) await SpaceLifecycle().unarchive(spaceIds);
    if (itemIds.isNotEmpty) {
      await _client
          .from('space_items')
          .update({'archived_at': null})
          .inFilter('id', itemIds);
      await SpaceLifecycle().reviveItemSpaces(itemIds);
    }
  }

  Future<void> moveManyToBin(Iterable<StoredEntry> entries) async {
    final (spaceIds, itemIds) = _split(entries);
    final patch = {'deleted_at': _now(), 'archived_at': null};
    if (spaceIds.isNotEmpty) await SpaceLifecycle().binArchived(spaceIds);
    if (itemIds.isNotEmpty) {
      await _client.from('space_items').update(patch).inFilter('id', itemIds);
    }
  }

  /// Permanently delete many. For spaces, the DB cascade removes their items.
  Future<void> purgeMany(Iterable<StoredEntry> entries) async {
    final (spaceIds, itemIds) = _split(entries);
    if (spaceIds.isNotEmpty) {
      await _client.from('spaces').delete().inFilter('id', spaceIds);
    }
    if (itemIds.isNotEmpty) {
      await _client.from('space_items').delete().inFilter('id', itemIds);
    }
  }

  /// Permanently delete everything in the bin (all soft-deleted rows).
  Future<void> purgeAll() async {
    await _client.from('spaces').delete().not('deleted_at', 'is', null);
    await _client.from('space_items').delete().not('deleted_at', 'is', null);
  }
}
