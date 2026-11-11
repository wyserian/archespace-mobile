import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/data/local_db.dart';
import 'package:archespace_mobile/src/shared/data/outbox.dart';
import 'package:archespace_mobile/src/shared/util/errors.dart';
import 'package:archespace_mobile/src/shared/util/uuid.dart';

/// Thrown by work that needs the server ([OfflineDb.online]) when it can't be
/// reached.
class OfflineException implements Exception {
  const OfflineException([
    this.message = "You're offline - reconnect to do this.",
  ]);
  final String message;
  @override
  String toString() => message;
}

/// What a sync couldn't land as made: edits kept as copies (made on a version
/// that changed meanwhile), changes the server refused (read-only), and ones
/// it couldn't save at all.
typedef SyncReport = ({int copied, int refused, int lost});

/// The database when signed in to an account.
///
/// Spaces and items live in an offline copy on this device: the account's
/// rows exactly as the server stores them (encrypted), kept by the local-mode
/// engine ([LocalDb]), which applies the same defaults and rules as the
/// database. Every screen reads the copy, so it opens at once with or
/// without a connection. Every change goes to the copy first and into the
/// [Outbox]; a [sync] sends the outbox to the server, then brings the copy up
/// to date with what changed there. Everything else (auth, the vault) goes
/// straight to the server. The web app's offlineCopy.js works the same way.
///
/// When the same thing changed on two devices: an item's text or content
/// edited here on a version that changed meanwhile is kept as a copy beside
/// it; any other change made last wins. Deleting for good needs the server:
/// it sends what's waiting first, then deletes there, then here.
class OfflineDb implements Db {
  OfflineDb(
    this._remote, {
    required this._openCopy,
    required this._openOutbox,
    required this._currentUser,
    required this._signedInFully,
  });

  static final OfflineDb instance = OfflineDb(
    RemoteDb(),
    openCopy: (id) => LocalDb(FileStore('copy_$id'), userId: id),
    openOutbox: FileOutbox.new,
    currentUser: currentUserId,
    // With two-factor pending the server shows nothing and takes nothing.
    signedInFully: () {
      final aal = Supabase.instance.client.auth.mfa
          .getAuthenticatorAssuranceLevel();
      return !(aal.currentLevel == AuthenticatorAssuranceLevels.aal1 &&
          aal.nextLevel == AuthenticatorAssuranceLevels.aal2);
    },
  );

  static const _synced = {'spaces', 'space_items'};
  static const _loggedRpc = {'update_space_positions', 'update_item_positions'};
  static const _page = 1000; // rows per request, the server's most
  static const _idChunk = 100; // ids per follow-up request
  // A request with no answer by then counts as a network failure, so a
  // connection that's up but goes nowhere is noticed quickly.
  static const _timeout = Duration(seconds: 10);
  static const _afterChange = Duration(milliseconds: 400);

  final Db _remote;
  final LocalDb Function(String userId) _openCopy;
  final Outbox Function(String userId) _openOutbox;
  final String? Function() _currentUser;
  final bool Function() _signedInFully;

  String? _userId;
  String? _lastUserId; // kept past sign-out, for [erase]
  LocalDb? _copy;
  Outbox? _outbox;

  /// Whether the server answered the last sync (for the offline banner).
  final ValueNotifier<bool> reachable = ValueNotifier<bool>(true);

  /// Bumped whenever a sync changed the copy, so the lists reload.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// How many changes wait to be sent.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  /// Told after a sync with changes that didn't land as made.
  void Function(SyncReport report)? onReport;

  /// Titles the copy kept of a conflicting edit (the app holds the key).
  Future<String> Function(String title) copyTitle = (title) async => title;

  // The copy follows the signed-in account.
  void _follow() {
    final id = _currentUser();
    if (id == _userId) return;
    _userId = id;
    if (id != null) _lastUserId = id;
    _copy = id == null ? null : _openCopy(id);
    _outbox = id == null ? null : _openOutbox(id);
    _firstSync = null;
    pending.value = 0;
    if (_outbox case final outbox?) {
      outbox.all().then((ops) {
        if (_outbox == outbox) pending.value = ops.length;
      });
    }
  }

