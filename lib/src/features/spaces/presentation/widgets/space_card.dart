import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/shared/widgets/action_menu.dart';
import 'package:archespace_mobile/src/shared/widgets/select_box.dart';
import 'package:archespace_mobile/src/shared/widgets/tag_chip.dart';

/// A space as a borderless card: the space colour as a curved top border, the
/// pin marker, name and actions menu on one row, then the description, tag
/// chips (tap one to filter, its x removes it; "Add tag" is in the menu) and
/// the item count.
class SpaceCard extends StatefulWidget {
  const SpaceCard({
    super.key,
    required this.space,
    required this.onTap,
    required this.onTogglePin,
    required this.onEdit,
    required this.onDuplicate,
    required this.onArchive,
    required this.onDelete,
    this.onToggleStar,
    this.onToggleReadOnly,
    this.onToggleLock,
    this.onMove,
    this.onExport,
    this.onSetTags,
    this.selectMode = false,
    this.selected = false,
    this.onSelectToggle,
    this.onTagClick,
    this.activeTags = const {},
    this.margin,
    this.actions,
    this.note,
  });

  final Space space;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  /// Star / unstar (adds it to Starred without moving it). Null hides it.
  final VoidCallback? onToggleStar;

  /// Read-only on / off. Null hides it.
  final VoidCallback? onToggleReadOnly;

  /// Protect / remove protection. Null hides it.
  final VoidCallback? onToggleLock;

  /// Move into another space or to the top level. Null hides it.
  final VoidCallback? onMove;

  /// Export the space (with its items) to PDF. Null hides it.
  final VoidCallback? onExport;

  /// Save a new tag list; true when saved. Null (e.g. offline) hides adding
  /// and removing tags.
  final Future<bool> Function(List<String> tags)? onSetTags;
  final bool selectMode;
  final bool selected;
  final VoidCallback? onSelectToggle;

  /// Tap a tag to filter by it. Null leaves tags as plain display chips.
  final void Function(String)? onTagClick;
  final Set<String> activeTags;
  final EdgeInsetsGeometry? margin;

  /// Archive and Bin: the card's only actions, in the header in place of its
  /// menu, and a line under the name ([note]: when it was archived or
  /// deleted). The card then doesn't open: there's no page for it.
  final Widget? actions;
  final String? note;

  @override
  State<SpaceCard> createState() => _SpaceCardState();
}

class _SpaceCardState extends State<SpaceCard> {
  // The inline tag field is open ("Add tag" in the menu).
  bool _addingTag = false;

  // Tags just changed here, shown until the saved space comes back (or the
  // save fails).
  List<String>? _pendingTags;

  List<String> get _tags => _pendingTags ?? widget.space.tags;

  @override
  void didUpdateWidget(covariant SpaceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reload brings a new Space: it has the saved tags.
    if (oldWidget.space != widget.space) _pendingTags = null;
  }

  Future<void> _saveTags(List<String> next) async {
    setState(() => _pendingTags = next);
    final ok = await widget.onSetTags!(next);
    if (!ok && mounted) setState(() => _pendingTags = null);
  }

  String get _countLabel {
    final n = widget.space.itemCount;
    return '$n ${n == 1 ? 'item' : 'items'}';
  }

  /// A tag chip tinted with the tag's own stable colour; brighter with a
  /// border when it's an active filter.
  Widget _tagChip(String tag, {VoidCallback? onRemove}) {
    final color = tagColor(tag);
    final active = widget.activeTags.contains(tag);
    return TagChip(
      label: tag,
      color: color,
      fill: color.withValues(alpha: active ? 0.26 : 0.16),
      edge: active
          ? BorderSide(color: color.withValues(alpha: 0.55))
          : BorderSide.none,
      onTap: widget.onTagClick == null || widget.selectMode
          ? null
          : () => widget.onTagClick!(tag),
      onRemove: onRemove,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Rebuild when a protected space is opened or hidden again.
    listenable: ContentLock.instance,
    builder: (context, _) => _build(context),
  );

  /// The name, with its markers (starred, read-only, protected).
  Widget _nameRow(Space space, ColorScheme scheme, bool hidden) => Row(
    children: [
      Flexible(
        child: Text(
          space.name.isEmpty ? 'Untitled' : space.name,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // Starred, right after the name, in the accent.
      if (space.starred)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Icon(
            Icons.star_rounded,
            size: 19,
            color: scheme.primary,
            semanticLabel: 'Starred',
          ),
        ),
      if (space.readOnly)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Icon(
            Icons.edit_off_outlined,
            size: 16,
            color: scheme.onSurfaceVariant,
            semanticLabel: 'Read-only',
          ),
        ),
      if (space.locked || hidden)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Icon(
            Icons.shield_outlined,
            size: 16,
            color: hidden ? scheme.onSurfaceVariant : scheme.primary,
            semanticLabel: hidden ? 'Protected' : 'Protected, open',
          ),
        ),
    ],
  );

