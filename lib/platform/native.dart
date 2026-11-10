// Everything that differs between Android and Windows (file pickers,
// thumbnails from the OS, saving files, screenshot blocking).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A file the user picked to import.
class PickedFile {
  PickedFile(
      {required this.name,
      this.size,
      this.mime,
      this.uri,
      this.path,
      this.originalLocation,
      this.modified});
  final String name;
  final int? size;
  final String? mime;

  /// Android content:// address.
  final String? uri;

  /// Windows file path.
  final String? path;

  /// Folder the file came from (see MediaItem.originalLocation).
  final String? originalLocation;

  /// When the file was last changed (used as its date for documents).
  final DateTime? modified;
}

/// A picked file opened for reading.
class OpenedFile {
  OpenedFile(this.path, {this.handle});
  final String path;
  final int? handle; // Android only
}

class Native {
  static const _ch = MethodChannel('lockbox/native');
  static bool get isAndroid => Platform.isAndroid;

  static const _hdr = MethodChannel('lockbox/hdr');
  static Future<int>? _sdk;
  static Future<bool>? _hdrDisplay;

  /// Android version number (API level); 0 on Windows.
  static Future<int> androidSdk() => _sdk ??= isAndroid
      ? _hdr.invokeMethod<int>('sdk').then((v) => v ?? 0, onError: (_) => 0)
      : Future.value(0);

  /// True if this phone can show Ultra HDR photos in HDR.
  static Future<bool> hdrPhotoDisplay() {
    if (isAndroid) {
      _hdr.setMethodCallHandler((call) async {
        hdrListener?.call(call.method, call.arguments);
      });
    }
    return _hdrDisplay ??= isAndroid
        ? _hdr
            .invokeMethod<bool>('capable')
            .then((v) => v ?? false, onError: (_) => false)
        : Future.value(false);
  }

  /// Receives "zoomed" (bool) and "tap" from the native HDR photo view.
  static void Function(String method, Object? args)? hdrListener;

  /// Double-tap zoom on the native HDR photo view (physical pixels).
  static Future<void> hdrZoomAt(double x, double y) =>
      _hdr.invokeMethod('zoomAt', {'x': x, 'y': y});

  static DateTime? _modified(String path) {
    try {
      return File(path).lastModifiedSync();
    } catch (_) {
      return null;
    }
  }

  static Future<List<PickedFile>> pickMedia() async {
    if (isAndroid) {
      final list = await _ch.invokeListMethod<Map>('pickMedia') ?? const [];
      return [
        for (final m in list)
          PickedFile(
            name: m['name'] as String,
            size: (m['size'] as num?)?.toInt(),
            mime: m['mime'] as String?,
            uri: m['uri'] as String,
            originalLocation: m['relativePath'] as String?,
            modified: m['modified'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch((m['modified'] as num).toInt()),
          )
      ];
    }
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Add to Lockbox',
      type: FileType.any,
    );
    return [
      for (final f in files)
        if (f.path != null)
          PickedFile(
              name: f.name,
              size: f.lengthSync(),
              path: f.path,
              originalLocation: p.dirname(f.path!),
              modified: _modified(f.path!)),
    ];
  }

  /// Picks any single file (used to restore backups).
  static Future<PickedFile?> pickFile() async {
    if (isAndroid) {
      final m = await _ch.invokeMapMethod<String, dynamic>('pickFile');
      if (m == null) return null;
      return PickedFile(
          name: m['name'] as String,
          size: (m['size'] as num?)?.toInt(),
          uri: m['uri'] as String);
    }
    final f = await FilePicker.pickFile(
      dialogTitle: 'Choose a Lockbox backup',
      type: FileType.custom,
      allowedExtensions: const ['lockbox'],
    );
    if (f?.path == null) return null;
    return PickedFile(name: f!.name, size: f.lengthSync(), path: f.path);
  }

  static Future<OpenedFile> open(PickedFile f) async {
    if (f.path != null) return OpenedFile(f.path!);
    final m = await _ch.invokeMapMethod<String, dynamic>(
        'openImport', {'uri': f.uri});
    return OpenedFile(m!['path'] as String, handle: m['handle'] as int);
  }

