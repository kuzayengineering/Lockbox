// A Lockbox vault: one folder on disk that holds everything.
//
//   <vault folder>/
//     index.lbx        encrypted library (items, folders, tags, settings)
//     index.lbx.bak    previous version of the index, for safety
//     blobs/ab/<id>    encrypted originals   (see blob_format.dart)
//     thumbs/ab/<id>   encrypted thumbnails
//
// File names are random, so nothing about the contents (names, dates, types,
// tags) is visible without the passphrase. Only the number and approximate
// sizes of files can be seen.
//
// Index file layout:
//     0   4  magic "LBXI"
//     4   1  version (1)
//     5   3  reserved
//     8  16  Argon2id salt
//     24  4  Argon2id memory (KiB)
//     28  4  Argon2id iterations
//     32  4  Argon2id parallelism
//     36 12  nonce for the wrapped master key
//     48 48  master key encrypted with the passphrase key (AAD = bytes 0..36)
//     96 12  nonce for the library
//     108 .. gzip(JSON library) encrypted with the master key (AAD = 0..108)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'auto_tag.dart';
import 'blob_format.dart';
import 'crypto.dart';
import 'models.dart';
import 'ultra_hdr.dart';

const List<int> kIndexMagic = [0x4C, 0x42, 0x58, 0x49]; // "LBXI"
const int kIndexVersion = 1;
const int _kIndexHeaderLength = 108;
const String kIndexFileName = 'index.lbx';

class WrongPassphraseException implements Exception {
  @override
  String toString() => 'Wrong passphrase';
}

class VaultCorruptException implements Exception {
  VaultCorruptException(this.message);
  final String message;
  @override
  String toString() => 'Vault damaged: $message';
}

class Vault {
  Vault._({
    required this.directory,
    required AesKey masterKey,
    required Uint8List keyHeader,
    required this.data,
  })  : _masterKey = masterKey, // ignore: prefer_initializing_formals
        _keyHeader = keyHeader; // ignore: prefer_initializing_formals

  /// Folder containing the vault.
  final String directory;

  AesKey? _masterKey;

  /// Bytes 0..96 of the index file (KDF params + wrapped master key). Only
  /// changes when the passphrase changes.
  Uint8List _keyHeader;

  /// The decrypted library. Mutate it, then call [save].
  final LibraryData data;

  bool get isLocked => _masterKey == null;

  AesKey get masterKey {
    final k = _masterKey;
    if (k == null) throw StateError('Vault is locked');
    return k;
  }

  String get indexPath => p.join(directory, kIndexFileName);
  String blobPath(String id) =>
      p.join(directory, 'blobs', id.substring(0, 2), id);
  String thumbPath(String id) =>
      p.join(directory, 'thumbs', id.substring(0, 2), id);

  static bool existsAt(String directory) =>
      File(p.join(directory, kIndexFileName)).existsSync();

  // ---------------------------------------------------------------- create

  static Future<Vault> create(
    String directory,
    String passphrase, {
    KdfParams params = KdfParams.standard,
  }) async {
    if (existsAt(directory)) {
      throw StateError('A vault already exists in $directory');
    }
    await Directory(directory).create(recursive: true);
    final masterBytes = randomBytes(kKeyLength);
    final keyHeader =
        await _buildKeyHeader(masterBytes, passphrase, params);
    final vault = Vault._(
      directory: directory,
      masterKey: await AesKey.fromBytes(masterBytes),
      keyHeader: keyHeader,
      data: LibraryData(),
    );
    masterBytes.fillRange(0, masterBytes.length, 0);
    await vault.save();
    return vault;
  }

  static Future<Uint8List> _buildKeyHeader(
      Uint8List masterBytes, String passphrase, KdfParams params) async {
    final h = Uint8List(96);
    h.setRange(0, 4, kIndexMagic);
    h[4] = kIndexVersion;
    final salt = randomBytes(16);
    h.setRange(8, 24, salt);
    writeU32LE(h, 24, params.memoryKiB);
    writeU32LE(h, 28, params.iterations);
    writeU32LE(h, 32, params.parallelism);
    final kek = await AesKey.fromBytes(
        await _deriveInBackground(passphrase, salt, params));
    final nonce = randomBytes(kNonceLength);
    final wrapped = await kek.encrypt(masterBytes, nonce,
        aad: Uint8List.sublistView(h, 0, 36));
    kek.wipe();
    h.setRange(36, 48, nonce);
    h.setRange(48, 96, wrapped);
    return h;
  }

