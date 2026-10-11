import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/spaces/domain/space_tree.dart';

// a > b > c > d, a > e, f (top level)
const _spaces = <(String, String?)>[
  ('a', null),
  ('b', 'a'),
  ('c', 'b'),
  ('d', 'c'),
  ('e', 'a'),
  ('f', null),
];
final _parents = {for (final (id, parent) in _spaces) id: parent};

List<String> _down(
  List<String> ids, [
  bool Function((String, String?))? include,
  List<(String, String?)> spaces = _spaces,
]) => descendantsOf(
  ids,
  spaces,
  idOf: (s) => s.$1,
  parentOf: (s) => s.$2,
  include: include,
)..sort();

void main() {
  test('walks up to the top', () {
    expect(chainOf('d', (id) => _parents[id]), ['d', 'c', 'b', 'a']);
    expect(ancestorsOf('d', (id) => _parents[id]), ['c', 'b', 'a']);
    expect(ancestorsOf('a', (id) => _parents[id]), isEmpty);
  });

  test('walks down every level', () {
    expect(_down(['a']), ['b', 'c', 'd', 'e']);
    expect(_down(['b', 'f']), ['c', 'd']);
    expect(_down(['d']), isEmpty);
  });

  test('can stop the walk down at a space', () {
    expect(_down(['a'], (s) => s.$1 != 'c'), ['b', 'e']);
  });

  test('stops at a parent loop', () {
    const loop = <(String, String?)>[('x', 'y'), ('y', 'x')];
    expect(chainOf('x', (id) => id == 'x' ? 'y' : 'x'), ['x', 'y']);
    expect(_down(['x'], null, loop), ['y']);
  });
}
