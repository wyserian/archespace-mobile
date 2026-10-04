import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:archespace_mobile/src/features/vault/domain/recovery_code.dart';
import 'package:archespace_mobile/src/features/vault/domain/vault_pin.dart';
import 'package:archespace_mobile/src/shared/crypto/arche_crypto.dart';
import 'package:archespace_mobile/src/shared/data/cache_store.dart';
import 'package:archespace_mobile/src/shared/data/db.dart';

class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Fetches the user's `user_encryption` row and unlocks or re-wraps the vault,
/// mirroring the web `vault.js` flow (see spec/crypto-format.md section 4).
///
/// The master AES key never leaves the client. Changing a PIN or recovery code
/// re-wraps the same master key under a freshly derived key, so already
/// encrypted rows keep decrypting without a re-encrypt pass.
class VaultService {
  Db get _client => Db.instance;

  static const String _checkPlaintext = 'ARCHE_VAULT_V1_OK';
  static const String _metaCacheKey = 'user_encryption';

  Future<bool> hasVault(String userId) async {
    // If unlock metadata is cached, a vault exists - answer instantly and skip
    // the network so launch never hangs on a stalled request when offline.
    final cached = await CacheStore.read(_metaCacheKey);
    if (cached is Map) return true;
    try {
      final row = await _client
          .from('user_encryption')
          .select('user_id')
          .eq('user_id', userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      return row != null;
    } catch (_) {
      // Unreachable and nothing cached: assume a vault exists so we show the
      // unlock screen (which surfaces a clear offline message) instead of the
      // setup screen or an endless spinner.
      return true;
    }
  }

  /// Load the unlock metadata (salt, key_check, wrapped_key). Fetches it from
  /// Supabase and caches it locally so the vault can be unlocked offline; when
  /// the network is unavailable, falls back to the cached copy. The cached data
  /// is ciphertext plus a public salt - the same values the server stores - so
  /// caching it does not weaken the zero-knowledge model (the PIN is still
  /// required to derive the unwrapping key).
  Future<Map<String, dynamic>?> _loadUnlockMeta(String userId) async {
    try {
      final meta = await _client
          .from('user_encryption')
          .select('salt, key_check, wrapped_key')
          .eq('user_id', userId)
          .maybeSingle();
      if (meta != null) await CacheStore.write(_metaCacheKey, meta);
      return meta;
    } catch (_) {
      final cached = await CacheStore.read(_metaCacheKey);
      if (cached is Map) return Map<String, dynamic>.from(cached);
      throw VaultException(
        "Can't reach the server, and there's no offline vault data on this "
        'device yet. Connect to the internet once to enable offline unlock.',
      );
    }
  }

  /// Derive the PIN key, unwrap the master key, and verify it. Returns the raw
  /// master key on success; throws [VaultException] on a wrong PIN / no vault.
  /// Works offline once the metadata has been cached by a prior online unlock
  /// or vault setup.
  Future<Uint8List> unlock(String userId, String pin) async {
    final meta = await _loadUnlockMeta(userId);
    if (meta == null) {
      throw VaultException('No vault PIN is configured for this account.');
    }
    final masterKey = await _unlockWithPin(meta, pin);
    await _upgradeLegacyPinSalt(userId, pin, masterKey, meta);
    return masterKey;
  }

  /// A vault made before Argon2id (PBKDF2 salt) is re-wrapped with Argon2id
  /// the first time its PIN opens it. Only the wrapped key changes, so the
  /// content is untouched. Best effort: if it can't be saved now (offline),
  /// the next unlock tries again.
  Future<void> _upgradeLegacyPinSalt(
    String userId,
    String pin,
    Uint8List masterKey,
    Map<String, dynamic> meta,
  ) async {
    final salt = meta['salt'];
    if (salt is! String || !ArcheCrypto.isLegacySaltDescriptor(salt)) return;
    try {
      await _persistPinWrapped(userId, pin, masterKey);
    } catch (e) {
      debugPrint('Could not move the vault to Argon2id yet: $e');
    }
  }

  /// The vault's PIN-wrapped key, for an encrypted backup to carry: the same
  /// values the server stores (public salt plus ciphertext), useless without
  /// the PIN. Uses the offline copy when the server can't be reached.
  Future<Map<String, String>> backupMeta(String userId) async {
    final meta = await _loadUnlockMeta(userId);
    if (meta == null || meta['wrapped_key'] == null) {
      throw VaultException('No vault PIN is configured for this account.');
    }
    return {
      'salt': meta['salt'] as String,
      'wrapped_key': meta['wrapped_key'] as String,
      'key_check': meta['key_check'] as String,
    };
  }

  /// Unwrap a vault key from its PIN-wrapped form (a backup's `vault` block).
  /// Throws [VaultException] 'Incorrect PIN.' when the PIN doesn't open it.
  Future<Uint8List> unwrapWithPin(Map<String, dynamic> meta, String pin) =>
      _unlockWithPin(meta, pin);

  /// Create a brand-new vault for a user who has none: generate a random master
  /// key, wrap it under [pin], and also wrap it under a fresh one-time recovery
  /// code. Returns the master key (to unlock the session) and the recovery code
  /// (to show once). Mirrors the web `setupUserVault`.
  Future<({Uint8List masterKey, String recoveryCode})> setupVault(
    String userId,
    String pin,
  ) async {
    final pinErr = validateVaultPin(pin);
    if (pinErr != null) throw VaultException(pinErr);

    // Safety net: never overwrite an existing vault. If a row already exists this
    // is an unlock situation misread as first-run setup - replacing the master
    // key would lock the user out of all their data. Fail closed (a check error
    // also aborts, rather than risk an overwrite).
    Map<String, dynamic>? existing;
    try {
      existing = await _client
          .from('user_encryption')
          .select('wrapped_key, key_check')
          .eq('user_id', userId)
          .maybeSingle();
    } catch (_) {
      throw VaultException(
        'Could not verify your vault. Check your connection and try again.',
      );
    }
    if (existing != null &&
        (existing['wrapped_key'] != null || existing['key_check'] != null)) {
      throw VaultException(
        'A vault already exists for this account. Reopen the app and unlock '
        'with your PIN.',
      );
    }

    final masterKey = ArcheCrypto.randomAesKey();
    final recoveryCode = generateRecoveryCode();
    await _persistPinWrapped(
      userId,
      pin,
      masterKey,
      recoveryCode: recoveryCode,
    );
    return (masterKey: masterKey, recoveryCode: recoveryCode);
  }

  /// Reset the vault when BOTH the PIN and recovery code are lost. Permanently
  /// deletes all encrypted content and the vault row (the data is unrecoverable
  /// without the key - that is the point), then creates a fresh vault and a new
  /// recovery code. The caller MUST re-verify the account password first.
  Future<({Uint8List masterKey, String recoveryCode})> resetVault(
    String userId,
    String pin,
  ) async {
    final pinErr = validateVaultPin(pin);
    if (pinErr != null) throw VaultException(pinErr);

    // Delete all encrypted content (space_items cascade from spaces, but delete
    // both explicitly), then drop the old vault row so setup starts fresh.
    await _client.from('space_items').delete().eq('user_id', userId);
    await _client.from('spaces').delete().eq('user_id', userId);
    await _client.from('user_encryption').delete().eq('user_id', userId);
    await CacheStore.delete(_metaCacheKey);

    final masterKey = ArcheCrypto.randomAesKey();
    final recoveryCode = generateRecoveryCode();
    await _persistPinWrapped(userId, pin, masterKey, recoveryCode: recoveryCode);
    return (masterKey: masterKey, recoveryCode: recoveryCode);
  }

  /// Verify the current PIN, then re-wrap the master key under [newPin].
  /// Returns the unchanged master key. Leaves any recovery code untouched.
  Future<Uint8List> changePin(
    String userId,
    String currentPin,
    String newPin,
  ) async {
    final pinErr = validateVaultPin(newPin);
    if (pinErr != null) throw VaultException(pinErr);

    final meta = await _client
        .from('user_encryption')
        .select('salt, key_check, wrapped_key')
        .eq('user_id', userId)
        .maybeSingle();
    if (meta == null) {
      throw VaultException('No vault PIN is configured for this account.');
    }

    final masterKey = await _unlockWithPin(meta, currentPin);
    await _persistPinWrapped(userId, newPin, masterKey);
    return masterKey;
  }

  /// Verify the current PIN, then create (or replace) the one-time recovery
  /// code that also wraps the master key. Returns the plaintext recovery code
  /// to show once.
  Future<String> createRecoveryCode(String userId, String currentPin) async {
    final meta = await _client
        .from('user_encryption')
        .select('salt, key_check, wrapped_key')
        .eq('user_id', userId)
        .maybeSingle();
    if (meta == null) {
      throw VaultException('No vault PIN is configured for this account.');
    }

    final masterKey = await _unlockWithPin(meta, currentPin);
    final recoveryCode = generateRecoveryCode();
    final recoverySalt = ArcheCrypto.newSaltDescriptor();
    final recoveryKey = await ArcheCrypto.deriveVaultKey(
      recoveryCode,
      recoverySalt,
    );
    final rawB64 = base64.encode(masterKey);
    final recoveryWrapped = await ArcheCrypto.encryptArc1(rawB64, recoveryKey);

    await _client
        .from('user_encryption')
        .update({
          'recovery_salt': recoverySalt,
          'recovery_wrapped_key': recoveryWrapped,
        })
        .eq('user_id', userId);

    return recoveryCode;
  }

  /// Unlock with the recovery code, set [newPin], and rotate the recovery code.
  /// Returns the recovered master key (to unlock the session straight away) and
  /// the new recovery code to show once (forgot-PIN, and from Settings).
  Future<({Uint8List masterKey, String recoveryCode})> recoverWithCode(
    String userId,
    String recoveryCode,
    String newPin,
  ) async {
    final pinErr = validateVaultPin(newPin);
    if (pinErr != null) throw VaultException(pinErr);
    final codeErr = validateRecoveryCode(recoveryCode);
    if (codeErr != null) throw VaultException(codeErr);

    final meta = await _client
        .from('user_encryption')
        .select('key_check, recovery_salt, recovery_wrapped_key')
        .eq('user_id', userId)
        .maybeSingle();
    if (meta == null) {
      throw VaultException('No vault PIN is configured for this account.');
    }
    if (meta['recovery_salt'] == null || meta['recovery_wrapped_key'] == null) {
      throw VaultException('No recovery code is configured for this vault.');
    }

    final masterKey = await _unlockWithRecovery(meta, recoveryCode);
    final nextCode = generateRecoveryCode();
    await _persistPinWrapped(userId, newPin, masterKey, recoveryCode: nextCode);
    return (masterKey: masterKey, recoveryCode: nextCode);
  }

  Future<Uint8List> _unlockWithPin(
    Map<String, dynamic> meta,
    String pin,
  ) async {
    final pinKey = await ArcheCrypto.deriveVaultKey(
      pin,
      meta['salt'] as String,
    );

    String rawKeyB64;
    try {
      rawKeyB64 = await ArcheCrypto.decryptArc1(
        meta['wrapped_key'] as String,
        pinKey,
      );
    } catch (_) {
      // A wrong PIN makes GCM authentication fail before the key check.
      throw VaultException('Incorrect PIN.');
    }

    final masterKey = base64.decode(rawKeyB64);
    final check = await ArcheCrypto.decryptArc1(
      meta['key_check'] as String,
      masterKey,
    );
    if (check != _checkPlaintext) {
      throw VaultException('Incorrect PIN.');
    }
    return Uint8List.fromList(masterKey);
  }

  Future<Uint8List> _unlockWithRecovery(
    Map<String, dynamic> meta,
    String recoveryCode,
  ) async {
    final recoveryKey = await ArcheCrypto.deriveVaultKey(
      normalizeRecoveryCode(recoveryCode),
      meta['recovery_salt'] as String,
    );

    String rawKeyB64;
    try {
      rawKeyB64 = await ArcheCrypto.decryptArc1(
        meta['recovery_wrapped_key'] as String,
        recoveryKey,
      );
    } catch (_) {
      throw VaultException('Recovery code could not unlock your vault.');
    }

    final masterKey = base64.decode(rawKeyB64);
    final check = await ArcheCrypto.decryptArc1(
      meta['key_check'] as String,
      masterKey,
    );
    if (check != _checkPlaintext) {
      throw VaultException('Recovery code could not unlock your vault.');
    }
    return Uint8List.fromList(masterKey);
  }

  /// Re-wrap [masterKey] under a PIN-derived key with a fresh salt. When
  /// [recoveryCode] is given, also wrap it under a recovery-derived key in the
  /// same row. Columns not in the payload are preserved by the upsert.
  Future<void> _persistPinWrapped(
    String userId,
    String pin,
    Uint8List masterKey, {
    String? recoveryCode,
  }) async {
    final pinSalt = ArcheCrypto.newSaltDescriptor();
    final pinKey = await ArcheCrypto.deriveVaultKey(pin, pinSalt);
    final rawB64 = base64.encode(masterKey);
    final wrappedKey = await ArcheCrypto.encryptArc1(rawB64, pinKey);
    final keyCheck = await ArcheCrypto.encryptArc1(_checkPlaintext, masterKey);

    final payload = <String, dynamic>{
      'user_id': userId,
      'salt': pinSalt,
      'key_check': keyCheck,
      'wrapped_key': wrappedKey,
    };

    if (recoveryCode != null) {
      final recoverySalt = ArcheCrypto.newSaltDescriptor();
      final recoveryKey = await ArcheCrypto.deriveVaultKey(
        normalizeRecoveryCode(recoveryCode),
        recoverySalt,
      );
      payload['recovery_salt'] = recoverySalt;
      payload['recovery_wrapped_key'] = await ArcheCrypto.encryptArc1(
        rawB64,
        recoveryKey,
      );
    }

    await _client.from('user_encryption').upsert(payload);

    // Keep the offline unlock cache in sync with the freshly wrapped key.
    await CacheStore.write(_metaCacheKey, {
      'salt': payload['salt'],
      'key_check': payload['key_check'],
      'wrapped_key': payload['wrapped_key'],
    });
  }
}
