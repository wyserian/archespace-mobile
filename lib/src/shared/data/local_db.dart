import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/util/uuid.dart';

/// Local mode's database: the same tables as the server, kept in this app's
/// private storage (one JSON file per table) and never sent anywhere. Rows hold
/// the same encrypted values the server would.
///
/// It mirrors what the database does for these tables (the web repo's
/// schema.sql): column defaults, `updated_at`, cascading deletes, the
/// read-only space guards, the vault PIN lockout and the 30-day recycle bin
/// purge. The web app's local mode works the same way.
class LocalDb implements Db {
  LocalDb(this._store);

  static final LocalDb instance = LocalDb(_FileStore());

  final LocalStore _store;
  Future<Map<String, Map<String, Map<String, dynamic>>>>? _loading;

  /// The tables and their primary keys.
  static const tables = {
    'spaces': 'id',
    'space_items': 'id',
    'user_encryption': 'user_id',
  };

  static const _binDays = 30;
  static const _pinMaxAttempts = 5;
  static const _pinLock = Duration(minutes: 5);

  static Map<String, dynamic> _defaults(String table) => switch (table) {
    'spaces' => {
      'description': '',
      'position': 0,
      'pinned': false,
      'color': null,
      'tags': <dynamic>[],
      'parent_id': null,
      'starred': false,
      'locked': false,
      'read_only': false,
      'deleted_at': null,
      'archived_at': null,
    },
    'space_items' => {
      'space_id': null,
      'title': '',
      'content': <String, dynamic>{},
      'tags': <dynamic>[],
      'reminder': null,
      'position': 0,
      'pinned': false,
      'starred': false,
      'locked': false,
      'deleted_at': null,
      'archived_at': null,
    },
    _ => {
      'wrapped_key': null,
      'recovery_salt': null,
      'recovery_wrapped_key': null,
      'pin_failed_attempts': 0,
      'pin_locked_until': null,
    },
  };

  /// The tables, loaded once (and the recycle bin purged).
  Future<Map<String, Map<String, Map<String, dynamic>>>> get _tables =>
      _loading ??= () async {
        final loaded = <String, Map<String, Map<String, dynamic>>>{};
        for (final table in tables.keys) {
          final key = tables[table]!;
          loaded[table] = {
            for (final row in await _store.read(table)) row[key] as String: row,
          };
        }
        await _purgeBin(loaded);
        return loaded;
      }();

  @override
  DbQuery from(String table) {
    if (!tables.containsKey(table)) {
      throw StateError('Table "$table" isn\'t available in local mode.');
    }
    return LocalQuery._(this, table);
  }