  @override
  DbQuery from(String table) {
    _follow();
    return _copy != null && _synced.contains(table)
        ? _SyncedQuery(this, table)
        : _remote.from(table);
  }

  @override
  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params}) async {
    _follow();
    final copy = _copy;
    if (copy == null) return _remote.rpc(fn, params: params);
    if (_loggedRpc.contains(fn)) {
      final result = await copy.rpc(fn, params: params);
      await _logged({'rpc': fn, 'params': params});
      return result;
    }
    if (fn == 'purge_expired') {
      // The server's own, best effort; the copy's at once.
      unawaited(_remote.rpc(fn, params: params).then((_) {}, onError: (_) {}));
      return copy.rpc(fn, params: params);
    }
    return _remote.rpc(fn, params: params);
  }

  // A copy never filled yet waits for its first sync before answering, so a
  // new device doesn't show an empty account meanwhile.
  Future<void>? _firstSync;

  Future<dynamic> _run(_SyncedQuery query) async {
    final copy = _copy!;
    if (query.op == 'delete') {
      return online(() async {
        final result = await _apply(
          _remote,
          query.table,
          query.calls,
        ).timeout(_timeout);
        await _apply(copy, query.table, query.calls);
        return result;
      }, refresh: false);
    }
    if (query.op == 'select' && !await _outbox!.filled()) {
      await (_firstSync ??= sync());
    }
    final op = query.op == 'select' ? null : await _describe(query);
    final result = await _apply(copy, query.table, query.calls);
    if (op != null) await _logged(op);
    return _strip(result);
  }

  Timer? _soon;

  Future<void> _logged(Map<String, dynamic> op) async {
    await _outbox!.add(op);
    pending.value++;
    _soon?.cancel();
    _soon = Timer(_afterChange, sync);
  }

  // What a change sends, and for an edit of an item's text or content, the
  // version it was made on and what a copy of it would hold.
  Future<Map<String, dynamic>> _describe(_SyncedQuery query) async {
    final op = <String, dynamic>{'table': query.table, 'calls': query.calls};
    if (query.table != 'space_items' || query.op != 'update') return op;
    final values = query.calls.firstWhere((c) => c[0] == 'update')[1] as Map;
    final id = query.calls
        .where((c) => c[0] == 'eq' && c[1] == 'id')
        .map((c) => c[2])
        .firstOrNull;
    if (id == null ||
        !(values.containsKey('title') || values.containsKey('content'))) {
      return op;
    }
    final row = (await _copy!.rowsOf('space_items'))[id];
    final base = row?['_synced'];
    if (row == null || base == null) return op;
    return {
      ...op,
      'target': id,
      'base': base,
      'copy': {
        'space_id': row['space_id'],
        'type': row['type'],
        'title': row['title'],
        'content': row['content'],
      },
    };
  }

  // The copy's rows carry `_synced`, the server's updated_at when last
  // synced; the app never sees it.
  static dynamic _strip(dynamic result) {
    Map<String, dynamic> clean(Map row) =>
        {...row.cast<String, dynamic>()}..remove('_synced');
    if (result is List) return [for (final r in result) clean(r as Map)];
    if (result is Map) return clean(result);
    return result;
  }

  // Sending

  // One sync at a time (and server-only work waits its turn).
  Future<void> _last = Future.value();
  Future<T> _exclusive<T>(Future<T> Function() work) {
    final run = _last.then((_) => work());
    _last = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Null when it landed; else how it ended. A network failure is thrown,
  /// leaving it, and everything after it, for the next sync.
  String? _outcome(Object error) {
    if (isNetworkError(error)) throw error;
    final code = error is PostgrestException ? error.code : null;
    if (code == '23505') return null; // sent before, its answer lost
    return code == 'P0R01' ? 'refused' : 'lost';
  }

  Future<String?> _send(Map<String, dynamic> op) async {
    try {
      if (op['rpc'] case final String fn) {
        await _remote
            .rpc(fn, params: (op['params'] as Map?)?.cast<String, dynamic>())
            .timeout(_timeout);
        return null;
      }
      final table = op['table'] as String;
      final calls = (op['calls'] as List).cast<List<dynamic>>();
      final base = op['base'];
      if (base == null) {
        await _apply(_remote, table, calls).timeout(_timeout);
        return null;
      }
      // Only if still on the version it was made on (filters go before the
      // select, which ends a query).
      final landed =
          await _apply(_remote, table, [
                for (final c in calls)
                  if (c[0] != 'select') c,
                ['eq', 'updated_at', base],
                ['select', 'id, updated_at'],
              ]).timeout(_timeout)
              as List;
      if (landed.isNotEmpty) {
        await _rebase(
          op['target'] as String,
          base,
          (landed.first as Map)['updated_at'],
        );
        return null;
      }
      return await _saveCopy(op);
    } catch (e) {
      return _outcome(e);
    }
  }

  // The item changed elsewhere (or is gone): keep this edit as a new item
  // beside it, or on the dashboard if its space is gone too.
  Future<String> _saveCopy(Map<String, dynamic> op) async {
    final calls = (op['calls'] as List).cast<List<dynamic>>();
    final values = calls.firstWhere((c) => c[0] == 'update')[1] as Map;
    final copy = op['copy'] as Map;
    final row = {
      'id': newUuid(),
      'type': copy['type'],
      'title': await copyTitle((values['title'] ?? copy['title']) as String),
      'content': values['content'] ?? copy['content'],
    };
    final spaceId = copy['space_id'];
    for (final space in [?spaceId, null]) {
      try {
        await _remote
            .from('space_items')
            .insert({...row, 'space_id': space})
            .timeout(_timeout);
        return 'copied';
      } catch (e) {
        if (isNetworkError(e)) rethrow;
        if (e is PostgrestException && e.code == 'P0R01') return 'refused';
      }
    }
    return 'lost';
  }

  // An edit landed as [version]: later edits of the item made here build on
  // it, not on the version it replaced.
  Future<void> _rebase(String id, Object oldBase, Object? version) async {
    final rows = await _copy!.rowsOf('space_items');
    if (rows[id] case final row?) {
      row['_synced'] = version;
      await _copy!.saveTable('space_items');
    }
    for (final op in await _outbox!.all()) {
      if (op['target'] == id && op['base'] == oldBase) {
        await _outbox!.put({...op, 'base': version});
      }
    }
  }

  Future<void> _push() async {
    var copied = 0, refused = 0, lost = 0;
    for (
      var ops = await _outbox!.all();
      ops.isNotEmpty;
      ops = await _outbox!.all()
    ) {
      final end = await _send(ops.first);
      await _outbox!.remove(ops.first['seq'] as int);
      pending.value = ops.length - 1;
      switch (end) {
        case 'copied':
          copied++;
        case 'refused':
          refused++;
        case 'lost':
          lost++;
      }
    }
    if (copied + refused + lost > 0) {
      onReport?.call((copied: copied, refused: refused, lost: lost));
    }
  }

  // Receiving

  Future<List<Map<String, dynamic>>> _pages(
    String table,
    String columns,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (var from = 0; ; from += _page) {
      final page =
          await _remote
                  .from(table)
                  .select(columns)
                  .order('id', ascending: true)
                  .range(from, from + _page - 1)
                  .timeout(_timeout)
              as List;
      rows.addAll(page.cast<Map>().map((r) => r.cast<String, dynamic>()));
      if (page.length < _page) return rows;
    }
  }

  /// The ids a waiting change touches, so a sync leaves them as they are here.
  static Set<Object?> _pendingIds(List<Map<String, dynamic>> ops) {
    final ids = <Object?>{};
    for (final op in ops) {
      ids.add(op['target']);
      for (final u
          in ((op['params'] as Map?)?['updates'] as List?) ?? const []) {
        ids.add((u as Map)['id']);
      }
      for (final c in (op['calls'] as List?) ?? const []) {
        final call = c as List;
        if (call[0] == 'insert' || call[0] == 'upsert') {
          final values = call[1];
          for (final v in values is List ? values : [values]) {
            ids.add((v as Map)['id']);
          }
        }
        if (call[0] == 'eq' && call[1] == 'id') ids.add(call[2]);
        if (call[0] == 'inFilter' && call[1] == 'id') {
          ids.addAll(call[2] as List);
        }
      }
    }
    return ids..remove(null);
  }

  // Bring the copy up to date: rows new or changed on the server come in,
  // rows gone from it go, except those with a change still waiting here.
  Future<void> _pull() async {
    final copy = _copy!;
    final pendingIds = _pendingIds(await _outbox!.all());
    var changed = false;
    for (final table in _synced) {
      final heads = await _pages(table, 'id, updated_at');
      final local = await copy.rowsOf(table);
      final stale = [
        for (final h in heads)
          if (!pendingIds.contains(h['id']) &&
              local[h['id']]?['_synced'] != h['updated_at'])
            h['id'] as String,
      ];
      var updated = 0;
      for (var i = 0; i < stale.length; i += _idChunk) {
        final rows =
            await _remote
                    .from(table)
                    .select('*')
                    .inFilter(
                      'id',
                      stale.sublist(i, min(i + _idChunk, stale.length)),
                    )
                    .timeout(_timeout)
                as List;
        for (final row in rows.cast<Map>()) {
          final r = row.cast<String, dynamic>();
          local[r['id'] as String] = {...r, '_synced': r['updated_at']};
          updated++;
        }
      }
      final live = {for (final h in heads) h['id']};
      final gone = [
        for (final id in local.keys)
          if (!live.contains(id) && !pendingIds.contains(id)) id,
      ];
      for (final id in gone) {
        local.remove(id);
      }
      if (updated > 0 || gone.isNotEmpty) {
        await copy.saveTable(table);
        changed = true;
      }
    }
    await _outbox!.setFilled(true);
    if (changed) changes.value++;
  }

  Future<void>? _running;
  var _again = false;

  /// Send what waits, then bring the copy up to date. One at a time; one asked
  /// for meanwhile runs right after. Never throws: offline, [reachable] says so.
  Future<void> sync() {
    _follow();
    if (_copy == null) return Future.value();
    if (_running case final running?) {
      _again = true;
      return running;
    }
    return _running = () async {
      try {
        do {
          _again = false;
          if (!_signedInFully()) return;
          await _exclusive(() async {
            await _push();
            await _pull();
          });
          reachable.value = true;
        } while (_again);
      } catch (e) {
        if (!isNetworkError(e)) debugPrint('Sync failed: $e');
        reachable.value = false;
      } finally {
        _running = null;
      }
    }();
  }

  /// Run [work] against the server once everything waiting is sent (and,
  /// with [refresh], the copy is up to date): for what must not act on an old
  /// copy. Throws [OfflineException] when the server can't be reached.
  Future<T> online<T>(Future<T> Function() work, {bool refresh = true}) async {
    _follow();
    if (_copy == null) return work();
    if (!_signedInFully()) {
      throw const OfflineException('Finish signing in first.');
    }
    try {
      await _exclusive(() async {
        await _push();
        if (refresh) await _pull();
      });
    } catch (e) {
      if (isNetworkError(e)) {
        reachable.value = false;
        throw const OfflineException();
      }
      rethrow;
    }
    return work();
  }

  /// Delete the last account's copy (signing out). Changes not sent yet stay
  /// in the outbox, which holds only ciphertext, and go out at the next
  /// sign-in. Waits for a running sync, so it can't write the rows back.
  Future<void> erase() => _exclusive(() async {
    final id = _lastUserId;
    if (id == null) return;
    final current = id == _userId;
    final copy = current ? _copy! : _openCopy(id);
    await (current ? _outbox! : _openOutbox(id)).setFilled(false);
    for (final table in _synced) {
      (await copy.rowsOf(table)).clear();
      await copy.saveTable(table);
    }
  });

  /// Item edits made offline before the offline copy waited in this queue
  /// file; any of this account's left from then go out through the copy,
  /// once.
  Future<void> adoptOldQueue() async {
    _follow();
    final userId = _userId;
    if (userId == null) return;
    try {
      final base = await getApplicationSupportDirectory();
      final file = File('${base.path}/offline/queue.json');
      if (!await file.exists()) return;
      final ops = (jsonDecode(await file.readAsString()) as List).cast<Map>();
      final kept = <Map>[];
      for (final op in ops) {
        final row = (op['row'] as Map).cast<String, dynamic>();
        if (row['user_id'] != null && row['user_id'] != userId) {
          kept.add(op);
          continue;
        }
        await from(op['table'] as String).upsert(row);
      }
      if (kept.isEmpty) {
        await file.delete();
      } else {
        await file.writeAsString(jsonEncode(kept));
      }
    } catch (e) {
      debugPrint('Old offline queue not adopted: $e');
    }
  }
}

