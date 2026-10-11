/// Spaces nest to any depth through their parent id. These walk a space's
/// ancestors or descendants, and stop at a parent loop (which the app never
/// creates, but a bad row mustn't hang it). Ported from the web `spaceTree.js`.
library;

/// A space and the spaces above it, nearest first: [id, parent, grandparent,
/// ...]. [parentOf] gives a space's parent id, or null at the top.
List<String> chainOf(String? id, String? Function(String id) parentOf) {
  final chain = <String>[];
  final seen = <String>{};
  for (var at = id; at != null && seen.add(at); at = parentOf(at)) {
    chain.add(at);
  }
  return chain;
}

/// The spaces above a space, nearest first (not the space itself).
List<String> ancestorsOf(String id, String? Function(String id) parentOf) =>
    chainOf(id, parentOf).skip(1).toList();

/// Every space below [ids] (not [ids] themselves), from (id, parentId)
/// pairs. [include] can stop the walk at a space (it and everything under it
/// are left out).
List<String> descendantsOf<T>(
  Iterable<String> ids,
  Iterable<T> spaces, {
  required String Function(T space) idOf,
  required String? Function(T space) parentOf,
  bool Function(T space)? include,
}) {
  final children = <String, List<T>>{};
  for (final s in spaces) {
    final parent = parentOf(s);
    if (parent != null) children.putIfAbsent(parent, () => []).add(s);
  }
  final out = <String>[];
  final seen = <String>{...ids};
  final queue = <String>[...ids];
  while (queue.isNotEmpty) {
    for (final child in children[queue.removeAt(0)] ?? <T>[]) {
      final id = idOf(child);
      if (seen.contains(id) || !(include?.call(child) ?? true)) continue;
      seen.add(id);
      out.add(id);
      queue.add(id);
    }
  }
  return out;
}
