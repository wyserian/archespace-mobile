import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_tree.dart';

String _nameOf(Space s) => s.name.isEmpty ? 'Untitled' : s.name;

/// Where each space sits, for labels: "A › B › C", folded to "A › … › D"
/// when it's deeper than three levels. Matches the web `spacePathLabel`.
Map<String, String> spacePathLabels(Iterable<Space> spaces) {
  final byId = {for (final s in spaces) s.id: s};
  String label(Space s) {
    final names = [
      for (final id in chainOf(s.id, (id) => byId[id]?.parentId).reversed)
        if (byId[id] case final up?) _nameOf(up),
    ];
    return names.length > 3
        ? '${names.first} › … › ${names.last}'
        : names.join(' › ');
  }

  return {for (final s in spaces) s.id: label(s)};
}

/// Spaces in tree order, each followed by its sub-spaces (keeping the given
/// order within a level), with their depth. A space whose parent isn't in the
/// list counts as top level. Matches the web `treeOrder`.
List<(Space, int)> spaceTreeOrder(List<Space> spaces) {
  final ids = {for (final s in spaces) s.id};
  final children = <String?, List<Space>>{};
  for (final s in spaces) {
    final parent = ids.contains(s.parentId) ? s.parentId : null;
    children.putIfAbsent(parent, () => []).add(s);
  }
  final out = <(Space, int)>[];
  final seen = <String>{};
  void visit(String? parent, int depth) {
    for (final s in children[parent] ?? const <Space>[]) {
      if (!seen.add(s.id)) continue;
      out.add((s, depth));
      visit(s.id, depth + 1);
    }
  }

  visit(null, 0);
  return out;
}
