import 'package:archespace_mobile/src/features/spaces/domain/space_tree.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';

typedef _Node = ({
  String id,
  String? parentId,
  String? deletedAt,
  String? archivedAt,
});

/// Deleting, archiving, restoring and moving spaces as whole subtrees (spaces
/// nest to any depth). Each step first reads the user's space tree (ids,
/// parents and dates only), so it reaches every level. Ported from the web
/// `spaceLifecycle.js`; the same rules:
///
/// - Deleting or archiving a space takes its active sub-spaces with it, at
///   the same moment; ones already archived or deleted keep their own state.
/// - Restoring or unarchiving brings back what went with it (the same
///   moment), and any removed space above it, so it reappears where it was.
///   Those spaces' other contents stay where they are.
class SpaceLifecycle {
  SpaceLifecycle([Db? db]) : _db = db ?? Db.instance;

  final Db _db;

  static bool _active(_Node s) => s.deletedAt == null && s.archivedAt == null;

  Future<({List<_Node> tree, Map<String, _Node> byId})> _loadTree() async {
    final rows =
        await _db
                .from('spaces')
                .select('id, parent_id, deleted_at, archived_at')
            as List;
    final tree = [
      for (final r in rows)
        (
          id: r['id'] as String,
          parentId: r['parent_id'] as String?,
          deletedAt: r['deleted_at']?.toString(),
          archivedAt: r['archived_at']?.toString(),
        ),
    ];
    return (tree: tree, byId: {for (final s in tree) s.id: s});
  }

  static List<String> _below(
    Iterable<String> ids,
    List<_Node> tree,
    bool Function(_Node) include,
  ) => descendantsOf(
    ids,
    tree,
    idOf: (s) => s.id,
    parentOf: (s) => s.parentId,
    include: include,
  );

  /// The spaces that went with each root (removed at the same moment), by
  /// that moment.
  static Map<String, List<String>> _removedWith(
    Iterable<String> ids,
    List<_Node> tree,
    Map<String, _Node> byId, {
    required bool archived,
  }) {
    String? at(_Node s) => archived ? s.archivedAt : s.deletedAt;
    final groups = <String, List<String>>{};
    for (final id in ids) {
      final root = byId[id];
      final when = root == null ? null : at(root);
      if (when == null) continue;
      groups.putIfAbsent(when, () => []).addAll([
        id,
        ..._below([id], tree, (s) => at(s) == when),
      ]);
    }
    return groups;
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  /// Bring back any removed space above [spaceIds] (only those spaces), and
  /// with [includeSelf] the spaces themselves.
  Future<void> _reviveAncestors(
    Iterable<String> spaceIds,
    Map<String, _Node> byId, {
    bool includeSelf = false,
  }) async {
    String? parentOf(String id) => byId[id]?.parentId;
    final deleted = <String>{};
    final archived = <String>{};
    for (final id in spaceIds) {
      final chain = includeSelf
          ? chainOf(id, parentOf)
          : ancestorsOf(id, parentOf);
      for (final up in chain) {
        final s = byId[up];
        if (s?.deletedAt != null) deleted.add(up);
        if (s?.archivedAt != null) archived.add(up);
      }
    }
    if (deleted.isNotEmpty) {
      await _db
          .from('spaces')
          .update({'deleted_at': null})
          .inFilter('id', deleted.toList());
    }
    for (final id in archived) {
      final at = byId[id]!.archivedAt!;
      await _db.from('spaces').update({'archived_at': null}).eq('id', id);
      await _db
          .from('space_items')
          .update({'archived_at': null})
          .eq('space_id', id)
          .eq('archived_at', at);
    }
  }

  /// Move spaces (and their active sub-spaces) to the bin.
  Future<void> delete(List<String> ids) async {
    if (ids.isEmpty) return;
    final (:tree, byId: _) = await _loadTree();
    await _db
        .from('spaces')
        .update({'deleted_at': _now()})
        .inFilter('id', {...ids, ..._below(ids, tree, _active)}.toList());
  }

  /// Archive spaces, their active sub-spaces, and the items in them.
  Future<void> archive(List<String> ids) async {
    if (ids.isEmpty) return;
    final (:tree, byId: _) = await _loadTree();
    final spaceIds = {...ids, ..._below(ids, tree, _active)}.toList();
    final now = _now();
    await _db
        .from('spaces')
        .update({'archived_at': now})
        .inFilter('id', spaceIds);
    await _db
        .from('space_items')
        .update({'archived_at': now})
        .inFilter('space_id', spaceIds)
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);
  }

