// Single-file backups.
//
// A backup (.lockbox file) is simply every file of the vault folder packed
// end to end. Everything inside is already encrypted, so the backup file is
// exactly as safe as the vault: it can only be opened with the Lockbox app
// and the passphrase.
//
// Layout:
//   "LBXP" (4) | version (1) | reserved (3)
//   repeated:  path length u16 LE | path (UTF-8) | size u64 LE | file bytes
//   end marker: path length 0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'vault.dart';

const List<int> kPackMagic = [0x4C, 0x42, 0x58, 0x50]; // "LBXP"
const String kBackupExtension = 'lockbox';

class BackupFormatException implements Exception {
  BackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'Not a valid Lockbox backup: $message';
}

final RegExp _allowedPath =
    RegExp(r'^(index\.lbx|(blobs|thumbs)/[0-9a-f]{2}/[0-9a-f]{32})$');

/// Writes a backup of the vault at [vaultDir] containing [relativePaths]
/// to [destPath]. [onProgress] receives (bytesDone, bytesTotal).
Future<void> writeBackup({
  required String vaultDir,
  required List<String> relativePaths,
  required String destPath,
  void Function(int done, int total)? onProgress,

  /// false = write straight into [destPath] (needed for Android
  /// "/proc/self/fd" destinations, which can't be renamed).
  bool atomic = true,
}) async {
  final files = <String, File>{};
  var total = 0;
  for (final rel in relativePaths) {
    final norm = rel.replaceAll(r'\', '/');
    final f = File(p.join(vaultDir, rel));
    if (!f.existsSync()) continue;
    files[norm] = f;
    total += f.lengthSync();
  }
  final tmp = atomic ? '$destPath.part' : destPath;
  final sink = File(tmp).openWrite();
  var done = 0;
  try {
    sink.add([...kPackMagic, 1, 0, 0, 0]);
    for (final e in files.entries) {
      final name = utf8.encode(e.key);
      final size = await e.value.length();
      final h = Uint8List(2 + name.length + 8);
      final bd = ByteData.sublistView(h);
      bd.setUint16(0, name.length, Endian.little);
      h.setRange(2, 2 + name.length, name);
      bd.setUint64(2 + name.length, size, Endian.little);
      sink.add(h);
      var written = 0;
      await for (final chunk in e.value.openRead()) {
        sink.add(chunk);
        written += chunk.length;
        done += chunk.length;
        onProgress?.call(done, total);
      }
      if (written != size) {
        throw StateError('${e.key} changed while backing up');
      }
    }
    sink.add([0, 0]);
    await sink.flush();
  } catch (_) {
    await sink.close();
    if (atomic) {
      try {
        await File(tmp).delete();
      } catch (_) {}
    }
    rethrow;
  }
  await sink.close();
  if (!atomic) return;
  final dest = File(destPath);
  if (dest.existsSync()) await dest.delete();
  await File(tmp).rename(destPath);
}

/// Unpacks a backup into [destDir], which must be empty or not exist.
/// Returns the number of files restored.
Future<int> restoreBackup({
  required String backupPath,
  required String destDir,
  void Function(int done, int total)? onProgress,
}) async {
  final dir = Directory(destDir);
  if (dir.existsSync() && dir.listSync().isNotEmpty) {
    throw StateError('Destination folder is not empty');
  }
  await dir.create(recursive: true);
  final f = await File(backupPath).open();
  final total = await f.length();
  var count = 0;
  try {
    final head = await f.read(8);
    if (head.length != 8 ||
        head[0] != kPackMagic[0] ||
        head[1] != kPackMagic[1] ||
        head[2] != kPackMagic[2] ||
        head[3] != kPackMagic[3]) {
      throw BackupFormatException('wrong file type');
    }
    if (head[4] != 1) throw BackupFormatException('unsupported version');
    var sawIndex = false;
    while (true) {
      final lenBytes = await f.read(2);
      if (lenBytes.length != 2) throw BackupFormatException('truncated');
      final nameLen = ByteData.sublistView(lenBytes).getUint16(0, Endian.little);
      if (nameLen == 0) break;
      final name = utf8.decode(await f.read(nameLen));
      if (!_allowedPath.hasMatch(name)) {
        throw BackupFormatException('unexpected entry "$name"');
      }
      final sizeBytes = await f.read(8);
      if (sizeBytes.length != 8) throw BackupFormatException('truncated');
      final size = ByteData.sublistView(sizeBytes).getUint64(0, Endian.little);
      final out = File(p.joinAll([destDir, ...name.split('/')]));
      await out.parent.create(recursive: true);
      final w = await out.open(mode: FileMode.write);
      var left = size;
      while (left > 0) {
        final chunk = await f.read(left > 1 << 20 ? 1 << 20 : left);
        if (chunk.isEmpty) {
          await w.close();
          throw BackupFormatException('truncated');
        }
        await w.writeFrom(chunk);
        left -= chunk.length;
        onProgress?.call(await f.position(), total);
      }
      await w.close();
      if (name == 'index.lbx') sawIndex = true;
      count++;
    }
    if (!sawIndex) throw BackupFormatException('no index inside');
  } finally {
    await f.close();
  }
  if (!Vault.existsAt(destDir)) {
    throw BackupFormatException('restored data is incomplete');
  }
  return count;
}
