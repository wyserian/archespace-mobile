import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/local_db.dart';

/// The app's database: Supabase normally, or this device's own store in local
/// mode (see AppMode). Queries read and await like supabase_flutter's, so the
/// repositories work the same with either.
abstract class Db {
  static Db get instance => AppMode.isLocal ? LocalDb.instance : _RemoteDb();

  DbQuery from(String table);

  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params});
}

/// A query being built; awaiting it runs it. The result is what supabase
/// returns: a list of rows, one row (`single`/`maybeSingle`), or null.
abstract class DbQuery implements Future<dynamic> {
  DbQuery select([String columns = '*']);
  DbQuery insert(Object values);
  DbQuery upsert(Object values);
  DbQuery update(Map<String, dynamic> values);
  DbQuery delete();

  DbQuery eq(String column, Object value);
  DbQuery neq(String column, Object value);
  DbQuery inFilter(String column, List<dynamic> values);
  DbQuery isFilter(String column, bool? value);
  DbQuery not(String column, String operator, Object? value);

  /// Postgrest `or` filter, e.g. `id.eq.<id>,parent_id.eq.<id>`.
  DbQuery or(String filters);

  /// Like supabase_flutter, descending unless [ascending] is set.
  DbQuery order(String column, {bool ascending = false});
  DbQuery limit(int count);
  DbQuery single();
  DbQuery maybeSingle();

  /// Runs the query (once).
  Future<dynamic> get result;

  @override
  Stream<dynamic> asStream() => result.asStream();

  @override
  Future<dynamic> catchError(
    Function onError, {
    bool Function(Object error)? test,
  }) => result.catchError(onError, test: test);

  @override
  Future<R> then<R>(
    FutureOr<R> Function(dynamic value) onValue, {
    Function? onError,
  }) => result.then(onValue, onError: onError);

  @override
  Future<dynamic> timeout(
    Duration timeLimit, {
    FutureOr<dynamic> Function()? onTimeout,
  }) => result.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<dynamic> whenComplete(FutureOr<void> Function() action) =>
      result.whenComplete(action);
}

/// Supabase, passed straight through.
class _RemoteDb implements Db {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  DbQuery from(String table) => _RemoteQuery(_client.from(table));

  @override
  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params}) =>
      _client.rpc(fn, params: params);
}

class _RemoteQuery extends DbQuery {
  _RemoteQuery(this._builder);

  // The supabase_flutter builder at this step of the chain.
  dynamic _builder;

  DbQuery _next(dynamic builder) {
    _builder = builder;
    return this;
  }

  @override
  DbQuery select([String columns = '*']) => _next(_builder.select(columns));
  @override
  DbQuery insert(Object values) => _next(_builder.insert(values));
  @override
  DbQuery upsert(Object values) => _next(_builder.upsert(values));
  @override
  DbQuery update(Map<String, dynamic> values) => _next(_builder.update(values));
  @override
  DbQuery delete() => _next(_builder.delete());
  @override
  DbQuery eq(String column, Object value) => _next(_builder.eq(column, value));
  @override
  DbQuery neq(String column, Object value) =>
      _next(_builder.neq(column, value));
  @override
  DbQuery inFilter(String column, List<dynamic> values) =>
      _next(_builder.inFilter(column, values));
  @override
  DbQuery isFilter(String column, bool? value) =>
      _next(_builder.isFilter(column, value));
  @override
  DbQuery not(String column, String operator, Object? value) =>
      _next(_builder.not(column, operator, value));
  @override
  DbQuery or(String filters) => _next(_builder.or(filters));
  @override
  DbQuery order(String column, {bool ascending = false}) =>
      _next(_builder.order(column, ascending: ascending));
  @override
  DbQuery limit(int count) => _next(_builder.limit(count));
  @override
  DbQuery single() => _next(_builder.single());
  @override
  DbQuery maybeSingle() => _next(_builder.maybeSingle());

  Future<dynamic>? _result;

  @override
  Future<dynamic> get result =>
      _result ??= Future<dynamic>.sync(() => (_builder as Future<dynamic>));
}
