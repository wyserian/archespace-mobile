import 'dart:convert';

import 'package:archespace_mobile/src/features/items/domain/reminder.dart';
import 'package:archespace_mobile/src/features/items/domain/rich_doc.dart';
import 'package:archespace_mobile/src/features/vault/data/vault_service.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/offline_db.dart';

/// JSON backup export/import, matching the web format. A backup is encrypted:
/// `{ app, version: 3, encrypted: true, exportedAt, vault, data }`, where
/// `data` is the contents `{ spaces: [...], items: [...] }` encrypted with the
/// vault key, and `vault` is that key wrapped with the vault PIN (as the
/// server stores it). So it opens as-is in the same vault, and anywhere else
/// with the vault PIN of the time. Each space carries its fields, its nesting
/// (`key`, and its parent's as `parentKey`) and an `items` array ({ type,
/// title, content, position, pinned, tags, starred, color, locked, reminder });
/// the top-level `items` are the dashboard's (no space).
class BackupRepository {
  BackupRepository(this._masterKey, [this._db]);

  final List<int> _masterKey;
  final Db? _db;

  Db get _client => _db ?? Db.instance;

  Future<String> _dec(Object? v) =>
      ArcheCrypto.decryptArc1((v ?? '') as String, _masterKey);
  Future<String> _enc(String v) => ArcheCrypto.encryptArc1(v, _masterKey);
  Future<String> _encJson(Object? v) =>
      ArcheCrypto.encryptArc1(jsonEncode(v), _masterKey);

  // Items the export couldn't decrypt (e.g. left from an earlier vault key),
  // left out and counted for the caller to report.
  var _unreadable = 0;

  /// Active items of one space, or the dashboard's items (no space) for `null`,
  /// decrypted for the backup.
  Future<List<Map<String, dynamic>>> _exportItems(String? spaceId) async {
    final query = _client
        .from('space_items')
        .select(
          'type, title, content, tags, reminder, position, pinned, starred, '
          'locked, color',
        );
    final itemRows =
        await (spaceId == null
                ? query.isFilter('space_id', null)
                : query.eq('space_id', spaceId))
            .isFilter('deleted_at', null)
            .isFilter('archived_at', null)
            .order('position', ascending: true);

    final items = <Map<String, dynamic>>[];
    for (final it in itemRows) {
      try {
        final r = it['reminder'];
        final reminder = r is String
            ? Reminder.fromJson(jsonDecode(await _dec(r)))
            : Reminder.fromJson(r); // an older, plain one (or none)
        final tags = await ArcheCrypto.decryptTags(it['tags'], _masterKey);
        items.add({
          'type': it['type'],
          'title': await _dec(it['title']),
          'content': await ArcheCrypto.decryptJsonMap(
            it['content'],
            _masterKey,
          ),
          'position': it['position'],
          'pinned': it['pinned'] ?? false,
          if (tags.isNotEmpty) 'tags': tags,
          if (it['starred'] == true) 'starred': true,
          'color': ?it['color'],
          if (it['locked'] == true) 'locked': true,
          'reminder': ?reminder?.toJson(),
        });
      } catch (_) {
        _unreadable++;
      }
    }
    return items;
  }

