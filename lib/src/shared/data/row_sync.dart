import 'dart:math';

import 'package:archespace_mobile/src/shared/data/db.dart';

// Ids per follow-up request, so its URL stays short.
const _idChunk = 100;
const _timeout = Duration(seconds: 8);

/// Load the rows of [table] that [filter] selects, in [order], downloading in
/// full only those that changed since [kept], the copy kept for offline reads
/// (CacheStore).
///
/// First it asks for each row's id and updated_at; the server bumps
/// updated_at on every change. Rows that are new or changed are then fetched
/// in full, the rest come from [kept]. A row deleted, moved away or hidden
/// since isn't in the first answer, so it simply drops out. Without a kept
/// copy, or when most rows changed, it downloads everything in one go.
Future<List<Map<String, dynamic>>> fetchChangedRows({
  required Db db,
  required String table,
  required String columns,
  required DbQuery Function(DbQuery) filter,
  required DbQuery Function(DbQuery) order,
  required List<Map<String, dynamic>> kept,
}) async {
  Future<List<Map<String, dynamic>>> rowsOf(DbQuery query) async => [
    for (final row in await query.timeout(_timeout) as List)
      (row as Map).cast<String, dynamic>(),
  ];
  Future<List<Map<String, dynamic>>> full() =>
      rowsOf(order(filter(db.from(table).select(columns))));

  if (kept.isEmpty) return full();
  final heads = await rowsOf(
    order(filter(db.from(table).select('id, updated_at'))),
  );
  final byId = {for (final row in kept) row['id']: row};
  final changed = [
    for (final head in heads)
      if (byId[head['id']]?['updated_at'] != head['updated_at'])
        head['id'] as String,
  ];
  if (changed.length * 2 > heads.length) return full();

  for (final id in changed) {
    byId.remove(id);
  }
  for (var i = 0; i < changed.length; i += _idChunk) {
    final ids = changed.sublist(i, min(i + _idChunk, changed.length));
    for (final row in await rowsOf(
      filter(db.from(table).select(columns)).inFilter('id', ids),
    )) {
      byId[row['id']] = row;
    }
  }
  // One deleted between the two requests is left out.
  return [for (final head in heads) ?byId[head['id']]];
}
