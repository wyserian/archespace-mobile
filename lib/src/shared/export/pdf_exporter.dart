import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:archespace_mobile/src/features/items/domain/kanban.dart';
import 'package:archespace_mobile/src/features/items/domain/rich_doc.dart';
import 'package:archespace_mobile/src/features/items/domain/rich_text_html.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/domain/whiteboard.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';

/// Builds a PDF for a whole space or a single item, per item type. Mirrors the
/// web PDF export's content structure.
class PdfExporter {
  const PdfExporter._();

  static Future<Uint8List> buildSpace(
    String name,
    List<SpaceItem> items,
  ) async {
    final stamp = _timestamp();
    final theme = await _theme();
    final doc = pw.Document(theme: theme);
    doc.addPage(
      pw.MultiPage(
        header: (context) => _pageHeader(stamp),
        footer: (context) => _pageFooter(context),
        build: (context) => [
          // The space name once, at the start of the document (not per page).
          pw.Text(
            name.isEmpty ? 'Space' : name,
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 12),
          if (items.isEmpty) pw.Text('This space has no items.'),
          for (final item in items) ..._section(item),
        ],
      ),
    );
    return doc.save();
  }

  static Future<Uint8List> buildItem(SpaceItem item) async {
    final stamp = _timestamp();
    final theme = await _theme();
    final doc = pw.Document(theme: theme);
    doc.addPage(
      pw.MultiPage(
        header: (context) => _pageHeader(stamp),
        footer: (context) => _pageFooter(context),
        build: (context) => _section(item),
      ),
    );
    return doc.save();
  }

  // A monospace face (for code) with broad glyph coverage, kept for _body.
  static pw.Font? _mono;

  /// A theme using DejaVu (broad symbol/arrow coverage, unlike the built-in
  /// Helvetica), and the DejaVu mono face for code.
  static Future<pw.ThemeData> _theme() async {
    final base = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
    _mono = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSansMono.ttf'));
    // No italic face is bundled: italic text (Rich text) uses the upright
    // fonts rather than falling back to Helvetica, which has no Unicode.
    return pw.ThemeData.withFont(
      base: base,
      bold: bold,
      italic: base,
      boldItalic: bold,
    );
  }

  /// The export time, e.g. "9/19/26, 8:36 PM".
  static String _timestamp() {
    final n = DateTime.now();
    final h = n.hour % 12 == 0 ? 12 : n.hour % 12;
    final ampm = n.hour >= 12 ? 'PM' : 'AM';
    final mm = n.minute.toString().padLeft(2, '0');
    final yy = (n.year % 100).toString().padLeft(2, '0');
    return '${n.month}/${n.day}/$yy, $h:$mm $ampm';
  }

  static const pw.TextStyle _chromeStyle = pw.TextStyle(
    fontSize: 8,
    color: PdfColors.grey600,
  );

