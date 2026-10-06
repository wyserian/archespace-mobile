import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:archespace_mobile/src/features/items/data/item_repository.dart';
import 'package:archespace_mobile/src/features/items/domain/code_highlight.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/presentation/kanban_editor.dart';
import 'package:archespace_mobile/src/features/items/presentation/rich_text_web_editor.dart';
import 'package:archespace_mobile/src/features/items/presentation/whiteboard_web_editor.dart';
import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/util/errors.dart';

/// Full-screen editor for one item. Pass [existing] to edit, or [type] (with no
/// [existing]) to create. The per-type body editor mutates [_content] in place;
/// Save re-encrypts and writes to Supabase, then pops `true` so the caller can
/// refresh. With [readOnly] (an item in a read-only space) it's a viewer: the
/// content stays selectable and copyable, but nothing can change or save.
class ItemEditorScreen extends StatefulWidget {
  const ItemEditorScreen({
    super.key,
    required this.spaceId,
    required this.type,
    this.existing,
    this.readOnly = false,
  });

  /// The item's space, or null for a dashboard item (belongs to no space).
  final String? spaceId;
  final String type;
  final SpaceItem? existing;
  final bool readOnly;

  @override
  State<ItemEditorScreen> createState() => _ItemEditorScreenState();
}

class _ItemEditorScreenState extends State<ItemEditorScreen> {
  late final TextEditingController _title = TextEditingController(
    text: widget.existing?.title ?? '',
  );
  late final Map<String, dynamic> _content = _initialContent();
  // The Whiteboard reports its last edit only when asked (before a save).
  final WhiteboardController _whiteboard = WhiteboardController();

  // Null until the item exists in the backend. Set after the first save of a
  // new item so later auto-saves update it instead of creating duplicates.
  late String? _itemId = widget.existing?.id;

  bool _saving = false;

  // Snapshot of the last persisted state, for change detection.
  late String _savedTitle = (widget.existing?.title ?? '').trim();
  late String _savedContentJson = jsonEncode(_content);
  // The item's type as edited: a List switches between bullets (menu_list)
  // and numbers (numbered_list) with its Numbered checkbox.
  late String _type = widget.type;
  late String _savedType = widget.type;
  // True once any save has succeeded, so the caller refreshes on close.
  bool _savedAny = false;

  // Previous auto-save tick's snapshot, so we only save once edits settle
  // (no change since the last tick) rather than on every keystroke.
  late String _tickTitle = _title.text;
  late String _tickContentJson = _savedContentJson;
  late String _tickType = widget.type;
  Timer? _autoSaveTimer;

  Map<String, dynamic> _initialContent() {
    final source = widget.existing?.content ?? defaultContentFor(widget.type);
    // Deep copy so editing never mutates the item still shown in the list.
    return jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  }