  /// Build the encrypted backup JSON (active spaces + items), and how many
  /// items were left out as undecryptable. [vaultMeta] is the vault's
  /// PIN-wrapped key (VaultService.backupMeta), carried so the file opens
  /// elsewhere with the vault PIN.
  Future<({String json, int unreadable})> exportJson(
    Map<String, String> vaultMeta,
  ) async {
    _unreadable = 0;
    // A List, not dynamic: `.indexed` below is an extension, which a
    // dynamic value can't reach.
    final spaceRows =
        await _client
                .from('spaces')
                .select(
                  'id, parent_id, name, description, tags, color, pinned, '
                  'starred, locked, read_only, position',
                )
                .isFilter('deleted_at', null)
                .isFilter('archived_at', null)
                .order('position', ascending: true)
            as List;

    // Nesting: each space's `key` is its place in the list, and a sub-space
    // names its parent's as `parentKey`.
    final keyOf = {
      for (var i = 0; i < spaceRows.length; i++) spaceRows[i]['id']: i,
    };
    final out = <Map<String, dynamic>>[];
    for (final (i, s) in spaceRows.indexed) {
      out.add({
        'key': i,
        'parentKey': ?keyOf[s['parent_id']],
        'name': await _dec(s['name']),
        'description': await _dec(s['description']),
        'color': s['color'],
        'tags': await ArcheCrypto.decryptTags(s['tags'], _masterKey),
        'pinned': s['pinned'] ?? false,
        if (s['starred'] == true) 'starred': true,
        if (s['locked'] == true) 'locked': true,
        if (s['read_only'] == true) 'readOnly': true,
        'position': s['position'],
        'items': await _exportItems(s['id'] as String),
      });
    }
    final contents = {
      'spaces': out,
      // Items that live on the dashboard, outside any space.
      'items': await _exportItems(null),
    };
    final payload = {
      'app': 'ArcheSpace',
      'version': 3,
      'encrypted': true,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'vault': vaultMeta,
      'data': await _encJson(contents),
    };
    return (
      json: const JsonEncoder.withIndent('  ').convert(payload),
      unreadable: _unreadable,
    );
  }

  /// The order to import a backup's spaces in, parents first: (index,
  /// parentIndex). A space's `parentKey` names another space's `key`; one
  /// that names no space (or loops) imports at the top level, as do older
  /// backups, which have neither. Matches the web `nestingOrder`.
  static List<(int, int?)> nestingOrder(List<dynamic> spaces) {
    Object? field(int i, String name) {
      final s = spaces[i];
      return s is Map ? s[name] : null;
    }

    final indexOfKey = <Object, int>{};
    for (var i = 0; i < spaces.length; i++) {
      final key = field(i, 'key');
      if (key != null) indexOfKey.putIfAbsent(key, () => i);
    }
    final parentOf = <int?>[
      for (var i = 0; i < spaces.length; i++)
        switch (field(i, 'parentKey')) {
          null => null,
          final key => indexOfKey[key] == i ? null : indexOfKey[key],
        },
    ];
    final children = <int, List<int>>{};
    for (var i = 0; i < spaces.length; i++) {
      final p = parentOf[i];
      if (p != null) children.putIfAbsent(p, () => []).add(i);
    }
    final order = <(int, int?)>[];
    final placed = <int>{};
    void place(int start) {
      final queue = [start];
      while (queue.isNotEmpty) {
        final i = queue.removeAt(0);
        if (!placed.add(i)) continue;
        final p = parentOf[i];
        order.add((
          i,
          i != start && p != null && placed.contains(p) ? p : null,
        ));
        queue.addAll(children[i] ?? const []);
      }
    }

    for (var i = 0; i < spaces.length; i++) {
      if (parentOf[i] == null) place(i);
    }
    // Whatever is left is in a parent loop: break it at the top level.
    for (var i = 0; i < spaces.length; i++) {
      place(i);
    }
    return order;
  }

  static bool _isEncrypted(Object? parsed) =>
      parsed is Map &&
      parsed['encrypted'] == true &&
      parsed['data'] is String &&
      parsed['vault'] is Map;

  /// Decrypt a sealed backup's contents with [key]; null if it doesn't fit.
  static Future<Object?> _open(
    Map<dynamic, dynamic> sealed,
    List<int> key,
  ) async {
    try {
      return jsonDecode(
        await ArcheCrypto.decryptArc1(sealed['data'] as String, key),
      );
    } catch (_) {
      return null;
    }
  }

  // The web's import limits (constants.js), all checked before anything is
  // saved.
  static const _maxFileSize = 10 * 1024 * 1024;
  static const _maxSpaces = 500;
  static const _maxItemsPerSpace = 1000;
  static const _maxName = 255;
  static const _maxDescription = 2000;
  static const _maxTitle = 255;

  static String _text(Object? v, int max) {
    final s = v is String ? v.trim() : '';
    return s.length > max ? s.substring(0, max) : s;
  }

