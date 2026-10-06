import 'package:archespace_mobile/src/features/spaces/domain/space_colors.dart';
import 'package:archespace_mobile/src/shared/util/uuid.dart';

/// The Kanban item type: cards in columns, the same as the web app's
/// (lib/kanban.js).
///
/// Content: { columns: [{ id, title, color, cards: [{ id, title, description }] }] }
/// `color` is a space colour preset id (kSpaceColors), or null for none.
/// Encrypted like any item's content.
class KanbanCard {
  KanbanCard({String? id, this.title = '', this.description = ''})
    : id = id ?? newUuid();

  final String id;
  String title;
  String description;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
  };
}

class KanbanColumn {
  KanbanColumn({
    String? id,
    this.title = '',
    this.color,
    List<KanbanCard>? cards,
  }) : id = id ?? newUuid(),
       cards = cards ?? [];

  final String id;
  String title;

  /// A space colour preset id, or null.
  String? color;
  final List<KanbanCard> cards;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'color': color,
    'cards': [for (final card in cards) card.toJson()],
  };
}

/// A new Kanban's content.
Map<String, dynamic> defaultKanban() => kanbanToJson([
  for (final title in const ['To do', 'Doing', 'Done'])
    KanbanColumn(title: title),
]);

/// The columns, made safe to edit (anything malformed is dropped).
List<KanbanColumn> kanbanColumns(Map<String, dynamic> content) {
  String text(Object? v) => v is String ? v : '';
  String? id(Object? v) => v is String && v.isNotEmpty ? v : null;
  return [
    for (final col in (content['columns'] as List? ?? const []))
      if (col is Map)
        KanbanColumn(
          id: id(col['id']),
          title: text(col['title']),
          color: kSpaceColors.containsKey(col['color'])
              ? col['color'] as String
              : null,
          cards: [
            for (final card in (col['cards'] as List? ?? const []))
              if (card is Map)
                KanbanCard(
                  id: id(card['id']),
                  title: text(card['title']),
                  description: text(card['description']),
                ),
          ],
        ),
  ];
}

Map<String, dynamic> kanbanToJson(List<KanbanColumn> columns) => {
  'columns': [for (final col in columns) col.toJson()],
};

/// Plain text: each column's title, then its cards ("- title: description").
String kanbanText(Map<String, dynamic> content) => kanbanColumns(content)
    .map(
      (col) => [
        col.title.isEmpty ? 'Untitled' : col.title,
        for (final card in col.cards)
          '- ${[card.title, card.description].where((s) => s.trim().isNotEmpty).join(': ')}',
      ].join('\n'),
    )
    .join('\n\n');

/// Every title and description, for search.
List<String> kanbanSearchParts(Map<String, dynamic> content) => [
  for (final col in kanbanColumns(content)) ...[
    col.title,
    for (final card in col.cards) ...[card.title, card.description],
  ],
];
