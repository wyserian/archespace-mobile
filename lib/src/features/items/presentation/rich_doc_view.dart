import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/domain/rich_doc.dart';

/// Read-only, native rendering of a Rich text document (Tiptap JSON) for item
/// card previews: headings, formatted text, lists, task lists, quotes, code,
/// dividers and tables. Editing happens in the WebView editor; this keeps the
/// list fast and fully native.
class RichDocView extends StatelessWidget {
  const RichDocView({super.key, required this.doc});

  final Map<String, dynamic> doc;

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks(context, richChildren(doc));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
  }

  static List<Widget> _blocks(
    BuildContext context,
    List<Map<String, dynamic>> nodes, {
    bool muted = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = DefaultTextStyle.of(
      context,
    ).style.copyWith(color: muted ? scheme.onSurfaceVariant : null);
    final out = <Widget>[];
    for (final node in nodes) {
      switch (node['type']) {
        case 'paragraph':
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text.rich(
                _inline(
                  context,
                  node,
                  base.copyWith(height: _lineHeight(node)),
                ),
                textAlign: _align(node),
              ),
            ),
          );
        case 'heading':
          final level =
              (node['attrs'] is Map ? node['attrs']['level'] : 1) ?? 1;
          final style = switch (level) {
            1 => theme.textTheme.titleLarge,
            2 => theme.textTheme.titleMedium?.copyWith(fontSize: 17),
            3 => theme.textTheme.titleSmall?.copyWith(fontSize: 15),
            _ => theme.textTheme.titleSmall?.copyWith(fontSize: 14),
          };
          out.add(
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 6),
              child: Text.rich(
                _inline(
                  context,
                  node,
                  (style ?? base).copyWith(
                    fontWeight: FontWeight.w700,
                    height: _lineHeight(node),
                  ),
                ),
                textAlign: _align(node),
              ),
            ),
          );
        case 'bulletList':
        case 'orderedList':
          final ordered = node['type'] == 'orderedList';
          final items = richChildren(node);
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < items.length; i++)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 22,
                          child: Text(ordered ? '${i + 1}.' : '•', style: base),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _tight(
                              _blocks(context, richChildren(items[i])),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          );
        case 'taskList':
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in richChildren(node))
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2, right: 6),
                          child: Icon(
                            _checked(item)
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 18,
                            color: _checked(item) ? scheme.primary : null,
                          ),
                        ),
                        Expanded(
                          child: DefaultTextStyle.merge(
                            style: _checked(item)
                                ? TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    decoration: TextDecoration.lineThrough,
                                  )
                                : null,
                            child: Builder(
                              builder: (context) => Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: _tight(
                                  _blocks(context, richChildren(item)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          );
        case 'blockquote':
          out.add(
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: scheme.primary, width: 3),
                ),
              ),
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontStyle: FontStyle.italic),
                child: Builder(
                  builder: (context) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _tight(
                      _blocks(context, richChildren(node), muted: true),
                    ),
                  ),
                ),
              ),
            ),
          );
        case 'codeBlock':
          final code = richChildren(
            node,
          ).map((t) => (t['text'] ?? '').toString()).join();
          out.add(
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.45,
                  color: Color(0xFFD5DAE2),
                ),
              ),
            ),
          );
        case 'horizontalRule':
          out.add(Divider(height: 16, color: scheme.outlineVariant));
        case 'table':
          out.add(_table(context, node, base));
        default:
          out.addAll(_blocks(context, richChildren(node), muted: muted));
      }
    }
    return out;
  }

  /// Blocks inside a list item or cell without the trailing paragraph gap.
  static List<Widget> _tight(List<Widget> blocks) => [
    for (final b in blocks)
      b is Padding && b.padding == const EdgeInsets.only(bottom: 6)
          ? b.child ?? const SizedBox.shrink()
          : b,
  ];

  /// A paragraph/heading's line spacing (the `lineHeight` attribute), or null
  /// for the default.
  static double? _lineHeight(Map<String, dynamic> node) {
    final attrs = node['attrs'];
    return double.tryParse('${attrs is Map ? attrs['lineHeight'] : ''}');
  }

  /// A paragraph/heading's text alignment (Tiptap's `textAlign` attribute).
  static TextAlign _align(Map<String, dynamic> node) {
    final attrs = node['attrs'];
    return switch (attrs is Map ? attrs['textAlign'] : null) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => TextAlign.start,
    };
  }

  static bool _checked(Map<String, dynamic> item) =>
      item['attrs'] is Map && item['attrs']['checked'] == true;

  static Widget _table(
    BuildContext context,
    Map<String, dynamic> node,
    TextStyle base,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final rows = richChildren(node);
    if (rows.isEmpty) return const SizedBox.shrink();
    var cols = 1;
    for (final r in rows) {
      final n = richChildren(r).length;
      if (n > cols) cols = n;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Table(
        border: TableBorder.all(color: scheme.outlineVariant),
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          for (final row in rows)
            TableRow(
              decoration:
                  richChildren(row).any((c) => c['type'] == 'tableHeader')
                  ? BoxDecoration(color: scheme.surfaceContainerHighest)
                  : null,
              children: [
                for (var i = 0; i < cols; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: i < richChildren(row).length
                        ? DefaultTextStyle.merge(
                            style: TextStyle(
                              fontWeight:
                                  richChildren(row)[i]['type'] == 'tableHeader'
                                  ? FontWeight.w600
                                  : null,
                            ),
                            child: Builder(
                              builder: (context) => Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: _tight(
                                  _blocks(
                                    context,
                                    richChildren(richChildren(row)[i]),
                                  ),
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Inline content (text with marks, hard breaks) as a TextSpan.
  static TextSpan _inline(
    BuildContext context,
    Map<String, dynamic> node,
    TextStyle base,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final children = <InlineSpan>[];
    for (final child in richChildren(node)) {
      if (child['type'] == 'hardBreak') {
        children.add(const TextSpan(text: '\n'));
        continue;
      }
      if (child['type'] != 'text') continue;
      var style = const TextStyle();
      final decorations = <TextDecoration>[];
      // Superscript / subscript: smaller text raised or lowered.
      PlaceholderAlignment? shift;
      for (final mark in (child['marks'] as List? ?? const [])) {
        if (mark is! Map) continue;
        switch (mark['type']) {
          case 'bold':
            style = style.copyWith(fontWeight: FontWeight.w700);
          case 'italic':
            style = style.copyWith(fontStyle: FontStyle.italic);
          case 'underline':
            decorations.add(TextDecoration.underline);
          case 'strike':
            decorations.add(TextDecoration.lineThrough);
          case 'code':
            style = style.copyWith(
              fontFamily: 'monospace',
              fontSize: (base.fontSize ?? 14) * 0.9,
              color: scheme.primary,
              backgroundColor: scheme.surfaceContainerHighest,
            );
          case 'link':
            style = style.copyWith(color: scheme.primary);
            decorations.add(TextDecoration.underline);
          case 'highlight':
            // Marker yellow, matching the editor.
            style = style.copyWith(
              backgroundColor: const Color(0xFFFACC15).withValues(alpha: 0.42),
            );
          case 'superscript':
            shift = PlaceholderAlignment.top;
          case 'subscript':
            shift = PlaceholderAlignment.bottom;
        }
      }
      if (decorations.isNotEmpty) {
        style = style.copyWith(decoration: TextDecoration.combine(decorations));
      }
      final text = (child['text'] ?? '').toString();
      if (shift != null) {
        children.add(
          WidgetSpan(
            alignment: shift,
            child: Text(
              text,
              style: base
                  .merge(style)
                  .copyWith(fontSize: (base.fontSize ?? 14) * 0.72),
            ),
          ),
        );
        continue;
      }
      children.add(TextSpan(text: text, style: style));
    }
    return TextSpan(style: base, children: children);
  }
}
