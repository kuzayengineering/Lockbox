// The encrypted file ("blob") format used for every photo, video, audio file
// and thumbnail stored in a Lockbox vault.
//
// The file is split into fixed-size chunks that are encrypted independently,
// so any byte range can be decrypted without reading the whole file. This is
// what makes instant seeking in long 4K/HDR videos possible.
//
// Layout (all integers little-endian unless noted):
//
//   Header, 80 bytes
//     0   4  magic "LBX1"
//     4   1  format version (1)
//     5   1  chunk size as a power of two (18 => 256 KiB)
//     6   2  reserved (0)
//     8   8  plaintext length in bytes
//     16 12  nonce used to wrap the file key
//     28 48  per-file key (32 bytes) encrypted with the vault master key
//            (AES-256-GCM, additional data = header bytes 0..16)
//     76  4  reserved (0)
//
//   Chunk i (i = 0 .. n-1), each (chunkSize + 16) bytes, the last one shorter
//     AES-256-GCM(fileKey,
//                 nonce = 00 00 00 00 || i as big-endian uint64,
//                 data  = plaintext bytes of chunk i,
//                 additional data = header bytes 0..16 || i (BE uint64) ||
//                                   1 if last chunk else 0)
//
// Because each file has its own random key, the counter nonces never repeat
// for the same key. Including the length and the "last chunk" flag in the
// additional data means chunks cannot be reordered, swapped between files,
// or the file truncated without detection.
//
// The Android player (android/.../EncryptedBlobDataSource.kt) implements the
// same reading logic in Kotlin. Keep the two in sync.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'crypto.dart';
import 'embedded_tags.dart';

const List<int> kBlobMagic = [0x4C, 0x42, 0x58, 0x31]; // "LBX1"
const int kBlobVersion = 1;
const int kBlobHeaderLength = 80;
const int kDefaultChunkShift = 18; // 256 KiB

class BlobFormatException implements Exception {
  BlobFormatException(this.message);
  final String message;
  @override
  String toString() => 'BlobFormatException: $message';
}

Uint8List _nonceFor(int chunkIndex) {
  final n = Uint8List(kNonceLength);
  ByteData.sublistView(n).setUint64(4, chunkIndex, Endian.big);
  return n;
}

Uint8List _chunkAad(Uint8List header16, int chunkIndex, bool last) {
  final aad = Uint8List(16 + 8 + 1);
  aad.setRange(0, 16, header16);
  ByteData.sublistView(aad).setUint64(16, chunkIndex, Endian.big);
  aad[24] = last ? 1 : 0;
  return aad;
}

int _chunkCount(int length, int chunkSize) =>
    length == 0 ? 1 : (length + chunkSize - 1) ~/ chunkSize;

