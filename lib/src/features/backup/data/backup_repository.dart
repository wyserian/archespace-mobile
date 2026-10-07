import 'dart:convert';

import 'package:archespace_mobile/src/features/items/domain/reminder.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/vault/data/vault_service.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';

/// JSON backup export/import, matching the web format. A backup is encrypted:
/// `{ app, version: 3, encrypted: true, exportedAt, vault, data }`, where
/// `data` is the contents `{ spaces: [...], items: [...] }` encrypted with the
/// vault key, and `vault` is that key wrapped with the vault PIN (as the
/// server stores it). So it opens as-is in the same vault, and anywhere else
/// with the vault PIN of the time. Each space carries its fields and an
/// `items` array ({ type, title, content, position, pinned, reminder }); the
/// top-level `items` are the dashboard's (no space).
class BackupRepository {
  BackupRepository(this._masterKey);

  final List<int> _masterKey;

  Db get _client => Db.instance;

  Future<String> _dec(Object? v) =>
      ArcheCrypto.decryptArc1((v ?? '') as String, _masterKey);
  Future<String> _enc(String v) => ArcheCrypto.encryptArc1(v, _masterKey);
  Future<String> _encJson(Object? v) =>
      ArcheCrypto.encryptArc1(jsonEncode(v), _masterKey);

  /// Active items of one space, or the dashboard's items (no space) for `null`,
  /// decrypted for the backup.
  Future<List<Map<String, dynamic>>> _exportItems(String? spaceId) async {
    final query = _client
        .from('space_items')
        .select('type, title, content, reminder, position, pinned, locked');
    final itemRows =
        await (spaceId == null
                ? query.isFilter('space_id', null)
                : query.eq('space_id', spaceId))
            .isFilter('deleted_at', null)
            .isFilter('archived_at', null)
            .order('position');

    final items = <Map<String, dynamic>>[];
    for (final it in itemRows) {
      final reminder = it['reminder'] is String
          ? Reminder.fromJson(jsonDecode(await _dec(it['reminder'])))
          : null;
      items.add({
        'type': it['type'],
        'title': await _dec(it['title']),
        'content': await ArcheCrypto.decryptJsonMap(it['content'], _masterKey),
        'position': it['position'],
        'pinned': it['pinned'] ?? false,
        if (it['locked'] == true) 'locked': true,
        'reminder': ?reminder?.toJson(),
      });
    }
    return items;
  }

  /// Build the encrypted backup JSON (active spaces + items). [vaultMeta] is
  /// the vault's PIN-wrapped key (VaultService.backupMeta), carried so the
  /// file opens elsewhere with the vault PIN.
  Future<String> exportJson(Map<String, String> vaultMeta) async {
    final spaceRows = await _client
        .from('spaces')
        .select('id, name, description, tags, color, pinned, locked, position')
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null)
        .order('position');

    final out = <Map<String, dynamic>>[];
    for (final s in spaceRows) {
      out.add({
        'name': await _dec(s['name']),
        'description': await _dec(s['description']),
        'color': s['color'],
        'tags': await ArcheCrypto.decryptTags(s['tags'], _masterKey),
        'pinned': s['pinned'] ?? false,
        if (s['locked'] == true) 'locked': true,
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
    return const JsonEncoder.withIndent('  ').convert(payload);
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

  /// Validate, encrypt and insert a backup's items into a space, or onto the
  /// dashboard for a `null` [spaceId]. Items with an unknown type or malformed
  /// content are skipped rather than failing the import.
  Future<({int imported, int skipped})> _importItems(
    List<dynamic> items,
    String? spaceId,
    String userId,
    Set<String> knownTypes,
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
      if (type is! String || !knownTypes.contains(type)) {
        skipped++;
        continue;
      }
      if (content is! Map) {
        skipped++;
        continue;
      }
      final title = it['title'] is String ? (it['title'] as String).trim() : '';
      final reminder = Reminder.fromJson(it['reminder']);
      rows.add({
        'space_id': spaceId,
        'user_id': userId,
        'type': type,
        'title': await _enc(title),
        'content': await _encJson(content),
        'position': it['position'] is int ? it['position'] : rows.length,
        'pinned': it['pinned'] == true,
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

    final sealed = jsonDecode(text);
    if (!_isEncrypted(sealed)) {
      throw const FormatException(
        'Only encrypted ArcheSpace backups can be imported.',
      );
    }
    sealed as Map;
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

    final existing = await _client
        .from('spaces')
        .select('id')
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);
    var spacePos = existing.length;

    // An old Markdown item isn't accepted: the database no longer takes it.
    final knownTypes = kItemTypes
        .map((d) => d.type)
        .where((t) => t != 'markdown')
        .toSet();
    var itemsImported = 0;
    var itemsSkipped = 0;
    var spacesImported = 0;

    for (final raw in parsedSpaces) {
      if (raw is! Map) continue;

      final rawName = raw['name'];
      final name = (rawName is String && rawName.trim().isNotEmpty)
          ? rawName.trim()
          : 'Imported Space';
      final description = raw['description'] is String
          ? (raw['description'] as String).trim()
          : '';
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
            'locked': raw['locked'] == true,
            'position': spacePos++,
          })
          .select('id')
          .single();
      final spaceId = created['id'] as String;
      spacesImported++;

      final items = raw['items'];
      if (items is! List) continue;
      final result = await _importItems(items, spaceId, userId, knownTypes);
      itemsImported += result.imported;
      itemsSkipped += result.skipped;
    }

    // Dashboard items (outside any space).
    if (parsed['items'] is List) {
      final result = await _importItems(
        parsed['items'] as List,
        null,
        userId,
        knownTypes,
      );
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
