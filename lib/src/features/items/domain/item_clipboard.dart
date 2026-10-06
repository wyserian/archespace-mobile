import 'package:archespace_mobile/src/features/items/domain/kanban.dart';
import 'package:archespace_mobile/src/features/items/domain/rich_doc.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';

/// Types whose content can be copied to the clipboard as plain text.
bool isCopyableType(String type) => const {
  'textbox',
  'markdown',
  'richtext',
  'code',
  'menu_list',
  'numbered_list',
  'checkbox_list',
  'card_list',
  'table',
  'kanban',
}.contains(type);

/// Serialize an item's content to plain text for copy-to-clipboard, matching
/// the web `itemToClipboardText` (lists bulleted/numbered, cards as
/// title+description, tables as tab-separated values). Whiteboards yield ''.
String itemClipboardText(SpaceItem item) {
  final c = item.content;
  switch (item.type) {
    case 'textbox':
      return (c['text'] ?? '').toString();
    case 'markdown':
    case 'richtext':
      return richContentPlainText(item.type, c);
    case 'code':
      return (c['code'] ?? '').toString();
    case 'menu_list':
    case 'checkbox_list':
      return _list(c, ordered: false);
    case 'numbered_list':
      return _list(c, ordered: true);
    case 'card_list':
      return _cards(c);
    case 'table':
      return _table(c);
    case 'kanban':
      return kanbanText(c);
    default:
      return '';
  }
}

String _list(Map<String, dynamic> c, {required bool ordered}) {
  final rows = (c['items'] as List? ?? const [])
      .whereType<Map>()
      .map((e) => (e['text'] ?? '').toString())
      .where((t) => t.trim().isNotEmpty)
      .toList();
  final lines = <String>[];
  for (var i = 0; i < rows.length; i++) {
    lines.add(ordered ? '${i + 1}. ${rows[i]}' : '• ${rows[i]}');
  }
  return lines.join('\n');
}

String _cards(Map<String, dynamic> c) {
  return (c['items'] as List? ?? const [])
      .whereType<Map>()
      .map(
        (e) =>
            '${(e['title'] ?? '').toString()}\n${(e['description'] ?? '').toString()}'
                .trim(),
      )
      .where((s) => s.isNotEmpty)
      .join('\n\n');
}

String _table(Map<String, dynamic> c) {
  final columns = c['columns'] as List? ?? const [];
  final rows = c['rows'] as List? ?? const [];
  final lines = <String>[];
  if (columns.any((x) => (x ?? '').toString().trim().isNotEmpty)) {
    lines.add(columns.map((x) => (x ?? '').toString()).join('\t'));
  }
  for (final r in rows) {
    if (r is List) lines.add(r.map((x) => (x ?? '').toString()).join('\t'));
  }
  return lines.join('\n');
}