  @override
  void initState() {
    super.initState();
    if (widget.readOnly) return; // nothing to save
    _autoSaveTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _autoTick(),
    );
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _title.dispose();
    super.dispose();
  }

  bool _isDirty() =>
      _title.text.trim() != _savedTitle ||
      jsonEncode(_content) != _savedContentJson ||
      _type != _savedType;

  // Auto-save unsaved edits once they settle (unchanged since the last tick),
  // so we don't write on every keystroke.
  void _autoTick() {
    if (_saving) return;
    final curTitle = _title.text;
    final curJson = jsonEncode(_content);
    final dirty =
        curTitle.trim() != _savedTitle ||
        curJson != _savedContentJson ||
        _type != _savedType;
    final settled =
        curTitle == _tickTitle &&
        curJson == _tickContentJson &&
        _type == _tickType;
    _tickTitle = curTitle;
    _tickContentJson = curJson;
    _tickType = _type;
    if (dirty && settled) _save(silent: true);
  }

  /// Persists the item. Returns true on success. [silent] suppresses the error
  /// snackbar (used by background auto-save). Never navigates.
  Future<bool> _save({bool silent = false}) async {
    if (_saving || widget.readOnly) return false;
    setState(() => _saving = true);
    final repo = ItemRepository(VaultSession.instance.masterKey);
    try {
      final title = _title.text.trim();
      final type = _type;
      if (_itemId != null) {
        await repo.updateItem(
          id: _itemId!,
          spaceId: widget.spaceId,
          type: type,
          title: title,
          content: _content,
        );
      } else {
        _itemId = await repo.createItem(
          spaceId: widget.spaceId,
          type: type,
          title: title,
          content: _content,
        );
      }
      _savedTitle = title;
      _savedContentJson = jsonEncode(_content);
      _savedType = type;
      _savedAny = true;
      if (mounted) setState(() => _saving = false);
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        if (!silent) showErrorSnack(context, saveErrorMessage(e));
      }
      return false;
    }
  }

  Future<void> _saveAndClose() async {
    await _whiteboard.flush();
    if (await _save() && mounted) await _close(true);
  }

  // Flush on leave: save pending edits, then close. On a save failure the user
  // stays in the editor (with the error) so nothing is lost.
  Future<void> _handleBack() async {
    await _whiteboard.flush();
    if (widget.readOnly || !_isDirty()) {
      if (mounted) await _close(_savedAny);
      return;
    }
    if (await _save() && mounted) await _close(true);
  }

  /// Close the editor with the keyboard put away first. Leaving while the
  /// Rich text editor's keyboard is up (it belongs to a WebView) can leave the
  /// screens below sized as if it were still open, cut off above where the
  /// keyboard was; so wait (briefly) until Android reports it closed.
  Future<void> _close(bool result) async {
    final view = View.of(context);
    FocusManager.instance.primaryFocus?.unfocus();
    if (view.viewInsets.bottom > 0) {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      for (var i = 0; i < 25 && view.viewInsets.bottom > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    if (mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final label = itemTypeDef(widget.type)?.label ?? 'Item';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBack();
      },
      // Opt out of the app-wide compact padding so writing longer text stays
      // comfortable, but keep the same rounded outline with an inside
      // placeholder for the form fields here.
      child: Theme(
        data: Theme.of(context).copyWith(
          inputDecorationTheme: const InputDecorationTheme(
            floatingLabelBehavior: FloatingLabelBehavior.never,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
        ),
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              widget.readOnly
                  ? label
                  : widget.existing != null
                  ? 'Edit $label'
                  : 'New $label',
            ),
            actions: [
              if (widget.readOnly)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Tooltip(
                    message: 'Read-only space',
                    child: Icon(Icons.edit_off_outlined, size: 20),
                  ),
                )
              else if (_saving)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  onPressed: _saveAndClose,
                  icon: const Icon(Icons.check),
                  tooltip: 'Save',
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            // Top trimmed to 8 so the title sits a uniform, small distance
            // below the app bar (matching the divider gap beneath it); bottom
            // trimmed to 8 so the trailing add button (list/card/table
            // editors) sits a uniform, small distance from the screen edge.
            // Rich text runs edge to edge: its page pads itself and its
            // toolbar spans the screen above the keyboard.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    controller: _title,
                    readOnly: widget.readOnly,
                    style: Theme.of(context).textTheme.titleLarge,
                    decoration: InputDecoration(
                      hintText: widget.readOnly ? 'Untitled' : 'Title',
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(height: 8),
                ),
                Expanded(
                  child: _isRichText
                      ? _buildBody()
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: _buildBody(),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Rich text, or an old Markdown note (it opens in the Rich text editor and
  // saves as Rich text).
  bool get _isRichText =>
      widget.type == 'richtext' || widget.type == 'markdown';

  /// A Rich text edit: the new document replaces the content (converting an
  /// older format on its first change), and the item becomes Rich text.
  void _onRichDoc(Map<String, dynamic> doc) {
    _content
      ..clear()
      ..['doc'] = doc;
    _type = 'richtext';
  }

  /// A Whiteboard edit: the board's new content replaces the old (converting
  /// an old drawing on open).
  void _onBoard(Map<String, dynamic> board) {
    _content
      ..clear()
      ..addAll(board);
  }

  Widget _buildBody() {
    final readOnly = widget.readOnly;
    switch (widget.type) {
      case 'textbox':
        return _NoteEditor(content: _content, readOnly: readOnly);
      case 'richtext':
      case 'markdown':
        return RichTextWebEditor(
          type: widget.type,
          content: Map<String, dynamic>.of(_content),
          readOnly: readOnly,
          onChanged: _onRichDoc,
        );
      case 'code':
        return _CodeEditor(content: _content, readOnly: readOnly);
      case 'menu_list':
      case 'numbered_list':
        // One List type: bullets or numbers, switched by its checkbox.
        return _ListEditor(
          content: _content,
          variant: _type == 'numbered_list'
              ? _ListVariant.numbered
              : _ListVariant.bullet,
          readOnly: readOnly,
          onNumberedChanged: (numbered) =>
              setState(() => _type = numbered ? 'numbered_list' : 'menu_list'),
        );
      case 'checkbox_list':
        return _ListEditor(
          content: _content,
          variant: _ListVariant.checklist,
          readOnly: readOnly,
        );
      case 'card_list':
        return _CardsEditor(content: _content, readOnly: readOnly);
      case 'table':
        return _TableEditor(content: _content, readOnly: readOnly);
      case 'kanban':
        return KanbanEditor(content: _content, readOnly: readOnly);
      case 'whiteboard':
        return WhiteboardWebEditor(
          content: Map<String, dynamic>.of(_content),
          readOnly: readOnly,
          controller: _whiteboard,
          onChanged: _onBoard,
        );
      default:
        return Center(child: Text("You can't edit this item type yet."));
    }
  }
}

/// Plain multiline text editor for note / markdown content (`{ text }`).
class _NoteEditor extends StatefulWidget {
  const _NoteEditor({required this.content, this.readOnly = false});

  final Map<String, dynamic> content;
  final bool readOnly;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  late final TextEditingController _text = TextEditingController(
    text: (widget.content['text'] ?? '').toString(),
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      readOnly: widget.readOnly,
      onChanged: (value) => widget.content['text'] = value,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      decoration: InputDecoration(
        hintText: widget.readOnly ? 'Empty' : 'Start writing...',
        border: InputBorder.none,
      ),
    );
  }
}

/// Plain monospace, tab-friendly editor for the `code` item type
/// (`{ code: "..." }`). Editing is unstyled monospace; syntax highlighting is
/// applied in the read view (item card), where the language is auto-detected.
class _CodeEditor extends StatefulWidget {
  const _CodeEditor({required this.content, this.readOnly = false});

  final Map<String, dynamic> content;
  final bool readOnly;

  @override
  State<_CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<_CodeEditor> {
  late final CodeHighlightController _code = CodeHighlightController(
    text: (widget.content['code'] ?? '').toString(),
    theme: codeHighlightTheme(
      // Placeholder; the real base colour is set per-build from the theme.
      const Color(0xFF000000),
    ),
  );

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Plain field (no box) like the other editors; text is live-highlighted.
    return TextField(
      controller: _code,
      readOnly: widget.readOnly,
      onChanged: (value) => widget.content['code'] = value,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        height: 1.5,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: widget.readOnly ? 'Empty' : 'Paste or write code...',
        border: InputBorder.none,
        isCollapsed: true,
      ),
    );
  }
}

enum _ListVariant { bullet, numbered, checklist }

/// Editable rows for `menu_list` / `numbered_list` / `checkbox_list`
/// (`{ items: [{id, text, checked?}] }`). Add, edit, remove, and drag to
/// reorder. [variant] controls the leading marker (bullet / number / checkbox).
class _ListEditor extends StatefulWidget {
  const _ListEditor({
    required this.content,
    required this.variant,
    this.readOnly = false,
    this.onNumberedChanged,
  });

  final Map<String, dynamic> content;
  final _ListVariant variant;
  final bool readOnly;

  /// For the List type: shows a Numbered checkbox that switches between
  /// bullets and numbers. Null (checklists) hides it.
  final ValueChanged<bool>? onNumberedChanged;

  @override
  State<_ListEditor> createState() => _ListEditorState();
}

class _ListEditorState extends State<_ListEditor> {
  late final List<Map<String, dynamic>> _items;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};

  @override
  void initState() {
    super.initState();
    _items = (((widget.content['items'] as List?) ?? const []))
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    for (final item in _items) {
      item['id'] ??= _uid();
    }
    // Share the same list instance so edits flow into the saved content.
    widget.content['items'] = _items;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(Map<String, dynamic> item) {
    return _controllers.putIfAbsent(
      item['id'] as String,
      () => TextEditingController(text: (item['text'] ?? '').toString()),
    );
  }

  FocusNode _focusNodeFor(Map<String, dynamic> item) =>
      _focusNodes.putIfAbsent(item['id'] as String, () => FocusNode());

  /// Enter splits the current item at the cursor: text before it stays, text
  /// after it moves into a fresh item that takes focus.
  void _insertAfter(int index, String text) {
    final newItem = <String, dynamic>{
      'id': _uid(),
      'text': text,
      if (widget.variant == _ListVariant.checklist) 'checked': false,
    };
    _controllers[newItem['id'] as String] = TextEditingController(text: text);
    setState(() => _items.insert(index + 1, newItem));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNodeFor(newItem).requestFocus(),
    );
  }

  void _add() {
    setState(
      () => _items.add({
        'id': _uid(),
        'text': '',
        if (widget.variant == _ListVariant.checklist) 'checked': false,
      }),
    );
  }

  Widget _leading(int index, Map<String, dynamic> item) {
    switch (widget.variant) {
      case _ListVariant.numbered:
        return SizedBox(
          width: 28,
          child: Text('${index + 1}.', textAlign: TextAlign.center),
        );
      case _ListVariant.bullet:
        return const SizedBox(
          width: 28,
          child: Text('•', textAlign: TextAlign.center),
        );
      case _ListVariant.checklist:
        return Checkbox(
          value: (item['checked'] ?? false) == true,
          onChanged: widget.readOnly
              ? null
              : (value) => setState(() => item['checked'] = value ?? false),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
    }
  }

  void _remove(int index) {
    final id = _items[index]['id'] as String;
    setState(() => _items.removeAt(index));
    _controllers.remove(id)?.dispose();
    _focusNodes.remove(id)?.dispose();
  }

  /// `newIndex` arrives already adjusted for the removed item (onReorderItem).
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            itemCount: _items.length,
            onReorderItem: _reorder,
            buildDefaultDragHandles: !widget.readOnly,
            itemBuilder: (context, index) {
              final item = _items[index];
              return Padding(
                key: ValueKey(item['id']),
                padding: EdgeInsets.zero,
                child: Row(
                  children: [
                    _leading(index, item),
                    Expanded(
                      child: TextField(
                        controller: _controllerFor(item),
                        focusNode: _focusNodeFor(item),
                        readOnly: widget.readOnly,
                        onChanged: (value) {
                          final nl = value.indexOf('\n');
                          if (nl < 0) {
                            item['text'] = value;
                            return;
                          }
                          // Enter pressed: keep text before the newline, push
                          // the rest into a new item instead of a line break.
                          final before = value.substring(0, nl);
                          final after = value.substring(nl + 1);
                          item['text'] = before;
                          _controllers[item['id']]!.value = TextEditingValue(
                            text: before,
                            selection: TextSelection.collapsed(
                              offset: before.length,
                            ),
                          );
                          _insertAfter(index, after);
                        },
                        // Wraps long text onto new lines; Enter is intercepted
                        // above to create a new item instead of a line break.
                        minLines: 1,
                        maxLines: null,
                        style:
                            widget.variant == _ListVariant.checklist &&
                                (item['checked'] ?? false) == true
                            ? const TextStyle(
                                decoration: TextDecoration.lineThrough,
                              )
                            : null,
                        decoration: InputDecoration(
                          hintText: widget.readOnly ? null : 'Item...',
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 1,
                          ),
                        ),
                      ),
                    ),
                    if (!widget.readOnly) ...[
                      IconButton(
                        onPressed: () => _remove(index),
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Remove',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            Icons.drag_handle,
                            size: 18,
                            semanticLabel: 'Drag to reorder',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
        if (!widget.readOnly) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Add item'),
                style: TextButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const Spacer(),
              if (widget.onNumberedChanged != null)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => widget.onNumberedChanged!(
                    widget.variant != _ListVariant.numbered,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: widget.variant == _ListVariant.numbered,
                        onChanged: (v) => widget.onNumberedChanged!(v ?? false),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      const Text('Numbered'),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

int _idCounter = 0;
String _uid() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_idCounter++).toRadixString(36)}';

/// Editable cards for `card_list` (`{ items: [{id, title, description}] }`).
/// Two fields per card; add, remove, and drag to reorder.
class _CardsEditor extends StatefulWidget {
  const _CardsEditor({required this.content, this.readOnly = false});

  final Map<String, dynamic> content;
  final bool readOnly;

  @override
  State<_CardsEditor> createState() => _CardsEditorState();
}

class _CardsEditorState extends State<_CardsEditor> {
  late final List<Map<String, dynamic>> _items;
  final Map<String, TextEditingController> _titleCtrls = {};
  final Map<String, TextEditingController> _descCtrls = {};

  @override
  void initState() {
    super.initState();
    _items = (((widget.content['items'] as List?) ?? const []))
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    for (final item in _items) {
      item['id'] ??= _uid();
    }
    widget.content['items'] = _items;
  }

  @override
  void dispose() {
    for (final controller in _titleCtrls.values) {
      controller.dispose();
    }
    for (final controller in _descCtrls.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _titleFor(Map<String, dynamic> item) =>
      _titleCtrls.putIfAbsent(
        item['id'] as String,
        () => TextEditingController(text: (item['title'] ?? '').toString()),
      );

  TextEditingController _descFor(Map<String, dynamic> item) =>
      _descCtrls.putIfAbsent(
        item['id'] as String,
        () =>
            TextEditingController(text: (item['description'] ?? '').toString()),
      );

  void _add() {
    setState(() => _items.add({'id': _uid(), 'title': '', 'description': ''}));
  }

  void _remove(int index) {
    final id = _items[index]['id'] as String;
    setState(() => _items.removeAt(index));
    _titleCtrls.remove(id)?.dispose();
    _descCtrls.remove(id)?.dispose();
  }

  /// `newIndex` arrives already adjusted for the removed item (onReorderItem).
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            itemCount: _items.length,
            onReorderItem: _reorder,
            buildDefaultDragHandles: !widget.readOnly,
            itemBuilder: (context, index) {
              final item = _items[index];
              final scheme = Theme.of(context).colorScheme;
              final border = scheme.outlineVariant.withValues(alpha: 0.5);
              return Padding(
                key: ValueKey(item['id']),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _titleFor(item),
                              readOnly: widget.readOnly,
                              onChanged: (value) => item['title'] = value,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: InputDecoration(
                                hintText: widget.readOnly ? null : 'Title',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                          if (!widget.readOnly) ...[
                            IconButton(
                              onPressed: () => _remove(index),
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Remove',
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: const Padding(
                                padding: EdgeInsets.all(6),
                                child: Icon(
                                  Icons.drag_handle,
                                  size: 18,
                                  semanticLabel: 'Drag to reorder',
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      // Separator between the card's heading and its content.
                      Padding(
                        padding: const EdgeInsets.only(right: 4, bottom: 4),
                        child: Divider(height: 1, color: border),
                      ),
                      TextField(
                        controller: _descFor(item),
                        readOnly: widget.readOnly,
                        onChanged: (value) => item['description'] = value,
                        minLines: 1,
                        maxLines: null,
                        decoration: InputDecoration(
                          hintText: widget.readOnly ? null : 'Description',
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (!widget.readOnly) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add card'),
              style: TextButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

const double _kCellWidth = 150;

/// Grid editor for `table` (`{ columns: [labels], rows: [[cells]] }`). Edit the
/// header + cells, add/remove columns and rows. The grid is kept rectangular
/// (every row has one cell per column). Scrolls both axes.
class _TableEditor extends StatefulWidget {
  const _TableEditor({required this.content, this.readOnly = false});

  final Map<String, dynamic> content;
  final bool readOnly;

  @override
  State<_TableEditor> createState() => _TableEditorState();
}

class _TableEditorState extends State<_TableEditor> {
  late final List<String> _columns;
  late final List<List<String>> _rows;
  late final List<TextEditingController> _colCtrls;
  late final List<List<TextEditingController>> _cellCtrls;

  @override
  void initState() {
    super.initState();
    _columns = (((widget.content['columns'] as List?) ?? const []))
        .map((e) => (e ?? '').toString())
        .toList();
    if (_columns.isEmpty) {
      _columns.addAll(['', '']);
    }
    _rows = (((widget.content['rows'] as List?) ?? const []))
        .map(
          (r) => (((r as List?) ?? const []))
              .map((e) => (e ?? '').toString())
              .toList(),
        )
        .toList();
    // Keep every row the width of the header.
    for (final row in _rows) {
      while (row.length < _columns.length) {
        row.add('');
      }
      if (row.length > _columns.length) {
        row.removeRange(_columns.length, row.length);
      }
    }
    if (_rows.isEmpty) {
      _rows.add(List<String>.filled(_columns.length, '', growable: true));
    }

    _colCtrls = [for (final c in _columns) TextEditingController(text: c)];
    _cellCtrls = [
      for (final row in _rows)
        [for (final cell in row) TextEditingController(text: cell)],
    ];

    // Share the same list instances so edits flow into the saved content.
    widget.content['columns'] = _columns;
    widget.content['rows'] = _rows;
  }

  @override
  void dispose() {
    for (final controller in _colCtrls) {
      controller.dispose();
    }
    for (final row in _cellCtrls) {
      for (final controller in row) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  void _addColumn() {
    setState(() {
      _columns.add('');
      _colCtrls.add(TextEditingController());
      for (var r = 0; r < _rows.length; r++) {
        _rows[r].add('');
        _cellCtrls[r].add(TextEditingController());
      }
    });
  }

  void _removeColumn(int c) {
    if (_columns.length <= 1) return;
    setState(() {
      _columns.removeAt(c);
      _colCtrls.removeAt(c).dispose();
      for (var r = 0; r < _rows.length; r++) {
        _rows[r].removeAt(c);
        _cellCtrls[r].removeAt(c).dispose();
      }
    });
  }

  void _addRow() {
    setState(() {
      _rows.add(List<String>.filled(_columns.length, '', growable: true));
      _cellCtrls.add([
        for (var c = 0; c < _columns.length; c++) TextEditingController(),
      ]);
    });
  }

  void _removeRow(int r) {
    if (_rows.length <= 1) return;
    setState(() {
      _rows.removeAt(r);
      for (final controller in _cellCtrls.removeAt(r)) {
        controller.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final border = Border.all(color: Theme.of(context).dividerColor);
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row + add-column button.
                  Row(
                    children: [
                      for (var c = 0; c < _columns.length; c++)
                        Container(
                          width: _kCellWidth,
                          decoration: BoxDecoration(
                            border: border,
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                          ),
                          padding: const EdgeInsets.only(left: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _colCtrls[c],
                                  readOnly: widget.readOnly,
                                  onChanged: (v) => _columns[c] = v,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: widget.readOnly
                                        ? null
                                        : 'Column ${c + 1}',
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                ),
                              ),
                              if (!widget.readOnly && _columns.length > 1)
                                InkWell(
                                  onTap: () => _removeColumn(c),
                                  child: const Padding(
                                    padding: EdgeInsets.all(6),
                                    child: Icon(Icons.close, size: 14),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      if (!widget.readOnly)
                        IconButton(
                          onPressed: _addColumn,
                          icon: const Icon(Icons.add),
                          tooltip: 'Add column',
                        ),
                    ],
                  ),
                  // Data rows + remove-row button.
                  for (var r = 0; r < _rows.length; r++)
                    Row(
                      children: [
                        for (var c = 0; c < _columns.length; c++)
                          Container(
                            width: _kCellWidth,
                            decoration: BoxDecoration(border: border),
                            child: TextField(
                              controller: _cellCtrls[r][c],
                              readOnly: widget.readOnly,
                              onChanged: (v) => _rows[r][c] = v,
                              minLines: 1,
                              maxLines: null,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                        if (!widget.readOnly)
                          IconButton(
                            onPressed: _rows.length > 1
                                ? () => _removeRow(r)
                                : null,
                            icon: const Icon(Icons.close, size: 16),
                            tooltip: 'Remove row',
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
        if (!widget.readOnly) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addRow,
              icon: const Icon(Icons.add),
              label: const Text('Add row'),
              style: TextButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
