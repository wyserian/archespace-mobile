import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:archespace_mobile/src/shared/data/expiry.dart';

/// A tiny JSON-file cache under the app support directory, used to keep the
/// last-seen **encrypted** rows for offline reads. Only ciphertext is written
/// to disk - decryption still needs the in-memory master key - so this does not
/// weaken the zero-knowledge model.
class CacheStore {
  const CacheStore._();

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _file(String key) async =>
      File('${(await _dir()).path}/$key.json');

  static Future<void> write(String key, Object data) async {
    try {
      await (await _file(key)).writeAsString(jsonEncode(data));
    } catch (_) {
      // A failed cache write must never break a successful fetch.
    }
  }

  static Future<Object?> read(String key) async {
    try {
      final file = await _file(key);
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Read a cached list of rows (empty if absent / not a list).
  /// The cached rows, without any whose self-destruct time has passed (the
  /// server hides those too).
  static Future<List<Map<String, dynamic>>> readRows(String key) async {
    final data = await read(key);
    if (data is List) return withoutExpired(data.cast<Map<String, dynamic>>());
    return [];
  }

  /// Insert or merge a row (by `id`) into a cached list, for optimistic
  /// offline updates.
  static Future<void> upsertRow(String key, Map<String, dynamic> row) async {
    final rows = await readRows(key);
    final index = rows.indexWhere((r) => r['id'] == row['id']);
    if (index >= 0) {
      rows[index] = {...rows[index], ...row};
    } else {
      rows.add(row);
    }
    await write(key, rows);
  }

  /// Remove a single cached key (e.g. the vault metadata on a vault reset).
  static Future<void> delete(String key) async {
    try {
      final file = await _file(key);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Wipe the whole cache (e.g. on sign-out, so the next account can't read it).
  static Future<void> clear() async {
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
