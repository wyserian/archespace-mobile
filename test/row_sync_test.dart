import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/shared/data/local_db.dart';
import 'package:archespace_mobile/src/shared/data/row_sync.dart';

// Mirrors the web rowSync.test.js, on the local-mode database.
void main() {
  late LocalDb db;

  Future<List<Map<String, dynamic>>> list(List<Map<String, dynamic>> kept) =>
      fetchChangedRows(
        db: db,
        table: 'spaces',
        columns: 'id, name, position, updated_at',
        filter: (q) => q.isFilter('deleted_at', null),
        order: (q) => q.order('position', ascending: true),
        kept: kept,
      );

  setUp(() async {
    db = LocalDb(MemoryStore());
    for (var i = 0; i < 6; i++) {
      await db.from('spaces').insert({'name': 'S$i', 'position': i});
    }
  });

  test(
    'downloads in full only new and changed rows, and drops removed ones',
    () async {
      final rows = await list(const []);
      // The kept copy says "kept" everywhere, so a row taken from it shows.
      final kept = [
        for (final r in rows)
          {
            ...r,
            'name': 'kept ${r['name']}',
            if (r['name'] == 'S1') 'updated_at': 'before',
          },
      ];
      await db.from('spaces').delete().eq('name', 'S2');
      await db.from('spaces').insert({'name': 'S9', 'position': 9});

      expect(
        [for (final r in await list(kept)) r['name']],
        ['kept S0', 'S1', 'kept S3', 'kept S4', 'kept S5', 'S9'],
      );
    },
  );

  test('downloads everything when most rows changed', () async {
    final kept = [
      for (final r in await list(const []))
        {...r, 'name': 'kept', 'updated_at': 'before'},
    ];
    expect(
      [for (final r in await list(kept)) r['name']],
      [for (var i = 0; i < 6; i++) 'S$i'],
    );
  });
}