/// Run [work] that must reach the server (see [OfflineDb.online]); local mode
/// has no server to wait for.
Future<T> whenOnline<T>(Future<T> Function() work) =>
    AppMode.isLocal ? work() : OfflineDb.instance.online(work);

/// Rebuild a recorded query on [db]: each step is `[method, ...args]`.
DbQuery _apply(Db db, String table, List<List<dynamic>> calls) {
  var q = db.from(table);
  for (final c in calls) {
    q = switch (c[0]) {
      'select' => q.select(c[1] as String),
      'insert' => q.insert(c[1] as Object),
      'upsert' => q.upsert(c[1] as Object),
      'update' => q.update((c[1] as Map).cast<String, dynamic>()),
      'delete' => q.delete(),
      'eq' => q.eq(c[1] as String, c[2] as Object),
      'neq' => q.neq(c[1] as String, c[2] as Object),
      'inFilter' => q.inFilter(c[1] as String, c[2] as List),
      'isFilter' => q.isFilter(c[1] as String, c[2] as bool?),
      'not' => q.not(c[1] as String, c[2] as String, c[3]),
      'or' => q.or(c[1] as String),
      'order' => q.order(c[1] as String, ascending: c[2] as bool),
      'limit' => q.limit(c[1] as int),
      'range' => q.range(c[1] as int, c[2] as int),
      'single' => q.single(),
      'maybeSingle' => q.maybeSingle(),
      _ => throw StateError('Unknown query step ${c[0]}'),
    };
  }
  return q;
}

