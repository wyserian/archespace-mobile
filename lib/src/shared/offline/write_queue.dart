import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/util/errors.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/util/uuid.dart';

/// A durable queue of pending writes for offline support. Each entry is an
/// **upsert** into a table (rows carry a client-generated id); only ciphertext
/// is persisted.
///
/// An edit of an existing item also carries [base], the version it was made
/// on: replayed, it lands only if the item is still on that version, and is
/// otherwise saved as a new item titled [copyTitle], so a newer edit made
/// elsewhere is never overwritten. A later write of a row already queued
/// replaces it. Writes of another account wait until it's signed in again.
///
/// Scope: covers the item create/edit path. Callers use [upsert]; when the
/// network is down the op is stored and replayed by [flush] on reconnect.
class WriteQueue {
  WriteQueue._() : _testDb = null, _testDir = null;
  static final WriteQueue instance = WriteQueue._();

  /// A queue on [db], kept in [dir] (tests).
  @visibleForTesting
  WriteQueue.test(Db db, Directory dir) : _testDb = db, _testDir = dir;

  final Db? _testDb;
  final Directory? _testDir;
  Db get _db => _testDb ?? Db.instance;

  /// Number of pending ops; UIs can watch this to show a "syncing" hint.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  bool _flushing = false;

  // Changes to the queue file, one at a time: a write queued while a flush
  // runs is never lost to the flush writing back what it read.
  Future<void> _last = Future.value();
  Future<T> _exclusive<T>(Future<T> Function() change) {
    final run = _last.then((_) => change());
    _last = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<File> _file() async {
    final dir =
        _testDir ??
        Directory('${(await getApplicationSupportDirectory()).path}/offline');
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
  /// (offline), false if it committed online, when [row] also gets the saved
  /// `updated_at` (for the caller's cache, as the base of a later edit).
  /// Non-network errors are rethrown.
  Future<bool> upsert(
    String table,
    Map<String, dynamic> row, {
    String? base,
    String? copyTitle,
  }) async {
    try {
      final saved = await _db.from(table).upsert(row).select('updated_at');
      if (saved is List && saved.isNotEmpty) {
        row['updated_at'] = (saved.first as Map)['updated_at'];
      }
      return false;
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      await _exclusive(() async {
        final ops = await _read();
        final same = ops.indexWhere(
          (op) => op['table'] == table && (op['row'] as Map)['id'] == row['id'],
        );
        if (same >= 0) {
          // Keep what the first write set (a new item's position) and the
          // version the first edit was made on.
          final first = ops[same];
          ops[same] = {
            ...first,
            'row': {...(first['row'] as Map<String, dynamic>), ...row},
            'copyTitle': copyTitle ?? first['copyTitle'],
          };
        } else {
          ops.add({
            'table': table,
            'row': row,
            'base': ?base,
            'copyTitle': ?copyTitle,
          });
        }
        await _writeAll(ops);
      });
      return true;
    }
  }

  /// Replay queued ops in order. Stops on the first network error (still
  /// offline); drops any op that fails permanently so it can't block the queue.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final ops = await _read();
      // Each op applied or dropped, as it was read.
      final done = <String>{};
      final userId = currentUserId();
      for (final op in ops) {
        final row = op['row'] as Map<String, dynamic>;
        if (row['user_id'] != null && row['user_id'] != userId) continue;
        try {
          await _apply(op['table'] as String, row, op);
        } catch (e) {
          if (isNetworkError(e)) break; // still offline: try again next time
          // Permanent failure (e.g. row's parent gone): drop it, so it can't
          // block the queue.
        }
        done.add(jsonEncode(op));
        // Read again: writes queued meanwhile stay, as does one changed since.
        await _exclusive(
          () async => _writeAll([
            for (final queued in await _read())
              if (!done.contains(jsonEncode(queued))) queued,
          ]),
        );
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _apply(
    String table,
    Map<String, dynamic> row,
    Map<String, dynamic> op,
  ) async {
    final base = op['base'] as String?;
    if (base == null) {
      await _db.from(table).upsert(row);
      return;
    }
    final updated = await _db
        .from(table)
        .update({'title': row['title'], 'content': row['content']})
        .eq('id', row['id'] as Object)
        .eq('updated_at', base)
        .select('id');
    if (updated is List && updated.isNotEmpty) return;
    // Changed elsewhere, or gone: keep this edit as a new item beside it, on
    // the dashboard if its space is gone too.
    final copy = {
      ...row,
      'id': newUuid(),
      'title': op['copyTitle'] ?? row['title'],
    };
    try {
      await _db.from(table).insert(copy);
    } catch (e) {
      if (isNetworkError(e) || copy['space_id'] == null) rethrow;
      await _db.from(table).insert({...copy, 'space_id': null});
    }
  }
}
