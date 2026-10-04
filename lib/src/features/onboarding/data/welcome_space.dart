import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/util/uuid.dart';

/// The sample space a new account starts with: a short tour of spaces, items
/// and the vault (`spec/welcome-space.json`, shared with the web app).
///
/// It's made once, when the vault is first set up, and encrypted with the new
/// vault key like anything the user writes. Accounts that already have a
/// vault never get it, and deleting it is like deleting any space.
class WelcomeSpace {
  WelcomeSpace._();

  static const _specAsset = 'spec/welcome-space.json';

  /// Create the welcome space and its items. Best effort: a failure leaves
  /// the account as it was (an empty dashboard), and setup carries on.
  static Future<void> create(String userId, Uint8List masterKey) async {
    try {
      final spec =
          jsonDecode(await rootBundle.loadString(_specAsset))
              as Map<String, dynamic>;
      final client = Supabase.instance.client;
      final created = await client
          .from('spaces')
          .insert(await spaceRow(spec, userId, masterKey))
          .select('id')
          .single();
      await client
          .from('space_items')
          .insert(
            await itemRows(spec, userId, created['id'] as String, masterKey),
          );
    } catch (e) {
      debugPrint("Couldn't create the welcome space: $e");
    }
  }

  /// The encrypted `spaces` row for the spec's space.
  static Future<Map<String, dynamic>> spaceRow(
    Map<String, dynamic> spec,
    String userId,
    Uint8List key,
  ) async {
    final space = spec['space'] as Map<String, dynamic>;
    return {
      'user_id': userId,
      'name': await ArcheCrypto.encryptArc1(space['name'] as String, key),
      'description': await ArcheCrypto.encryptArc1(
        space['description'] as String,
        key,
      ),
      'tags': await ArcheCrypto.encryptArc1(jsonEncode(space['tags']), key),
      'color': space['color'],
      'pinned': space['pinned'] == true,
      'position': 0,
    };
  }

  /// The encrypted `space_items` rows, in the spec's order.
  static Future<List<Map<String, dynamic>>> itemRows(
    Map<String, dynamic> spec,
    String userId,
    String spaceId,
    Uint8List key,
  ) async {
    final items = (spec['items'] as List).cast<Map<String, dynamic>>();
    return [
      for (final (position, item) in items.indexed)
        {
          'space_id': spaceId,
          'user_id': userId,
          'type': item['type'],
          'title': await ArcheCrypto.encryptArc1(item['title'] as String, key),
          'content': await ArcheCrypto.encryptArc1(
            jsonEncode(_withEntryIds(item['content'] as Map<String, dynamic>)),
            key,
          ),
          'tags': await ArcheCrypto.encryptArc1(jsonEncode(const []), key),
          'position': position,
          'pinned': item['pinned'] == true,
          // Protected: the content needs the vault PIN to open.
          'locked': item['locked'] == true,
        },
    ];
  }

  /// A copy of an item's content with a fresh id on each list entry.
  static Map<String, dynamic> _withEntryIds(Map<String, dynamic> content) {
    final entries = content['items'];
    if (entries is! List) return content;
    return {
      ...content,
      'items': [
        for (final entry in entries.cast<Map<String, dynamic>>())
          {'id': newUuid(), ...entry},
      ],
    };
  }
}