  /// Forget everything kept on this device.
  Future<void> erase() async {
    await _store.erase();
    _loading = null;
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  static dynamic _copy(dynamic value) => jsonDecode(jsonEncode(value));

  static bool _same(dynamic a, dynamic b) => jsonEncode(a) == jsonEncode(b);

  static PostgrestException _fail(String message, [String code = 'LOCAL']) =>
      PostgrestException(message: message, code: code);

  static final _readOnly = _fail('This space is read-only.', 'P0R01');

  Future<List<Map<String, dynamic>>> _run(LocalQuery q) async {
    final t = await _tables;
    final rows = t[q._table]!;
    final key = tables[q._table]!;
    List<Map<String, dynamic>> matching() =>
        rows.values.where((r) => q._filters.every((f) => f(r))).toList();
    switch (q._op) {
      case 'insert':
        final created = [
          for (final v in _list(q._values)) _newRow(q._table, v),
        ];
        for (final row in created) {
          if (rows.containsKey(_key(q._table, row))) {
            throw _fail('duplicate key value', '23505');
          }
          if (q._table == 'space_items' && _isReadOnly(t, row['space_id'])) {
            throw _readOnly;
          }
        }
        return _write(t, q._table, created);
      case 'upsert':
        final upserted = [
          for (final v in _list(q._values))
            if (rows[v[key]] case final existing?)
              {
                ...existing,
                ..._copy(v) as Map<String, dynamic>,
                if (q._table != 'user_encryption') 'updated_at': _now(),
              }
            else
              _newRow(q._table, v),
        ];
        return _write(t, q._table, upserted);
      case 'update':
        final updated = [
          for (final old in matching())
            _guard(t, q._table, old, {
              ...old,
              ..._copy(q._values) as Map<String, dynamic>,
            }),
        ];
        for (final row in updated) {
          if (q._table != 'user_encryption') row['updated_at'] = _now();
        }
        return _write(t, q._table, updated);
      case 'delete':
        final removed = matching();
        if (q._table == 'spaces') {
          // ON DELETE CASCADE: sub-spaces, and the items of every space.
          final ids = removed.map((r) => r['id'] as String).toSet();
          for (final space in t['spaces']!.values) {
            if (ids.contains(space['parent_id'])) {
              ids.add(space['id'] as String);
            }
          }
          await _erase(t, 'space_items', [
            for (final item in t['space_items']!.values)
              if (ids.contains(item['space_id'])) item,
          ]);
          await _erase(t, 'spaces', [for (final id in ids) ?t['spaces']![id]]);
        } else {
          await _erase(t, q._table, removed);
        }
        return removed;
      default:
        final selected = matching();
        for (final o in q._orders.reversed) {
          selected.sort((a, b) => _compare(a[o.$1], b[o.$1], o.$2));
        }
        return q._limit == null ? selected : selected.take(q._limit!).toList();
    }
  }

  static List<Map<String, dynamic>> _list(Object? values) => [
    for (final v in values is List ? values : [values])
      (v as Map).cast<String, dynamic>(),
  ];

  String _key(String table, Map<String, dynamic> row) =>
      row[tables[table]!] as String;

  Map<String, dynamic> _newRow(String table, Map<String, dynamic> values) {
    final now = _now();
    final row = {
      ..._defaults(table),
      ..._copy(values) as Map<String, dynamic>,
      'created_at': now,
    };
    if (tables[table] == 'id') row['id'] ??= newUuid();
    row['user_id'] ??= AppMode.localUserId;
    if (table != 'user_encryption') row['updated_at'] = now;
    return row;
  }

  // Ordering as Postgres does it: ascending puts nulls last, descending first.
  static int _compare(dynamic a, dynamic b, bool ascending) {
    if (a == b) return 0;
    if (a == null) return ascending ? 1 : -1;
    if (b == null) return ascending ? -1 : 1;
    final c = a is bool
        ? (a ? 1 : 0).compareTo(b == true ? 1 : 0)
        : (a as Comparable).compareTo(b);
    return ascending ? c : -c;
  }

  bool _isReadOnly(
    Map<String, Map<String, Map<String, dynamic>>> t,
    Object? spaceId,
  ) => spaceId != null && t['spaces']![spaceId]?['read_only'] == true;

  /// The read-only space guards (schema.sql, trg_*_read_only).
  Map<String, dynamic> _guard(
    Map<String, Map<String, Map<String, dynamic>>> t,
    String table,
    Map<String, dynamic> old,
    Map<String, dynamic> row,
  ) {
    if (table == 'spaces') {
      final detailsChanged = [
        'name',
        'description',
        'color',
        'tags',
        'parent_id',
      ].any((c) => !_same(old[c], row[c]));
      if (old['read_only'] == true &&
          row['read_only'] == true &&
          detailsChanged) {
        throw _readOnly;
      }
    } else if (table == 'space_items') {
      if (old['space_id'] != row['space_id']) {
        if (_isReadOnly(t, old['space_id']) ||
            _isReadOnly(t, row['space_id'])) {
          throw _readOnly;
        }
      } else if ([
            'title',
            'content',
            'tags',
            'type',
          ].any((c) => !_same(old[c], row[c])) &&
          _isReadOnly(t, row['space_id'])) {
        throw _readOnly;
      }
    }
    return row;
  }

  Future<List<Map<String, dynamic>>> _write(
    Map<String, Map<String, Map<String, dynamic>>> t,
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    for (final row in rows) {
      t[table]![_key(table, row)] = row;
    }
    await _persist(t, table);
    return rows;
  }

  Future<void> _erase(
    Map<String, Map<String, Map<String, dynamic>>> t,
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;
    for (final row in rows) {
      t[table]!.remove(_key(table, row));
    }
    await _persist(t, table);
  }

  // Saves run one at a time, so two quick changes can't race on a file.
  Future<void> _saving = Future<void>.value();

  Future<void> _persist(
    Map<String, Map<String, Map<String, dynamic>>> t,
    String table,
  ) {
    final rows = t[table]!.values.toList();
    return _saving = _saving
        .catchError((Object _) {})
        .then((_) => _store.write(table, rows));
  }

  /// The recycle bin keeps things for 30 days (purge_old_deleted_records).
  Future<void> _purgeBin(
    Map<String, Map<String, Map<String, dynamic>>> t,
  ) async {
    final cutoff = DateTime.now().subtract(const Duration(days: _binDays));
    bool expired(Map<String, dynamic> row) {
      final at = DateTime.tryParse((row['deleted_at'] ?? '').toString());
      return at != null && at.isBefore(cutoff);
    }

    await _erase(
      t,
      'space_items',
      t['space_items']!.values.where(expired).toList(),
    );
    await _erase(t, 'spaces', t['spaces']!.values.where(expired).toList());
  }

  @override
  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params}) async {
    final t = await _tables;
    final vault = t['user_encryption']![AppMode.localUserId];
    switch (fn) {
      case 'update_space_positions':
      case 'update_item_positions':
        final table = fn == 'update_space_positions' ? 'spaces' : 'space_items';
        final updates = (params?['updates'] as List?) ?? const [];
        await _write(t, table, [
          for (final u in updates.cast<Map>())
            if (t[table]![u['id']] != null)
              {
                ...t[table]![u['id']]!,
                'position': u['position'],
                'updated_at': _now(),
              },
        ]);
        return null;
      case 'get_vault_pin_lock_status':
        final until = DateTime.tryParse(
          (vault?['pin_locked_until'] ?? '').toString(),
        );
        final left = until?.difference(DateTime.now()) ?? Duration.zero;
        final locked = left > Duration.zero;
        return {
          'locked': locked,
          'retry_after_seconds': locked
              ? (left.inMilliseconds / 1000).ceil()
              : 0,
        };
      case 'record_vault_pin_unlock_failure':
        if (vault == null) return null;
        final until = DateTime.tryParse(
          (vault['pin_locked_until'] ?? '').toString(),
        );
        final lockExpired = until != null && !until.isAfter(DateTime.now());
        final attempts =
            (lockExpired
                ? 0
                : (vault['pin_failed_attempts'] as num? ?? 0).toInt()) +
            1;
        await _write(t, 'user_encryption', [
          {
            ...vault,
            'pin_failed_attempts': attempts,
            'pin_locked_until': attempts >= _pinMaxAttempts
                ? DateTime.now().add(_pinLock).toUtc().toIso8601String()
                : null,
          },
        ]);
        return null;
      case 'record_vault_pin_unlock_success':
        if (vault != null) {
          await _write(t, 'user_encryption', [
            {...vault, 'pin_failed_attempts': 0, 'pin_locked_until': null},
          ]);
        }
        return null;
      case 'log_client_event':
        return null; // Nothing is logged in local mode.
      default:
        throw _fail('Not available in local mode.');
    }
  }
}