  /// Whether [content] has the shape [type]'s editor expects (as on the
  /// web). An old Markdown item, or any unknown type, is not accepted.
  static bool _validContent(String type, Map content) {
    bool list(Object? v, int max) => v is List && v.length <= max;
    return switch (type) {
      'textbox' => content['text'] is String,
      'richtext' =>
        isRichDoc(content.cast<String, dynamic>()) || content['html'] is String,
      'code' => content['code'] is String,
      'checkbox_list' ||
      'menu_list' ||
      'numbered_list' ||
      'card_list' => list(content['items'], 1000),
      'table' => list(content['columns'], 100) && list(content['rows'], 1000),
      'kanban' =>
        list(content['columns'], 50) &&
            (content['columns'] as List).every(
              (c) => c is Map && list(c['cards'], 1000),
            ),
      'whiteboard' =>
        content['elements'] is List
            ? list(content['elements'], 20000)
            : list(content['strokes'], 10000),
      _ => false,
    };
  }

  /// Validate, encrypt and insert a backup's items into a space, or onto the
  /// dashboard for a `null` [spaceId]. Items with an unknown type or malformed
  /// content are skipped rather than failing the import.
  Future<({int imported, int skipped})> _importItems(
    List<dynamic> items,
    String? spaceId,
    String userId,
  ) async {
    var skipped = 0;
    final rows = <Map<String, dynamic>>[];
    for (final it in items) {
      if (it is! Map) {
        skipped++;
        continue;
      }
      // Backups made before the Whiteboard was renamed call it 'draw'.
      final type = it['type'] == 'draw' ? 'whiteboard' : it['type'];
      final content = it['content'];
      if (type is! String || content is! Map || !_validContent(type, content)) {
        skipped++;
        continue;
      }
      final title = _text(it['title'], _maxTitle);
      final reminder = Reminder.fromJson(it['reminder']);
      final tags = it['tags'] is List
          ? (it['tags'] as List).map((e) => e.toString()).toList()
          : <String>[];
      rows.add({
        'space_id': spaceId,
        'user_id': userId,
        'type': type,
        'title': await _enc(title),
        'content': await _encJson(content),
        'tags': await _encJson(tags),
        'position': it['position'] is int ? it['position'] : rows.length,
        'pinned': it['pinned'] == true,
        'starred': it['starred'] == true,
        'color': it['color'] is String ? it['color'] : null,
        'locked': it['locked'] == true,
        'reminder': ?(reminder == null
            ? null
            : await _encJson(reminder.toJson())),
      });
    }
    if (rows.isNotEmpty) {
      await _client.from('space_items').insert(rows);
    }
    return (imported: rows.length, skipped: skipped);
  }