/// A query on a synced table, recorded as it's built and run when awaited.
class _SyncedQuery extends DbQuery {
  _SyncedQuery(this._db, this.table);

  final OfflineDb _db;
  final String table;
  String op = 'select';
  final List<List<dynamic>> calls = [];

  DbQuery _step(List<dynamic> call) {
    calls.add(call);
    return this;
  }

  // A new row gets its id here, so the copy and the server share it.
  static Object _withIds(Object values) {
    Map<String, dynamic> one(Map v) => {
      ...v.cast<String, dynamic>(),
      if (v['id'] == null) 'id': newUuid(),
    };
    return values is List
        ? [for (final v in values) one(v as Map)]
        : one(values as Map);
  }

  @override
  DbQuery select([String columns = '*']) => _step(['select', columns]);
  @override
  DbQuery insert(Object values) {
    op = 'insert';
    return _step(['insert', _withIds(values)]);
  }

  @override
  DbQuery upsert(Object values) {
    op = 'upsert';
    return _step(['upsert', _withIds(values)]);
  }

  @override
  DbQuery update(Map<String, dynamic> values) {
    op = 'update';
    return _step(['update', values]);
  }

  @override
  DbQuery delete() {
    op = 'delete';
    return _step(['delete']);
  }

  @override
  DbQuery eq(String column, Object value) => _step(['eq', column, value]);
  @override
  DbQuery neq(String column, Object value) => _step(['neq', column, value]);
  @override
  DbQuery inFilter(String column, List<dynamic> values) =>
      _step(['inFilter', column, values]);
  @override
  DbQuery isFilter(String column, bool? value) =>
      _step(['isFilter', column, value]);
  @override
  DbQuery not(String column, String operator, Object? value) =>
      _step(['not', column, operator, value]);
  @override
  DbQuery or(String filters) => _step(['or', filters]);
  @override
  DbQuery order(String column, {bool ascending = false}) =>
      _step(['order', column, ascending]);
  @override
  DbQuery limit(int count) => _step(['limit', count]);
  @override
  DbQuery range(int from, int to) => _step(['range', from, to]);
  @override
  DbQuery single() => _step(['single']);
  @override
  DbQuery maybeSingle() => _step(['maybeSingle']);

  Future<dynamic>? _result;

  @override
  Future<dynamic> get result => _result ??= _db._run(this);
}
