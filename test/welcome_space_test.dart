import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/items/domain/item_types.dart';
import 'package:archespace_mobile/src/features/onboarding/data/welcome_space.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';

void main() {
  final raw = File('spec/welcome-space.json').readAsStringSync();
  final spec = jsonDecode(raw) as Map<String, dynamic>;

  test('uses only item types the app knows, in plain ASCII punctuation', () {
    for (final item in (spec['items'] as List).cast<Map<String, dynamic>>()) {
      expect(itemTypeDef(item['type'] as String), isNotNull);
    }
    expect(raw.contains(RegExp('[–—]')), isFalse);
  });

  test('encrypts the space and its items with the vault key', () async {
    final key = ArcheCrypto.randomAesKey();
    final space = await WelcomeSpace.spaceRow(spec, 'user-1', key);
    expect(jsonEncode(space), isNot(contains('Welcome to ArcheSpace')));
    expect(
      await ArcheCrypto.decryptArc1(space['name'] as String, key),
      'Welcome to ArcheSpace',
    );

    final rows = await WelcomeSpace.itemRows(spec, 'user-1', 'space-1', key);
    expect(rows, hasLength((spec['items'] as List).length));
    expect(rows.every((r) => r['space_id'] == 'space-1'), isTrue);
    // The sample protected item stays protected.
    expect(rows.where((r) => r['locked'] == true), isNotEmpty);
    final checklist = rows.firstWhere((r) => r['type'] == 'checkbox_list');
    final content =
        jsonDecode(
              await ArcheCrypto.decryptArc1(
                checklist['content'] as String,
                key,
              ),
            )
            as Map<String, dynamic>;
    final ids = (content['items'] as List).map((e) => (e as Map)['id']);
    // List entries get their own ids.
    expect(ids.toSet(), hasLength(ids.length));
  });
}
