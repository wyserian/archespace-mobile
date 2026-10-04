import 'dart:convert';

import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/cache_store.dart';
import 'package:archespace_mobile/src/shared/offline/write_queue.dart';
import 'package:archespace_mobile/src/shared/util/uuid.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// Reads and decrypts the items in a space, or - for a `null` space id - the
/// dashboard's items, which belong to no space. The `title` column is an `arc1`
/// string and `content` is `arc1(JSON.stringify(obj))`; everything else is
/// plain metadata. Mirrors the web `decryptItem` + default ordering.
class ItemRepository {
  ItemRepository(this._masterKey);

  final List<int> _masterKey;

  Db get _client => Db.instance;

  /// Offline cache key for a space's items, or the dashboard's for `null`.
  static String cacheKeyFor(String? spaceId) =>
      'items_${spaceId ?? 'dashboard'}';

  /// Restrict an items query to one space, or to the dashboard for `null`.
  DbQuery _whereSpace(DbQuery query, String? spaceId) => spaceId == null
      ? query.isFilter('space_id', null)
      : query.eq('space_id', spaceId);

  /// The owner, set explicitly on new rows: a dashboard item has no space for
  /// the database trigger to derive it from.
  String? get _userId => currentUserId();

  /// Fetch a space's (or the dashboard's) items, caching the encrypted rows; on
  /// a network error, fall back to the cache. `fromCache` is true when the
  /// fallback was used.
  Future<({List<SpaceItem> items, bool fromCache})> listItems(
    String? spaceId,
  ) => _list(cacheKeyFor(spaceId), (q) => _whereSpace(q, spaceId));

  /// Starred items from every space and the dashboard (the Starred view).
  Future<({List<SpaceItem> items, bool fromCache})> listStarredItems() =>
      _list('items_starred', (q) => q.eq('starred', true));

  static const _columns =
      'id, space_id, type, title, content, tags, pinned, starred, locked, '
      'position, created_at';

  /// Fetch active items matching [where], caching the encrypted rows under
  /// [cacheKey]; on a network error, fall back to that cache.
  Future<({List<SpaceItem> items, bool fromCache})> _list(
    String cacheKey,
    DbQuery Function(DbQuery) where,
  ) async {
    List<dynamic> rows;
    try {
      rows = await where(_client.from('space_items').select(_columns))
          .isFilter('deleted_at', null)
          .isFilter('archived_at', null)
          .order('pinned', ascending: false)
          .order('position', ascending: true)
          .timeout(const Duration(seconds: 8));
      await CacheStore.write(cacheKey, rows);
      WriteQueue.instance.flush(); // network is up: drain any queued writes
    } catch (_) {
      final cached = await CacheStore.read(cacheKey);
      if (cached is List) {
        return (items: await _decode(cached), fromCache: true);
      }
      rethrow;
    }
    return (items: await _decode(rows), fromCache: false);
  }

  Future<List<SpaceItem>> _decode(List<dynamic> rows) async {
    final items = <SpaceItem>[];
    for (final row in rows) {
      final m = row as Map;
      try {
        items.add(
          SpaceItem(
            id: m['id'] as String,
            type: (m['type'] ?? '') as String,
            title: await ArcheCrypto.decryptArc1(
              (m['title'] ?? '') as String,
              _masterKey,
            ),
            content: await ArcheCrypto.decryptJsonMap(m['content'], _masterKey),
            tags: await ArcheCrypto.decryptTags(m['tags'], _masterKey),
            pinned: (m['pinned'] ?? false) as bool,
            starred: (m['starred'] ?? false) as bool,
            locked: (m['locked'] ?? false) as bool,
            spaceId: m['space_id'] as String?,
            createdAt: DateTime.tryParse((m['created_at'] ?? '').toString()),
          ),
        );
      } catch (_) {
        // Skip a row we can't decrypt (e.g. left from a previous vault key)
        // rather than failing the whole list.
        continue;
      }
    }
    return items;
  }

  Future<String> _encTags(List<String> tags) =>
      ArcheCrypto.encryptArc1(jsonEncode(tags), _masterKey);

  /// Update an item's tags only (encrypted like space tags).
  Future<void> setTags(String id, List<String> tags) async {
    await _client
        .from('space_items')
        .update({'tags': await _encTags(tags)})
        .eq('id', id);
  }

  Future<String> _encTitle(String title) =>
      ArcheCrypto.encryptArc1(title, _masterKey);

  Future<String> _encContent(Map<String, dynamic> content) =>
      ArcheCrypto.encryptArc1(jsonEncode(content), _masterKey);

