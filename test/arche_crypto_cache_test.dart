import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/vault/application/vault_session.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';

// A cached value still decrypts after its key's bytes are wiped (the cache
// answers for that same key object); an uncached one then fails. That tells
// the two apart without reaching into the cache.
void main() {
  Uint8List newKey() => ArcheCrypto.randomAesKey();
  void wipe(Uint8List key) => key.fillRange(0, key.length, 0);

  setUp(ArcheCrypto.clearCache);

  test('a value just encrypted needs no decryption', () async {
    final key = newKey();
    final value = await ArcheCrypto.encryptArc1('hello', key);
    wipe(key);
    expect(await ArcheCrypto.decryptArc1(value, key), 'hello');
  });

  test('a clear forgets everything, a lock clears', () async {
    final key = newKey();
    final value = await ArcheCrypto.encryptArc1('hello', key);
    VaultSession.instance.unlock(key);
    VaultSession.instance.lock();
    wipe(key);
    await expectLater(ArcheCrypto.decryptArc1(value, key), throwsA(anything));
  });

  test('keeps nothing from a decryption that finishes after a clear', () async {
    final key = newKey();
    final value = await ArcheCrypto.encryptArc1('hello', key);
    ArcheCrypto.clearCache();
    final running = ArcheCrypto.decryptArc1(value, key);
    ArcheCrypto.clearCache(); // the vault locks mid-decryption
    expect(await running, 'hello');
    wipe(key);
    await expectLater(ArcheCrypto.decryptArc1(value, key), throwsA(anything));
  });

  test('never answers for another key', () async {
    final value = await ArcheCrypto.encryptArc1('hello', newKey());
    await expectLater(
      ArcheCrypto.decryptArc1(value, newKey()),
      throwsA(anything),
    );
  });

  test('warm decrypts a long list in the background, ahead of use', () async {
    final key = newKey();
    final values = [
      for (var i = 0; i < 40; i++) await ArcheCrypto.encryptArc1('v$i', key),
    ];
    ArcheCrypto.clearCache();
    await ArcheCrypto.warm([...values, null, '', 'arc1:broken'], key);
    wipe(key);
    for (var i = 0; i < 40; i++) {
      expect(await ArcheCrypto.decryptArc1(values[i], key), 'v$i');
    }
  });
}
