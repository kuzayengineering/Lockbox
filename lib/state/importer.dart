// Adds files to the vault: detects type, reads metadata (dates, length,
// resolution, frame rate, HDR), makes a thumbnail, encrypts the file, tags it
// from its name and (optionally) deletes the unprotected original.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../core/crypto.dart';
import '../core/embedded_tags.dart';
import '../core/models.dart';
import '../core/mp4_probe.dart';
import '../core/ultra_hdr.dart';
import '../core/vault.dart';
import '../platform/native.dart';
import '../platform/player.dart';

const int kThumbSize = 512;

const _photoExt = {
  'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
  'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic',
  'heif': 'image/heif', 'bmp': 'image/bmp', 'avif': 'image/avif',
  'dng': 'image/x-adobe-dng',
};
const _videoExt = {
  'mp4': 'video/mp4', 'm4v': 'video/mp4', 'mov': 'video/quicktime',
  'mkv': 'video/x-matroska', 'webm': 'video/webm', '3gp': 'video/3gpp',
  'avi': 'video/x-msvideo', 'ts': 'video/mp2t', 'mts': 'video/mp2t',
  'm2ts': 'video/mp2t',
};
const _audioExt = {
  'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac',
  'wav': 'audio/wav', 'flac': 'audio/flac', 'ogg': 'audio/ogg',
  'opus': 'audio/opus', 'wma': 'audio/x-ms-wma', 'amr': 'audio/amr',
};

