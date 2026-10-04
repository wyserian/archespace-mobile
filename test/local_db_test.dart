import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/local_db.dart';

void main() {
  LocalDb db() => LocalDb(MemoryStore());

  Future<String?> errorCode(Future<dynamic> query) async {
    try {
      await query;
      return null;
    } on PostgrestException catch (e) {
      return e.code;
    }
  }

  test('inserts with defaults and reads back with filters and order', () async {
    final d = db();
    final a = await d
        .from('spaces')
        .insert({'name': 'A', 'position': 1})
        .select()
        .single();
    expect(a['user_id'], AppMode.localUserId);
    expect(a['pinned'], isFalse);
    expect(a['deleted_at'], isNull);
    await d.from('spaces').insert([
      {'name': 'B', 'position': 0, 'pinned': true},
      {'name': 'C', 'position': 2},
    ]);
    final rows = await d
        .from('spaces')
        .select('name')
        .isFilter('deleted_at', null)
        .order('pinned', ascending: false)
        .order('position', ascending: true);
    expect([for (final r in rows) r['name']], ['B', 'A', 'C']);
    expect(rows.first, {'name': 'B'});
    expect(
      await d.from('spaces').select().eq('name', 'Z').maybeSingle(),
      isNull,
    );
    expect(await errorCode(d.from('spaces').select().single()), 'PGRST116');
  });

  test('cascades a hard delete and matches "or" filters', () async {
    final d = db();
    final parent = await d
        .from('spaces')
        .insert({'name': 'P'})
        .select()
        .single();
    final child = await d
        .from('spaces')
        .insert({'name': 'C', 'parent_id': parent['id']})
        .select()
        .single();
    await d.from('space_items').insert([
      {'space_id': child['id'], 'type': 'textbox'},
      {'space_id': null, 'type': 'textbox'},
    ]);
    final family = await d
        .from('spaces')
        .select('id')
        .or('id.eq.${parent['id']},parent_id.eq.${parent['id']}');
    expect(family, hasLength(2));

    await d.from('spaces').delete().eq('id', parent['id'] as String);
    expect(await d.from('spaces').select(), isEmpty);
    final items = await d.from('space_items').select();
    expect(items, hasLength(1));
    expect(items.first['space_id'], isNull);
  });

  test('guards read-only spaces like the database', () async {
    final d = db();
    final space = await d
        .from('spaces')
        .insert({'name': 'R'})
        .select()
        .single();
    final id = space['id'] as String;
    final item = await d
        .from('space_items')
        .insert({'space_id': id, 'type': 'textbox', 'title': 't'})
        .select()
        .single();
    await d.from('spaces').update({'read_only': true}).eq('id', id);

    expect(
      await errorCode(d.from('spaces').update({'name': 'X'}).eq('id', id)),
      'P0R01',
    );
    expect(
      await errorCode(
        d
            .from('space_items')
            .update({'title': 'x'})
            .eq('id', item['id'] as String),
      ),
      'P0R01',
    );
    expect(
      await errorCode(
        d.from('space_items').insert({'space_id': id, 'type': 'textbox'}),
      ),
      'P0R01',
    );
    // Pinning stays allowed.
    expect(
      await errorCode(
        d
            .from('space_items')
            .update({'pinned': true})
            .eq('id', item['id'] as String),
      ),
      isNull,
    );
  });

  test('reorders and locks the PIN after five failures', () async {
    final d = db();
    final a = await d.from('spaces').insert({'name': 'A'}).select().single();
    await d.rpc(
      'update_space_positions',
      params: {
        'updates': [
          {'id': a['id'], 'position': 5},
        ],
      },
    );
    final moved = await d
        .from('spaces')
        .select('position')
        .eq('id', a['id'] as String)
        .single();
    expect(moved['position'], 5);

    await d.from('user_encryption').upsert({
      'user_id': AppMode.localUserId,
      'salt': 's',
      'key_check': 'k',
    });
    for (var i = 0; i < 5; i++) {
      await d.rpc('record_vault_pin_unlock_failure');
    }
    expect((await d.rpc('get_vault_pin_lock_status'))['locked'], isTrue);
    await d.rpc('record_vault_pin_unlock_success');
    expect((await d.rpc('get_vault_pin_lock_status'))['locked'], isFalse);
  });

  test(
    'empties recycle bin entries older than 30 days when it opens',
    () async {
      final store = MemoryStore();
      final old = DateTime.now()
          .subtract(const Duration(days: 31))
          .toUtc()
          .toIso8601String();
      store.tables['space_items'] = [
        {'id': 'old', 'deleted_at': old},
        {'id': 'new', 'deleted_at': DateTime.now().toUtc().toIso8601String()},
      ];
      final rows = await LocalDb(store).from('space_items').select('id');
      expect(rows, [
        {'id': 'new'},
      ]);
    },
  );
}
