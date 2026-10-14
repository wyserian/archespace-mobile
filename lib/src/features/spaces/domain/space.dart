/// A decrypted space.
class Space {
  Space({
    required this.id,
    required this.name,
    required this.description,
    required this.pinned,
    this.starred = false,
    this.readOnly = false,
    this.locked = false,
    this.tags = const [],
    this.color,
    this.parentId,
    this.itemCount = 0,
    this.createdAt,
  });

  final String id;
  final String name;
  final String description;
  final bool pinned;

  /// In the Starred view. A quick-access flag only: it never affects order.
  final bool starred;

  /// Read-only (stored on the server): its details and items can be viewed,
  /// copied and exported, but not changed.
  final bool readOnly;

  /// Protected: the name shows, but opening the space (and its sub-spaces and
  /// items, wherever they're listed) needs the vault PIN (see ContentLock).
  final bool locked;
  final List<String> tags;

  /// Parent space id for a sub-space (nested to any depth), or null for
  /// top-level.
  final String? parentId;

  /// Preset colour id (violet/blue/green/amber/rose/slate), or null.
  final String? color;

  /// Number of (non-deleted, non-archived) items in this space and every
  /// sub-space below it. Computed at fetch time; 0 when unknown.
  final int itemCount;
  final DateTime? createdAt;
}