String _ext(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

const _fileExt = {
  'pdf': 'application/pdf', 'txt': 'text/plain', 'md': 'text/markdown',
  'csv': 'text/csv', 'json': 'application/json', 'xml': 'application/xml',
  'log': 'text/plain', 'html': 'text/html', 'htm': 'text/html',
  'rtf': 'application/rtf', 'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'odt': 'application/vnd.oasis.opendocument.text',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'zip': 'application/zip', '7z': 'application/x-7z-compressed',
  'rar': 'application/vnd.rar', 'gz': 'application/gzip', 'tar': 'application/x-tar',
  'apk': 'application/vnd.android.package-archive', 'epub': 'application/epub+zip',
  'dwg': 'image/vnd.dwg', 'dxf': 'image/vnd.dxf', 'kml': 'application/vnd.google-earth.kml+xml',
};

/// Works out the kind of file and its MIME type. Anything that isn't a
/// photo, video or audio file is stored as a general file.
(MediaKind, String) classify(String name, String? mime) {
  final e = _ext(name);
  if (_photoExt.containsKey(e)) return (MediaKind.photo, _photoExt[e]!);
  if (_videoExt.containsKey(e)) return (MediaKind.video, _videoExt[e]!);
  if (_audioExt.containsKey(e)) return (MediaKind.audio, _audioExt[e]!);
  if (_fileExt.containsKey(e)) return (MediaKind.file, _fileExt[e]!);
  if (mime != null && mime.isNotEmpty) {
    if (mime.startsWith('image/')) return (MediaKind.photo, mime);
    if (mime.startsWith('video/')) return (MediaKind.video, mime);
    if (mime.startsWith('audio/')) return (MediaKind.audio, mime);
    return (MediaKind.file, mime);
  }
  return (MediaKind.file, 'application/octet-stream');
}

class ImportResult {
  int added = 0;
  int originalsDeleted = 0;
  int originalsKept = 0;
  final failures = <String, String>{};
}

class Importer {
  Importer(this.vault);
  final Vault vault;
  bool _autoTag = true;

  Future<ImportResult> run(
    List<PickedFile> files, {
    required bool deleteOriginals,
    bool autoTag = true,
    String? folderId,
    void Function(int done, int total, String name)? onProgress,
  }) async {
    _autoTag = autoTag;
    final result = ImportResult();
    for (var n = 0; n < files.length; n++) {
      final f = files[n];
      onProgress?.call(n, files.length, f.name);
      try {
        final ok = await _importOne(f, folderId, deleteOriginals, result);
        if (ok) result.added++;
      } catch (e) {
        result.failures[f.name] = e.toString();
      }
      if (n % 10 == 9) await vault.save();
    }
    await vault.save();
    onProgress?.call(files.length, files.length, '');
    return result;
  }

  Future<bool> _importOne(PickedFile f, String? folderId, bool deleteOriginal,
      ImportResult result) async {
    final (kind, mime) = classify(f.name, f.mime);
    final opened = await Native.open(f);
    var closed = false;
    try {
      final size = await File(opened.path).length();
      final item = MediaItem(
        id: randomId(8),
        blobId: '', // set below
        name: f.name,
        kind: kind,
        mimeType: mime,
        sizeBytes: size,
        addedAt: DateTime.now(),
        folderId: folderId,
        originalLocation: f.originalLocation,
      );
      Uint8List? thumb;

      // ---- metadata
      final media = kind != MediaKind.file;
      if (kind == MediaKind.file) {
        item.createdAt = f.modified;
        if (mime == 'application/pdf') thumb = await pdfThumbnail(opened.path);
      }
      if (kind == MediaKind.video || kind == MediaKind.audio) {
        final info = await probeMp4(opened.path);
        if (info != null) {
          item
            ..durationMs = info.durationMs
            ..width = info.width
            ..height = info.height
            ..fps = info.fps
            ..hdr = info.hdr
            ..codec = info.videoCodec ?? info.audioCodec
            ..createdAt = info.createdAt;
        }
      }
      if (Native.isAndroid && media) {
        final m = await Native.probe(opened, kind.name, thumbSize: kThumbSize);
        if (m != null) {
          thumb = m['thumbnail'] as Uint8List?;
          item.durationMs ??= (m['durationMs'] as num?)?.toInt();
          if (item.width == null) {
            // Android reports the size before rotation.
            final rot = (m['rotation'] as num?)?.toInt() ?? 0;
            final w = (m['width'] as num?)?.toInt();
            final h = (m['height'] as num?)?.toInt();
            final turned = rot == 90 || rot == 270;
            item
              ..width = turned ? h : w
              ..height = turned ? w : h;
          }
          if (item.fps == null) {
            final frames = (m['frameCount'] as num?)?.toInt();
            final d = item.durationMs;
            if (frames != null && d != null && d > 0) {
              item.fps = (frames * 1000 / d * 100).round() / 100;
            }
          }
          if (item.hdr == HdrFormat.none) {
            final t = (m['colorTransfer'] as num?)?.toInt();
            if (t == 7) item.hdr = HdrFormat.hlg;
            if (t == 6) item.hdr = HdrFormat.hdr10;
          }
          item.createdAt ??= _parseAndroidDate(m['date'] as String?);
        }
      }
      if (kind == MediaKind.photo) {
        final bytes = await File(opened.path).readAsBytes();
        if (looksUltraHdr(bytes.length > 262144
            ? Uint8List.sublistView(bytes, 0, 262144)
            : bytes)) {
          item.hdr = HdrFormat.ultraHdr;
        }
        item.createdAt ??= await _exifDate(bytes);
        final dims = await imageSize(bytes);
        if (dims != null) {
          item
            ..width = dims.$1
            ..height = dims.$2;
        }
        thumb ??= await photoThumbnail(bytes);
      } else if (!Native.isAndroid && media) {
        try {
          final m = await mpvProbe(opened.path)
              .timeout(const Duration(seconds: 20));
          thumb ??= m.jpeg == null ? null : await _shrinkJpeg(m.jpeg!);
          item.durationMs ??= m.durationMs;
          item.width ??= m.width;
          item.height ??= m.height;
        } catch (_) {}
      }
      item.createdAt ??= f.modified;
      if (!Native.isAndroid && item.createdAt == null) {
        try {
          item.createdAt = await File(opened.path).lastModified();
        } catch (_) {}
      }

      // ---- encrypt
      final blobId = await vault.storeFile(opened.path);
      final stored = MediaItem.fromJson({...item.toJson(), 'blob': blobId});
      if (thumb != null) stored.thumbId = await vault.storeThumbnail(thumb);
      if (_autoTag) vault.autoTag(stored);
      // Tags kept in the file itself (e.g. written when it was restored).
      for (final t in await _embeddedTags(opened.path)) {
        stored.tagIds.add(vault.tagNamed(t).id);
      }
      vault.data.items.add(stored);

      // ---- original
      closed = true;
      final deleted = await Native.close(opened, deleteOriginal: deleteOriginal);
      if (deleteOriginal) {
        deleted ? result.originalsDeleted++ : result.originalsKept++;
      }
      return true;
    } finally {
      if (!closed) await Native.close(opened);
    }
  }
}


/// Keywords stored in the file's own metadata (XMP), if any.
Future<List<String>> _embeddedTags(String path) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    final file = f;
    final length = await file.length();
    return await readEmbeddedTags(length, (a, b) async {
      await file.setPosition(a);
      return file.read(b - a);
    });
  } catch (_) {
    return const [];
  } finally {
    await f?.close();
  }
}

