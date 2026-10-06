import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:highlight/highlight.dart' show highlight;

import 'package:archespace_mobile/src/features/items/presentation/rich_doc_view.dart';
import 'package:archespace_mobile/src/features/items/presentation/widgets/type_badge.dart';
import 'package:archespace_mobile/src/features/items/domain/rich_doc.dart';
import 'package:archespace_mobile/src/features/items/domain/code_highlight.dart';
import 'package:archespace_mobile/src/features/items/domain/item_clipboard.dart';
import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/items/domain/rich_text_html.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/features/items/domain/whiteboard.dart';
import 'package:archespace_mobile/src/features/upcoming/presentation/reminder_widgets.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/features/vault/presentation/widgets/vault_pin_prompt.dart';
import 'package:archespace_mobile/src/shared/widgets/app_snackbar.dart';
import 'package:archespace_mobile/src/shared/widgets/select_box.dart';

/// Renders one space item as a card: a type badge, title, and a type-specific
/// body preview. Tapping the card opens the full editor; the action menu and
/// copy button handle per-item actions.
class ItemCard extends StatefulWidget {
  const ItemCard({
    super.key,
    required this.item,
    this.onTap,
    this.onTogglePin,
    this.onToggleStar,
    this.onToggleLock,
    this.onDuplicate,
    this.onMove,
    this.onArchive,
    this.onDelete,
    this.onExport,
    this.onSetTags,
    this.onSetReminder,
    this.selectMode = false,
    this.selected = false,
    this.onSelectToggle,
    this.margin,
    this.grid = false,
    this.contextLabel,
    this.readOnly = false,
  });

  final SpaceItem item;
  final VoidCallback? onTap;
  final VoidCallback? onTogglePin;
  final VoidCallback? onToggleStar;

  /// Protect / remove protection. A hidden protected item shows a panel
  /// instead of its content; tapping the card (onTap) asks for the PIN.
  final VoidCallback? onToggleLock;

  /// Where the item lives, shown beside the title when it's listed outside its
  /// space (the Starred view). Null shows just the title.
  final String? contextLabel;

  /// In a read-only space. The host leaves out the editing callbacks; this
  /// only adds a marker when the item is listed outside its space.
  final bool readOnly;
  final VoidCallback? onDuplicate;
  final VoidCallback? onMove;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;
  final VoidCallback? onExport;

  /// Persist a new tag list for this item. Null hides tag editing.
  final void Function(List<String>)? onSetTags;

  /// Open the reminder sheet. Null hides reminder editing.
  final VoidCallback? onSetReminder;
  final bool selectMode;
  final bool selected;
  final VoidCallback? onSelectToggle;
  final EdgeInsetsGeometry? margin;

  /// Whether the card is rendered in the two-column grid view.
  final bool grid;

  @override
  State<ItemCard> createState() => _ItemCardState();
}

// A body taller than this is clamped to this fixed height (clipped, not
// hidden); tapping the card then reveals it in full. The header chevron is a
// separate control that hides the body entirely (header only).
const double _kCollapsedMaxHeight = 480;

// The clamped preview shows ~25 lines, so a very long note or markdown body is
// cut to this many characters for it: laying out a huge string in every card
// that scrolls into view would stutter the list. Expanding shows it all.
const int _kPreviewChars = 4000;