  /// Closes an opened file. If [deleteOriginal] is true, tries to delete
  /// the user's original copy. Returns true if the original was deleted.
  static Future<bool> close(OpenedFile f, {bool deleteOriginal = false}) async {
    if (f.handle != null) {
      return await _ch.invokeMethod<bool>('closeImport',
              {'handle': f.handle, 'deleteOriginal': deleteOriginal}) ??
          false;
    }
    if (deleteOriginal) {
      try {
        await File(f.path).delete();
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// Android only: metadata + thumbnail made by the phone's own decoders.
  static Future<Map<String, dynamic>?> probe(OpenedFile f, String kind,
      {int thumbSize = 512}) async {
    if (f.handle == null) return null;
    return _ch.invokeMapMethod<String, dynamic>(
        'probe', {'handle': f.handle, 'kind': kind, 'thumbSize': thumbSize});
  }

  /// Android only: convert image bytes to JPEG (for formats Flutter can't
  /// show directly, e.g. some HEIC files).
  static Future<Uint8List?> toJpeg(Uint8List bytes, {int maxSide = 4096}) async {
    if (!isAndroid) return null;
    return _ch.invokeMethod<Uint8List>(
        'toJpeg', {'bytes': bytes, 'maxSide': maxSide});
  }

  /// Lets the user choose a folder for exports. Returns an opaque handle.
  /// [persist] keeps access after the app restarts (default restore folder).
  static Future<String?> pickFolder({String? title, bool persist = false}) async {
    if (isAndroid) {
      return _ch.invokeMethod<String>('pickFolder', {'persist': persist});
    }
    return FilePicker.getDirectoryPath(dialogTitle: title);
  }

  /// Copies [src] into a folder from [pickFolder] under [name].
  static Future<void> writeToFolder(
      String folder, String src, String name, String mime) async {
    if (isAndroid) {
      await _ch.invokeMethod('writeToFolder',
          {'tree': folder, 'src': src, 'name': name, 'mime': mime});
      return;
    }
    await File(src).copy(_uniquePath(folder, name));
  }

  /// "Save as" for a single file. On Windows the user picks a folder.
  /// Returns false if cancelled.
  static Future<bool> saveAs(String src, String name, String mime) async {
    if (isAndroid) {
      return await _ch.invokeMethod<bool>(
              'saveAs', {'src': src, 'name': name, 'mime': mime}) ??
          false;
    }
    final dir =
        await FilePicker.getDirectoryPath(dialogTitle: 'Save backup to…');
    if (dir == null) return false;
    await File(src).copy(_uniquePath(dir, name));
    return true;
  }

  /// Asks where to save a new file and returns a path Dart can write to
  /// directly. Close it with [close]. Null if cancelled.
  /// On Windows the user picks a folder.
  static Future<OpenedFile?> createForWrite(String name, String mime) async {
    if (isAndroid) {
      final m = await _ch.invokeMapMethod<String, dynamic>(
          'createForWrite', {'name': name, 'mime': mime});
      if (m == null) return null;
      return OpenedFile(m['path'] as String, handle: m['handle'] as int);
    }
    final dir =
        await FilePicker.getDirectoryPath(dialogTitle: 'Save backup to…');
    if (dir == null) return null;
    return OpenedFile(_uniquePath(dir, name));
  }

  /// Human-readable name for a folder handle from [pickFolder].
  static String folderLabel(String folder) {
    if (!isAndroid) return folder;
    // content://.../tree/primary%3APictures%2FRestored -> Pictures/Restored
    final decoded = Uri.decodeComponent(folder);
    final i = decoded.lastIndexOf(':');
    final rel = i >= 0 ? decoded.substring(i + 1) : decoded;
    return rel.isEmpty ? 'Phone storage' : rel;
  }

  /// Android: writes a vault file back to shared storage, decrypting it on
  /// the fly ([blobPath] + per-file [key]) so no decrypted temp copy exists.
  ///
  /// * [folder] set: into that folder (a [pickFolder] handle).
  /// * otherwise: through the system media store into [relativePath]
  ///   (e.g. "DCIM/Camera/") so it shows up in Gallery apps again.
  ///
  /// Returns a description of where the file went.
  static Future<String> restoreFromVaultAndroid({
    required String blobPath,
    required Uint8List key,
    required String name,
    required String mime,
    required String kind,
    String? relativePath,
    String? folder,
  }) async {
    if (folder != null) {
      await _ch.invokeMethod('writeToFolder', {
        'tree': folder, 'blob': blobPath, 'key': key, 'name': name, 'mime': mime,
      });
      return folderLabel(folder);
    }
    final used = await _ch.invokeMethod<String>('restoreToMediaStore', {
      'blob': blobPath,
      'key': key,
      'name': name,
      'mime': mime,
      'kind': kind,
      'relativePath': relativePath ?? defaultRelativePath(kind),
    });
    return used ?? relativePath ?? '';
  }

  /// Windows: a free file name in [dir] for [name].
  static String uniquePath(String dir, String name) => _uniquePath(dir, name);

  /// Android default restore folders when none is chosen in Settings.
  static String defaultRelativePath(String kind) => switch (kind) {
        'photo' => 'Pictures/Lockbox/',
        'video' => 'Movies/Lockbox/',
        'audio' => 'Music/Lockbox/',
        'file' => 'Documents/Lockbox/',
        _ => 'Download/Lockbox/',
      };

  static String _uniquePath(String dir, String name) {
    var path = p.join(dir, name);
    var n = 1;
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    while (File(path).existsSync()) {
      path = p.join(dir, '$base ($n)$ext');
      n++;
    }
    return path;
  }
}