/// Encrypts a stream of plaintext into a blob file at [destPath].
///
/// [length] must be the exact number of bytes [source] will produce.
/// The file is written to a temporary name and renamed when complete, so a
/// crash never leaves a half-written blob in place.
Future<void> writeBlob({
  required Stream<List<int>> source,
  required int length,
  required String destPath,
  required AesKey masterKey,
  int chunkShift = kDefaultChunkShift,
  void Function(int bytesDone)? onProgress,
}) async {
  final chunkSize = 1 << chunkShift;
  final header = Uint8List(kBlobHeaderLength);
  header.setRange(0, 4, kBlobMagic);
  header[4] = kBlobVersion;
  header[5] = chunkShift;
  writeU64LE(header, 8, length);
  final header16 = Uint8List.sublistView(header, 0, 16);

  final fileKeyBytes = randomBytes(kKeyLength);
  final fileKey = await AesKey.fromBytes(fileKeyBytes);
  final wrapNonce = randomBytes(kNonceLength);
  final wrapped =
      await masterKey.encrypt(fileKeyBytes, wrapNonce, aad: header16);
  header.setRange(16, 28, wrapNonce);
  header.setRange(28, 76, wrapped);

  final tmpPath = '$destPath.part';
  await File(destPath).parent.create(recursive: true);
  final sink = await File(tmpPath).open(mode: FileMode.write);
  try {
    await sink.writeFrom(header);
    final total = _chunkCount(length, chunkSize);
    final buffer = Uint8List(chunkSize);
    var filled = 0;
    var chunkIndex = 0;
    var consumed = 0;

    Future<void> flush(bool last) async {
      final ct = await fileKey.encrypt(
        Uint8List.sublistView(buffer, 0, filled),
        _nonceFor(chunkIndex),
        aad: _chunkAad(header16, chunkIndex, last),
      );
      await sink.writeFrom(ct);
      chunkIndex++;
      filled = 0;
    }

    await for (final data in source) {
      var offset = 0;
      while (offset < data.length) {
        final take = math.min(chunkSize - filled, data.length - offset);
        buffer.setRange(filled, filled + take, data, offset);
        filled += take;
        offset += take;
        consumed += take;
        if (consumed > length) {
          throw BlobFormatException('Source is longer than declared length');
        }
        if (filled == chunkSize && consumed < length) {
          await flush(false);
          onProgress?.call(consumed);
        }
      }
    }
    if (consumed != length) {
      throw BlobFormatException(
          'Source produced $consumed bytes, expected $length');
    }
    await flush(true);
    onProgress?.call(consumed);
    if (chunkIndex != total) {
      throw StateError('Internal chunk count mismatch');
    }
    await sink.flush();
  } catch (_) {
    await sink.close();
    try {
      await File(tmpPath).delete();
    } catch (_) {}
    rethrow;
  }
  await sink.close();
  await File(tmpPath).rename(destPath);
}

/// Convenience: encrypt an existing plaintext file.
Future<void> encryptFileToBlob({
  required String sourcePath,
  required String destPath,
  required AesKey masterKey,
  void Function(int bytesDone)? onProgress,
}) async {
  final f = File(sourcePath);
  final len = await f.length();
  await writeBlob(
    source: f.openRead(),
    length: len,
    destPath: destPath,
    masterKey: masterKey,
    onProgress: onProgress,
  );
}

/// Convenience: encrypt bytes already in memory (e.g. thumbnails).
Future<void> encryptBytesToBlob({
  required Uint8List bytes,
  required String destPath,
  required AesKey masterKey,
}) =>
    writeBlob(
      source: Stream.value(bytes),
      length: bytes.length,
      destPath: destPath,
      masterKey: masterKey,
    );

/// Parsed blob header.
class BlobHeader {
  BlobHeader._(this.raw, this.chunkShift, this.length);

  final Uint8List raw;
  final int chunkShift;
  final int length;

  int get chunkSize => 1 << chunkShift;
  Uint8List get header16 => Uint8List.sublistView(raw, 0, 16);
  int get chunkCount => _chunkCount(length, chunkSize);

  static BlobHeader parse(Uint8List raw) {
    if (raw.length < kBlobHeaderLength) {
      throw BlobFormatException('File too short');
    }
    for (var i = 0; i < 4; i++) {
      if (raw[i] != kBlobMagic[i]) {
        throw BlobFormatException('Not a Lockbox file');
      }
    }
    if (raw[4] != kBlobVersion) {
      throw BlobFormatException('Unsupported version ${raw[4]}');
    }
    final shift = raw[5];
    if (shift < 12 || shift > 24) {
      throw BlobFormatException('Bad chunk size');
    }
    return BlobHeader._(
        Uint8List.fromList(raw.sublist(0, kBlobHeaderLength)),
        shift,
        readU64LE(raw, 8));
  }

  /// Decrypts the per-file key with the vault master key.
  Future<Uint8List> unwrapFileKey(AesKey masterKey) => masterKey.decrypt(
        Uint8List.sublistView(raw, 28, 76),
        Uint8List.sublistView(raw, 16, 28),
        aad: header16,
      );
}

/// Random-access reader for a blob. Keeps the most recently used chunk
/// decrypted in memory so sequential small reads are cheap.
class BlobReader {
  BlobReader._(this._file, this.header, this._fileKey);

  final RandomAccessFile _file;
  final BlobHeader header;
  final AesKey _fileKey;
  int _cachedIndex = -1;
  Uint8List? _cached;

  int get length => header.length;