/// A local query, built up like supabase_flutter's and run when awaited.
class LocalQuery extends DbQuery {
  LocalQuery._(this._db, this._table);

  final LocalDb _db;
  final String _table;
  String _op = 'select';
  String _columns = '*';
  String? _returning;
  Object? _values;
  final List<bool Function(Map<String, dynamic>)> _filters = [];
  final List<(String, bool)> _orders = [];
  int? _limit;
  String? _one;

  @override
  DbQuery select([String columns = '*']) {
    if (_op == 'select') {
      _columns = columns;
    } else {
      _returning = columns; // e.g. insert(...).select()
    }
    return this;
  }

  @override
  DbQuery insert(Object values) => this
    .._op = 'insert'
    .._values = values;
  @override
  DbQuery upsert(Object values) => this
    .._op = 'upsert'
    .._values = values;
  @override
  DbQuery update(Map<String, dynamic> values) => this
    .._op = 'update'
    .._values = values;
  @override
  DbQuery delete() => this.._op = 'delete';

  DbQuery _where(bool Function(Map<String, dynamic>) test) {
    _filters.add(test);
    return this;
  }

  static bool _equals(dynamic a, dynamic b) =>
      a == b || (a != null && b != null && a.toString() == b.toString());

  @override
  DbQuery eq(String column, Object value) =>
      _where((r) => _equals(r[column], value));
  @override
  DbQuery neq(String column, Object value) =>
      _where((r) => !_equals(r[column], value));
  @override
  DbQuery inFilter(String column, List<dynamic> values) =>
      _where((r) => values.any((v) => _equals(r[column], v)));
  @override
  DbQuery isFilter(String column, bool? value) =>
      _where((r) => value == null ? r[column] == null : r[column] == value);
  @override
  DbQuery not(String column, String operator, Object? value) => _where(
    (r) => operator == 'is'
        ? !(value == null ? r[column] == null : r[column] == value)
        : !_equals(r[column], value),
  );

