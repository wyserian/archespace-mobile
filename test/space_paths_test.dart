import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_paths.dart';

Space _space(String id, [String? parentId]) => Space(
  id: id,
  name: id.toUpperCase(),
  description: '',
  pinned: false,
  parentId: parentId,
);

void main() {
  // a > b > c > d > e, a > f, g (top level)
  final spaces = [
    _space('a'),
    _space('b', 'a'),
    _space('c', 'b'),
    _space('d', 'c'),
    _space('e', 'd'),
    _space('f', 'a'),
    _space('g'),
  ];

  test('labels a space with its path, folded when deep', () {
    final paths = spacePathLabels(spaces);
    expect(paths['a'], 'A');
    expect(paths['c'], 'A › B › C');
    expect(paths['e'], 'A › … › E');
  });

  test('orders spaces as a tree with their depth', () {
    expect(
      [for (final (s, depth) in spaceTreeOrder(spaces)) '${s.id}$depth'],
      ['a0', 'b1', 'c2', 'd3', 'e4', 'f1', 'g0'],
    );
  });
}
