// Tags stored inside a file's own metadata, so they survive a trip out of
// Lockbox (Restore) and back in (Add).
//
// Tags are written as standard XMP keywords (dc:subject), the same place
// Windows Explorer, Lightroom and digiKam keep keywords:
//
//  * JPEG: an XMP "APP1" segment near the start of the file. An existing XMP
//    segment is updated (its other contents are kept); otherwise a new one is
//    inserted right after the Exif segment. Nothing after it moves relative
//    to the MPF/Ultra HDR data, so gain maps keep working.
//  * MP4 / MOV / M4A / HEIC (ISO media files): an XMP "uuid" box appended at
//    the very end of the file. Appending never moves the video data, so the
//    file plays exactly as before. An earlier XMP box at the end is replaced;
//    one elsewhere is blanked out (renamed to "free", same size).
//
// Other file types are left unchanged.
//
// The planner only reads the parts of the file it needs (through [ReadAt]),
// so it works on encrypted vault files without decrypting them whole, and on
// huge videos.

import 'dart:convert';
import 'dart:typed_data';

/// Reads bytes [start, end) of a file.
typedef ReadAt = Future<Uint8List> Function(int start, int end);

/// One edit to a file: bytes [start, end) are replaced by [bytes].
/// start == end inserts.
class FilePatch {
  FilePatch(this.start, this.end, this.bytes);
  final int start;
  final int end;
  final Uint8List bytes;

  Map<String, Object> toMap() => {'start': start, 'end': end, 'bytes': bytes};

  @override
  String toString() => 'FilePatch($start-$end, ${bytes.length} bytes)';
}

/// Applies [patches] (sorted, not overlapping) to a byte stream.
/// [slice] gives the original bytes [start, end) (end null = to the end).
Stream<List<int>> patchedStream(
    List<FilePatch> patches, Stream<List<int>> Function(int start, int? end) slice) async* {
  var pos = 0;
  for (final p in patches) {
    if (p.start > pos) yield* slice(pos, p.start);
    yield p.bytes;
    pos = p.end;
  }
  yield* slice(pos, null);
}

/// Applies patches to bytes in memory (tests, small files).
Uint8List applyPatches(Uint8List data, List<FilePatch> patches) {
  final out = BytesBuilder(copy: false);
  var pos = 0;
  for (final p in patches) {
    out.add(Uint8List.sublistView(data, pos, p.start));
    out.add(p.bytes);
    pos = p.end;
  }
  out.add(Uint8List.sublistView(data, pos));
  return out.takeBytes();
}

enum _Format { jpeg, isoMedia, other }

Future<_Format> _detect(int length, ReadAt read) async {
  if (length < 12) return _Format.other;
  final h = await read(0, 12);
  if (h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF) return _Format.jpeg;
  final type = String.fromCharCodes(h.sublist(4, 8));
  if (const {'ftyp', 'moov', 'mdat', 'wide', 'free', 'skip'}.contains(type)) {
    return _Format.isoMedia;
  }
  return _Format.other;
}

/// Tags kept in the file's metadata (empty if none or unsupported).
Future<List<String>> readEmbeddedTags(int length, ReadAt read) async {
  try {
    final xmp = switch (await _detect(length, read)) {
      _Format.jpeg => (await _jpegXmp(length, read))?.packet,
      _Format.isoMedia => await _isoXmpForReading(length, read),
      _Format.other => null,
    };
    return xmp == null ? const [] : subjectsFromXmp(xmp);
  } catch (_) {
    return const [];
  }
}

