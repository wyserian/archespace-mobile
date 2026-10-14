import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The Rich text editor: the web app's Tiptap editor, bundled offline into
/// `assets/rich_text_editor.html` (built from the web repo with
/// `npm run build:mobile-editor`), running in a WebView under a native
/// toolbar. Both platforms therefore save identical Tiptap JSON.
///
/// [onChanged] receives the new document (`{ type: 'doc', ... }`) after each
/// edit, and once on load when older content (the old Rich text HTML or the
/// old Markdown type) was converted, so the host can save the new format.
class RichTextWebEditor extends StatefulWidget {
  const RichTextWebEditor({
    super.key,
    required this.type,
    required this.content,
    required this.onChanged,
    this.readOnly = false,
  });

  /// 'richtext', or 'markdown' for an old Markdown note (converted on load).
  final String type;
  final Map<String, dynamic> content;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool readOnly;

  @override
  State<RichTextWebEditor> createState() => _RichTextWebEditorState();
}

class _RichTextWebEditorState extends State<RichTextWebEditor> {
  late final WebViewController _web;
  bool _ready = false;
  bool _pageLoaded = false;
  Map<String, dynamic> _active = const {};
  bool _canUndo = false;
  bool _canRedo = false;

  // Find and replace (the editor's searchReplace extension, via the bridge).
  bool _searchOpen = false;
  final TextEditingController _find = TextEditingController();
  final TextEditingController _replace = TextEditingController();
  bool _matchCase = false;
  bool _wholeWords = false;
  bool _regex = false;
  int _matchCount = 0;
  int _matchIndex = 0;
  bool _searchInvalid = false;