  /// Re-encrypt and save an existing item's title + content. Queued offline.
  ///
  /// Goes through the write queue as an upsert, so the row carries what a
  /// fresh insert needs: `type` and `user_id` (NOT NULL, no default) and the
  /// item's `space_id` (null for a dashboard item). Without them the insert
  /// path fails even when the row already exists.
  Future<void> updateItem({
    required String id,
    required String? spaceId,
    required String type,
    required String title,
    required Map<String, dynamic> content,
  }) async {
    final row = {
      'id': id,
      'space_id': spaceId,
      'user_id': ?_userId,
      'type': type,
      'title': await _encTitle(title),
      'content': await _encContent(content),
    };
    await WriteQueue.instance.upsert('space_items', row);
    await CacheStore.upsertRow(cacheKeyFor(spaceId), row);
  }

  Future<void> setPinned(String id, bool pinned) async {
    await _client.from('space_items').update({'pinned': pinned}).eq('id', id);
  }

  /// Star / unstar. Never touches the item's position.
  Future<void> setStarred(String id, bool starred) async {
    await _client.from('space_items').update({'starred': starred}).eq('id', id);
  }

  /// Protect / remove protection (a flag only; nothing is re-encrypted).
  Future<void> setLocked(String id, bool locked) async {
    await _client.from('space_items').update({'locked': locked}).eq('id', id);
  }

  Future<void> archiveItem(String id) async {
    await _client
        .from('space_items')
        .update({'archived_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id);
  }

  Future<void> deleteItem(String id) async {
    await _client
        .from('space_items')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id);
  }

  Future<int> _endPosition(String? spaceId) async {
    final existing = await _whereSpace(
      _client.from('space_items').select('id'),
      spaceId,
    ).isFilter('deleted_at', null).isFilter('archived_at', null);
    return existing.length;
  }

  Future<void> duplicateItem(String? spaceId, SpaceItem item) async {
    final title = item.title.isEmpty
        ? 'Untitled (copy)'
        : '${item.title} (copy)';
    await _client.from('space_items').insert({
      'space_id': spaceId,
      'user_id': ?_userId,
      'type': item.type,
      'title': await _encTitle(title),
      'content': await _encContent(item.content),
      'position': await _endPosition(spaceId),
      // A copy of a protected item stays protected.
      'locked': item.locked,
    });
  }

  /// Move an item to another space, or to the dashboard for `null`.
  Future<void> moveItem(String itemId, String? targetSpaceId) async {
    await _client
        .from('space_items')
        .update({
          'space_id': targetSpaceId,
          'position': await _endPosition(targetSpaceId),
          'pinned': false,
        })
        .eq('id', itemId);
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// Persist a new order (positions 0..N-1) via the batch RPC.
  Future<void> reorder(List<String> orderedIds) async {
    final updates = [
      for (var i = 0; i < orderedIds.length; i++)
        {'id': orderedIds[i], 'position': i},
    ];
    await _client.rpc('update_item_positions', params: {'updates': updates});
  }

  Future<void> bulkSetPinned(List<String> ids, bool pinned) async {
    if (ids.isEmpty) return;
    await _client
        .from('space_items')
        .update({'pinned': pinned})
        .inFilter('id', ids);
  }

  Future<void> bulkArchive(List<String> ids) async {
    if (ids.isEmpty) return;
    await _client
        .from('space_items')
        .update({'archived_at': _nowIso()})
        .inFilter('id', ids);
  }

  Future<void> bulkDelete(List<String> ids) async {
    if (ids.isEmpty) return;
    await _client
        .from('space_items')
        .update({'deleted_at': _nowIso()})
        .inFilter('id', ids);
  }

  /// Undo an archive or move-to-bin: clears both timestamps for the items.
  Future<void> restoreItems(List<String> ids) async {
    if (ids.isEmpty) return;
    await _client
        .from('space_items')
        .update({'archived_at': null, 'deleted_at': null})
        .inFilter('id', ids);
  }

  /// Move items to another space, or to the dashboard for `null`.
  Future<void> bulkMove(List<String> ids, String? targetSpaceId) async {
    var position = await _endPosition(targetSpaceId);
    for (final id in ids) {
      await _client
          .from('space_items')
          .update({
            'space_id': targetSpaceId,
            'position': position,
            'pinned': false,
          })
          .eq('id', id);
      position++;
    }
  }

  /// Create a new item. Uses a client-generated id + cache-based position so it
  /// works offline (queued) and appears immediately in the cache.
  /// Creates an item and returns its new id (so callers can switch to update
  /// mode for subsequent saves, e.g. auto-save).
  Future<String> createItem({
    required String? spaceId,
    required String type,
    String title = '',
    required Map<String, dynamic> content,
  }) async {
    final cacheKey = cacheKeyFor(spaceId);
    final position = (await CacheStore.readRows(cacheKey)).length;
    final id = newUuid();
    final row = {
      'id': id,
      'space_id': spaceId,
      'user_id': ?_userId,
      'type': type,
      'title': await _encTitle(title),
      'content': await _encContent(content),
      'position': position,
      'pinned': false,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    await WriteQueue.instance.upsert('space_items', row);
    await CacheStore.upsertRow(cacheKey, row);
    return id;
  }
}
