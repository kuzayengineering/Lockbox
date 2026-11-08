// Low-level cryptography helpers for Lockbox.
//
// * AES-256-GCM (via BoringSSL through package:webcrypto) for all encryption.
// * Argon2id (package:cryptography) to turn the passphrase into a key.
//
// Nothing in this file touches the disk.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:cryptography/dart.dart' show DartArgon2id;
import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:webcrypto/webcrypto.dart';

const int kKeyLength = 32; // 256-bit keys
const int kNonceLength = 12; // 96-bit GCM nonces
const int kTagLength = 16; // 128-bit GCM tags

/// Thrown when data cannot be decrypted: wrong passphrase, or the data was
/// modified / corrupted.
class DecryptionException implements Exception {
  DecryptionException([this.message = 'Decryption failed']);
  final String message;
  @override
  String toString() => 'DecryptionException: $message';
}

/// Cryptographically secure random bytes.
Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  // fillRandomBytes accepts at most 64 KiB per call.
  for (var offset = 0; offset < length; offset += 65536) {
    final end = (offset + 65536 < length) ? offset + 65536 : length;
    fillRandomBytes(Uint8List.sublistView(out, offset, end));
  }
  return out;
}

/// A random lowercase hex id (default 128 bits) used for file names.
String randomId([int bytes = 16]) {
  final b = randomBytes(bytes);
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Parameters for the Argon2id passphrase hashing.
class KdfParams {
  const KdfParams({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  /// 64 MiB, 3 passes. Takes roughly 0.5-3 s depending on the device, which
  /// makes guessing passphrases expensive for an attacker.
  static const standard =
      KdfParams(memoryKiB: 65536, iterations: 3, parallelism: 1);

  /// Very cheap parameters, ONLY for automated tests.
  static const testing = KdfParams(memoryKiB: 64, iterations: 1, parallelism: 1);

  final int memoryKiB;
  final int iterations;
  final int parallelism;
}

/// Derives a 256-bit key from [passphrase] and [salt] with Argon2id.
///
/// This is deliberately slow; call it from a background isolate.
Future<Uint8List> deriveKeyFromPassphrase(
  String passphrase,
  Uint8List salt,
  KdfParams params,
) async {
  final argon = DartArgon2id(
    memory: params.memoryKiB,
    iterations: params.iterations,
    parallelism: params.parallelism,
    hashLength: kKeyLength,
  );
  final key = await argon.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// AES-256-GCM key wrapper with a tiny cache of the imported key object.
class AesKey {
  AesKey._(this.bytes, this._key);

  static Future<AesKey> fromBytes(Uint8List bytes) async {
    if (bytes.length != kKeyLength) {
      throw ArgumentError('AES key must be $kKeyLength bytes');
    }
    final copy = Uint8List.fromList(bytes);
    return AesKey._(copy, await AesGcmSecretKey.importRawKey(copy));
  }

  /// Raw key bytes. Handle with care.
  final Uint8List bytes;
  final AesGcmSecretKey _key;

  /// Returns ciphertext followed by the 16-byte authentication tag.
  Future<Uint8List> encrypt(
    List<int> plaintext,
    Uint8List nonce, {
    List<int>? aad,
  }) =>
      _key.encryptBytes(plaintext, nonce, additionalData: aad);

  /// [data] is ciphertext followed by the 16-byte tag.
  Future<Uint8List> decrypt(
    List<int> data,
    Uint8List nonce, {
    List<int>? aad,
  }) async {
    try {
      return await _key.decryptBytes(data, nonce, additionalData: aad);
    } catch (_) {
      throw DecryptionException();
    }
  }

  /// Overwrites the raw key bytes in memory (best effort).
  void wipe() => bytes.fillRange(0, bytes.length, 0);
}

/// Little helpers for reading/writing fixed-width integers.
void writeU64LE(Uint8List b, int offset, int value) {
  ByteData.sublistView(b).setUint64(offset, value, Endian.little);
}

int readU64LE(Uint8List b, int offset) =>
    ByteData.sublistView(b).getUint64(offset, Endian.little);

void writeU32LE(Uint8List b, int offset, int value) {
  ByteData.sublistView(b).setUint32(offset, value, Endian.little);
}

int readU32LE(Uint8List b, int offset) =>
    ByteData.sublistView(b).getUint32(offset, Endian.little);

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