  @override
  void dispose() {
    _find.dispose();
    _replace.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Only the bundled editor page loads; anything else (a tapped link,
          // a script) is blocked. The page's own CSP also blocks the network.
          onNavigationRequest: (request) {
            if (_pageLoaded) return NavigationDecision.prevent;
            _pageLoaded = true;
            return NavigationDecision.navigate;
          },
        ),
      )
      ..addJavaScriptChannel('Arche', onMessageReceived: _onMessage)
      ..loadFlutterAsset('assets/rich_text_editor.html');
  }

  Map<String, String> _themeColors() {
    final scheme = Theme.of(context).colorScheme;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return {
      'bg': hex(scheme.surface),
      'text': hex(scheme.onSurface),
      'muted': hex(scheme.onSurfaceVariant),
      'border': hex(scheme.outlineVariant),
      'surface': hex(scheme.surfaceContainerHighest),
      'accent': hex(scheme.primary),
    };
  }

  Future<void> _call(String js) async {
    try {
      await _web.runJavaScript(js);
    } catch (_) {
      // Page not ready or torn down: ignore.
    }
  }

  void _onMessage(JavaScriptMessage message) {
    final msg = jsonDecode(message.message);
    if (msg is! Map) return;
    switch (msg['type']) {
      case 'ready':
        _call('editorApi.setTheme(${jsonEncode(_themeColors())})');
        _call(
          'editorApi.load(${jsonEncode({'type': widget.type, 'content': widget.content, 'editable': !widget.readOnly})})',
        );
        if (mounted) setState(() => _ready = true);
      case 'state':
        if (!mounted) return;
        setState(() {
          _active = (msg['active'] as Map? ?? const {}).cast<String, dynamic>();
          _canUndo = msg['canUndo'] == true;
          _canRedo = msg['canRedo'] == true;
          final search = msg['search'];
          if (search is Map) {
            _matchCount = (search['count'] as num?)?.toInt() ?? 0;
            _matchIndex = (search['index'] as num?)?.toInt() ?? 0;
            _searchInvalid = search['invalid'] == true;
          }
        });
      case 'change':
      case 'converted':
        final doc = msg['doc'];
        if (doc is Map) widget.onChanged(doc.cast<String, dynamic>());
    }
  }

  void _exec(String cmd, [Object? arg]) {
    final a = arg == null ? '' : ', ${jsonEncode(arg)}';
    _call('editorApi.exec(${jsonEncode(cmd)}$a)');
  }

  Future<void> _link() async {
    final current = (_active['linkHref'] ?? '').toString();
    final controller = TextEditingController(
      text: current.isEmpty ? 'https://' : current,
    );
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://'),
        ),
        actions: [
          if (current.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null) return;
    _exec('link', url.isEmpty || url == 'https://' ? null : url);
  }

  Widget _btn(IconData icon, String tip, String cmd, {String? state}) {
    final on = state != null && _active[state] == true;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(icon, size: 21),
      tooltip: tip,
      isSelected: on,
      color: on ? scheme.primary : scheme.onSurfaceVariant,
      style: on
          ? IconButton.styleFrom(backgroundColor: scheme.primaryContainer)
          : null,
      visualDensity: VisualDensity.compact,
      onPressed: _ready ? () => _exec(cmd) : null,
    );
  }

  // Find and replace

  void _runSearch() {
    _call(
      'editorApi.search(${jsonEncode({'term': _find.text, 'replace': _replace.text, 'caseSensitive': _matchCase, 'wholeWord': _wholeWords, 'regex': _regex})})',
    );
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    if (_find.text.isNotEmpty) _runSearch();
  }

  /// Close the panel and clear the highlights (the terms are kept for next
  /// time).
  void _closeSearch() {
    setState(() => _searchOpen = false);
    _call('editorApi.search(${jsonEncode({'term': ''})})');
  }

  Widget _searchPanel() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    InputDecoration field(String hint, {bool error = false}) => InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: error
          ? OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: scheme.error),
            )
          : null,
    );
    Widget option(String label, bool value, ValueChanged<bool> onChanged) =>
        FilterChip(
          label: Text(label),
          selected: value,
          showCheckmark: true,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onSelected: (v) {
            setState(() => onChanged(v));
            _runSearch();
          },
        );
    final hasMatches = _matchCount > 0;
    return Material(
      color: scheme.surfaceContainer,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _find,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: field('Search', error: _searchInvalid),
                    onChanged: (_) => _runSearch(),
                    // Enter steps to the next match and keeps the keyboard.
                    onEditingComplete: () {},
                    onSubmitted: (_) => _call('editorApi.nextMatch()'),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${hasMatches ? _matchIndex + 1 : 0} / $_matchCount',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up),
                  tooltip: 'Previous match',
                  visualDensity: VisualDensity.compact,
                  onPressed: hasMatches
                      ? () => _call('editorApi.previousMatch()')
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down),
                  tooltip: 'Next match',
                  visualDensity: VisualDensity.compact,
                  onPressed: hasMatches
                      ? () => _call('editorApi.nextMatch()')
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close find and replace',
                  visualDensity: VisualDensity.compact,
                  onPressed: _closeSearch,
                ),
              ],
            ),
            if (_searchInvalid)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  'Not a valid regular expression.',
                  style: textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _replace,
                    decoration: field('Replace'),
                    onChanged: (_) => _runSearch(),
                    onEditingComplete: () {},
                    onSubmitted: (_) => _call('editorApi.replaceMatch()'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: hasMatches
                      ? () => _call('editorApi.replaceMatch()')
                      : null,
                  child: const Text('Replace'),
                ),
                FilledButton.tonal(
                  onPressed: hasMatches
                      ? () => _call('editorApi.replaceAll()')
                      : null,
                  child: const Text('All'),
                ),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                option('Match case', _matchCase, (v) => _matchCase = v),
                option('Whole words', _wholeWords, (v) => _wholeWords = v),
                option('Regex', _regex, (v) => _regex = v),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A toolbar button with a menu (Heading, List, Alignment, Table).
  Widget _menu<T>({
    required IconData icon,
    required String tip,
    required bool active,
    required List<PopupMenuEntry<T>> items,
    required ValueChanged<T> onSelected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return PopupMenuButton<T>(
      tooltip: tip,
      enabled: _ready,
      onSelected: onSelected,
      itemBuilder: (_) => items,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: active ? scheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 21, color: color),
            Icon(Icons.arrow_drop_down, size: 16, color: color),
          ],
        ),
      ),
    );
  }

  PopupMenuEntry<T> _item<T>(T value, IconData icon, String label, bool on) =>
      CheckedPopupMenuItem<T>(
        value: value,
        checked: on,
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Text(label),
          ],
        ),
      );

  Widget _sep() => Container(
    width: 1,
    height: 22,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: Theme.of(context).colorScheme.outlineVariant,
  );

  /// Grouped like the web toolbar: history | blocks | inline formatting |
  /// super/subscript | alignment | table.
  Widget _toolbar() {
    final scheme = Theme.of(context).colorScheme;
    final heading = (_active['heading'] as num?)?.toInt() ?? 0;
    final align = (_active['align'] ?? 'left').toString();
    final lineHeight = _active['lineHeight']?.toString();
    final inTable = _active['table'] == true;
    bool on(String key) => _active[key] == true;
    const headingIcons = {
      0: Icons.notes,
      1: Icons.looks_one_outlined,
      2: Icons.looks_two_outlined,
      3: Icons.looks_3_outlined,
      4: Icons.looks_4_outlined,
    };
    const alignIcons = {
      'left': Icons.format_align_left,
      'center': Icons.format_align_center,
      'right': Icons.format_align_right,
      'justify': Icons.format_align_justify,
    };
    return Material(
      color: scheme.surfaceContainer,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.undo, size: 21),
                tooltip: 'Undo',
                visualDensity: VisualDensity.compact,
                onPressed: _canUndo ? () => _exec('undo') : null,
              ),
              IconButton(
                icon: const Icon(Icons.redo, size: 21),
                tooltip: 'Redo',
                visualDensity: VisualDensity.compact,
                onPressed: _canRedo ? () => _exec('redo') : null,
              ),
              _sep(),
              _menu<int>(
                icon: heading > 0 ? headingIcons[heading]! : Icons.title,
                tip: 'Heading',
                active: heading > 0,
                onSelected: (level) =>
                    _exec('heading', level == 0 ? null : level),
                items: [
                  _item(0, headingIcons[0]!, 'Text', heading == 0),
                  _item(1, headingIcons[1]!, 'Heading 1', heading == 1),
                  _item(2, headingIcons[2]!, 'Heading 2', heading == 2),
                  _item(3, headingIcons[3]!, 'Heading 3', heading == 3),
                  _item(4, headingIcons[4]!, 'Heading 4', heading == 4),
                ],
              ),
              _menu<String>(
                icon: on('orderedList')
                    ? Icons.format_list_numbered
                    : on('taskList')
                    ? Icons.checklist
                    : Icons.format_list_bulleted,
                tip: 'List',
                active: on('bulletList') || on('orderedList') || on('taskList'),
                onSelected: _exec,
                items: [
                  _item(
                    'bulletList',
                    Icons.format_list_bulleted,
                    'Bullet list',
                    on('bulletList'),
                  ),
                  _item(
                    'orderedList',
                    Icons.format_list_numbered,
                    'Numbered list',
                    on('orderedList'),
                  ),
                  _item(
                    'taskList',
                    Icons.checklist,
                    'Task list',
                    on('taskList'),
                  ),
                ],
              ),
              _btn(
                Icons.format_quote,
                'Quote',
                'blockquote',
                state: 'blockquote',
              ),
              _btn(
                Icons.data_object,
                'Code block',
                'codeBlock',
                state: 'codeBlock',
              ),
              _sep(),
              _btn(Icons.format_bold, 'Bold', 'bold', state: 'bold'),
              _btn(Icons.format_italic, 'Italic', 'italic', state: 'italic'),
              _btn(
                Icons.format_strikethrough,
                'Strikethrough',
                'strike',
                state: 'strike',
              ),
              _btn(Icons.code, 'Inline code', 'code', state: 'code'),
              _btn(
                Icons.format_underlined,
                'Underline',
                'underline',
                state: 'underline',
              ),
              _btn(
                Icons.border_color_outlined,
                'Highlight',
                'highlight',
                state: 'highlight',
              ),
              IconButton(
                icon: Icon(
                  Icons.link,
                  size: 21,
                  color: on('link') ? scheme.primary : scheme.onSurfaceVariant,
                ),
                tooltip: 'Link',
                visualDensity: VisualDensity.compact,
                onPressed: _ready ? _link : null,
              ),
              _sep(),
              _btn(
                Icons.superscript,
                'Superscript',
                'superscript',
                state: 'superscript',
              ),
              _btn(
                Icons.subscript,
                'Subscript',
                'subscript',
                state: 'subscript',
              ),
              _sep(),
              _menu<String>(
                icon: alignIcons[align] ?? Icons.format_align_left,
                tip: 'Alignment',
                active: align != 'left',
                onSelected: (value) => _exec('align', value),
                items: [
                  _item(
                    'left',
                    alignIcons['left']!,
                    'Align left',
                    align == 'left',
                  ),
                  _item(
                    'center',
                    alignIcons['center']!,
                    'Align centre',
                    align == 'center',
                  ),
                  _item(
                    'right',
                    alignIcons['right']!,
                    'Align right',
                    align == 'right',
                  ),
                  _item(
                    'justify',
                    alignIcons['justify']!,
                    'Justify',
                    align == 'justify',
                  ),
                ],
              ),
              // Line spacing for the selected paragraphs (Normal = default).
              _menu<String>(
                icon: Icons.format_line_spacing,
                tip: 'Line spacing',
                active: lineHeight != null,
                onSelected: (value) =>
                    _exec('lineHeight', value == 'normal' ? null : value),
                items: [
                  for (final (value, label) in [
                    ('1.2', 'Compact'),
                    ('normal', 'Normal'),
                    ('1.8', 'Relaxed'),
                    ('2', 'Double'),
                  ])
                    _item(
                      value,
                      Icons.format_line_spacing,
                      label,
                      (lineHeight ?? 'normal') == value,
                    ),
                ],
              ),
              _sep(),
              _menu<String>(
                icon: Icons.table_chart_outlined,
                tip: 'Table',
                active: inTable,
                onSelected: _exec,
                items: [
                  _item(
                    'table',
                    Icons.table_chart_outlined,
                    'Insert table',
                    false,
                  ),
                  if (inTable) ...[
                    _item(
                      'addRow',
                      Icons.table_rows_outlined,
                      'Add row',
                      false,
                    ),
                    _item(
                      'addColumn',
                      Icons.view_column_outlined,
                      'Add column',
                      false,
                    ),
                    _item(
                      'deleteRow',
                      Icons.playlist_remove,
                      'Delete row',
                      false,
                    ),
                    _item(
                      'deleteColumn',
                      Icons.remove_circle_outline,
                      'Delete column',
                      false,
                    ),
                    _item(
                      'deleteTable',
                      Icons.delete_outline,
                      'Delete table',
                      false,
                    ),
                  ],
                ],
              ),
              _btn(Icons.horizontal_rule, 'Divider', 'hr'),
              _sep(),
              IconButton(
                icon: Icon(
                  Icons.find_replace,
                  size: 21,
                  color: _searchOpen ? scheme.primary : scheme.onSurfaceVariant,
                ),
                tooltip: 'Find and replace',
                isSelected: _searchOpen,
                style: _searchOpen
                    ? IconButton.styleFrom(
                        backgroundColor: scheme.primaryContainer,
                      )
                    : null,
                visualDensity: VisualDensity.compact,
                onPressed: _ready
                    ? () => _searchOpen ? _closeSearch() : _openSearch()
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: WebViewWidget(controller: _web)),
        // ExcludeFocus: tapping the toolbar must not pull focus from the
        // WebView (that would close the keyboard and drop pending formatting).
        // The search panel takes focus for its fields, so it sits outside
        // the toolbar's ExcludeFocus.
        if (!widget.readOnly && _searchOpen) _searchPanel(),
        if (!widget.readOnly) ExcludeFocus(child: _toolbar()),
      ],
    );
  }
}