  static Future<BlobReader> open(String path, AesKey masterKey) async {
    final file = await File(path).open();
    try {
      final raw = await file.read(kBlobHeaderLength);
      final header = BlobHeader.parse(raw);
      final keyBytes = await header.unwrapFileKey(masterKey);
      final key = await AesKey.fromBytes(keyBytes);
      keyBytes.fillRange(0, keyBytes.length, 0);
      return BlobReader._(file, header, key);
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  Future<void> _lock = Future.value();

  /// Serialises chunk loads: a RandomAccessFile allows one operation at a time.
  Future<Uint8List> _chunk(int index) {
    if (index == _cachedIndex && _cached != null) return Future.value(_cached!);
    final next = _lock.then((_) => _loadChunk(index));
    _lock = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<Uint8List> _loadChunk(int index) async {
    if (index == _cachedIndex && _cached != null) return _cached!;
    final cs = header.chunkSize;
    final count = header.chunkCount;
    if (index < 0 || index >= count) {
      throw RangeError.index(index, null, 'chunk');
    }
    final last = index == count - 1;
    final plainLen = last ? header.length - index * cs : cs;
    final offset = kBlobHeaderLength + index * (cs + kTagLength);
    await _file.setPosition(offset);
    final ct = await _file.read(plainLen + kTagLength);
    if (ct.length != plainLen + kTagLength) {
      throw DecryptionException('File is truncated');
    }
    final pt = await _fileKey.decrypt(ct, _nonceFor(index),
        aad: _chunkAad(header.header16, index, last));
    _cachedIndex = index;
    _cached = pt;
    return pt;
  }

  /// Reads plaintext bytes [start, end).
  Future<Uint8List> read(int start, int end) async {
    if (start < 0 || end > length || start > end) {
      throw RangeError('Bad range $start-$end of $length');
    }
    final out = Uint8List(end - start);
    var pos = start;
    final cs = header.chunkSize;
    while (pos < end) {
      final idx = pos ~/ cs;
      final chunk = await _chunk(idx);
      final within = pos - idx * cs;
      final take = math.min(chunk.length - within, end - pos);
      out.setRange(pos - start, pos - start + take, chunk, within);
      pos += take;
    }
    return out;
  }

  /// Streams plaintext bytes [start, end) chunk by chunk.
  Stream<Uint8List> stream([int start = 0, int? end]) async* {
    final stop = end ?? length;
    var pos = start;
    final cs = header.chunkSize;
    while (pos < stop) {
      final idx = pos ~/ cs;
      final chunk = await _chunk(idx);
      final within = pos - idx * cs;
      final take = math.min(chunk.length - within, stop - pos);
      yield Uint8List.sublistView(chunk, within, within + take);
      pos += take;
    }
  }

  Future<Uint8List> readAll() => read(0, length);

  Future<void> close() async {
    await _lock;
    _cached = null;
    _fileKey.wipe();
    await _file.close();
  }
}

/// Reads the per-file key of a blob (used by the Android native player,
/// which decrypts on its own without ever seeing the master key).
Future<Uint8List> readBlobFileKey(String path, AesKey masterKey) async {
  final f = await File(path).open();
  try {
    final header = BlobHeader.parse(await f.read(kBlobHeaderLength));
    return await header.unwrapFileKey(masterKey);
  } finally {
    await f.close();
  }
}

/// Decrypts a whole blob into memory.
Future<Uint8List> readBlobBytes(String path, AesKey masterKey) async {
  final r = await BlobReader.open(path, masterKey);
  try {
    return await r.readAll();
  } finally {
    await r.close();
  }
}

/// Decrypts a blob into a plaintext file (used for "Export").
Future<void> decryptBlobToFile(
  String blobPath,
  String destPath,
  AesKey masterKey, {
  void Function(int bytesDone)? onProgress,
  List<FilePatch> patches = const [],
}) async {
  final r = await BlobReader.open(blobPath, masterKey);
  final sink = File(destPath).openWrite();
  var done = 0;
  try {
    await for (final part in patchedStream(patches, (a, b) => r.stream(a, b))) {
      sink.add(part);
      done += part.length;
      onProgress?.call(done);
    }
    await sink.flush();
  } finally {
    await sink.close();
    await r.close();
  }
}
