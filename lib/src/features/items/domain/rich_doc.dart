import 'package:archespace_mobile/src/features/items/domain/rich_text_html.dart';

/// Rich text content is Tiptap (ProseMirror) JSON: `{ doc: { type: 'doc',
/// content: [...] } }`, written by the Tiptap editor on web and in the app's
/// WebView. Items saved before it hold `{ html }` (the old Rich text) or are
/// the old `markdown` type with `{ text }`; they still display, and convert
/// the first time they're edited. Mirrors the web `lib/richText/doc.js`.

const Map<String, dynamic> kEmptyRichDoc = {
  'type': 'doc',
  'content': [
    {'type': 'paragraph'},
  ],
};

/// True when [content] holds a Tiptap document (not an older format).
bool isRichDoc(Map<String, dynamic> content) {
  final doc = content['doc'];
  return doc is Map && doc['type'] == 'doc';
}

/// Child nodes of a Tiptap node.
List<Map<String, dynamic>> richChildren(Object? node) {
  if (node is! Map) return const [];
  final content = node['content'];
  if (content is! List) return const [];
  return content
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();
}

const Set<String> _blocks = {
  'paragraph',
  'heading',
  'blockquote',
  'codeBlock',
  'listItem',
  'taskItem',
  'tableRow',
  'horizontalRule',
};

/// Text being built that remembers its last character, so a line break never
/// has to copy all the text so far to look (which made long documents slow).
class _PlainText {
  final StringBuffer _buf = StringBuffer();
  bool _endsWithNewline = false;

  void write(String s) {
    if (s.isEmpty) return;
    _buf.write(s);
    _endsWithNewline = s.endsWith('\n');
  }

  void lineBreak() {
    if (_buf.isNotEmpty && !_endsWithNewline) write('\n');
  }

  @override
  String toString() => _buf.toString();
}

final RegExp _cellBreaks = RegExp(r'\s*\n\s*');

/// A table cell on one line.
String _cellText(Map<String, dynamic> cell) {
  final out = _PlainText();
  for (final child in richChildren(cell)) {
    _nodeText(child, out);
  }
  return out.toString().trim().replaceAll(_cellBreaks, ' ');
}

void _nodeText(Map<String, dynamic> node, _PlainText out) {
  final type = node['type'];
  if (type == 'text') return out.write((node['text'] ?? '').toString());
  if (type == 'hardBreak') return out.write('\n');
  if (type == 'tableRow') {
    out.write(
      [for (final cell in richChildren(node)) _cellText(cell)].join('\t'),
    );
    return out.lineBreak();
  }
  for (final child in richChildren(node)) {
    _nodeText(child, out);
  }
  if (_blocks.contains(type)) out.lineBreak();
}

/// Plain text of Rich text content in any of its formats: a line per block,
/// tabs between table cells (for copy, search and empty checks).
String richContentPlainText(String type, Map<String, dynamic> content) {
  if (isRichDoc(content)) {
    final out = _PlainText();
    _nodeText((content['doc'] as Map).cast<String, dynamic>(), out);
    return out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
  if (type == 'markdown') return (content['text'] ?? '').toString();
  return richHtmlToPlainText((content['html'] ?? '').toString());
}