  /// Import an encrypted backup: re-encrypt and insert its spaces + items. A
  /// backup from another vault needs the vault PIN it was made with:
  /// [askBackupPin] is given a `check` that tries a PIN, and resolves false to
  /// cancel (then this returns null). Otherwise returns how many spaces and
  /// items were imported, and how many items were skipped (unknown type or
  /// malformed content).
  Future<({int spaces, int items, int skipped})?> importJson(
    String text, {
    Future<bool> Function(Future<bool> Function(String pin) check)?
    askBackupPin,
  }) async {
    final userId = currentUserId();
    if (userId == null) throw StateError('Not authenticated');
    // Importing needs the server: checked once, before anything is written.
    await whenOnline(() async {});
    if (text.length > _maxFileSize) {
      throw const FormatException(
        'The file is too large. The maximum size is 10MB.',
      );
    }

    final Object? file;
    try {
      file = jsonDecode(text);
    } on FormatException {
      throw const FormatException("That backup file isn't valid.");
    }
    if (!_isEncrypted(file)) {
      throw const FormatException(
        'Only encrypted ArcheSpace backups can be imported.',
      );
    }
    final sealed = file as Map;
    var contents = await _open(sealed, _masterKey);
    if (contents == null) {
      if (askBackupPin == null) {
        throw const FormatException('This backup is from another vault.');
      }
      final vault = (sealed['vault'] as Map).cast<String, dynamic>();
      final ok = await askBackupPin((pin) async {
        try {
          final key = await VaultService().unwrapWithPin(vault, pin);
          contents = await _open(sealed, key);
          return contents != null;
        } on VaultException catch (e) {
          if (e.message == 'Incorrect PIN.') return false;
          rethrow;
        }
      });
      if (!ok) return null;
    }
    final parsed = contents;
    if (parsed is! Map || parsed['spaces'] is! List) {
      throw const FormatException('The encrypted contents are damaged.');
    }
    final parsedSpaces = parsed['spaces'] as List;
    if (parsedSpaces.length > _maxSpaces) {
      throw const FormatException(
        'Too many spaces. The maximum allowed is $_maxSpaces.',
      );
    }
    if (parsedSpaces.any((s) => s is! Map)) {
      throw const FormatException(
        'Each space in the backup must be an object.',
      );
    }
    for (final s in parsedSpaces.cast<Map>()) {
      if (s['items'] is List &&
          (s['items'] as List).length > _maxItemsPerSpace) {
        final name = _text(s['name'], _maxName);
        throw FormatException(
          'Too many items in space "${name.isEmpty ? 'Imported Space' : name}". '
          'The maximum allowed is $_maxItemsPerSpace.',
        );
      }
    }
    if (parsed['items'] is List &&
        (parsed['items'] as List).length > _maxItemsPerSpace) {
      throw const FormatException(
        'Too many dashboard items. The maximum allowed is $_maxItemsPerSpace.',
      );
    }

    // Top-level spaces go after the existing ones, each in its backup order.
    final existing = await _client
        .from('spaces')
        .select('id')
        .isFilter('parent_id', null)
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);
    final placed = <String?, int>{}; // parent id -> spaces placed in it so far

    var itemsImported = 0;
    var itemsSkipped = 0;
    var spacesImported = 0;
    // Backup position -> new space id, for the sub-spaces that follow.
    final newIds = <int, String>{};

    for (final (index, parentIndex) in nestingOrder(parsedSpaces)) {
      final raw = parsedSpaces[index] as Map;
      final parentId = parentIndex == null ? null : newIds[parentIndex];
      final nth = placed[parentId] ?? 0;
      placed[parentId] = nth + 1;
      // Mobile backups carry each space's place; web ones list them in order.
      final position =
          (parentId == null ? existing.length : 0) +
          (raw['position'] is int ? raw['position'] as int : nth);

      final named = _text(raw['name'], _maxName);
      final name = named.isEmpty ? 'Imported Space' : named;
      final description = _text(raw['description'], _maxDescription);
      final color = raw['color'] is String ? raw['color'] as String : null;
      final tags = raw['tags'] is List
          ? (raw['tags'] as List).map((e) => e.toString()).toList()
          : <String>[];

      final created = await _client
          .from('spaces')
          .insert({
            'user_id': userId,
            'name': await _enc(name),
            'description': await _enc(description),
            'color': color,
            'tags': await _encJson(tags),
            'pinned': raw['pinned'] == true,
            'starred': raw['starred'] == true,
            'locked': raw['locked'] == true,
            'parent_id': parentId,
            'position': position,
          })
          .select('id')
          .single();
      final spaceId = created['id'] as String;
      newIds[index] = spaceId;
      spacesImported++;

      final items = raw['items'];
      if (items is List) {
        final result = await _importItems(items, spaceId, userId);
        itemsImported += result.imported;
        itemsSkipped += result.skipped;
      }
      // Read-only last: it refuses the items otherwise.
      if (raw['readOnly'] == true) {
        await _client
            .from('spaces')
            .update({'read_only': true})
            .eq('id', spaceId);
      }
    }

    // Dashboard items (outside any space).
    if (parsed['items'] is List) {
      final result = await _importItems(parsed['items'] as List, null, userId);
      itemsImported += result.imported;
      itemsSkipped += result.skipped;
    }
    return (
      spaces: spacesImported,
      items: itemsImported,
      skipped: itemsSkipped,
    );
  }
}
