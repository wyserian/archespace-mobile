import 'dart:convert';

import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/cache_store.dart';
import 'package:archespace_mobile/src/shared/offline/write_queue.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// Reads spaces from Supabase and decrypts them with the master key. Encrypted
/// columns (`name`, `description`) are `arc1` values; everything else is plain
/// metadata. Mirrors the web `decryptSpace` + default ordering.
class SpaceRepository {
  SpaceRepository(this._masterKey);

  final List<int> _masterKey;

  Db get _client => Db.instance;

  /// Fetch spaces, caching the encrypted rows; on a network error, fall back
  /// to the cache. `fromCache` is true when the offline fallback was used.
  Future<({List<Space> spaces, bool fromCache})> listSpaces() async {
    const cacheKey = 'spaces';
    List<dynamic> rows;
    try {
      rows = await _client
          .from('spaces')
          .select(
            'id, name, description, tags, color, parent_id, pinned, starred, read_only, locked, position, created_at',
          )
          .isFilter('deleted_at', null)
          .isFilter('archived_at', null)
          .order('pinned', ascending: false)
          .order('position', ascending: true)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 8));

      // Per-space item counts (lightweight: no titles/content).
      final itemRows = await _client
          .from('space_items')
          .select('space_id, pinned')
          .isFilter('deleted_at', null)
          .isFilter('archived_at', null)
          .timeout(const Duration(seconds: 8));
      final total = <String, int>{};
      final pinned = <String, int>{};
      for (final r in itemRows) {
        // Dashboard items belong to no space, so they count toward none.
        final sid = r['space_id'] as String?;
        if (sid == null) continue;
        total[sid] = (total[sid] ?? 0) + 1;
        if (r['pinned'] == true) pinned[sid] = (pinned[sid] ?? 0) + 1;
      }
      for (final r in rows) {
        final m = r as Map<String, dynamic>;
        m['_item_count'] = total[m['id']] ?? 0;
        m['_pinned_count'] = pinned[m['id']] ?? 0;
      }
      await CacheStore.write(cacheKey, rows);
      WriteQueue.instance.flush(); // network is up: drain any queued writes
    } catch (_) {
      final cached = await CacheStore.read(cacheKey);
      if (cached is List) {
        return (spaces: _registerLocks(await _decode(cached)), fromCache: true);
      }
      rethrow;
    }
    return (spaces: _registerLocks(await _decode(rows)), fromCache: false);
  }

  /// Tell ContentLock which spaces are protected, so their items stay hidden
  /// wherever they're listed (Starred, search).
  List<Space> _registerLocks(List<Space> spaces) {
    ContentLock.instance.setSpaces(spaces);
    return spaces;
  }

  Future<List<Space>> _decode(List<dynamic> rows) async {
    final spaces = <Space>[];
    for (final row in rows) {
      final m = row as Map;
      try {
        spaces.add(
          Space(
            id: m['id'] as String,
            name: await ArcheCrypto.decryptArc1(
              (m['name'] ?? '') as String,
              _masterKey,
            ),
            description: await ArcheCrypto.decryptArc1(
              (m['description'] ?? '') as String,
              _masterKey,
            ),
            pinned: (m['pinned'] ?? false) as bool,
            starred: (m['starred'] ?? false) as bool,
            readOnly: (m['read_only'] ?? false) as bool,
            locked: (m['locked'] ?? false) as bool,
            tags: await ArcheCrypto.decryptTags(m['tags'], _masterKey),
            color: m['color'] as String?,
            parentId: m['parent_id'] as String?,
            itemCount: (m['_item_count'] ?? 0) as int,
            pinnedCount: (m['_pinned_count'] ?? 0) as int,
            createdAt: DateTime.tryParse((m['created_at'] ?? '').toString()),
          ),
        );
      } catch (_) {
        // Skip a row we can't decrypt (e.g. left from a previous vault key)
        // rather than failing the whole list.
        continue;
      }
    }
    return spaces;
  }

  Future<String> _enc(String value) =>
      ArcheCrypto.encryptArc1(value, _masterKey);

  Future<String> _encTags(List<String> tags) =>
      ArcheCrypto.encryptArc1(jsonEncode(tags), _masterKey);

  /// Duplicate a space and all its (non-deleted, non-archived) items. Item
  /// ciphertext is copied verbatim - it's already encrypted with the same key.
  Future<void> duplicateSpace(Space space) async {
    final userId = currentUserId();
    if (userId == null) throw StateError('Not authenticated');

    final existing = await _client
        .from('spaces')
        .select('id')
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);

    final payload = <String, dynamic>{
      'user_id': userId,
      'name': await _enc('${space.name} (copy)'),
      'description': await _enc(space.description),
      'color': space.color,
      'position': existing.length,
      // A copy of a protected space stays protected.
      'locked': space.locked,
    };
    if (space.tags.isNotEmpty) payload['tags'] = await _encTags(space.tags);

    final created = await _client
        .from('spaces')
        .insert(payload)
        .select('id')
        .single();
    final newId = created['id'] as String;

    final srcItems = await _client
        .from('space_items')
        .select('type, title, content, position, pinned, locked')
        .eq('space_id', space.id)
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);

    if (srcItems.isNotEmpty) {
      final rows = [
        for (final it in srcItems)
          {
            'space_id': newId,
            'type': it['type'],
            'title': it['title'],
            'content': it['content'],
            'position': it['position'],
            'pinned': it['pinned'] ?? false,
            'locked': it['locked'] ?? false,
          },
      ];
      await _client.from('space_items').insert(rows);
    }
  }

  /// Create a new space at the end of the list (position = current count).
  Future<void> createSpace({
    required String name,
    String description = '',
    String? color,
    List<String> tags = const [],
    String? parentId,
  }) async {
    final userId = currentUserId();
    if (userId == null) throw StateError('Not authenticated');

    final existing = await _client
        .from('spaces')
        .select('id')
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);

    final payload = {
      'user_id': userId,
      'name': await _enc(name),
      'description': await _enc(description),
      'color': color,
      // `tags` is jsonb NOT NULL; always store an encrypted array (matching the
      // web) rather than null, which would violate the constraint.
      'tags': await _encTags(tags),
      'position': existing.length,
    };
    if (parentId != null) payload['parent_id'] = parentId;
    await _client.from('spaces').insert(payload);
  }

  /// Sub-spaces of a top-level space (one-level nesting).
  Future<List<Space>> listSubSpaces(String parentId) async {
    final result = await listSpaces();
    return result.spaces.where((s) => s.parentId == parentId).toList();
  }

  Future<void> updateSpace({
    required String id,
    required String name,
    String description = '',
    String? color,
    List<String> tags = const [],
  }) async {
    await _client
        .from('spaces')
        .update({
          'name': await _enc(name),
          'description': await _enc(description),
          'color': color,
          // `tags` is jsonb NOT NULL; store an encrypted array, never null.
          'tags': await _encTags(tags),
        })
        .eq('id', id);
  }

  Future<void> setPinned(String id, bool pinned) async {
    await _client.from('spaces').update({'pinned': pinned}).eq('id', id);
  }

  /// Star / unstar. Never touches the space's position.
  Future<void> setStarred(String id, bool starred) async {
    await _client.from('spaces').update({'starred': starred}).eq('id', id);
  }

  /// Read-only on / off. While on, the database refuses changes to the
  /// space's details and to its items' content.
  Future<void> setReadOnly(String id, bool readOnly) async {
    await _client.from('spaces').update({'read_only': readOnly}).eq('id', id);
  }

  /// Protect / remove protection (a flag only; nothing is re-encrypted).
  Future<void> setLocked(String id, bool locked) async {
    await _client.from('spaces').update({'locked': locked}).eq('id', id);
    ContentLock.instance.setSpaceLocked(id, locked);
  }

  /// The space's current read-only flag, straight from the server.
  Future<bool> fetchReadOnly(String id) async {
    final row = await _client
        .from('spaces')
        .select('read_only')
        .eq('id', id)
        .single()
        .timeout(const Duration(seconds: 8));
    return (row['read_only'] ?? false) as bool;
  }

  Future<void> archiveSpace(String id) async {
    // Cascade to child spaces (one-level nesting).
    await _client
        .from('spaces')
        .update({'archived_at': DateTime.now().toUtc().toIso8601String()})
        .or('id.eq.$id,parent_id.eq.$id');
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// Persist a new order (positions 0..N-1) via the batch RPC.
  Future<void> reorder(List<String> orderedIds) async {
    final updates = [
      for (var i = 0; i < orderedIds.length; i++)
        {'id': orderedIds[i], 'position': i},
    ];
    await _client.rpc('update_space_positions', params: {'updates': updates});
  }

  Future<void> bulkSetPinned(List<String> ids, bool pinned) async {
    if (ids.isEmpty) return;
    await _client.from('spaces').update({'pinned': pinned}).inFilter('id', ids);
  }

  Future<void> bulkArchive(List<String> ids) async {
    if (ids.isEmpty) return;
    final now = _nowIso();
    await _client
        .from('spaces')
        .update({'archived_at': now})
        .inFilter('id', ids);
    // Cascade to child spaces of any archived top-level space.
    await _client
        .from('spaces')
        .update({'archived_at': now})
        .inFilter('parent_id', ids);
  }

  Future<void> bulkDelete(List<String> ids) async {
    if (ids.isEmpty) return;
    final now = _nowIso();
    await _client
        .from('spaces')
        .update({'deleted_at': now})
        .inFilter('id', ids);
    // Cascade to child spaces.
    await _client
        .from('spaces')
        .update({'deleted_at': now})
        .inFilter('parent_id', ids);
  }

  /// Soft-delete to the recycle bin (sets deleted_at), matching the web.
  /// Cascades to child spaces (one-level nesting).
  Future<void> deleteSpace(String id) async {
    await _client
        .from('spaces')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .or('id.eq.$id,parent_id.eq.$id');
  }

  /// Undo an archive or move-to-bin: clears both timestamps for the spaces and
  /// their child spaces (one-level nesting).
  Future<void> restoreSpaces(List<String> ids) async {
    if (ids.isEmpty) return;
    const cleared = {'archived_at': null, 'deleted_at': null};
    await _client.from('spaces').update(cleared).inFilter('id', ids);
    await _client.from('spaces').update(cleared).inFilter('parent_id', ids);
  }
}
