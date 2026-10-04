import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:archespace_mobile/src/shared/util/errors.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';

/// A durable queue of pending writes for offline support. Each entry is an
/// idempotent **upsert** into a table (rows carry a client-generated id), so
/// replaying is always safe. Only ciphertext is persisted.
///
/// Scope: covers the item create/edit path. Callers use [upsert]; when the
/// network is down the op is stored and replayed by [flush] on reconnect.
class WriteQueue {
  WriteQueue._();
  static final WriteQueue instance = WriteQueue._();

  /// Number of pending ops; UIs can watch this to show a "syncing" hint.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  bool _flushing = false;

  Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/offline');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/queue.json');
  }

  Future<List<Map<String, dynamic>>> _read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) return decoded.cast<Map<String, dynamic>>();
    } catch (_) {}
    return [];
  }

  Future<void> _writeAll(List<Map<String, dynamic>> ops) async {
    try {
      await (await _file()).writeAsString(jsonEncode(ops));
    } catch (_) {}
    pending.value = ops.length;
  }

  Future<void> init() async {
    pending.value = (await _read()).length;
  }

  /// Upsert [row] into [table]. Returns true if it was queued for later
  /// (offline), false if it committed online. Non-network errors are rethrown.
  Future<bool> upsert(String table, Map<String, dynamic> row) async {
    try {
      await Db.instance.from(table).upsert(row);
      return false;
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      final ops = await _read();
      ops.add({'table': table, 'row': row});
      await _writeAll(ops);
      return true;
    }
  }

  /// Replay queued ops in order. Stops on the first network error (still
  /// offline); drops any op that fails permanently so it can't block the queue.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      var ops = await _read();
      while (ops.isNotEmpty) {
        final op = ops.first;
        try {
          await Db.instance
              .from(op['table'] as String)
              .upsert(op['row'] as Map<String, dynamic>);
        } catch (e) {
          if (isNetworkError(e)) break; // try again next time
          // Permanent failure (e.g. row's parent gone): drop and continue.
        }
        ops = ops.sublist(1);
        await _writeAll(ops);
      }
    } finally {
      _flushing = false;
    }
  }
}