  static Future<Uint8List> _deriveInBackground(
      String passphrase, Uint8List salt, KdfParams params) {
    final m = params.memoryKiB, it = params.iterations, par = params.parallelism;
    return Isolate.run(() => deriveKeyFromPassphrase(passphrase, salt,
        KdfParams(memoryKiB: m, iterations: it, parallelism: par)));
  }

  // ------------------------------------------------------------------ open

  /// Opens (unlocks) the vault. Throws [WrongPassphraseException].
  static Future<Vault> open(String directory, String passphrase) async {
    final main = File(p.join(directory, kIndexFileName));
    final backup = File('${main.path}.bak');
    Object? firstError;
    for (final f in [main, backup]) {
      if (!f.existsSync()) continue;
      try {
        return await _openFile(directory, f, passphrase);
      } on WrongPassphraseException {
        rethrow;
      } catch (e) {
        // Main index damaged: fall back to the backup copy.
        firstError ??= e;
      }
    }
    throw firstError ?? VaultCorruptException('No index file found');
  }

  static Future<Vault> _openFile(
      String directory, File f, String passphrase) async {
    final bytes = await f.readAsBytes();
    if (bytes.length < _kIndexHeaderLength + kTagLength) {
      throw VaultCorruptException('Index too short');
    }
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != kIndexMagic[i]) {
        throw VaultCorruptException('Not a Lockbox vault');
      }
    }
    if (bytes[4] != kIndexVersion) {
      throw VaultCorruptException('Unsupported vault version ${bytes[4]}');
    }
    final salt = Uint8List.fromList(bytes.sublist(8, 24));
    final params = KdfParams(
      memoryKiB: readU32LE(bytes, 24),
      iterations: readU32LE(bytes, 28),
      parallelism: readU32LE(bytes, 32),
    );
    final kek = await AesKey.fromBytes(
        await _deriveInBackground(passphrase, salt, params));
    Uint8List masterBytes;
    try {
      masterBytes = await kek.decrypt(
        Uint8List.sublistView(bytes, 48, 96),
        Uint8List.sublistView(bytes, 36, 48),
        aad: Uint8List.sublistView(bytes, 0, 36),
      );
    } on DecryptionException {
      throw WrongPassphraseException();
    } finally {
      kek.wipe();
    }
    final master = await AesKey.fromBytes(masterBytes);
    masterBytes.fillRange(0, masterBytes.length, 0);
    Uint8List plain;
    try {
      plain = await master.decrypt(
        Uint8List.sublistView(bytes, _kIndexHeaderLength),
        Uint8List.sublistView(bytes, 96, 108),
        aad: Uint8List.sublistView(bytes, 0, _kIndexHeaderLength),
      );
    } on DecryptionException {
      throw VaultCorruptException('Index failed integrity check');
    }
    final json = jsonDecode(utf8.decode(gzip.decode(plain)));
    return Vault._(
      directory: directory,
      masterKey: master,
      keyHeader: Uint8List.fromList(bytes.sublist(0, 96)),
      data: LibraryData.fromJson((json as Map).cast<String, dynamic>()),
    );
  }

  // ------------------------------------------------------------------ save

  Future<void> _saveChain = Future.value();

  /// Encrypts and writes the index. Calls are queued so they never overlap.
  Future<void> save() {
    final next = _saveChain.then((_) => _saveNow());
    _saveChain = next.catchError((_) {});
    return next;
  }

  Future<void> _saveNow() async {
    final key = masterKey;
    final plain = gzip.encode(utf8.encode(jsonEncode(data.toJson())));
    final header = Uint8List(_kIndexHeaderLength);
    header.setRange(0, 96, _keyHeader);
    final nonce = randomBytes(kNonceLength);
    header.setRange(96, 108, nonce);
    final ct = await key.encrypt(plain, nonce, aad: header);
    final out = BytesBuilder(copy: false)
      ..add(header)
      ..add(ct);

    final main = File(indexPath);
    final tmp = File('$indexPath.tmp');
    await tmp.writeAsBytes(out.takeBytes(), flush: true);
    if (main.existsSync()) {
      await main.copy('$indexPath.bak');
    }
    await tmp.rename(main.path);
  }

  // -------------------------------------------------------- passphrase/lock

  /// Re-encrypts the master key with a new passphrase. Media files do not
  /// need to be rewritten, so this is instant.
  Future<void> changePassphrase(String newPassphrase,
      {KdfParams params = KdfParams.standard}) async {
    _keyHeader = await _buildKeyHeader(masterKey.bytes, newPassphrase, params);
    await save();
    // Make sure the old passphrase can't open the backup copy either.
    await File(indexPath).copy('$indexPath.bak');
  }

  /// Checks a passphrase without changing anything.
  Future<bool> verifyPassphrase(String passphrase) async {
    final h = _keyHeader;
    final params = KdfParams(
        memoryKiB: readU32LE(h, 24),
        iterations: readU32LE(h, 28),
        parallelism: readU32LE(h, 32));
    final kek = await AesKey.fromBytes(await _deriveInBackground(
        passphrase, Uint8List.fromList(h.sublist(8, 24)), params));
    try {
      await kek.decrypt(
          Uint8List.sublistView(h, 48, 96), Uint8List.sublistView(h, 36, 48),
          aad: Uint8List.sublistView(h, 0, 36));
      return true;
    } on DecryptionException {
      return false;
    } finally {
      kek.wipe();
    }
  }

  /// Forgets the key. The object can't be used afterwards.
  Future<void> lock() async {
    await _saveChain;
    _masterKey?.wipe();
    _masterKey = null;
  }

  // ----------------------------------------------------------------- media

  MediaItem? itemById(String id) {
    for (final i in data.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Encrypts a file into the vault and returns the new blob id.
  /// Runs the encryption on a background isolate.
  Future<String> storeFile(String sourcePath) async {
    final id = randomId();
    final dest = blobPath(id);
    final keyBytes = Uint8List.fromList(masterKey.bytes);
    await Isolate.run(() async {
      final k = await AesKey.fromBytes(keyBytes);
      await encryptFileToBlob(
          sourcePath: sourcePath, destPath: dest, masterKey: k);
      k.wipe();
    });
    keyBytes.fillRange(0, keyBytes.length, 0);
    return id;
  }

  /// Encrypts bytes held in memory (e.g. a saved video frame) as an original.
  Future<String> storeBytes(Uint8List bytes) async {
    final id = randomId();
    await encryptBytesToBlob(
        bytes: bytes, destPath: blobPath(id), masterKey: masterKey);
    return id;
  }

  /// The top-level folder called [name], created if missing.
  Folder topFolderNamed(String name) {
    for (final f in data.folders) {
      if (f.parentId == null && f.name == name) return f;
    }
    return createFolder(name);
  }

  Future<String> storeThumbnail(Uint8List bytes) async {
    final id = randomId();
    await encryptBytesToBlob(
        bytes: bytes, destPath: thumbPath(id), masterKey: masterKey);
    return id;
  }

  Future<Uint8List?> readThumbnail(MediaItem item) async {
    final t = item.thumbId;
    if (t == null) return null;
    try {
      return await readBlobBytes(thumbPath(t), masterKey);
    } catch (_) {
      return null;
    }
  }

  /// Decrypts a whole original into memory (photos). Uses a background
  /// isolate so big images don't freeze the UI.
  Future<Uint8List> readOriginal(MediaItem item) {
    final path = blobPath(item.blobId);
    final keyBytes = Uint8List.fromList(masterKey.bytes);
    return Isolate.run(() async {
      final k = await AesKey.fromBytes(keyBytes);
      try {
        return await readBlobBytes(path, k);
      } finally {
        k.wipe();
      }
    });
  }

  Future<BlobReader> openOriginal(MediaItem item) =>
      BlobReader.open(blobPath(item.blobId), masterKey);

  /// The per-file key of an item (for the Android native player).
  Future<Uint8List> fileKeyFor(MediaItem item) =>
      readBlobFileKey(blobPath(item.blobId), masterKey);

  /// Writes a decrypted copy of [item] to [destPath].
  Future<void> exportItem(MediaItem item, String destPath) {
    final src = blobPath(item.blobId);
    final keyBytes = Uint8List.fromList(masterKey.bytes);
    return Isolate.run(() async {
      final k = await AesKey.fromBytes(keyBytes);
      try {
        await decryptBlobToFile(src, destPath, k);
      } finally {
        k.wipe();
      }
    });
  }

  /// Permanently removes items and their encrypted files.
  Future<void> deleteItems(Iterable<String> ids) async {
    final set = ids.toSet();
    final doomed = data.items.where((i) => set.contains(i.id)).toList();
    data.items.removeWhere((i) => set.contains(i.id));
    await save();
    for (final i in doomed) {
      await _deleteQuietly(blobPath(i.blobId));
      if (i.thumbId != null) await _deleteQuietly(thumbPath(i.thumbId!));
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  // --------------------------------------------------------- folders/tags

  Folder createFolder(String name, {String? parentId}) {
    final f = Folder(id: randomId(8), name: name, parentId: parentId);
    data.folders.add(f);
    return f;
  }

  /// All folder ids inside [folderId] (including itself).
  Set<String> folderAndDescendants(String folderId) {
    final out = <String>{folderId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in data.folders) {
        if (f.parentId != null &&
            out.contains(f.parentId) &&
            out.add(f.id)) {
          grew = true;
        }
      }
    }
    return out;
  }

  /// Deletes a folder. Its items and sub-folders move up to the parent.
  void deleteFolder(String folderId) {
    final f = data.folders.firstWhere((x) => x.id == folderId);
    for (final child in data.folders) {
      if (child.parentId == folderId) child.parentId = f.parentId;
    }
    for (final i in data.items) {
      if (i.folderId == folderId) i.folderId = f.parentId;
    }
    data.folders.remove(f);
    data.settings.folderViews.remove(folderId);
  }

  Tag createTag(String name, {int? color}) {
    final t = Tag(id: randomId(8), name: name, color: color ?? 0xFF5C6BC0);
    data.tags.add(t);
    return t;
  }

  /// Finds a tag by name (ignoring upper/lower case) or creates it.
  Tag tagNamed(String name) {
    final lower = name.toLowerCase();
    for (final t in data.tags) {
      if (t.name.toLowerCase() == lower) return t;
    }
    return createTag(name, color: _tagPalette[data.tags.length % _tagPalette.length]);
  }

  static const _tagPalette = [
    0xFF5C6BC0, 0xFF26A69A, 0xFFEF5350, 0xFFAB47BC, 0xFFFFA726,
    0xFF42A5F5, 0xFF66BB6A, 0xFFEC407A, 0xFF8D6E63, 0xFF78909C,
  ];

  /// Tags an item with the words of its file name (see auto_tag.dart).
  void autoTag(MediaItem item) {
    for (final w in tagWordsFromFileName(item.name)) {
      item.tagIds.add(tagNamed(w).id);
    }
  }

  /// Marks existing JPEG photos that are Ultra HDR (reads only the start of
  /// each file). Returns how many were found.
  Future<int> scanUltraHdrPhotos() async {
    var found = 0;
    for (final i in [...data.items]) {
      if (i.kind != MediaKind.photo || i.hdr != HdrFormat.none) continue;
      if (i.mimeType != 'image/jpeg') continue;
      BlobReader? r;
      try {
        r = await BlobReader.open(blobPath(i.blobId), masterKey);
        final head = await r.read(0, r.length < 262144 ? r.length : 262144);
        if (looksUltraHdr(head)) {
          i.hdr = HdrFormat.ultraHdr;
          found++;
        }
      } catch (_) {
        // unreadable file: leave as is
      } finally {
        await r?.close();
      }
    }
    return found;
  }

  /// Removes tags that were created automatically under the old, looser
  /// file-name rule but contain digits or underscores (e.g.
  /// "PXL_2026110612030045"). A tag is only removed if every item carrying
  /// it has that exact word in its file name, so tags made by hand are kept.
  /// Returns how many tags were removed.
  int removeInvalidAutoTags() {
    var removed = 0;
    for (final tag in [...data.tags]) {
      if (!isInvalidAutoTagName(tag.name)) continue;
      final lower = tag.name.toLowerCase();
      final holders = data.items.where((i) => i.tagIds.contains(tag.id));
      final allFromNames = holders.every((i) {
        var base = i.name;
        final dot = base.lastIndexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        return base
            .split(RegExp(r'\s+'))
            .any((w) => w.toLowerCase().contains(lower));
      });
      if (holders.isEmpty || !allFromNames) continue;
      deleteTag(tag.id);
      removed++;
    }
    return removed;
  }

  void deleteTag(String tagId) {
    data.tags.removeWhere((t) => t.id == tagId);
    for (final i in data.items) {
      i.tagIds.remove(tagId);
    }
  }

  /// Every file that belongs to the vault, relative to [directory].
  /// Used by backups.
  List<String> allFilesRelative() {
    final out = <String>[kIndexFileName];
    for (final i in data.items) {
      out.add(p.relative(blobPath(i.blobId), from: directory));
      if (i.thumbId != null) {
        out.add(p.relative(thumbPath(i.thumbId!), from: directory));
      }
    }
    return out;
  }
}
