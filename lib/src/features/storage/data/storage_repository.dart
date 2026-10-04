import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';

/// A space or item that is archived or in the recycle bin.
class StoredEntry {
  StoredEntry({
    required this.id,
    required this.label,
    required this.isSpace,
    required this.type,
  });

  final String id;
  final String label;
  final bool isSpace;
  final String type; // 'space' or the item type
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
        .select('id, name')
        .not('archived_at', 'is', null)
        .isFilter('deleted_at', null);
    final itemRows = await _client
        .from('space_items')
        .select('id, title, type')
        .not('archived_at', 'is', null)
        .isFilter('deleted_at', null);
    return _decode(spaceRows, itemRows);
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

  /// Number of entries in the recycle bin (spaces + items); ids only, so
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
        .select('id, name')
        .not('deleted_at', 'is', null);
    final itemRows = await _client
        .from('space_items')
        .select('id, title, type')
        .not('deleted_at', 'is', null);
    return _decode(spaceRows, itemRows);
  }

  Future<List<StoredEntry>> _decode(
    List<dynamic> spaces,
    List<dynamic> items,
  ) async {
    final entries = <StoredEntry>[];
    for (final r in spaces) {
      entries.add(
        StoredEntry(
          id: r['id'] as String,
          label: await ArcheCrypto.decryptArc1(
            (r['name'] ?? '') as String,
            _masterKey,
          ),
          isSpace: true,
          type: 'space',
        ),
      );
    }
    for (final r in items) {
      entries.add(
        StoredEntry(
          id: r['id'] as String,
          label: await ArcheCrypto.decryptArc1(
            (r['title'] ?? '') as String,
            _masterKey,
          ),
          isSpace: false,
          type: (r['type'] ?? '') as String,
        ),
      );
    }
    return entries;
  }

  String _table(StoredEntry e) => e.isSpace ? 'spaces' : 'space_items';

  Future<void> restoreArchived(StoredEntry e) async {
    await _client.from(_table(e)).update({'archived_at': null}).eq('id', e.id);
  }

  Future<void> restoreDeleted(StoredEntry e) async {
    await _client.from(_table(e)).update({'deleted_at': null}).eq('id', e.id);
  }

  /// Move an archived entry to the recycle bin.
  Future<void> moveToBin(StoredEntry e) async {
    await _client
        .from(_table(e))
        .update({'deleted_at': _now(), 'archived_at': null})
        .eq('id', e.id);
  }

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
    if (spaceIds.isNotEmpty) {
      await _client
          .from('spaces')
          .update({'deleted_at': null})
          .inFilter('id', spaceIds);
    }
    if (itemIds.isNotEmpty) {
      await _client
          .from('space_items')
          .update({'deleted_at': null})
          .inFilter('id', itemIds);
    }
  }

  Future<void> restoreArchivedMany(Iterable<StoredEntry> entries) async {
    final (spaceIds, itemIds) = _split(entries);
    if (spaceIds.isNotEmpty) {
      await _client
          .from('spaces')
          .update({'archived_at': null})
          .inFilter('id', spaceIds);
    }
    if (itemIds.isNotEmpty) {
      await _client
          .from('space_items')
          .update({'archived_at': null})
          .inFilter('id', itemIds);
    }
  }

  Future<void> moveManyToBin(Iterable<StoredEntry> entries) async {
    final (spaceIds, itemIds) = _split(entries);
    final patch = {'deleted_at': _now(), 'archived_at': null};
    if (spaceIds.isNotEmpty) {
      await _client.from('spaces').update(patch).inFilter('id', spaceIds);
    }
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

  /// Permanently delete everything in the recycle bin (all soft-deleted rows).
  Future<void> purgeAll() async {
    await _client.from('spaces').delete().not('deleted_at', 'is', null);
    await _client.from('space_items').delete().not('deleted_at', 'is', null);
  }
}