class _ItemCardState extends State<ItemCard>
    with AutomaticKeepAliveClientMixin {
  // Header-only collapse (chevron): hides the body entirely.
  bool _collapsed = false;
  bool _addingTag = false;
  // Measured: is the body taller than the clamp threshold?
  bool _overflowing = false;
  // Set when a long, clamped body is tapped to reveal it in full.
  bool _expanded = false;
  final GlobalKey _bodyKey = GlobalKey();
  final TextEditingController _tagController = TextEditingController();

  @override
  void initState() {
    super.initState();
    ContentLock.instance.addListener(_onLockChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureBody());
  }

  // Whether this card's content was hidden at the last build, so a change
  // change elsewhere doesn't rebuild every card in the list.
  bool? _wasHidden;

  /// An item opened or hidden again: its body is shown or covered.
  void _onLockChanged() {
    if (!mounted) return;
    if (ContentLock.instance.isItemHidden(widget.item) == _wasHidden) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureBody());
  }

  @override
  void didUpdateWidget(covariant ItemCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Content changed (e.g. after an edit) - re-measure the natural height.
    if (oldWidget.item.content != widget.item.content) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureBody());
    }
  }

  /// Measure the body's natural height (it's laid out unclamped,
  /// so this reads the true height) and flag whether the body is "long" - long
  /// bodies clamp to a fixed height until tapped.
  void _measureBody() {
    if (!mounted) return;
    final box = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    final height = box?.size.height;
    if (height == null) return;
    final long = height > _kCollapsedMaxHeight;
    if (long != _overflowing) setState(() => _overflowing = long);
  }

  @override
  void dispose() {
    ContentLock.instance.removeListener(_onLockChanged);
    _tagController.dispose();
    super.dispose();
  }

  // A card the user expanded or collapsed is kept alive off-screen: rebuilt
  // fresh, it would come back at a different height and shift the list.
  @override
  bool get wantKeepAlive => _expanded || _collapsed;

  void _setExpanded() {
    setState(() => _expanded = true);
    updateKeepAlive();
  }

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep-alive bookkeeping
    final item = widget.item;
    final selectMode = widget.selectMode;
    final selected = widget.selected;
    final onTap = widget.onTap;
    final onSelectToggle = widget.onSelectToggle;
    final onTogglePin = widget.onTogglePin;
    final onToggleStar = widget.onToggleStar;
    final onDuplicate = widget.onDuplicate;
    final onMove = widget.onMove;
    final onArchive = widget.onArchive;
    final onDelete = widget.onDelete;
    final onExport = widget.onExport;
    final onToggleLock = widget.onToggleLock;
    final onSetReminder = widget.onSetReminder;
    final scheme = Theme.of(context).colorScheme;
    // Protected (itself or its space) and not opened with the PIN: the content,
    // Copy and Export PDF stay out of reach.
    final hidden = ContentLock.instance.isItemHidden(item);
    _wasHidden = hidden;
    final canCopy = !hidden && isCopyableType(item.type);
    // Styled like a space card: borderless on a lighter surface with a soft
    // shadow, and a soft accent border only when selected. Pinned is shown by
    // the pin marker, so a pinned card has no border.
    final borderSide = selected
        ? BorderSide(color: scheme.primary.withValues(alpha: 0.4), width: 1.5)
        : BorderSide.none;
    return Card(
      margin:
          widget.margin ??
          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainer,
      elevation: 2,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: borderSide,
      ),
      child: InkWell(
        // A clamped (long, not yet expanded) body reveals itself in full on
        // tap; otherwise a tap opens the full editor.
        // A hidden item opens with the PIN: via onTap (which asks first), or
        // here for an item with no editor.
        onTap: selectMode
            ? onSelectToggle
            : (hidden && onTap == null)
            ? _unlock
            : (!hidden && !_collapsed && _overflowing && !_expanded)
            ? _setExpanded
            : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          // A slightly tighter top keeps the header row compact.
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (item.pinned)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.push_pin,
                        size: 16,
                        color: scheme.primary,
                        semanticLabel: 'Pinned',
                      ),
                    ),
                  if (itemTypeDef(item.type) != null)
                    Padding(
                      padding: EdgeInsets.only(right: widget.grid ? 6 : 8),
                      // A smaller badge in the compact grid cards.
                      child: TypeBadge(type: item.type, compact: widget.grid),
                    ),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          flex: 3,
                          child: Text(
                            item.title.isEmpty ? 'Untitled' : item.title,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Starred, right after the name, in the accent.
                        if (item.starred)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.star_rounded,
                              size: 17,
                              color: scheme.primary,
                              semanticLabel: 'Starred',
                            ),
                          ),
                        // Protected: a shield, or once the PIN has opened it,
                        // a button to hide it again.
                        if (hidden)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.shield_outlined,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                              semanticLabel: 'Protected',
                            ),
                          )
                        else if (item.locked)
                          SizedBox(
                            height: 28,
                            width: 28,
                            child: IconButton(
                              icon: Icon(
                                Icons.visibility_off_outlined,
                                size: 16,
                                color: scheme.primary,
                              ),
                              padding: EdgeInsets.zero,
                              tooltip: 'Hide again',
                              onPressed: () =>
                                  ContentLock.instance.hide(item.id),
                            ),
                          ),
                        if (widget.readOnly && widget.contextLabel != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.edit_off_outlined,
                              size: 15,
                              color: scheme.onSurfaceVariant,
                              semanticLabel: 'Read-only',
                            ),
                          ),
                        if (widget.contextLabel != null) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            flex: 2,
                            child: Text(
                              widget.contextLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!selectMode)
                    SizedBox(
                      height: 32,
                      width: 32,
                      child: IconButton(
                        icon: Icon(
                          _collapsed ? Icons.expand_more : Icons.expand_less,
                          size: 20,
                        ),
                        padding: EdgeInsets.zero,
                        tooltip: _collapsed ? 'Expand' : 'Collapse',
                        onPressed: () => _toggleCollapsed(),
                      ),
                    ),
                  // In the compact grid the copy action moves into the 3-dot
                  // menu; the list keeps the quick copy button.
                  if (!selectMode && !widget.grid && canCopy)
                    SizedBox(
                      height: 32,
                      width: 32,
                      child: IconButton(
                        icon: const Icon(Icons.content_copy, size: 16),
                        padding: EdgeInsets.zero,
                        tooltip: 'Copy',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: itemClipboardText(item)),
                          );
                          if (context.mounted) {
                            showSuccessSnack(context, 'Copied to clipboard');
                          }
                        },
                      ),
                    ),
                  if (!selectMode &&
                      (onTogglePin != null ||
                          onToggleStar != null ||
                          onSetReminder != null ||
                          onToggleLock != null ||
                          onDuplicate != null ||
                          onMove != null ||
                          onArchive != null ||
                          (onExport != null && !hidden) ||
                          onDelete != null ||
                          (widget.grid && canCopy)))
                    SizedBox(
                      height: 32,
                      width: 32,
                      child: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 18),
                        padding: EdgeInsets.zero,
                        tooltip: 'Item actions',
                        menuPadding: const EdgeInsets.symmetric(vertical: 4),
                        // Clip the item hover highlight to the menu's rounded
                        // corners so it doesn't poke past them.
                        clipBehavior: Clip.antiAlias,
                        onSelected: (value) async {
                          if (value == 'copy') {
                            await Clipboard.setData(
                              ClipboardData(text: itemClipboardText(item)),
                            );
                            if (context.mounted) {
                              showSuccessSnack(context, 'Copied to clipboard');
                            }
                          }
                          if (value == 'pin') onTogglePin?.call();
                          if (value == 'star') onToggleStar?.call();
                          if (value == 'reminder') onSetReminder?.call();
                          if (value == 'lock') onToggleLock?.call();
                          if (value == 'duplicate') onDuplicate?.call();
                          if (value == 'move') onMove?.call();
                          if (value == 'export') onExport?.call();
                          if (value == 'archive') onArchive?.call();
                          if (value == 'delete') onDelete?.call();
                        },
                        itemBuilder: (context) => [
                          if (widget.grid && canCopy)
                            const PopupMenuItem(
                              height: 40,
                              value: 'copy',
                              child: Text('Copy'),
                            ),
                          if (onTogglePin != null)
                            PopupMenuItem(
                              height: 40,
                              value: 'pin',
                              child: Text(item.pinned ? 'Unpin' : 'Pin'),
                            ),
                          if (onToggleStar != null)
                            PopupMenuItem(
                              height: 40,
                              value: 'star',
                              child: Text(item.starred ? 'Unstar' : 'Star'),
                            ),
                          if (onSetReminder != null)
                            PopupMenuItem(
                              height: 40,
                              value: 'reminder',
                              child: Text(
                                item.reminder == null
                                    ? 'Add reminder'
                                    : 'Change reminder',
                              ),
                            ),
                          if (onToggleLock != null)
                            PopupMenuItem(
                              height: 40,
                              value: 'lock',
                              child: Text(
                                item.locked ? 'Remove protection' : 'Protect',
                              ),
                            ),
                          if (onDuplicate != null)
                            const PopupMenuItem(
                              height: 40,
                              value: 'duplicate',
                              child: Text('Duplicate'),
                            ),
                          if (onMove != null)
                            const PopupMenuItem(
                              height: 40,
                              value: 'move',
                              child: Text('Move'),
                            ),
                          if (onExport != null && !hidden)
                            const PopupMenuItem(
                              height: 40,
                              value: 'export',
                              child: Text('Export PDF'),
                            ),
                          if (onArchive != null)
                            const PopupMenuItem(
                              height: 40,
                              value: 'archive',
                              child: Text('Archive'),
                            ),
                          if (onDelete != null)
                            const PopupMenuItem(
                              height: 40,
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                        ],
                      ),
                    ),
                  if (selectMode)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: SelectBox(selected: selected),
                    ),
                ],
              ),
              _tagsRow(context, scheme),
              if (!_collapsed) ...[
                const SizedBox(height: 10),
                Divider(height: 1, color: scheme.outlineVariant),
                const SizedBox(height: 10),
                if (hidden) _lockedBody(scheme) else _buildBody(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The body preview. A long body is clamped to a fixed height and clipped,
  /// with a soft fade at the bottom to signal there is more; tapping the card
  /// reveals it in full. The body is keyed and laid out at its full height (in
  /// a non-scrolling scroll view) so its true height can always be measured.
  ///
  /// The clamp applies from the very first frame (the card is never taller
  /// than the preview until expanded); measuring only adds the fade. If a card
  /// first laid out at its full height and then shrank a frame later, every
  /// long card scrolling into view would change size under the finger and the
  /// list would keep correcting its position (scrolling that sticks and falls
  /// back).
  ///
  /// A long preview is wrapped in IgnorePointer: it needs no interaction (the
  /// card's InkWell handles the tap-to-expand), and nothing in the clipped
  /// region can trap the list's scroll gestures.
  Widget _buildBody() {
    final body = KeyedSubtree(
      key: _bodyKey,
      child: _ItemBody(item: widget.item, preview: !_expanded),
    );
    if (_expanded) return body;
    // A non-scrolling scroll view lays the body out at its full height and
    // sizes itself to that, capped by the max height, clipping the rest. With
    // NeverScrollableScrollPhysics it takes no drags, so the list scrolls.
    Widget clamped = ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _kCollapsedMaxHeight),
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: body,
      ),
    );
    if (_overflowing) {
      clamped = ShaderMask(
        // dstIn keeps the body where the gradient is opaque and fades it to
        // transparent over the last stretch, so the card background shows
        // through - a "more below" cue without any label.
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.82, 1.0],
          colors: [Colors.black, Colors.black, Colors.transparent],
        ).createShader(rect),
        child: clamped,
      );
    }
    return IgnorePointer(ignoring: _overflowing, child: clamped);
  }

  Future<void> _unlock() async {
    final item = widget.item;
    final ok = await askVaultPin(
      context,
      title: 'Open protected item',
      confirmLabel: 'Open',
      message:
          'Enter your vault PIN to open '
          '"${item.title.isEmpty ? 'Untitled' : item.title}".',
    );
    if (ok) ContentLock.instance.revealItem(item);
  }

  /// In place of a hidden protected item's content. The card's tap (which opens
  /// the item) asks for the PIN first.
  Widget _lockedBody(ColorScheme scheme) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: widget.grid ? 14 : 22),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(Icons.shield_outlined, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text(
            'Protected',
            style: textTheme.titleSmall?.copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: 2),
          Text(
            'Tap to open with your vault PIN',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagsRow(BuildContext context, ColorScheme scheme) {
    final tags = widget.item.tags;
    final reminder = widget.item.reminder;
    final canEdit = widget.onSetTags != null && !widget.selectMode;
    if (tags.isEmpty && reminder == null && !canEdit) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (reminder != null)
            ReminderChip(
              reminder: reminder,
              onTap: widget.selectMode ? null : widget.onSetReminder,
            ),
          for (final tag in tags)
            _TagChip(
              label: tag,
              onRemove: canEdit ? () => _removeTag(tag) : null,
            ),
          if (canEdit && !_addingTag)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _addingTag = true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 12, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 2),
                    Text(
                      'Tag',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (canEdit && _addingTag)
            SizedBox(
              width: 120,
              child: TextField(
                controller: _tagController,
                autofocus: true,
                style: const TextStyle(fontSize: 12),
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'tag',
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onSubmitted: (_) => _commitTag(),
                onTapOutside: (_) => _commitTag(),
              ),
            ),
        ],
      ),
    );
  }

  void _removeTag(String tag) {
    widget.onSetTags?.call(widget.item.tags.where((t) => t != tag).toList());
  }

  /// Commit the inline tag field: merge any comma-separated tags, then close.
  void _commitTag() {
    final value = _tagController.text;
    _tagController.clear();
    final additions = value
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty);
    final merged = {...widget.item.tags, ...additions}.toList();
    if (merged.length != widget.item.tags.length) {
      widget.onSetTags?.call(merged);
    }
    if (mounted) setState(() => _addingTag = false);
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, this.onRemove});

  final String label;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.only(
        left: 6,
        right: onRemove != null ? 1 : 6,
        top: 1,
        bottom: 1,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (onRemove != null)
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.close,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemBody extends StatelessWidget {
  const _ItemBody({required this.item, this.preview = false});

  final SpaceItem item;

  /// Showing the clamped preview: very long text is cut to what it can show.
  final bool preview;

  String _text(Object? raw) {
    final text = (raw ?? '').toString();
    return preview && text.length > _kPreviewChars
        ? text.substring(0, _kPreviewChars)
        : text;
  }

  @override
  Widget build(BuildContext context) {
    final c = item.content;
    switch (item.type) {
      case 'textbox':
        final plain = _text(c['text']);
        // Non-selectable so a tap on the body opens the item (via the card's
        // InkWell) instead of starting a text selection. Use the copy button
        // in the header to copy.
        return plain.isEmpty ? const _Empty() : Text(plain);
      case 'richtext':
        // Tiptap JSON, drawn natively (the editor itself is a WebView).
        if (isRichDoc(c)) {
          return richContentPlainText('richtext', c).isEmpty
              ? const _Empty()
              : RichDocView(doc: (c['doc'] as Map).cast<String, dynamic>());
        }
        // Saved before the Tiptap editor: shown as before until next edit.
        final spans = parseRichHtml((c['html'] ?? '').toString());
        return spans.isEmpty
            ? const _Empty()
            : Text.rich(
                richSpansToTextSpan(
                  spans,
                  base: DefaultTextStyle.of(context).style,
                ),
              );
      case 'markdown':
        // An old Markdown note (converts to Rich text when next edited).
        final md = _text(c['text']);
        return md.isEmpty
            ? const _Empty()
            : MarkdownBody(data: md, selectable: false);
      case 'code':
        return _Code(code: (c['code'] ?? '').toString());
      case 'menu_list':
        return _ListView(items: _listTexts(c), ordered: false);
      case 'numbered_list':
        return _ListView(items: _listTexts(c), ordered: true);
      case 'checkbox_list':
        return _Checklist(items: (c['items'] as List?) ?? const []);
      case 'card_list':
        return _Cards(items: (c['items'] as List?) ?? const []);
      case 'table':
        return _TableView(columns: _columns(c), rows: _rows(c));
      case 'whiteboard':
        return _Whiteboard(content: c);
      default:
        return Text('Unsupported item type: ${item.type}');
    }
  }
}

// Renderers

class _ListView extends StatelessWidget {
  const _ListView({required this.items, required this.ordered});

  final List<String> items;
  final bool ordered;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _Empty();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 26, child: Text(ordered ? '${i + 1}.' : '•')),
                Expanded(child: Text(items[i])),
              ],
            ),
          ),
      ],
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist({required this.items});

  final List<dynamic> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _Empty();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final raw in items)
          if (raw is Map)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    (raw['checked'] ?? false) == true
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      (raw['text'] ?? '').toString(),
                      style: (raw['checked'] ?? false) == true
                          ? const TextStyle(
                              decoration: TextDecoration.lineThrough,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

class _Cards extends StatelessWidget {
  const _Cards({required this.items});

  final List<dynamic> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _Empty();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final raw in items)
          if (raw is Map)
            Builder(
              builder: (context) {
                final title = (raw['title'] ?? '').toString();
                final desc = (raw['description'] ?? '').toString();
                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title.isNotEmpty)
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      // A divider separates the heading from the content when
                      // both are present.
                      if (title.isNotEmpty && desc.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Divider(
                            height: 1,
                            color: scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                        ),
                      if (desc.isNotEmpty) Text(desc),
                    ],
                  ),
                );
              },
            ),
      ],
    );
  }
}