  Widget _build(BuildContext context) {
    final space = widget.space;
    final selectMode = widget.selectMode;
    final margin =
        widget.margin ??
        const EdgeInsets.symmetric(horizontal: 12, vertical: 3);
    final scheme = Theme.of(context).colorScheme;
    // Protected (itself or its parent) and not opened: the name, tags and count
    // show; the description and editing wait for the PIN.
    final lock = ContentLock.instance;
    final hidden =
        lock.isSpaceHidden(space.id) ||
        (space.locked && !lock.isRevealed(space.id));
    // Tags are part of the space's details: frozen while read-only, and
    // edited only once a protected space is open.
    final canEditTags =
        widget.onSetTags != null && !space.readOnly && !hidden && !selectMode;
    final tags = _tags;
    final adding = _addingTag && canEditTags;
    // Cards are borderless except a selected card in select mode, which keeps a
    // soft accent border alongside its checkbox. Pinned is shown by the pin
    // marker; normal and pinned cards have no border.
    final borderSide = widget.selected
        ? BorderSide(color: scheme.primary.withValues(alpha: 0.4), width: 1.5)
        : BorderSide.none;
    final topColor = spaceColor(space.color)?.withValues(alpha: 0.5);

    return Stack(
      children: [
        Card(
          margin: margin,
          clipBehavior: Clip.antiAlias,
          // Borderless: the card is set off from the page by a lighter surface
          // (a couple of tones up from colorScheme.surface) plus a soft shadow.
          // surfaceContainer keeps it distinct without being washed-out light.
          color: scheme.surfaceContainer,
          elevation: 2,
          shadowColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: borderSide,
          ),
          child: InkWell(
            // With actions (Archive, Bin) there's no page to open.
            onTap: selectMode
                ? widget.onSelectToggle
                : widget.actions == null
                ? widget.onTap
                : null,
            child: Padding(
              // No top/right padding: the 48 menu button's own space sets the
              // header's height and its distance from the edge.
              padding: const EdgeInsets.fromLTRB(16, 0, 0, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Row(
                      children: [
                        if (space.pinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Icon(
                              Icons.push_pin,
                              size: 18,
                              color: scheme.primary,
                              semanticLabel: 'Pinned',
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _nameRow(space, scheme, hidden),
                              if (widget.note != null)
                                Text(
                                  widget.note!,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                            ],
                          ),
                        ),
                        if (!selectMode)
                          widget.actions != null
                              ? Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    right: 8,
                                  ),
                                  child: widget.actions,
                                )
                              : _menu(space, hidden, canEditTags),
                        if (selectMode)
                          Padding(
                            padding: const EdgeInsets.only(left: 8, right: 12),
                            child: SelectBox(selected: widget.selected),
                          ),
                      ],
                    ),
                  ),
                  if (space.description.isNotEmpty && !hidden)
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        space.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 16),
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final tag in tags)
                          _tagChip(
                            tag,
                            onRemove: canEditTags
                                ? () => _saveTags(
                                    tags.where((t) => t != tag).toList(),
                                  )
                                : null,
                          ),
                        if (adding)
                          TagInput(
                            onCommit: (added) {
                              setState(() => _addingTag = false);
                              final merged = {...tags, ...added}.toList();
                              if (merged.length != tags.length) {
                                _saveTags(merged);
                              }
                            },
                          ),
                        if (tags.isNotEmpty || adding)
                          Text(
                            '·',
                            style: TextStyle(
                              fontSize: 14,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        // Lined up with the tag chips' tap height when there
                        // are tags; on its own it takes only its text height.
                        SizedBox(
                          height: tags.isNotEmpty || adding
                              ? kTagTapHeight
                              : null,
                          child: Center(
                            widthFactor: 1,
                            heightFactor: 1,
                            child: Text(
                              _countLabel,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Space colour as the card's top border, curved around the top corners
        // to match the web (a coloured top border on a rounded card).
        if (topColor != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                // Must match the Card's margin exactly so the colour strip sits
                // flush on the card's top edge (mismatched insets leave a gap).
                padding: margin,
                child: CustomPaint(
                  painter: _TopBorderPainter(color: topColor, radius: 16),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The actions menu, in the web's groups: mark (Pin, Star, Add tag),
  /// content (Edit, Duplicate, Move, Export PDF), keep (Read-only, Protect,
  /// Archive), then Delete.
  Widget _menu(Space space, bool hidden, bool canEditTags) {
    final w = widget;
    return ActionMenuButton(
      tooltip: 'Space actions',
      entries: [
        ActionMenuEntry(
          group: 'mark',
          icon: Icons.push_pin_outlined,
          label: space.pinned ? 'Unpin' : 'Pin',
          crossed: space.pinned,
          onSelected: w.onTogglePin,
        ),
        if (w.onToggleStar != null)
          ActionMenuEntry(
            group: 'mark',
            icon: Icons.star_outline_rounded,
            label: space.starred ? 'Unstar' : 'Star',
            crossed: space.starred,
            onSelected: w.onToggleStar!,
          ),
        if (canEditTags)
          ActionMenuEntry(
            group: 'mark',
            icon: Icons.sell_outlined,
            label: 'Add tag',
            onSelected: () => setState(() => _addingTag = true),
          ),
        // Editing shows the description, so a hidden protected space opens
        // first.
        if (!space.readOnly && !hidden)
          ActionMenuEntry(
            group: 'content',
            icon: Icons.edit_outlined,
            label: 'Edit',
            onSelected: w.onEdit,
          ),
        ActionMenuEntry(
          group: 'content',
          icon: Icons.content_copy_outlined,
          label: 'Duplicate',
          onSelected: w.onDuplicate,
        ),
        // A read-only space stays where it is; a hidden one opens first
        // (moving it out of a protected space would show it without the PIN).
        if (w.onMove != null && !space.readOnly && !hidden)
          ActionMenuEntry(
            group: 'content',
            icon: Icons.arrow_forward,
            label: 'Move',
            onSelected: w.onMove!,
          ),
        // Exporting releases the content, so a hidden protected space opens
        // first.
        if (w.onExport != null && !hidden)
          ActionMenuEntry(
            group: 'content',
            icon: Icons.file_download_outlined,
            label: 'Export PDF',
            onSelected: w.onExport!,
          ),
        // Read-only freezes the space's content (details and items); managing
        // the space itself stays.
        if (w.onToggleReadOnly != null)
          ActionMenuEntry(
            group: 'keep',
            icon: space.readOnly
                ? Icons.edit_outlined
                : Icons.edit_off_outlined,
            label: space.readOnly ? 'Allow editing' : 'Read-only',
            onSelected: w.onToggleReadOnly!,
          ),
        if (w.onToggleLock != null)
          ActionMenuEntry(
            group: 'keep',
            icon: space.locked
                ? Icons.remove_moderator_outlined
                : Icons.shield_outlined,
            label: space.locked ? 'Unprotect' : 'Protect',
            onSelected: w.onToggleLock!,
          ),
        ActionMenuEntry(
          group: 'keep',
          icon: Icons.archive_outlined,
          label: 'Archive',
          onSelected: w.onArchive,
        ),
        ActionMenuEntry(
          group: 'delete',
          icon: Icons.delete_outline,
          label: 'Delete',
          onSelected: w.onDelete,
          danger: true,
        ),
      ],
    );
  }
}

/// Fills the space colour as a curved top border: [_thickness]px across the top
/// and around the upper part of each corner, then tapering to a gradual point
/// as it curves down toward the sides (rather than ending in a straight cut).
class _TopBorderPainter extends CustomPainter {
  _TopBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const double _thickness = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final r = radius;
    const t = _thickness;
    final ri = r - t;
    const s45 = 0.70710678; // sin/cos 45 deg: the band is full thickness here
    const sTip = 0.92718385; // sin 68 deg: where the band tapers out
    const cTip = 0.37460659; // cos 68 deg
    // Inner edge stays a concentric band down to the 45-degree diagonal; the
    // outer edge continues a little further, and the two meet so each end
    // narrows to a gradual point instead of a straight diagonal cut.
    final iLeft = Offset(r - ri * s45, r - ri * s45);
    final iRight = Offset(w - (r - ri * s45), r - ri * s45);
    final tipLeft = Offset(r * (1 - sTip), r * (1 - cTip));
    final tipRight = Offset(w - r * (1 - sTip), r * (1 - cTip));

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final path = Path()
      ..moveTo(tipLeft.dx, tipLeft.dy)
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..lineTo(w - r, 0)
      ..arcToPoint(tipRight, radius: Radius.circular(r))
      ..lineTo(iRight.dx, iRight.dy)
      ..arcToPoint(
        Offset(w - r, t),
        radius: Radius.circular(ri),
        clockwise: false,
      )
      ..lineTo(r, t)
      ..arcToPoint(iLeft, radius: Radius.circular(ri), clockwise: false)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TopBorderPainter old) =>
      old.color != color || old.radius != radius;
}