  /// Every page's header: export time top-left, the site URL top-right.
  static pw.Widget _pageHeader(String stamp) => pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 12),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(stamp, style: _chromeStyle),
        pw.Spacer(),
        pw.Text('https://archespace.app/', style: _chromeStyle),
      ],
    ),
  );

  /// Every page's footer: the page number bottom-right.
  static pw.Widget _pageFooter(pw.Context context) => pw.Container(
    margin: const pw.EdgeInsets.only(top: 8),
    child: pw.Row(
      children: [
        pw.Spacer(),
        pw.Text(
          '${context.pageNumber}/${context.pagesCount}',
          style: _chromeStyle,
        ),
      ],
    ),
  );

  /// Text that page-breaks when it runs past the bottom of a page. pw.Text
  /// only splits with overflow: span; the default refuses and throws once the
  /// text is taller than a page.
  static pw.Text _text(String text, {pw.TextStyle? style}) =>
      pw.Text(text, style: style, overflow: pw.TextOverflow.span);

  // Each item contributes a FLAT list of top-level widgets to the MultiPage
  // build (never a single pw.Column). MultiPage can only page-break between
  // top-level widgets and inside splittable ones (spanning Text, Table); a
  // Column is atomic, so wrapping big content in one made MultiPage loop
  // forever. Container and Padding are atomic too: any text that can run long
  // (list rows, card descriptions) must be a bare _text, or one taller than a
  // page throws "Widget won't fit into the page". Spacing goes in SizedBoxes.
  static List<pw.Widget> _section(SpaceItem item) => [
    pw.SizedBox(height: 8),
    _text(
      item.title.isEmpty ? 'Untitled' : item.title,
      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
    ),
    pw.SizedBox(height: 4),
    // A protected item that isn't open stays out of the file.
    if (ContentLock.instance.isItemHidden(item))
      pw.Text('Protected')
    else
      ..._body(item),
    pw.Divider(),
  ];

  static List<pw.Widget> _body(SpaceItem item) {
    final c = item.content;
    switch (item.type) {
      case 'textbox':
      case 'markdown':
        final text = (c['text'] ?? '').toString();
        return [_text(text.isEmpty ? '(empty)' : text)];
      case 'richtext':
        if (isRichDoc(c)) {
          if (richContentPlainText('richtext', c).isEmpty) {
            return [pw.Text('(empty)')];
          }
          return _richDoc((c['doc'] as Map).cast<String, dynamic>());
        }
        // Saved before the Tiptap editor (converts when next edited).
        final text = richHtmlToPlainText((c['html'] ?? '').toString());
        return [_text(text.isEmpty ? '(empty)' : text)];
      case 'code':
        final code = (c['code'] ?? '').toString();
        if (code.isEmpty) return [pw.Text('(empty)')];
        // Plain monospace text splits across pages (a decorated Container
        // cannot), so a long code block never hangs the export.
        return [
          _text(
            code,
            style: pw.TextStyle(font: _mono, fontSize: 9, lineSpacing: 2),
          ),
        ];
      case 'menu_list':
        return _bullets(c, ordered: false);
      case 'numbered_list':
        return _bullets(c, ordered: true);
      case 'checkbox_list':
        return _checklist(c);
      case 'card_list':
        return _cards(c);
      case 'table':
        return [_table(c)];
      case 'kanban':
        return _kanban(c);
      case 'whiteboard':
        return [_whiteboard(c)];
      default:
        return const [];
    }
  }

  // Rich text (Tiptap JSON)
  // Flat, splittable widgets only (see _section): each block is one spanning
  // RichText, and nesting is shown with a leading indent rather than a
  // Padding (which can't split across pages).

  static const _nbsp = '\u00A0';

  static pw.RichText _rich(
    List<pw.InlineSpan> spans, {
    pw.TextStyle? style,
    pw.TextAlign? align,
  }) => pw.RichText(
    text: pw.TextSpan(children: spans, style: style),
    textAlign: align,
    overflow: pw.TextOverflow.span,
  );

  /// Extra spacing for a paragraph/heading's `lineHeight` (the editor's
  /// Normal is 1.5, which the PDF's default spacing already matches).
  static pw.TextStyle? _lineSpacing(Map<String, dynamic> node, double size) {
    final attrs = node['attrs'];
    final lh = double.tryParse('${attrs is Map ? attrs['lineHeight'] : ''}');
    if (lh == null) return null;
    return pw.TextStyle(lineSpacing: ((lh - 1.2) * size).clamp(0, 2 * size));
  }

  /// A paragraph/heading's alignment (Tiptap's `textAlign` attribute).
  static pw.TextAlign? _align(Map<String, dynamic> node) {
    final attrs = node['attrs'];
    return switch (attrs is Map ? attrs['textAlign'] : null) {
      'center' => pw.TextAlign.center,
      'right' => pw.TextAlign.right,
      'justify' => pw.TextAlign.justify,
      _ => null,
    };
  }

  /// Text runs for a node's inline content (text with its marks).
  static List<pw.InlineSpan> _runs(Map<String, dynamic>? node) {
    final spans = <pw.InlineSpan>[];
    for (final child in richChildren(node)) {
      if (child['type'] == 'hardBreak') {
        spans.add(const pw.TextSpan(text: '\n'));
        continue;
      }
      if (child['type'] != 'text') continue;
      var style = const pw.TextStyle();
      final decorations = <pw.TextDecoration>[];
      for (final mark in (child['marks'] as List? ?? const [])) {
        if (mark is! Map) continue;
        switch (mark['type']) {
          case 'bold':
            style = style.copyWith(fontWeight: pw.FontWeight.bold);
          case 'italic':
            style = style.copyWith(fontStyle: pw.FontStyle.italic);
          case 'underline':
            decorations.add(pw.TextDecoration.underline);
          case 'strike':
            decorations.add(pw.TextDecoration.lineThrough);
          case 'code':
            style = style.copyWith(font: _mono, fontSize: 9.5);
          case 'link':
            style = style.copyWith(color: PdfColor.fromHex('#0b7f64'));
            decorations.add(pw.TextDecoration.underline);
          case 'highlight':
            style = style.copyWith(
              background: pw.BoxDecoration(color: PdfColor.fromHex('#fdf1a8')),
            );
          case 'superscript':
          case 'subscript':
            // Smaller text; the pdf package can't shift the baseline.
            style = style.copyWith(fontSize: 8);
        }
      }
      if (decorations.isNotEmpty) {
        style = style.copyWith(
          decoration: pw.TextDecoration.combine(decorations),
        );
      }
      spans.add(
        pw.TextSpan(text: (child['text'] ?? '').toString(), style: style),
      );
    }
    return spans;
  }

  static List<pw.Widget> _richDoc(Map<String, dynamic> doc) {
    final out = <pw.Widget>[];

    void blocks(List<Map<String, dynamic>> nodes, {String indent = ''}) {
      for (final n in nodes) {
        switch (n['type']) {
          case 'paragraph':
            out.add(
              _rich(
                [pw.TextSpan(text: indent), ..._runs(n)],
                align: _align(n),
                style: _lineSpacing(n, 11),
              ),
            );
            out.add(pw.SizedBox(height: 3));
          case 'heading':
            final level = (n['attrs'] is Map ? n['attrs']['level'] : 1) ?? 1;
            final size = switch (level) {
              1 => 16.0,
              2 => 14.0,
              _ => 12.5,
            };
            out.add(pw.SizedBox(height: 4));
            out.add(
              _rich(
                _runs(n),
                style: pw.TextStyle(
                  fontSize: size,
                  fontWeight: pw.FontWeight.bold,
                ),
                align: _align(n),
              ),
            );
            out.add(pw.SizedBox(height: 3));
          case 'bulletList':
          case 'orderedList':
          case 'taskList':
            final items = richChildren(n);
            for (var i = 0; i < items.length; i++) {
              final item = items[i];
              final checked =
                  item['attrs'] is Map && item['attrs']['checked'] == true;
              final marker = switch (n['type']) {
                'orderedList' => '${i + 1}. ',
                'taskList' => checked ? '☑  ' : '☐  ',
                _ => '• ',
              };
              final children = richChildren(item);
              final first = children.isNotEmpty ? children.first : null;
              out.add(
                _rich(
                  [pw.TextSpan(text: '$indent$marker'), ..._runs(first)],
                  style: checked
                      ? const pw.TextStyle(
                          color: PdfColors.grey600,
                          decoration: pw.TextDecoration.lineThrough,
                        )
                      : null,
                ),
              );
              if (children.length > 1) {
                blocks(children.sublist(1), indent: '$indent${_nbsp * 4}');
              }
            }
            out.add(pw.SizedBox(height: 3));
          case 'blockquote':
            blocks(richChildren(n), indent: '$indent│${_nbsp * 2}');
          case 'codeBlock':
            final code = richChildren(
              n,
            ).map((t) => (t['text'] ?? '').toString()).join();
            out.add(
              _text(
                code,
                style: pw.TextStyle(font: _mono, fontSize: 9, lineSpacing: 2),
              ),
            );
            out.add(pw.SizedBox(height: 4));
          case 'horizontalRule':
            out.add(pw.Divider(thickness: 0.3));
          case 'table':
            final rows = richChildren(n);
            if (rows.isEmpty) break;
            String cellText(Map<String, dynamic> cell) =>
                richContentPlainText('richtext', {
                  'doc': {'type': 'doc', 'content': cell['content'] ?? []},
                }).replaceAll('\n', ' ');
            final firstIsHeader = richChildren(
              rows.first,
            ).every((c) => c['type'] == 'tableHeader');
            final table = [
              for (final r in rows)
                [for (final c in richChildren(r)) cellText(c)],
            ];
            out.add(
              pw.TableHelper.fromTextArray(
                headers: firstIsHeader ? table.first : null,
                data: firstIsHeader ? table.sublist(1) : table,
              ),
            );
            out.add(pw.SizedBox(height: 4));
          default:
            blocks(richChildren(n), indent: indent);
        }
      }
    }

    blocks(richChildren(doc));
    return out;
  }

  static List<pw.Widget> _bullets(
    Map<String, dynamic> c, {
    required bool ordered,
  }) {
    final rows = (c['items'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => (e['text'] ?? '').toString())
        .where((t) => t.trim().isNotEmpty)
        .toList();
    if (rows.isEmpty) return [pw.Text('(empty)')];
    // One bare Text per row (a Padding wrapper can't split), so a long list
    // page-breaks between rows and a very long row splits within itself.
    return [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) pw.SizedBox(height: 2),
        _text(ordered ? '${i + 1}. ${rows[i]}' : '• ${rows[i]}'),
      ],
    ];
  }

  static List<pw.Widget> _checklist(Map<String, dynamic> c) {
    final items = (c['items'] as List? ?? const []).whereType<Map>().toList();
    if (items.isEmpty) return [pw.Text('(empty)')];
    return [
      for (final it in items)
        _text(
          '${(it['checked'] ?? false) == true ? '☑' : '☐'}  '
          '${(it['text'] ?? '').toString()}',
        ),
    ];
  }

  static List<pw.Widget> _cards(Map<String, dynamic> c) {
    final items = (c['items'] as List? ?? const []).whereType<Map>().toList();
    if (items.isEmpty) return [pw.Text('(empty)')];
    // Bare Texts per card, not a bordered Container: a Container can't split,
    // so one card with a long description overflowed the page. A thin rule
    // between cards keeps them visually separate.
    return [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) pw.Divider(height: 10, thickness: 0.3),
        if ((items[i]['title'] ?? '').toString().isNotEmpty)
          _text(
            (items[i]['title']).toString(),
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
        if ((items[i]['description'] ?? '').toString().isNotEmpty)
          _text((items[i]['description']).toString()),
      ],
    ];
  }

  /// Each column as a heading with its count, then its cards (split-safe bare
  /// Texts, like [_cards]).
  static List<pw.Widget> _kanban(Map<String, dynamic> c) {
    final columns = kanbanColumns(c);
    if (!columns.any((col) => col.cards.isNotEmpty || col.title.isNotEmpty)) {
      return [pw.Text('(empty)')];
    }
    return [
      for (final col in columns) ...[
        pw.SizedBox(height: 4),
        _text(
          '${col.title.isEmpty ? 'Untitled' : col.title}  (${col.cards.length})',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 2),
        if (col.cards.isEmpty) pw.Text('(empty)'),
        for (var i = 0; i < col.cards.length; i++) ...[
          if (i > 0) pw.Divider(height: 8, thickness: 0.3),
          _text(col.cards[i].title.isEmpty ? 'Untitled' : col.cards[i].title),
          if (col.cards[i].description.isNotEmpty)
            _text(
              col.cards[i].description,
              style: const pw.TextStyle(color: PdfColors.grey700),
            ),
        ],
        pw.SizedBox(height: 6),
      ],
    ];
  }

  static pw.Widget _table(Map<String, dynamic> c) {
    final columns = (c['columns'] as List? ?? const [])
        .map((e) => (e ?? '').toString())
        .toList();
    final rows = (c['rows'] as List? ?? const [])
        .map(
          (r) => r is List
              ? r.map((e) => (e ?? '').toString()).toList()
              : <String>[],
        )
        .toList();
    if (columns.isEmpty && rows.isEmpty) return pw.Text('(empty)');
    return pw.TableHelper.fromTextArray(
      headers: columns.isEmpty ? null : columns,
      data: rows,
    );
  }

  /// The preview saved with the board; an old drawing gets one when it first
  /// opens in the app.
  static pw.Widget _whiteboard(Map<String, dynamic> c) {
    if (!hasBoardContent(c)) return pw.Text('(empty)');
    final bytes = boardPreviewBytes(c);
    if (bytes == null) {
      return pw.Text('Open this whiteboard in the app to include it.');
    }
    return pw.ConstrainedBox(
      constraints: const pw.BoxConstraints(maxHeight: 360),
      child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
    );
  }
}