  /// Restore spaces from the bin, with what was deleted along with them.
  Future<void> restore(List<String> ids) async {
    final (:tree, :byId) = await _loadTree();
    final spaceIds = _removedWith(
      ids,
      tree,
      byId,
      archived: false,
    ).values.expand((g) => g).toList();
    if (spaceIds.isEmpty) return;
    await _db
        .from('spaces')
        .update({'deleted_at': null})
        .inFilter('id', spaceIds);
    await _reviveAncestors(ids, byId);
  }

  /// Unarchive spaces, with the sub-spaces and items archived along with
  /// them.
  Future<void> unarchive(List<String> ids) async {
    final (:tree, :byId) = await _loadTree();
    final groups = _removedWith(ids, tree, byId, archived: true);
    if (groups.isEmpty) return;
    for (final MapEntry(key: at, value: spaceIds) in groups.entries) {
      await _db
          .from('spaces')
          .update({'archived_at': null})
          .inFilter('id', spaceIds);
      await _db
          .from('space_items')
          .update({'archived_at': null})
          .inFilter('space_id', spaceIds)
          .eq('archived_at', at);
    }
    await _reviveAncestors(ids, byId);
  }

  /// Undo an archive or a move to the bin, whichever happened.
  Future<void> undoRemove(List<String> ids) async {
    await unarchive(ids);
    await restore(ids);
  }

  /// Move archived spaces (with what was archived along with them) to the
  /// bin.
  Future<void> binArchived(List<String> ids) async {
    final (:tree, :byId) = await _loadTree();
    final removed = {'deleted_at': _now(), 'archived_at': null};
    for (final MapEntry(key: at, value: spaceIds) in _removedWith(
      ids,
      tree,
      byId,
      archived: true,
    ).entries) {
      await _db.from('spaces').update(removed).inFilter('id', spaceIds);
      await _db
          .from('space_items')
          .update(removed)
          .inFilter('space_id', spaceIds)
          .eq('archived_at', at);
    }
  }

  /// Move spaces, with everything in them, into [parentId] (null = top
  /// level), after the spaces already there. A space can't go inside itself or
  /// one of its own sub-spaces, and one whose parent is moving too stays
  /// inside it.
  Future<void> move(List<String> ids, String? parentId) async {
    if (ids.isEmpty) return;
    final (:tree, :byId) = await _loadTree();
    String? parentOf(String id) => byId[id]?.parentId;
    final moving = ids.toSet();
    if (parentId != null && chainOf(parentId, parentOf).any(moving.contains)) {
      throw StateError("A space can't move inside itself.");
    }
    final roots = ids.where(
      (id) =>
          parentOf(id) != parentId &&
          !ancestorsOf(id, parentOf).any(moving.contains),
    );
    var position = tree
        .where((s) => _active(s) && s.parentId == parentId)
        .length;
    for (final id in roots) {
      await _db
          .from('spaces')
          .update({'parent_id': parentId, 'position': position++})
          .eq('id', id);
    }
  }

  /// Bring back the removed spaces above restored items, so they show again.
  Future<void> reviveItemSpaces(List<String> itemIds) async {
    if (itemIds.isEmpty) return;
    final rows =
        await _db.from('space_items').select('space_id').inFilter('id', itemIds)
            as List;
    final spaceIds = {
      for (final r in rows)
        if (r['space_id'] != null) r['space_id'] as String,
    };
    if (spaceIds.isEmpty) return;
    final (tree: _, :byId) = await _loadTree();
    await _reviveAncestors(spaceIds, byId, includeSelf: true);
  }
}