/// Read-only code preview with auto-detected syntax highlighting. The global
/// `highlight` instance registers all languages, so `autoDetection` works with
/// no language picker; when nothing is detected it falls back to plain mono.
class _Code extends StatelessWidget {
  const _Code({required this.code});

  final String code;

  // The preview shows only a short snippet (the card clamps to ~25 lines
  // anyway); the full code opens in the editor on tap. Keeping it small keeps
  // the highlight parse cheap and the render well under the clamp threshold, so
  // a large snippet can't stall or glitch the card.
  static const int _kPreviewLines = 22;
  static const int _kPreviewChars = 1200;

  String _snippet() {
    var text = code;
    var truncated = false;
    final lines = text.split('\n');
    if (lines.length > _kPreviewLines) {
      text = lines.take(_kPreviewLines).join('\n');
      truncated = true;
    }
    if (text.length > _kPreviewChars) {
      text = text.substring(0, _kPreviewChars);
      truncated = true;
    }
    return truncated ? '$text\n...' : text;
  }

  // Auto-detection tries every language, so its answer is kept per snippet:
  // a card scrolling back into view (or rebuilt) doesn't run it again.
  static final Map<String, String?> _languageCache = {};

  static String? _detectLanguage(String snippet) {
    if (_languageCache.containsKey(snippet)) return _languageCache[snippet];
    final lang = highlight.parse(snippet, autoDetection: true).language;
    if (_languageCache.length >= 200) {
      _languageCache.remove(_languageCache.keys.first);
    }
    return _languageCache[snippet] = lang;
  }

