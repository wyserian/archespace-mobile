import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Dart port of the ArcheSpace `arc1` crypto contract.
///
/// Must stay byte-compatible with the web reference implementation so data
/// encrypted on either client decrypts on the other. Validated against
/// `spec/vectors.json` by `test/crypto_vectors_test.dart`. See
/// `spec/crypto-format.md` for the full contract.
class ArcheCrypto {
  ArcheCrypto._();

  static const _prefix = 'arc1:';
  static const _tagLength = 16; // AES-GCM 128-bit auth tag
  // On a phone, cryptography_flutter (registered by itself) runs larger values
  // on the platform's own AES and keeps small ones in Dart, where a native
  // call would cost more. A background isolate (see warm) uses Dart's.
  static final AesGcm _aes = AesGcm.with256bits(nonceLength: 12);

  // Argon2id parameters, matching the web (OWASP-aligned): 19 MiB, 2 passes,
  // 1 lane.
  static const _argonMemory = 19456; // KiB
  static const _argonIterations = 2;
  static const _argonParallelism = 1;

  // PBKDF2-SHA-256 iterations that pre-Argon2id vaults were made with.
  static const _legacyPbkdf2Iterations = 310000;

  /// Whether a stored salt predates Argon2id (a plain base64 PBKDF2 salt).
  static bool isLegacySaltDescriptor(String descriptor) =>
      !descriptor.startsWith('argon2id\$');

  /// Generate a fresh random 32-byte AES-256 master key. Equivalent to the
  /// web's `crypto.subtle.generateKey` + raw export.
  static Uint8List randomAesKey() {
    final rng = Random.secure();
    return Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
  }

