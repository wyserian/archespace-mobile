import 'dart:convert';

import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';

/// The Secret item type was removed; existing secrets become plain Notes.
///
/// A secret's text is a second ciphertext inside its (already encrypted)
/// content, so only an unlocked device can open it: the conversion runs here,
/// once per app session after unlock, not on the server. It covers archived
/// and binned secrets too, and is safe to repeat (converted items are no longer
/// secrets). A secret in a read-only space is refused by the database and left
/// for a later run, once the space allows editing. Mirrors the web's
/// `secretMigration.js`.
class SecretMigration {
  SecretMigration._();

  static bool _ranThisSession = false;

  /// A Note's content from a secret's content (its nested ciphertext opened).
  static Future<Map<String, dynamic>> _noteContent(
    Map<dynamic, dynamic> content,
    List<int> masterKey,
  ) async {
    final cipher = content['cipher'] is String
        ? content['cipher'] as String
        : '';
    return {
      'text': cipher.isEmpty
          ? ''
          : await ArcheCrypto.decryptArc1(cipher, masterKey),
    };
  }

  /// Convert this account's secrets into Notes. Runs once per session; returns
  /// how many were converted (0 when there were none or it already ran).
  static Future<int> runOnce(List<int> masterKey) async {
    if (_ranThisSession) return 0;
    _ranThisSession = true;
    final client = Db.instance;

    List<dynamic> rows;
    try {
      rows = await client
          .from('space_items')
          .select('id, content')
          .eq('type', 'secret')
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      _ranThisSession = false; // try again next time (e.g. offline)
      return 0;
    }

    var converted = 0;
    for (final row in rows) {
      try {
        final m = row as Map;
        final content = await ArcheCrypto.decryptJsonMap(
          m['content'],
          masterKey,
        );
        final note = await _noteContent(content, masterKey);
        // Only the type and body change; title and tags stay as they are.
        await client
            .from('space_items')
            .update({
              'type': 'textbox',
              'content': await ArcheCrypto.encryptArc1(
                jsonEncode(note),
                masterKey,
              ),
            })
            .eq('id', m['id'] as String);
        converted++;
      } catch (_) {
        // Unreadable (another vault's key) or refused: leave it for next time.
      }
    }
    return converted;
  }
}
