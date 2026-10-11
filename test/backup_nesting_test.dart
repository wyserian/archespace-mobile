import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/backup/data/backup_repository.dart';

// Mirrors the web exportImport.test.js.
void main() {
  test('imports parents before their sub-spaces, at every level', () {
    // Listed children first: c (in b), b (in a), a, d (top level).
    final order = BackupRepository.nestingOrder([
      {'key': 2, 'parentKey': 1},
      {'key': 1, 'parentKey': 0},
      {'key': 0},
      {'key': 3},
    ]);
    expect(order, hasLength(4));
    final position = {for (final (n, (i, _)) in order.indexed) i: n};
    expect(position[2]!, lessThan(position[1]!));
    expect(position[1]!, lessThan(position[0]!));
    expect({for (final (i, p) in order) i: p}, {0: 1, 1: 2, 2: null, 3: null});
  });

  test('imports an older backup (no keys) flat', () {
    expect(
      BackupRepository.nestingOrder([
        {'name': 'a'},
        {'name': 'b'},
      ]),
      [(0, null), (1, null)],
    );
  });

  test('breaks a parent loop or a missing parent at the top level', () {
    final order = {
      for (final (i, p) in BackupRepository.nestingOrder([
        {'key': 'a', 'parentKey': 'b'},
        {'key': 'b', 'parentKey': 'a'},
        {'key': 'c', 'parentKey': 'missing'},
      ]))
        i: p,
    };
    expect(order[2], isNull);
    expect([order[0], order[1]].where((p) => p == null), hasLength(1));
  });
}
