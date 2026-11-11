import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/backup/data/backup_repository.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/app_mode.dart';
import 'package:archespace_mobile/src/shared/data/local_db.dart';

// Mirrors the web exportImport.roundtrip.test.js, on the local-mode database.
void main() {
  setUp(() => AppMode.local.value = true); // the local user imports
  tearDown(() => AppMode.local.value = false);

  test(
    "keeps an item's tags, star and colour, and counts unreadable items",
    () async {
      final key = ArcheCrypto.randomAesKey();
      Future<String> enc(String v) => ArcheCrypto.encryptArc1(v, key);
      final db = LocalDb(MemoryStore());
      final space = await db
          .from('spaces')
          .insert({
            'name': await enc('S'),
            'description': await enc(''),
            'tags': await enc('[]'),
          })
          .select()
          .single();
      await db.from('space_items').insert([
        {
          'space_id': space['id'],
          'type': 'textbox',
          'title': await enc('T'),
          'content': await enc(jsonEncode({'text': 'x'})),
          'tags': await enc(jsonEncode(['work'])),
          'starred': true,
          'color': 'rose',
        },
        {'space_id': space['id'], 'type': 'textbox', 'title': 'arc1:broken'},
      ]);

      final repo = BackupRepository(key, db);
      final (:json, :unreadable) = await repo.exportJson(const {
        'salt': 's',
        'wrapped_key': 'w',
        'key_check': 'k',
      });
      expect(unreadable, 1);

      await db.from('spaces').delete().neq('id', '');
      await repo.importJson(json);
      final item = (await db.from('space_items').select() as List).single;
      expect(await ArcheCrypto.decryptArc1(item['title'] as String, key), 'T');
      expect(await ArcheCrypto.decryptTags(item['tags'], key), ['work']);
      expect(item['starred'], isTrue);
      expect(item['color'], 'rose');
    },
  );

  test("keeps the order of spaces and items, and a space's star and "
      'read-only', () async {
    final key = ArcheCrypto.randomAesKey();
    Future<String> enc(String v) => ArcheCrypto.encryptArc1(v, key);
    final db = LocalDb(MemoryStore());
    Future<String> space(
      String name,
      int position, {
      bool starred = false,
    }) async =>
        (await db
                .from('spaces')
                .insert({
                  'name': await enc(name),
                  'description': await enc(''),
                  'tags': await enc('[]'),
                  'position': position,
                  'starred': starred,
                })
                .select()
                .single())['id']
            as String;
    await space('A', 0, starred: true);
    final b = await space('B', 1);
    for (final (title, position) in [('second', 1), ('first', 0)]) {
      await db.from('space_items').insert({
        'space_id': b,
        'type': 'textbox',
        'title': await enc(title),
        'content': await enc(jsonEncode({'text': ''})),
        'position': position,
      });
    }
    await db.from('spaces').update({'read_only': true}).eq('id', b);

    final repo = BackupRepository(key, db);
    final (:json, unreadable: _) = await repo.exportJson(const {});
    await db.from('spaces').update({'read_only': false}).eq('id', b);
    await db.from('space_items').delete().neq('id', '');
    await db.from('spaces').delete().neq('id', '');
    await repo.importJson(json);

    final spaces =
        await db.from('spaces').select().order('position', ascending: true)
            as List;
    expect(
      [
        for (final s in spaces) [s['starred'], s['read_only']],
      ],
      [
        [true, false],
        [false, true],
      ],
    );
    final items =
        await db.from('space_items').select().order('position', ascending: true)
            as List;
    expect(
      [for (final i in items) await ArcheCrypto.decryptArc1(i['title'], key)],
      ['first', 'second'],
    );
  });

  test('imports a web backup in order, skips bad items, and refuses one over '
      'the limits before saving anything', () async {
    final key = ArcheCrypto.randomAesKey();
    final db = LocalDb(MemoryStore());
    final repo = BackupRepository(key, db);
    Future<String> sealed(Map<String, dynamic> contents) async => jsonEncode({
      'app': 'ArcheSpace',
      'version': 3,
      'encrypted': true,
      'vault': const {},
      'data': await ArcheCrypto.encryptArc1(jsonEncode(contents), key),
    });
    // As the web writes it: no positions, listed in order.
    final summary = await repo.importJson(
      await sealed({
        'spaces': [
          {
            'key': 0,
            'name': 'First',
            'items': [
              {
                'type': 'textbox',
                'title': 'ok',
                'content': {'text': ''},
              },
              {
                'type': 'textbox',
                'title': 'bad',
                'content': {'code': ''},
              },
              {
                'type': 'markdown',
                'content': {'text': ''},
              },
            ],
          },
          {'key': 1, 'name': 'Second'},
        ],
        'items': [],
      }),
    );
    expect(summary, (spaces: 2, items: 1, skipped: 2));
    final spaces =
        await db.from('spaces').select().order('position', ascending: true)
            as List;
    expect(
      [for (final s in spaces) await ArcheCrypto.decryptArc1(s['name'], key)],
      ['First', 'Second'],
    );

    await expectLater(
      repo.importJson(
        await sealed({
          'spaces': [
            {'name': 'Fine'},
            {
              'name': 'Too full',
              'items': List.filled(1001, {
                'type': 'textbox',
                'content': {'text': ''},
              }),
            },
          ],
        }),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Too many items in space "Too full"'),
        ),
      ),
    );
    expect(await db.from('spaces').select() as List, hasLength(2));
  });
}