  @override
  Widget build(BuildContext context) {
    if (code.trim().isEmpty) return const _Empty();
    // Always a dark code surface (black shade), independent of the app theme.
    const bg = Color(0xFF0D1117);
    const baseColor = Color(0xFFD5DAE2);
    const mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      height: 1.5,
    );

    final shown = _snippet();
    final lang = _detectLanguage(shown);
    final Widget body = (lang == null || lang.isEmpty)
        ? Padding(
            padding: const EdgeInsets.all(12),
            child: Text(shown, style: mono.copyWith(color: baseColor)),
          )
        : HighlightView(
            shown,
            language: lang,
            theme: codeHighlightTheme(baseColor),
            padding: const EdgeInsets.all(12),
            textStyle: mono,
          );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: body,
        ),
      ),
    );
  }
}

class _TableView extends StatelessWidget {
  const _TableView({required this.columns, required this.rows});

  final List<String> columns;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final colCount = columns.isNotEmpty
        ? columns.length
        : (rows.isNotEmpty ? rows.first.length : 0);
    if (colCount == 0) return const _Empty();

    final scheme = Theme.of(context).colorScheme;
    final soft = scheme.outlineVariant.withValues(alpha: 0.5);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: soft),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        // Soften the DataTable's built-in row dividers to match the border.
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: soft),
          child: DataTable(
            // Row dividers come from the theme above; add soft vertical
            // dividers so there are borders between columns too.
            border: TableBorder(verticalInside: BorderSide(color: soft)),
            columns: [
              for (var i = 0; i < colCount; i++)
                DataColumn(
                  label: Text(
                    i < columns.length && columns[i].isNotEmpty
                        ? columns[i]
                        : ' ',
                  ),
                ),
            ],
            rows: [
              for (final r in rows)
                DataRow(
                  cells: [
                    for (var i = 0; i < colCount; i++)
                      DataCell(Text(i < r.length ? r[i] : '')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Whiteboard's saved preview image. Decoded once per preview, not on every
/// rebuild of the list.
class _Whiteboard extends StatefulWidget {
  const _Whiteboard({required this.content});

  final Map<String, dynamic> content;

  @override
  State<_Whiteboard> createState() => _WhiteboardState();
}

class _WhiteboardState extends State<_Whiteboard> {
  Object? _source;
  Uint8List? _bytes;

  @override
  Widget build(BuildContext context) {
    final preview = widget.content['preview'];
    if (!identical(preview, _source)) {
      _source = preview;
      _bytes = boardPreviewBytes(widget.content);
    }
    final bytes = _bytes;
    if (bytes == null) {
      if (!hasBoardContent(widget.content)) return const _Empty();
      // An old drawing (or a missing preview): opening it makes one.
      return Text(
        'Open to view this whiteboard',
        style: TextStyle(color: Theme.of(context).hintColor),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Colors.white,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: Image.memory(
            bytes,
            width: double.infinity,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Empty',
      style: TextStyle(
        color: Theme.of(context).hintColor,
        fontStyle: FontStyle.italic,
      ),
    );
  }
}

// Content extractors

List<String> _listTexts(Map<String, dynamic> c) =>
    ((c['items'] as List?) ?? const [])
        .map((e) => (e is Map ? (e['text'] ?? '') : '').toString())
        .toList();

List<String> _columns(Map<String, dynamic> c) =>
    ((c['columns'] as List?) ?? const [])
        .map((e) => (e ?? '').toString())
        .toList();

List<List<String>> _rows(Map<String, dynamic> c) =>
    ((c['rows'] as List?) ?? const [])
        .map(
          (r) => ((r as List?) ?? const [])
              .map((e) => (e ?? '').toString())
              .toList(),
        )
        .toList();