  /// Build a self-describing salt descriptor for a NEW wrapping key, matching
  /// the web `newSaltDescriptor()`: `argon2id$<m>$<t>$<p>$<saltB64>` with a
  /// fresh 16-byte random salt. [deriveVaultKey] reads the params back out.
  static String newSaltDescriptor() {
    final rng = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );
    return 'argon2id\$$_argonMemory\$$_argonIterations\$$_argonParallelism\$${base64.encode(salt)}';
  }

  /// Derive the 32-byte AES key from a vault secret using the Argon2id
  /// parameters in [descriptor] (`argon2id$m$t$p$saltB64`). A vault made
  /// before Argon2id stores a plain base64 salt for PBKDF2; it still opens,
  /// and unlock moves it to Argon2id (see VaultService).
  static Future<Uint8List> deriveVaultKey(
    String secret,
    String descriptor,
  ) async {
    if (isLegacySaltDescriptor(descriptor)) {
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: _legacyPbkdf2Iterations,
        bits: 256,
      );
      final key = await pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(secret)),
        nonce: base64.decode(descriptor),
      );
      return Uint8List.fromList(await key.extractBytes());
    }
    final parts = descriptor.split('\$'); // [argon2id, m, t, p, saltB64]
    if (parts.length != 5) {
      throw const FormatException('Unsupported vault key format.');
    }
    final algorithm = Argon2id(
      memory: int.parse(parts[1]), // KiB
      iterations: int.parse(parts[2]),
      parallelism: int.parse(parts[3]),
      hashLength: 32,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(secret)),
      nonce: base64.decode(parts[4]),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  // Decrypted text by ciphertext, kept in memory while unlocked. Every
  // ciphertext has its own random IV, so an entry can never go stale: lists,
  // search and reloads only decrypt values they haven't seen. An entry holds
  // the key it was decrypted with and only answers for that key. Least
  // recently used entries go first past the cap (in characters, ciphertext
  // plus text).
  static const _cacheMaxChars = 16 * 1024 * 1024;
  static final _cache = <String, ({List<int> key, String text})>{};
  static var _cachedChars = 0;
  // Bumped on every clear, so work started before a lock can't refill it.
  static var _generation = 0;

  // A list with fewer values to decrypt than this stays on this isolate:
  // starting another costs more than it saves.
  static const _backgroundMin = 32;

  static String? _cached(String value, List<int> key) {
    final entry = _cache.remove(value);
    if (entry == null) return null;
    _cache[value] = entry; // now the most recently used
    return identical(entry.key, key) ? entry.text : null;
  }

  static void _remember(
    String value,
    List<int> key,
    String text,
    int startedIn,
  ) {
    if (startedIn != _generation || _cache.containsKey(value)) return;
    final size = value.length + text.length;
    if (size > _cacheMaxChars) return;
    _cache[value] = (key: key, text: text);
    _cachedChars += size;
    while (_cachedChars > _cacheMaxChars) {
      final oldest = _cache.keys.first;
      _cachedChars -= oldest.length + _cache.remove(oldest)!.text.length;
    }
  }

  /// Forget every decrypted value (the vault locked).
  static void clearCache() {
    _cache.clear();
    _cachedChars = 0;
    _generation++;
  }

  /// Decrypt the `arc1:` values among [values] that aren't decrypted yet, all
  /// at once: on a background isolate when there are many, so a long list
  /// never stalls scrolling. Later [decryptArc1] calls for them are instant.
  /// One that fails is left for [decryptArc1] to fail on.
  static Future<void> warm(Iterable<Object?> values, List<int> keyBytes) async {
    final missing = {
      for (final v in values)
        if (v is String &&
            v.startsWith(_prefix) &&
            _cached(v, keyBytes) == null)
          v,
    }.toList();
    if (missing.isEmpty) return;
    final startedIn = _generation;
    final texts = missing.length < _backgroundMin
        ? await _decryptAll(missing, keyBytes)
        : await _decryptInBackground(missing, keyBytes);
    for (var i = 0; i < missing.length; i++) {
      final text = texts[i];
      if (text != null) _remember(missing[i], keyBytes, text, startedIn);
    }
  }

  // Its own function, so the isolate gets only these two values.
  static Future<List<String?>> _decryptInBackground(
    List<String> values,
    List<int> keyBytes,
  ) => Isolate.run(() => _decryptAll(values, keyBytes));

  static Future<List<String?>> _decryptAll(
    List<String> values,
    List<int> keyBytes,
  ) async {
    final texts = <String?>[];
    for (final value in values) {
      try {
        texts.add(await _decrypt(value, keyBytes));
      } catch (_) {
        texts.add(null);
      }
    }
    return texts;
  }

  /// Decrypt an `arc1:` value with a raw 32-byte AES key. An empty value
  /// decrypts to ''; anything else that isn't `arc1:` is rejected.
  static Future<String> decryptArc1(String value, List<int> keyBytes) async {
    if (value.isEmpty) return '';
    if (!value.startsWith(_prefix)) {
      throw const FormatException('Not an encrypted value');
    }
    final hit = _cached(value, keyBytes);
    if (hit != null) return hit;
    final startedIn = _generation;
    final text = await _decrypt(value, keyBytes);
    _remember(value, keyBytes, text, startedIn);
    return text;
  }

  static Future<String> _decrypt(String value, List<int> keyBytes) async {
    final body = value.substring(_prefix.length);
    final dot = body.indexOf('.');
    if (dot < 0) throw const FormatException('Invalid arc1 payload');

    final iv = base64.decode(body.substring(0, dot));
    final ctWithTag = base64.decode(body.substring(dot + 1));
    // The web appends the GCM tag to the ciphertext; split it back out.
    final cipherText = ctWithTag.sublist(0, ctWithTag.length - _tagLength);
    final mac = Mac(ctWithTag.sublist(ctWithTag.length - _tagLength));

    final clear = await _aes.decrypt(
      SecretBox(cipherText, nonce: iv, mac: mac),
      secretKey: SecretKey(keyBytes),
    );
    return utf8.decode(clear);
  }

  /// Decrypt an encrypted JSON object (an item's content); `{}` when empty.
  static Future<Map<String, dynamic>> decryptJsonMap(
    Object? value,
    List<int> keyBytes,
  ) async {
    if (value is! String || value.isEmpty) return <String, dynamic>{};
    final text = await decryptArc1(value, keyBytes);
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    return decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{};
  }

  /// Decrypt a row's tags. Tags left at the column default (an empty list)
  /// were never encrypted.
  static Future<List<String>> decryptTags(
    Object? value,
    List<int> keyBytes,
  ) async {
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is! String || value.isEmpty) return const [];
    final text = await decryptArc1(value, keyBytes);
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {}
    return const [];
  }

  /// Encrypt a string into an `arc1:` value (fresh random 12-byte IV).
  static Future<String> encryptArc1(
    String plaintext,
    List<int> keyBytes,
  ) async {
    final startedIn = _generation;
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(keyBytes),
    );
    final ctWithTag = <int>[...box.cipherText, ...box.mac.bytes];
    final value =
        '$_prefix${base64.encode(box.nonce)}.${base64.encode(ctWithTag)}';
    // A saved value comes straight back from the server; no need to decrypt it.
    _remember(value, keyBytes, plaintext, startedIn);
    return value;
  }
}