/// The edits that store [tags] in the file. Empty list: nothing to change.
/// Null: this kind of file can't hold tags (or not safely), leave it alone.
Future<List<FilePatch>?> planTagPatches(int length, ReadAt read, List<String> tags) async {
  try {
    return switch (await _detect(length, read)) {
      _Format.jpeg => await _jpegPlan(length, read, tags),
      _Format.isoMedia => await _isoPlan(length, read, tags),
      _Format.other => null,
    };
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------------- XMP

const _xmpNs = 'http://ns.adobe.com/xap/1.0/\u0000';

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _unesc(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

final _subjectRe = RegExp(r'<dc:subject\s*/>|<dc:subject\b[^>]*>.*?</dc:subject>', dotAll: true);
final _liRe = RegExp(r'<rdf:li\b[^>]*>(.*?)</rdf:li>', dotAll: true);

/// Keywords (dc:subject) in an XMP packet.
List<String> subjectsFromXmp(String xmp) {
  final out = <String>[];
  for (final m in _subjectRe.allMatches(xmp)) {
    for (final li in _liRe.allMatches(m.group(0)!)) {
      final t = _unesc(li.group(1)!.trim());
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
  }
  return out;
}

String _subjectDescription(List<String> tags) =>
    '<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:subject><rdf:Bag>'
    '${tags.map((t) => '<rdf:li>${_esc(t)}</rdf:li>').join()}'
    '</rdf:Bag></dc:subject></rdf:Description>';

/// [existing] XMP with its keywords replaced by [tags] (or a new packet).
/// Null if [existing] can't be understood.
String? xmpWithSubjects(String? existing, List<String> tags) {
  if (existing == null) {
    return '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        '${_subjectDescription(tags)}'
        '</rdf:RDF></x:xmpmeta>'
        '<?xpacket end="w"?>';
  }
  final end = existing.lastIndexOf('</rdf:RDF>');
  if (end < 0) return null;
  var head = existing.substring(0, end).replaceAll(_subjectRe, '');
  final tail = existing.substring(end).replaceAll(_subjectRe, '');
  // Drop a description we wrote before that is now empty.
  head = head.replaceAll(
      '<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '</rdf:Description>',
      '');
  return head + (tags.isEmpty ? '' : _subjectDescription(tags)) + tail;
}

bool _sameTags(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b);

// ------------------------------------------------------------------- JPEG

class _JpegXmp {
  _JpegXmp(this.start, this.end, this.packet, this.mpfBefore);
  final int start, end; // whole segment, marker included
  final String packet;
  final bool mpfBefore;
}

/// Walks the JPEG header segments. Returns the XMP segment, if any, and
/// sets [insertAt] (via the callback) to just after the leading APP0/Exif
/// segments.
Future<_JpegXmp?> _jpegXmp(int length, ReadAt read, {void Function(int)? insertAt}) async {
  var pos = 2;
  var leading = true;
  var mpf = false;
  insertAt?.call(pos);
  for (var guard = 0; guard < 200 && pos + 4 <= length; guard++) {
    final h = await read(pos, pos + 4);
    if (h[0] != 0xFF) return null;
    final marker = h[1];
    // Only the APPn / COM segments before the image data matter.
    if (!((marker >= 0xE0 && marker <= 0xEF) || marker == 0xFE)) return null;
    final segLen = (h[2] << 8) | h[3];
    final end = pos + 2 + segLen;
    if (segLen < 2 || end > length) return null;
    final idLen = segLen - 2 < 29 ? segLen - 2 : 29;
    final id = await read(pos + 4, pos + 4 + idLen);
    final idText = latin1.decode(id, allowInvalid: true);
    if (marker == 0xE1 && idText == _xmpNs) {
      final body = await read(pos + 4 + 29, end);
      return _JpegXmp(pos, end, utf8.decode(body, allowMalformed: true), mpf);
    }
    if (marker == 0xE2 && idText.startsWith('MPF\u0000')) mpf = true;
    final isExif = marker == 0xE1 && idText.startsWith('Exif\u0000');
    if (leading && (marker == 0xE0 || isExif)) {
      insertAt?.call(end);
    } else {
      leading = false;
    }
    pos = end;
  }
  return null;
}

Future<List<FilePatch>?> _jpegPlan(int length, ReadAt read, List<String> tags) async {
  var insertAt = 2;
  final old = await _jpegXmp(length, read, insertAt: (p) => insertAt = p);
  final oldTags = old == null ? const <String>[] : subjectsFromXmp(old.packet);
  if (_sameTags(oldTags, tags)) return const [];
  final packet = xmpWithSubjects(old?.packet, tags);
  if (packet == null) return null;
  final body = utf8.encode(packet);
  final segLen = 2 + 29 + body.length;
  if (segLen > 0xFFFF) return null;
  final seg = BytesBuilder()
    ..add([0xFF, 0xE1, segLen >> 8, segLen & 0xFF])
    ..add(latin1.encode(_xmpNs))
    ..add(body);
  final bytes = seg.takeBytes();
  if (old == null) return [FilePatch(insertAt, insertAt, bytes)];
  // Changing the size of a segment that sits after the MPF table would move
  // the gain map / extra images away from where the table says they are.
  if (old.mpfBefore && bytes.length != old.end - old.start) return null;
  return [FilePatch(old.start, old.end, bytes)];
}

// -------------------------------------------------------------- ISO media

/// Adobe's XMP box id for MP4/MOV/HEIC.
const _xmpUuid = [
  0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, //
  0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
];

class _Box {
  _Box(this.start, this.end, this.type, this.headerLen, this.toEnd);
  final int start, end, headerLen;
  final String type;
  final bool toEnd; // size 0: "runs to the end of the file"
}

Future<List<_Box>?> _boxes(int from, int to, ReadAt read) async {
  final out = <_Box>[];
  var pos = from;
  while (pos + 8 <= to) {
    if (out.length > 20000) return null;
    final h = await read(pos, pos + 8 + 8 > to ? pos + 8 : pos + 16);
    final bd = ByteData.sublistView(h);
    var size = bd.getUint32(0);
    final type = latin1.decode(h.sublist(4, 8), allowInvalid: true);
    var header = 8;
    var toEnd = false;
    if (size == 1) {
      if (h.length < 16) return null;
      size = bd.getUint64(8);
      header = 16;
    } else if (size == 0) {
      size = to - pos;
      toEnd = true;
    }
    if (size < header || pos + size > to) return null;
    out.add(_Box(pos, pos + size, type, header, toEnd));
    pos += size;
  }
  return out;
}

Future<bool> _isXmpUuid(_Box b, ReadAt read) async {
  if (b.type != 'uuid' || b.end - b.start < b.headerLen + 16) return false;
  final id = await read(b.start + b.headerLen, b.start + b.headerLen + 16);
  for (var i = 0; i < 16; i++) {
    if (id[i] != _xmpUuid[i]) return false;
  }
  return true;
}

Future<String> _uuidPayload(_Box b, ReadAt read) async => utf8.decode(
    await read(b.start + b.headerLen + 16, b.end),
    allowMalformed: true);

Future<String?> _isoXmpForReading(int length, ReadAt read) async {
  final top = await _boxes(0, length, read);
  if (top == null) return null;
  for (final b in top.reversed) {
    if (await _isXmpUuid(b, read)) return _uuidPayload(b, read);
  }
  // QuickTime / some cameras: moov › udta › XMP_
  for (final moov in top.where((b) => b.type == 'moov')) {
    final kids = await _boxes(moov.start + moov.headerLen, moov.end, read);
    for (final udta in kids?.where((b) => b.type == 'udta') ?? const <_Box>[]) {
      final inner = await _boxes(udta.start + udta.headerLen, udta.end, read);
      for (final x in inner?.where((b) => b.type == 'XMP_') ?? const <_Box>[]) {
        return utf8.decode(await read(x.start + x.headerLen, x.end), allowMalformed: true);
      }
    }
  }
  return null;
}

Future<List<FilePatch>?> _isoPlan(int length, ReadAt read, List<String> tags) async {
  final top = await _boxes(0, length, read);
  if (top == null || top.isEmpty) return null;
  // A last box with no size runs to the end of the file: anything appended
  // would become part of it.
  if (top.last.toEnd) return null;
  final xmpBoxes = <_Box>[];
  for (final b in top) {
    if (await _isXmpUuid(b, read)) xmpBoxes.add(b);
  }
  final oldPacket = xmpBoxes.isEmpty ? null : await _uuidPayload(xmpBoxes.last, read);
  final oldTags = oldPacket == null ? const <String>[] : subjectsFromXmp(oldPacket);
  if (_sameTags(oldTags, tags)) return const [];
  final packet = xmpWithSubjects(oldPacket, tags);
  if (packet == null) return null;
  final body = utf8.encode(packet);
  final size = 8 + 16 + body.length;
  final box = BytesBuilder()
    ..add([size >> 24 & 0xFF, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF])
    ..add(latin1.encode('uuid'))
    ..add(_xmpUuid)
    ..add(body);
  final newBox = box.takeBytes();
  final patches = <FilePatch>[];
  var appendAt = length;
  for (final b in xmpBoxes) {
    if (b.end == length) {
      appendAt = b.start; // replace the old box at the end
    } else {
      patches.add(FilePatch(b.start + 4, b.start + 8, Uint8List.fromList(latin1.encode('free'))));
    }
  }
  patches.add(FilePatch(appendAt, length, newBox));
  return patches;
}
