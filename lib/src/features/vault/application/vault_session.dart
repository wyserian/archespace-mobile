import 'package:flutter/foundation.dart';

import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';

/// Holds the unlocked vault master key in memory for the lifetime of the
/// process (biometric unlock keeps its own copy, see SecureKeyStore).
/// [unlocked] lets the UI react to lock/unlock. Decrypted text stays in
/// memory only while unlocked: a lock, or a different key, drops it all.
class VaultSession {
  VaultSession._();
  static final VaultSession instance = VaultSession._();

  final ValueNotifier<bool> unlocked = ValueNotifier<bool>(false);
  Uint8List? _masterKey;

  Uint8List get masterKey {
    final key = _masterKey;
    if (key == null) throw StateError('Vault is locked');
    return key;
  }

  void unlock(Uint8List masterKey) {
    if (!identical(_masterKey, masterKey)) ArcheCrypto.clearCache();
    _masterKey = masterKey;
    unlocked.value = true;
  }

  void lock() {
    _masterKey = null;
    ArcheCrypto.clearCache();
    unlocked.value = false;
  }
}
