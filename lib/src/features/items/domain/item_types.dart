import 'package:flutter/material.dart';

import 'package:archespace_mobile/src/features/items/domain/kanban.dart';
import 'package:archespace_mobile/src/features/items/domain/rich_doc.dart';

/// Definition of an item type: label, description, icon and colour.
class ItemTypeDef {
  const ItemTypeDef({
    required this.type,
    required this.label,
    required this.description,
    required this.icon,
    required this.color,
    this.addable = true,
  });

  final String type;
  final String label;
  final String description;
  final IconData icon;

  /// Accent colour for this type (badge + add-menu icon), matching the web's
  /// per-type palette.
  final Color color;

  /// Offered in the add-item menu. False for a variant of another type (a
  /// numbered List), which opens and edits normally but isn't picked there.
  final bool addable;

  /// [color] for a theme brightness: the pale shades fade on a light
  /// background, so light mode uses a deeper shade of the same hue (as the
  /// web's light theme does).
  Color colorFor(Brightness brightness) => brightness == Brightness.light
      ? _kLightTypeColors[color.toARGB32()] ?? color
      : color;
}

const Map<int, Color> _kLightTypeColors = {
  0xFF60A5FA: Color(0xFF2563EB), // blue
  0xFFFB7185: Color(0xFFE11D48), // rose
  0xFFC084FC: Color(0xFF9333EA), // purple
  0xFF4ADE80: Color(0xFF15803D), // green
  0xFFFBBF24: Color(0xFFB45309), // amber
  0xFF38BDF8: Color(0xFF0369A1), // sky
  0xFFE879F9: Color(0xFFC026D3), // fuchsia
  0xFFFB923C: Color(0xFFC2410C), // orange
  0xFF34D399: Color(0xFF047857), // emerald
  0xFF2DD4BF: Color(0xFF0F766E), // teal
};

const List<ItemTypeDef> kItemTypes = [
  ItemTypeDef(
    type: 'textbox',
    label: 'Note',
    description: 'Free-form plain text',
    icon: Icons.notes,
    color: Color(0xFF60A5FA), // blue
  ),
  ItemTypeDef(
    type: 'richtext',
    label: 'Rich text',
    description: 'Headings, lists, tasks, tables, links and more',
    icon: Icons.text_fields,
    color: Color(0xFFFB7185), // rose
  ),
  ItemTypeDef(
    // An old Markdown note: shown as Rich text, and saved as Rich text the
    // next time it's edited. No longer offered in the add menu.
    type: 'markdown',
    label: 'Rich text',
    description: 'Headings, lists, tasks, tables, links and more',
    icon: Icons.text_fields,
    color: Color(0xFFFB7185), // rose, like Rich text
    addable: false,
  ),
  ItemTypeDef(
    type: 'menu_list',
    label: 'List',
    description: 'Bullet or numbered list',
    icon: Icons.list,
    color: Color(0xFFC084FC), // purple
  ),
  ItemTypeDef(
    // A List with numbers on (its Numbered checkbox); not a separate choice.
    type: 'numbered_list',
    label: 'List',
    description: 'Bullet or numbered list',
    icon: Icons.format_list_numbered,
    color: Color(0xFFC084FC), // purple, like List
    addable: false,
  ),
  ItemTypeDef(
    type: 'checkbox_list',
    label: 'Checklist',
    description: 'Items with checkboxes',
    icon: Icons.checklist,
    color: Color(0xFF4ADE80), // green
  ),
  ItemTypeDef(
    type: 'card_list',
    label: 'Cards',
    description: 'Title and description pairs',
    icon: Icons.view_agenda_outlined,
    color: Color(0xFFFBBF24), // amber
  ),
  ItemTypeDef(
    type: 'table',
    label: 'Table',
    description: 'Rows and columns of text',
    icon: Icons.table_chart_outlined,
    color: Color(0xFF38BDF8), // sky
  ),
  ItemTypeDef(
    type: 'kanban',
    label: 'Kanban',
    description: 'Cards in columns, from to do to done',
    icon: Icons.view_kanban_outlined,
    color: Color(0xFF2DD4BF), // teal
  ),
  ItemTypeDef(
    type: 'whiteboard',
    label: 'Whiteboard',
    description: 'Shapes, arrows, text and sketches',
    icon: Icons.category_outlined,
    color: Color(0xFFE879F9), // fuchsia
  ),
  ItemTypeDef(
    type: 'code',
    label: 'Code',
    description: 'Code snippet with syntax highlighting',
    icon: Icons.data_object,
    color: Color(0xFFFB923C), // orange
  ),
];

ItemTypeDef? itemTypeDef(String type) {
  for (final def in kItemTypes) {
    if (def.type == type) return def;
  }
  return null;
}

/// A known type, so its card opens the editor on tap.
bool isEditableType(String type) => itemTypeDef(type) != null;

/// The starting content for a newly created item, matching the web defaults.
Map<String, dynamic> defaultContentFor(String type) {
  switch (type) {
    case 'textbox':
      return {'text': ''};
    case 'richtext':
      return {'doc': kEmptyRichDoc};
    case 'code':
      return {'code': ''};
    case 'menu_list':
    case 'numbered_list':
    case 'card_list':
      return {'items': <dynamic>[]};
    case 'checkbox_list':
      return {
        'items': [
          {'id': _newId(), 'text': '', 'checked': false},
        ],
      };
    case 'table':
      return {
        'columns': ['', ''],
        'rows': [
          ['', ''],
          ['', ''],
        ],
      };
    case 'whiteboard':
      return {'elements': <dynamic>[]};
    case 'kanban':
      return defaultKanban();
    default:
      return <String, dynamic>{};
  }
}

String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);
