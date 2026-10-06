import 'package:archespace_mobile/src/features/items/domain/kanban.dart';
import 'package:archespace_mobile/src/features/items/domain/rich_doc.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';

/// One searchable entry: either a space or an item. [haystack] is the
/// lowercased text matched against; the rest is for display/navigation.
class SearchHit {
  SearchHit({
    required this.isSpace,
    required this.id,
    required this.spaceId,
    required this.spaceName,
    required this.title,
    required this.type,
    required this.haystack,
    this.contentText = '',
    this.locked = false,
  });

  final bool isSpace;
  final String id;

  /// Lowercased content text (an item's body, a space's description), matched
  /// only while it isn't hidden by Protect.
  final String contentText;

  /// The item or space itself is protected (see ContentLock).
  final bool locked;

  /// Whether [query] (lowercased) matches. A protected item or space, or one
  /// inside a protected space, is found by its name and tags only until opened:
  /// matching its content would reveal what it says.
  bool matches(String query) {
    if (haystack.contains(query)) return true;
    final lock = ContentLock.instance;
    final hidden = isSpace
        ? lock.isSpaceHidden(id)
        : (locked && !lock.isRevealed(id)) || lock.isSpaceHidden(spaceId);
    return !hidden && contentText.contains(query);
  }

  /// The item's space, or null for a dashboard item (belongs to no space).
  final String? spaceId;
  final String spaceName;
  final String title;
  final String type;
  final String haystack;
}

/// Loads and decrypts every space + item into a flat search index. Mirrors the
/// web global search: spaces match on name/description/tags; items match on
/// title, tags, and type-specific content text.
class SearchRepository {
  SearchRepository(this._masterKey);

  final List<int> _masterKey;

  Db get _client => Db.instance;

  Future<List<SearchHit>> loadIndex() async {
    final spaceRows = await _client
        .from('spaces')
        .select('id, name, description, tags, parent_id, locked')
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);

    final hits = <SearchHit>[];
    final spaceNameById = <String, String>{};
    ContentLock.instance.registerSpaces([
      for (final row in spaceRows)
        (
          id: row['id'] as String,
          locked: (row['locked'] ?? false) as bool,
          parentId: row['parent_id'] as String?,
        ),
    ]);

    for (final row in spaceRows) {
      final id = row['id'] as String;
      final locked = (row['locked'] ?? false) as bool;
      final name = await ArcheCrypto.decryptArc1(
        (row['name'] ?? '') as String,
        _masterKey,
      );
      final description = await ArcheCrypto.decryptArc1(
        (row['description'] ?? '') as String,
        _masterKey,
      );
      final tags = await ArcheCrypto.decryptTags(row['tags'], _masterKey);
      spaceNameById[id] = name;
      hits.add(
        SearchHit(
          isSpace: true,
          id: id,
          spaceId: id,
          spaceName: name,
          title: name,
          type: 'space',
          haystack: '$name ${tags.join(' ')}'.toLowerCase(),
          contentText: description.toLowerCase(),
          locked: locked,
        ),
      );
    }

    final itemRows = await _client
        .from('space_items')
        .select('id, space_id, type, title, content, tags, locked')
        .isFilter('deleted_at', null)
        .isFilter('archived_at', null);

    for (final row in itemRows) {
      final type = (row['type'] ?? '') as String;
      final title = await ArcheCrypto.decryptArc1(
        (row['title'] ?? '') as String,
        _masterKey,
      );
      final content = await ArcheCrypto.decryptJsonMap(
        row['content'],
        _masterKey,
      );
      final tags = await ArcheCrypto.decryptTags(row['tags'], _masterKey);
      final spaceId = row['space_id'] as String?;
      hits.add(
        SearchHit(
          isSpace: false,
          id: row['id'] as String,
          spaceId: spaceId,
          spaceName: spaceId == null
              ? 'Dashboard'
              : spaceNameById[spaceId] ?? '',
          title: title,
          type: type,
          haystack: '$title ${tags.join(' ')}'.toLowerCase(),
          contentText: _itemText(type, title, content).toLowerCase(),
          locked: (row['locked'] ?? false) as bool,
        ),
      );
    }

    return hits;
  }
}

/// Type-specific searchable text (title + content). Whiteboards add nothing
/// beyond the title.
String _itemText(String type, String title, Map<String, dynamic> content) {
  final parts = <String>[title];
  switch (type) {
    case 'textbox':
      parts.add((content['text'] ?? '').toString());
    case 'markdown':
    case 'richtext':
      parts.add(richContentPlainText(type, content));
    case 'menu_list':
    case 'numbered_list':
    case 'checkbox_list':
      for (final it in (content['items'] as List? ?? const [])) {
        if (it is Map) parts.add((it['text'] ?? '').toString());
      }
    case 'card_list':
      for (final it in (content['items'] as List? ?? const [])) {
        if (it is Map) {
          parts.add((it['title'] ?? '').toString());
          parts.add((it['description'] ?? '').toString());
        }
      }
    case 'table':
      for (final c in (content['columns'] as List? ?? const [])) {
        parts.add((c ?? '').toString());
      }
      for (final r in (content['rows'] as List? ?? const [])) {
        if (r is List) {
          for (final cell in r) {
            parts.add((cell ?? '').toString());
          }
        }
      }
    case 'kanban':
      parts.addAll(kanbanSearchParts(content));
  }
  return parts.join(' ');
}