DateTime? _parseAndroidDate(String? s) {
  // e.g. "20230704T120000.000Z"
  if (s == null || s.length < 15) return null;
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})').firstMatch(s);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (v[0] < 1971) return null;
  final utc = DateTime.utc(v[0], v[1], v[2], v[3], v[4], v[5]);
  return s.contains('Z') ? utc.toLocal() : DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

Future<DateTime?> _exifDate(Uint8List bytes) async {
  try {
    final head = bytes.length > 4 << 20 ? Uint8List.sublistView(bytes, 0, 4 << 20) : bytes;
    final tags = await readExifFromBytes(head);
    final raw = (tags['EXIF DateTimeOriginal'] ??
            tags['EXIF DateTimeDigitized'] ??
            tags['Image DateTime'])
        ?.printable;
    if (raw == null) return null;
    final m = RegExp(r'(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})').firstMatch(raw);
    if (m == null) return null;
    final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    if (v[0] < 1971) return null;
    return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  } catch (_) {
    return null;
  }
}

Future<(int, int)?> imageSize(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final d = await ui.ImageDescriptor.encoded(buffer);
    final r = (d.width, d.height);
    d.dispose();
    buffer.dispose();
    return r;
  } catch (_) {
    return null;
  }
}

/// Decodes with Flutter's image decoders, scales to [kThumbSize], encodes
/// as JPEG in the background.
Future<Uint8List?> photoThumbnail(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final d = await ui.ImageDescriptor.encoded(buffer);
    final scale = kThumbSize / (d.width > d.height ? d.width : d.height);
    final codec = await d.instantiateCodec(
      targetWidth: scale < 1 ? (d.width * scale).round() : null,
      targetHeight: scale < 1 ? (d.height * scale).round() : null,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = image.width, h = image.height;
    image.dispose();
    codec.dispose();
    d.dispose();
    buffer.dispose();
    if (rgba == null) return null;
    final raw = rgba.buffer.asUint8List();
    return await Isolate.run(() => Uint8List.fromList(img.encodeJpg(
        img.Image.fromBytes(
            width: w, height: h, bytes: raw.buffer, numChannels: 4),
        quality: 82)));
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _shrinkJpeg(Uint8List jpeg) => Isolate.run(() {
      final im = img.decodeImage(jpeg);
      if (im == null) return null;
      final big = im.width > im.height ? im.width : im.height;
      final out = big > kThumbSize
          ? img.copyResize(im,
              width: im.width >= im.height ? kThumbSize : null,
              height: im.height > im.width ? kThumbSize : null)
          : im;
      return Uint8List.fromList(img.encodeJpg(out, quality: 82));
    });

/// First page of a PDF as a JPEG thumbnail (null if it can't be read).
Future<Uint8List?> pdfThumbnail(String path) async {
  PdfDocument? doc;
  try {
    await pdfrxFlutterInitialize();
    doc = await PdfDocument.openFile(path);
    if (doc.pages.isEmpty) return null;
    final page = doc.pages.first;
    final scale = kThumbSize / (page.width > page.height ? page.width : page.height);
    final w = (page.width * scale).round(), h = (page.height * scale).round();
    final image = await page.render(
        fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xFFFFFFFF);
    if (image == null) return null;
    final px = Uint8List.fromList(image.pixels);
    final iw = image.width, ih = image.height;
    image.dispose();
    return await Isolate.run(() => Uint8List.fromList(img.encodeJpg(
        img.Image.fromBytes(
            width: iw, height: ih, bytes: px.buffer, numChannels: 4,
            order: img.ChannelOrder.bgra),
        quality: 82)));
  } catch (_) {
    return null;
  } finally {
    await doc?.dispose();
  }
}
