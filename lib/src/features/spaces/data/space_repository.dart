import 'dart:convert';

import 'package:archespace_mobile/src/features/spaces/data/space_lifecycle.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_tree.dart';
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

  /// Duplicate a space beside it (same parent), with its active items and its
  /// active sub-spaces at every level. Only the copy itself is renamed
  /// "(copy)"; sub-spaces and items are copied as stored - their ciphertext
  /// is already encrypted with the same key.
  Future<void> duplicateSpace(Space space) async {
    final userId = currentUserId();
    if (userId == null) throw StateError('Not authenticated');

    final active =
        await _client
                .from('spaces')
                .select(
                  'id, parent_id, name, description, tags, color, position, '
                  'pinned, locked',
                )
                .isFilter('deleted_at', null)
                .isFilter('archived_at', null)
            as List;

    final payload = <String, dynamic>{
      'user_id': userId,
      'name': await _enc('${space.name} (copy)'),
      'description': await _enc(space.description),
      'color': space.color,
      'parent_id': space.parentId,
      // After the spaces that share its parent.
      'position': active.where((s) => s['parent_id'] == space.parentId).length,
      // A copy of a protected space stays protected.
      'locked': space.locked,
    };
    if (space.tags.isNotEmpty) payload['tags'] = await _encTags(space.tags);

    final created = await _client
        .from('spaces')
        .insert(payload)
        .select('id')
        .single();
    final copies = {space.id: created['id'] as String};
    await _copyItems(space.id, copies[space.id]!);

    final byId = {for (final s in active) s['id'] as String: s};
    // Parents come before their children, so each copy's parent exists.
    for (final id in descendantsOf(
      [space.id],
      active,
      idOf: (s) => s['id'] as String,
      parentOf: (s) => s['parent_id'] as String?,
    )) {
      final s = byId[id]!;
      final copy = await _client
          .from('spaces')
          .insert({
            'user_id': userId,
            'parent_id': copies[s['parent_id']],
            'name': s['name'],
            'description': s['description'],
            'tags': s['tags'],
            'color': s['color'],
            'position': s['position'],
            'pinned': s['pinned'] ?? false,
            'locked': s['locked'] ?? false,
          })
          .select('id')
          .single();
      copies[id] = copy['id'] as String;
      await _copyItems(id, copies[id]!);
    }
  }

  /// Copy a space's active items into another space.
  Future<void> _copyItems(String fromId, String toId) async {
    final srcItems = await _client
        .from('space_items')
        .select('type, title, content, position, pinned, locked')
        .eq('space_id', fromId)
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);
    if (srcItems.isEmpty) return;
    await _client.from('space_items').insert([
      for (final it in srcItems)
        {
          'space_id': toId,
          'type': it['type'],
          'title': it['title'],
          'content': it['content'],
          'position': it['position'],
          'pinned': it['pinned'] ?? false,
          'locked': it['locked'] ?? false,
        },
    ]);
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

  /// The direct sub-spaces of a space.
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

  /// Archive a space with its sub-spaces at every level (see SpaceLifecycle).
  Future<void> archiveSpace(String id) => SpaceLifecycle().archive([id]);

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

  Future<void> bulkArchive(List<String> ids) => SpaceLifecycle().archive(ids);

  Future<void> bulkDelete(List<String> ids) => SpaceLifecycle().delete(ids);

  /// Move spaces into [parentId], or to the top level for null.
  Future<void> moveSpaces(List<String> ids, String? parentId) =>
      SpaceLifecycle().move(ids, parentId);

  /// Soft-delete to the recycle bin (sets deleted_at), matching the web, with
  /// the space's sub-spaces at every level.
  Future<void> deleteSpace(String id) => SpaceLifecycle().delete([id]);

  /// Undo an archive or move-to-bin, with what went along with it.
  Future<void> restoreSpaces(List<String> ids) =>
      SpaceLifecycle().undoRemove(ids);
}
