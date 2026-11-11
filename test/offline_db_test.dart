import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/shared/data/db.dart';
import 'package:archespace_mobile/src/shared/data/local_db.dart';
import 'package:archespace_mobile/src/shared/data/offline_db.dart';
import 'package:archespace_mobile/src/shared/data/outbox.dart';

// Mirrors the web offlineCopy.test.js. The "server" is the local engine too;
// while [_Server.down], every request fails as with no network.
class _Server implements Db {
  final db = LocalDb(MemoryStore(), userId: 'u');
  bool down = false;

  @override
  DbQuery from(String table) => down ? _Offline() : db.from(table);

  @override
  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params}) => down
      ? Future.error(const SocketException('No network'))
      : db.rpc(fn, params: params);
}

class _Offline extends DbQuery {
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
  DbQuery range(int from, int to) => this;
  @override
  DbQuery single() => this;
  @override
  DbQuery maybeSingle() => this;
}

void main() {
  late _Server server;
  late OfflineDb db;

  Future<List<Map>> rows(Db on, [String table = 'space_items']) async =>
      (await on.from(table).select().order('created_at', ascending: true)
              as List)
          .cast<Map>();
  Future<void> tick() => Future.delayed(const Duration(milliseconds: 5));

  setUp(() {
    server = _Server();
    final outbox = MemoryOutbox();
    db = OfflineDb(
      server,
      openCopy: (id) => LocalDb(MemoryStore(), userId: id),
      openOutbox: (_) => outbox,
      currentUser: () => 'u',
      signedInFully: () => true,
    );
  });

  test('saves changes on the device and sends them when it syncs', () async {
    server.down = true;
    final item = await db
        .from('space_items')
        .insert({'type': 'textbox', 'title': 'a'})
        .select()
        .single();
    expect([for (final r in await rows(db)) r['title']], ['a']);
    await db.sync();
    expect(db.pending.value, 1);
    expect(db.reachable.value, isFalse);

    server.down = false;
    await db.sync();
    expect(db.pending.value, 0);
    expect(
      [
        for (final r in await rows(server)) [r['id'], r['title']],
      ],
      [
        [item['id'], 'a'],
      ],
    );
    expect(db.reachable.value, isTrue);
  });

  test('brings in what changed on the server and drops what went', () async {
    final row = await server
        .from('spaces')
        .insert({'name': 'S'})
        .select()
        .single();
    await db.sync();
    expect([for (final r in await rows(db, 'spaces')) r['name']], ['S']);
    expect((await rows(db, 'spaces')).single.containsKey('_synced'), isFalse);

    await tick();
    await server.from('spaces').update({'name': 'S2'}).eq('id', row['id']);
    await db.sync();
    expect([for (final r in await rows(db, 'spaces')) r['name']], ['S2']);

    await server.from('spaces').delete().eq('id', row['id']);
    await db.sync();
    expect(await rows(db, 'spaces'), isEmpty);
  });

  test('keeps an edit made on an older version as a copy', () async {
    db.copyTitle = (title) async => '$title (offline copy)';
    final item = await db
        .from('space_items')
        .insert({'type': 'textbox', 'title': 'v1'})
        .select()
        .single();
    await db.sync();

    await tick();
    await server
        .from('space_items')
        .update({'title': 'theirs'})
        .eq('id', item['id']);
    await db.from('space_items').update({'title': 'mine'}).eq('id', item['id']);
    await db.sync();

    final titles = [for (final r in await rows(server)) r['title']]..sort();
    expect(titles, ['mine (offline copy)', 'theirs']);
  });

  test('sends a run of edits to one item as one line of versions', () async {
    final item = await db
        .from('space_items')
        .insert({'type': 'textbox', 'title': 'v1'})
        .select()
        .single();
    await db.sync();
    await tick();
    await db.from('space_items').update({'title': 'v2'}).eq('id', item['id']);
    await tick();
    await db.from('space_items').update({'title': 'v3'}).eq('id', item['id']);
    await db.sync();
    expect([for (final r in await rows(server)) r['title']], ['v3']);
  });

  test(
    'sends what waits before deleting for good, and needs the server',
    () async {
      final item = await db
          .from('space_items')
          .insert({'type': 'textbox', 'title': 'x'})
          .select()
          .single();
      server.down = true;
      await expectLater(
        db.from('space_items').delete().eq('id', item['id']),
        throwsA(isA<OfflineException>()),
      );
      expect(await rows(db), hasLength(1));

      server.down = false;
      await db.from('space_items').delete().eq('id', item['id']);
      expect(await rows(server), isEmpty);
      expect(await rows(db), isEmpty);
    },
  );

  test('logs reordering for the server too', () async {
    final a = await db
        .from('spaces')
        .insert({'name': 'a', 'position': 0})
        .select()
        .single();
    final b = await db
        .from('spaces')
        .insert({'name': 'b', 'position': 1})
        .select()
        .single();
    await db.rpc(
      'update_space_positions',
      params: {
        'updates': [
          {'id': a['id'], 'position': 1},
          {'id': b['id'], 'position': 0},
        ],
      },
    );
    await db.sync();
    final ordered =
        await server
                .from('spaces')
                .select('name')
                .order('position', ascending: true)
            as List;
    expect([for (final s in ordered) s['name']], ['b', 'a']);
  });
}
