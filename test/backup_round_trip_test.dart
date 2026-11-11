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
}
