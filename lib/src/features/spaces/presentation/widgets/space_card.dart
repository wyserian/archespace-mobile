import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/spaces/domain/space.dart';
import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/features/vault/application/content_lock.dart';
import 'package:archespace_mobile/src/shared/widgets/action_menu.dart';
import 'package:archespace_mobile/src/shared/widgets/select_box.dart';

/// A space as a borderless card: the space colour as a curved top border, the
/// pin marker, name and actions menu on one row, then the description, tag
/// chips and the item count.
class SpaceCard extends StatelessWidget {
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
    this.selectMode = false,
    this.selected = false,
    this.onSelectToggle,
    this.onTagClick,
    this.activeTags = const {},
    this.margin,
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
  final bool selectMode;
  final bool selected;
  final VoidCallback? onSelectToggle;

  /// Tap a tag to filter by it. Null leaves tags as plain display chips.
  final void Function(String)? onTagClick;
  final Set<String> activeTags;
  final EdgeInsetsGeometry? margin;

  String get _countLabel =>
      '${space.itemCount} ${space.itemCount == 1 ? 'item' : 'items'}';

  /// A tag chip tinted with the tag's own stable [color]; brighter with a
  /// border when it's an active filter.
  Widget _tagChip(Color color, String tag) {
    final active = activeTags.contains(tag);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: active ? 0.26 : 0.16),
        borderRadius: BorderRadius.circular(7),
        border: active
            ? Border.all(color: color.withValues(alpha: 0.55))
            : null,
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
    // A tappable chip consumes its own tap, so it filters instead of opening
    // the space. Null onTagClick (or select mode) leaves it a plain chip.
    if (onTagClick == null || selectMode) return chip;
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () => onTagClick!(tag),
      child: chip,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Rebuild when a protected space is opened or hidden again.
    listenable: ContentLock.instance,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Protected (itself or its parent) and not opened: the name, tags and count
    // show; the description and editing wait for the PIN.
    final lock = ContentLock.instance;
    final hidden =
        lock.isSpaceHidden(space.id) ||
        (space.locked && !lock.isRevealed(space.id));
    // Cards are borderless except a selected card in select mode, which keeps a
    // soft accent border alongside its checkbox. Pinned is shown by the pin
    // marker; normal and pinned cards have no border.
    final borderSide = selected
        ? BorderSide(color: scheme.primary.withValues(alpha: 0.4), width: 1.5)
        : BorderSide.none;
    final topColor = spaceColor(space.color)?.withValues(alpha: 0.5);

    return Stack(
      children: [
        Card(
          margin:
              margin ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
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
            onTap: selectMode ? onSelectToggle : onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                space.name.isEmpty ? 'Untitled' : space.name,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
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
                                  color: hidden
                                      ? scheme.onSurfaceVariant
                                      : scheme.primary,
                                  semanticLabel: hidden
                                      ? 'Protected'
                                      : 'Protected, open',
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (!selectMode)
                        ActionMenuButton(
                          tooltip: 'Space actions',
                          iconColor: scheme.onSurfaceVariant.withValues(
                            alpha: 0.6,
                          ),
                          entries: [
                            ActionMenuEntry(
                              icon: Icons.push_pin_outlined,
                              label: space.pinned ? 'Unpin' : 'Pin',
                              onSelected: onTogglePin,
                            ),
                            if (onToggleStar != null)
                              ActionMenuEntry(
                                icon: Icons.star_outline_rounded,
                                label: space.starred ? 'Unstar' : 'Star',
                                onSelected: onToggleStar!,
                              ),
                            // Read-only freezes the space's content (details
                            // and items); managing the space itself stays.
                            if (onToggleReadOnly != null)
                              ActionMenuEntry(
                                icon: space.readOnly
                                    ? Icons.edit_outlined
                                    : Icons.edit_off_outlined,
                                label: space.readOnly
                                    ? 'Allow editing'
                                    : 'Read-only',
                                onSelected: onToggleReadOnly!,
                              ),
                            if (onToggleLock != null)
                              ActionMenuEntry(
                                icon: space.locked
                                    ? Icons.remove_moderator_outlined
                                    : Icons.shield_outlined,
                                label: space.locked
                                    ? 'Remove protection'
                                    : 'Protect',
                                onSelected: onToggleLock!,
                              ),
                            // Editing shows the description, so a hidden
                            // protected space opens first.
                            if (!space.readOnly && !hidden)
                              ActionMenuEntry(
                                icon: Icons.edit_outlined,
                                label: 'Edit',
                                onSelected: onEdit,
                              ),
                            ActionMenuEntry(
                              icon: Icons.content_copy_outlined,
                              label: 'Duplicate',
                              onSelected: onDuplicate,
                            ),
                            // A read-only space stays where it is; a hidden
                            // one opens first (moving it out of a protected
                            // space would show it without the PIN).
                            if (onMove != null && !space.readOnly && !hidden)
                              ActionMenuEntry(
                                icon: Icons.drive_file_move_outlined,
                                label: 'Move',
                                onSelected: onMove!,
                              ),
                            ActionMenuEntry(
                              icon: Icons.archive_outlined,
                              label: 'Archive',
                              onSelected: onArchive,
                            ),
                            ActionMenuEntry(
                              icon: Icons.delete_outline,
                              label: 'Delete',
                              onSelected: onDelete,
                              danger: true,
                            ),
                          ],
                        ),
                      if (selectMode)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: SelectBox(selected: selected),
                        ),
                    ],
                  ),
                  if (space.description.isNotEmpty && !hidden)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        space.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final tag in space.tags.take(4))
                          _tagChip(tagColor(tag), tag),
                        if (space.tags.isNotEmpty)
                          Text(
                            '·',
                            style: TextStyle(
                              fontSize: 14,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        Text(
                          _countLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
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
                padding:
                    margin ??
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                child: CustomPaint(
                  painter: _TopBorderPainter(color: topColor, radius: 16),
                ),
              ),
            ),
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
