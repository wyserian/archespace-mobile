import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/domain/item_types.dart';

/// An item's type as its coloured icon in a tinted pill (the mark on item
/// cards), used wherever an item is listed so types read the same everywhere:
/// item cards, Archive and the Bin. The type's name is its label.
class TypeBadge extends StatelessWidget {
  const TypeBadge({super.key, required this.type, this.compact = false});

  final String type;

  /// The smaller badge used in the compact grid cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final def = itemTypeDef(type);
    if (def == null) return const SizedBox.shrink();
    final color = def.colorFor(Theme.of(context).brightness);
    return Container(
      padding: EdgeInsets.all(compact ? 2 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(compact ? 5 : 6),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Icon(
        def.icon,
        size: compact ? 13 : 16,
        color: color,
        semanticLabel: def.label,
      ),
    );
  }
}