  /// Supports the `col.eq.value` terms the app uses.
  @override
  DbQuery or(String filters) {
    final terms = [
      for (final term in filters.split(','))
        if (term.split('.') case [final col, 'eq', ...final rest])
          (col, rest.join('.')),
    ];
    return _where((r) => terms.any((t) => _equals(r[t.$1], t.$2)));
  }

  @override
  DbQuery order(String column, {bool ascending = false}) {
    _orders.add((column, ascending));
    return this;
  }

  @override
  DbQuery limit(int count) => this.._limit = count;
  @override
  DbQuery single() => this.._one = 'single';
  @override
  DbQuery maybeSingle() => this.._one = 'maybe';

  Future<dynamic>? _result;

  @override
  Future<dynamic> get result => _result ??= _execute();

  Future<dynamic> _execute() async {
    final rows = await _db._run(this);
    final columns = _op == 'select' ? _columns : _returning;
    if (columns == null) return null;
    final shaped = [for (final row in rows) _project(row, columns)];
    if (_one == null) return shaped;
    if (shaped.length == 1) return shaped.first;
    if (shaped.isEmpty && _one == 'maybe') return null;
    throw LocalDb._fail(
      'JSON object requested, multiple (or no) rows returned',
      'PGRST116',
    );
  }

  static Map<String, dynamic> _project(
    Map<String, dynamic> row,
    String columns,
  ) {
    final copy = LocalDb._copy(row) as Map<String, dynamic>;
    if (columns.trim() == '*') return copy;
    return {
      for (final col in columns.split(',').map((c) => c.trim()))
        if (col.isNotEmpty) col: copy[col],
    };
  }
}

/// Where local mode keeps its tables.
abstract class LocalStore {
  Future<List<Map<String, dynamic>>> read(String table);
  Future<void> write(String table, List<Map<String, dynamic>> rows);
  Future<void> erase();
}

/// One JSON file per table in the app's private storage, replaced atomically
/// (written beside it, then renamed) so a crash can't leave half a file.
class _FileStore implements LocalStore {
  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/local');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<List<Map<String, dynamic>>> read(String table) async {
    final file = File('${(await _dir()).path}/$table.json');
    if (!await file.exists()) return [];
    final decoded = jsonDecode(await file.readAsString());
    return [
      for (final row in decoded as List) (row as Map).cast<String, dynamic>(),
    ];
  }

  @override
  Future<void> write(String table, List<Map<String, dynamic>> rows) async {
    final dir = await _dir();
    final temp = File('${dir.path}/$table.json.tmp');
    await temp.writeAsString(jsonEncode(rows), flush: true);
    await temp.rename('${dir.path}/$table.json');
  }

  @override
  Future<void> erase() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// Keeps tables in memory only (tests).
class MemoryStore implements LocalStore {
  final Map<String, List<Map<String, dynamic>>> tables = {};

  @override
  Future<List<Map<String, dynamic>>> read(String table) async =>
      tables[table] ?? [];

  @override
  Future<void> write(String table, List<Map<String, dynamic>> rows) async =>
      tables[table] = rows;

  @override
  Future<void> erase() async => tables.clear();
}
