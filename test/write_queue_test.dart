import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/data/local_db.dart';
import 'package:archespace_mobile/src/shared/offline/write_queue.dart';

/// The local database, with [offline] tables that fail as with no network,
/// and a hook run the first time [table] is written to.
class _FlakyDb implements Db {
  _FlakyDb(this.inner);

  final LocalDb inner;
  final Set<String> offline = {};
  void Function()? onFirstUse;

  @override
  DbQuery from(String table) {
    if (offline.contains(table)) return _OfflineQuery();
    final hook = onFirstUse;
    onFirstUse = null;
    hook?.call();
    return inner.from(table);
  }

  @override
  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params}) =>
      inner.rpc(fn, params: params);
}

class _OfflineQuery extends DbQuery {
  @override
  Future<dynamic> get result =>
      Future.error(const SocketException('No network'));
  @override
  DbQuery select([String columns = '*']) => this;
  @override
  DbQuery insert(Object values) => this;
  @override
  DbQuery upsert(Object values) => this;
  @override
  DbQuery update(Map<String, dynamic> values) => this;
  @override
  DbQuery delete() => this;
  @override
  DbQuery eq(String column, Object value) => this;
  @override
  DbQuery neq(String column, Object value) => this;
  @override
  DbQuery inFilter(String column, List<dynamic> values) => this;
  @override
  DbQuery isFilter(String column, bool? value) => this;
  @override
  DbQuery not(String column, String operator, Object? value) => this;
  @override
  DbQuery or(String filters) => this;
  @override
  DbQuery order(String column, {bool ascending = false}) => this;
  @override
  DbQuery limit(int count) => this;
  @override
  DbQuery single() => this;
  @override
  DbQuery maybeSingle() => this;
}

void main() {
  late Directory dir;
  late _FlakyDb db;
  late WriteQueue queue;

  Map<String, dynamic> item(String title) => {
    'id': 'item-$title',
    'user_id': AppMode.localUserId,
    'type': 'textbox',
    'title': title,
    'content': '',
  };

  setUp(() async {
    AppMode.local.value = true; // the local user owns the queued rows
    dir = await Directory.systemTemp.createTemp('write_queue_test');
    db = _FlakyDb(LocalDb(MemoryStore()));
    queue = WriteQueue.test(db, dir);
  });
  tearDown(() async {
    AppMode.local.value = false;
    await dir.delete(recursive: true);
  });

  test('queues a write made offline and replays it once back online', () async {
    db.offline.add('space_items');
    expect(await queue.upsert('space_items', item('a')), isTrue);
    expect(queue.pending.value, 1);

    db.offline.clear();
    await queue.flush();
    expect(queue.pending.value, 0);
    final rows = await db.inner.from('space_items').select() as List;
    expect([for (final r in rows) r['title']], ['a']);
  });

  test('a write queued while a flush runs is kept', () async {
    db.offline.add('space_items');
    await queue.upsert('space_items', item('a'));
    db.offline.clear();

    // While the flush replays "a", another edit is queued offline.
    late Future<bool> during;
    db.offline.add('spaces');
    db.onFirstUse = () => during = queue.upsert('spaces', {'id': 's1'});
    await queue.flush();
    expect(await during, isTrue);

    expect(queue.pending.value, 1);
    final rows = await db.inner.from('space_items').select() as List;
    expect([for (final r in rows) r['title']], ['a']);
  });
}
