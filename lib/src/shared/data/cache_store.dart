import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A tiny JSON-file cache under the app support directory, used to keep the
/// vault metadata for unlocking offline. Only ciphertext and wrapped keys are
/// written to disk - decryption still needs the PIN - so this does not weaken
/// the zero-knowledge model.
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
