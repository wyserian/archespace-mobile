import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/spaces/data/space_lifecycle.dart';
import 'package:archespace_mobile/src/shared/data/local_db.dart';

// Mirrors the web spaceLifecycle.test.js, on the local-mode database.
void main() {
  late LocalDb db;
  late SpaceLifecycle life;
  late Map<String, String> ids;

  // a > b > c > d, with an item in each; e on its own.
  setUp(() async {
    db = LocalDb(MemoryStore());
    life = SpaceLifecycle(db);
    ids = {};
    String? parent;
    for (final name in ['a', 'b', 'c', 'd', 'e']) {
      final space = await db
          .from('spaces')
          .insert({'name': name, 'parent_id': name == 'e' ? null : parent})
          .select()
          .single();
      ids[name] = space['id'] as String;
      if (name != 'e') parent = ids[name];
      final item = await db
          .from('space_items')
          .insert({'space_id': ids[name], 'type': 'textbox'})
          .select()
          .single();
      ids['${name}Item'] = item['id'] as String;
    }
  });

  String stateOf(Map row) => row['deleted_at'] != null
      ? 'bin'
      : row['archived_at'] != null
      ? 'archive'
      : 'active';

  Future<Map<String, String>> spaces() async {
    final rows = await db.from('spaces').select() as List;
    return {for (final r in rows) r['name'] as String: stateOf(r)};
  }

  Future<String> item(String key) async {
    final row = await db
        .from('space_items')
        .select()
        .eq('id', ids[key]!)
        .single();
    return stateOf(row);
  }

  Future<void> tick() => Future.delayed(const Duration(milliseconds: 5));

  const allActive = {
    'a': 'active',
    'b': 'active',
    'c': 'active',
    'd': 'active',
    'e': 'active',
  };

  test(
    'deletes every level below a space, and restores them together',
    () async {
      await life.delete([ids['b']!]);
      expect(await spaces(), {
        'a': 'active',
        'b': 'bin',
        'c': 'bin',
        'd': 'bin',
        'e': 'active',
      });
      await life.restore([ids['b']!]);
      expect(await spaces(), allActive);
    },
  );

  test('a sub-space deleted on its own stays in the bin', () async {
    await life.delete([ids['c']!]);
    await tick();
    await life.delete([ids['a']!]);
    await life.restore([ids['a']!]);
    expect(await spaces(), {...allActive, 'c': 'bin', 'd': 'bin'});
  });

  test('restoring a deep space brings back the spaces above it', () async {
    await life.delete([ids['a']!]);
    await life.restore([ids['c']!]);
    expect(await spaces(), allActive);

    await life.archive([ids['a']!]);
    await tick();
    await life.unarchive([ids['d']!]);
    expect(await spaces(), allActive);
    expect(await item('dItem'), 'active');
  });

  test(
    'archives every level, and brings back only what went with it',
    () async {
      await db
          .from('space_items')
          .update({'archived_at': DateTime.utc(2000).toIso8601String()})
          .eq('id', ids['cItem']!);
      await life.archive([ids['b']!]);
      expect(await item('dItem'), 'archive');
      await life.unarchive([ids['b']!]);
      expect((await spaces())['d'], 'active');
      expect(await item('dItem'), 'active');
      expect(await item('cItem'), 'archive');
    },
  );

  test(
    'moves an archived subtree to the bin, and undo brings it back',
    () async {
      await life.archive([ids['b']!]);
      await life.binArchived([ids['b']!]);
      expect(await spaces(), {
        ...allActive,
        'b': 'bin',
        'c': 'bin',
        'd': 'bin',
      });
      expect(await item('dItem'), 'bin');
      await life.undoRemove([ids['b']!]);
      expect(await spaces(), allActive);
    },
  );

  test('restoring an item brings back the spaces it lives in', () async {
    await life.delete([ids['b']!]);
    await life.reviveItemSpaces([ids['dItem']!]);
    expect(await spaces(), allActive);
  });

  test('hard-deleting a space removes every level below it', () async {
    await db.from('spaces').delete().eq('id', ids['a']!);
    final rows = await db.from('spaces').select('name') as List;
    expect([for (final r in rows) r['name']], ['e']);
  });
}
