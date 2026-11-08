// Reads metadata from MP4 / MOV / M4A / 3GP files (ISO base media format)
// without any native code: duration, resolution, frame rate, codec,
// rotation, creation date and HDR transfer function (HLG / PQ / Dolby Vision).
//
// Only the `moov` box is read into memory; the (huge) media data is skipped.

import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

class Mp4Info {
  int? durationMs;
  int? width;
  int? height;
  int rotation = 0;
  double? fps;
  String? videoCodec;
  String? audioCodec;
  DateTime? createdAt;
  HdrFormat hdr = HdrFormat.none;
  bool hasVideo = false;
  bool hasAudio = false;

  @override
  String toString() =>
      'Mp4Info(dur=$durationMs, ${width}x$height rot=$rotation fps=$fps '
      'v=$videoCodec a=$audioCodec hdr=${hdr.name} created=$createdAt)';
}

const int _maxMoovBytes = 256 * 1024 * 1024;

/// Returns null if the file isn't an ISO media file or can't be parsed.
Future<Mp4Info?> probeMp4(String path) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    final length = await f.length();
    var pos = 0;
    Uint8List? moov;
    var sawFtyp = false;
    while (pos + 8 <= length) {
      await f.setPosition(pos);
      final h = await f.read(16);
      if (h.length < 8) break;
      final bd = ByteData.sublistView(h);
      var size = bd.getUint32(0);
      final type = String.fromCharCodes(h.sublist(4, 8));
      var headerLen = 8;
      if (size == 1) {
        if (h.length < 16) break;
        size = bd.getUint64(8);
        headerLen = 16;
      } else if (size == 0) {
        size = length - pos;
      }
      if (size < headerLen) break;
      if (type == 'ftyp') sawFtyp = true;
      if (pos == 0 && type != 'ftyp' && type != 'moov' && type != 'wide' &&
          type != 'mdat' && type != 'free' && type != 'skip') {
        return null; // not an ISO media file
      }
      if (type == 'moov') {
        if (size > _maxMoovBytes) return null;
        await f.setPosition(pos + headerLen);
        moov = await f.read(size - headerLen);
        break;
      }
      pos += size;
    }
    if (moov == null) return null;
    final info = Mp4Info();
    _parseMoov(moov, info);
    if (!sawFtyp && !info.hasVideo && !info.hasAudio) return null;
    return info;
  } catch (_) {
    return null;
  } finally {
    await f?.close();
  }
}

/// Parses an in-memory `moov` payload (exposed for tests).
Mp4Info parseMoovPayload(Uint8List moov) {
  final info = Mp4Info();
  _parseMoov(moov, info);
  return info;
}

class _Box {
  _Box(this.type, this.data);
  final String type;
  final Uint8List data; // payload, without the header
}

Iterable<_Box> _children(Uint8List buf, [int start = 0]) sync* {
  var pos = start;
  while (pos + 8 <= buf.length) {
    final bd = ByteData.sublistView(buf);
    var size = bd.getUint32(pos);
    final type = String.fromCharCodes(buf.sublist(pos + 4, pos + 8));
    var hl = 8;
    if (size == 1) {
      if (pos + 16 > buf.length) return;
      size = bd.getUint64(pos + 8);
      hl = 16;
    } else if (size == 0) {
      size = buf.length - pos;
    }
    if (size < hl || pos + size > buf.length) return;
    yield _Box(type, Uint8List.sublistView(buf, pos + hl, pos + size));
    pos += size;
  }
}

_Box? _find(Uint8List buf, String type, [int start = 0]) {
  for (final b in _children(buf, start)) {
    if (b.type == type) return b;
  }
  return null;
}

final DateTime _epoch1904 = DateTime.utc(1904, 1, 1);

void _parseMoov(Uint8List moov, Mp4Info info) {
  for (final box in _children(moov)) {
    if (box.type == 'mvhd') {
      _parseMvhd(box.data, info);
    } else if (box.type == 'trak') {
      _parseTrak(box.data, info);
    }
  }
}

void _parseMvhd(Uint8List d, Mp4Info info) {
  if (d.isEmpty) return;
  final bd = ByteData.sublistView(d);
  final v = d[0];
  int created, timescale, duration;
  if (v == 1) {
    if (d.length < 32) return;
    created = bd.getUint64(4);
    timescale = bd.getUint32(20);
    duration = bd.getUint64(24);
  } else {
    if (d.length < 20) return;
    created = bd.getUint32(4);
    timescale = bd.getUint32(12);
    duration = bd.getUint32(16);
  }
  // Seconds since 1904; ignore obviously-unset values (before 1971).
  if (created > 2082844800 + 31536000) {
    info.createdAt = _epoch1904.add(Duration(seconds: created)).toLocal();
  }
  if (timescale > 0 && duration > 0 && duration != 0xFFFFFFFF) {
    info.durationMs = (duration * 1000 / timescale).round();
  }
}

void _parseTrak(Uint8List trak, Mp4Info info) {
  int? tkW, tkH;
  var rotation = 0;
  final tkhd = _find(trak, 'tkhd');
  if (tkhd != null) {
    final d = tkhd.data;
    final bd = ByteData.sublistView(d);
    final matrixOff = d.isNotEmpty && d[0] == 1 ? 52 : 40;
    if (d.length >= matrixOff + 36 + 8) {
      final a = bd.getInt32(matrixOff);
      final b = bd.getInt32(matrixOff + 4);
      final c = bd.getInt32(matrixOff + 12);
      final dd = bd.getInt32(matrixOff + 16);
      const one = 0x10000;
      if (a == 0 && b == one && c == -one && dd == 0) rotation = 90;
      if (a == -one && b == 0 && c == 0 && dd == -one) rotation = 180;
      if (a == 0 && b == -one && c == one && dd == 0) rotation = 270;
      tkW = bd.getUint32(matrixOff + 36) >> 16;
      tkH = bd.getUint32(matrixOff + 40) >> 16;
    }
  }
  final mdia = _find(trak, 'mdia');
  if (mdia == null) return;
  String? handler;
  final hdlr = _find(mdia.data, 'hdlr');
  if (hdlr != null && hdlr.data.length >= 12) {
    handler = String.fromCharCodes(hdlr.data.sublist(8, 12));
  }
  int? mdTimescale, mdDuration;
  final mdhd = _find(mdia.data, 'mdhd');
  if (mdhd != null && mdhd.data.isNotEmpty) {
    final d = mdhd.data;
    final bd = ByteData.sublistView(d);
    if (d[0] == 1 && d.length >= 32) {
      mdTimescale = bd.getUint32(20);
      mdDuration = bd.getUint64(24);
    } else if (d.length >= 20) {
      mdTimescale = bd.getUint32(12);
      mdDuration = bd.getUint32(16);
    }
  }
  final stbl = _find(_find(mdia.data, 'minf')?.data ?? Uint8List(0), 'stbl');
  if (handler == 'vide') {
    if (info.hasVideo) return; // keep the first video track
    info.hasVideo = true;
    info.rotation = rotation;
    int? seW, seH;
    if (stbl != null) {
      final stsd = _find(stbl.data, 'stsd');
      if (stsd != null && stsd.data.length > 8) {
        // full box (4) + entry count (4), then sample entries
        for (final entry in _children(stsd.data, 8)) {
          info.videoCodec = entry.type;
          final e = entry.data;
          if (e.length >= 78) {
            final bd = ByteData.sublistView(e);
            seW = bd.getUint16(24);
            seH = bd.getUint16(26);
            _parseVisualChildren(entry.type, Uint8List.sublistView(e, 78), info);
          }
          break;
        }
      }
      final stts = _find(stbl.data, 'stts');
      if (stts != null && mdTimescale != null && mdTimescale > 0) {
        final d = stts.data;
        final bd = ByteData.sublistView(d);
        if (d.length >= 8) {
          final n = bd.getUint32(4);
          var frames = 0;
          var ticks = 0;
          for (var i = 0; i < n && 8 + i * 8 + 8 <= d.length; i++) {
            final count = bd.getUint32(8 + i * 8);
            final delta = bd.getUint32(12 + i * 8);
            frames += count;
            ticks += count * delta;
          }
          if (frames > 1 && ticks > 0) {
            final fps = frames * mdTimescale / ticks;
            info.fps = (fps * 100).round() / 100;
          }
        }
      }
    }
    var w = seW ?? tkW;
    var h = seH ?? tkH;
    if (w != null && h != null && (rotation == 90 || rotation == 270)) {
      final t = w;
      w = h;
      h = t;
    }
    info.width = w;
    info.height = h;
    if (info.durationMs == null &&
        mdTimescale != null &&
        mdTimescale > 0 &&
        mdDuration != null) {
      info.durationMs = (mdDuration * 1000 / mdTimescale).round();
    }
  } else if (handler == 'soun') {
    info.hasAudio = true;
    if (stbl != null) {
      final stsd = _find(stbl.data, 'stsd');
      if (stsd != null && stsd.data.length > 8) {
        for (final entry in _children(stsd.data, 8)) {
          info.audioCodec ??= entry.type;
          break;
        }
      }
    }
    if (info.durationMs == null &&
        mdTimescale != null &&
        mdTimescale > 0 &&
        mdDuration != null) {
      info.durationMs = (mdDuration * 1000 / mdTimescale).round();
    }
  }
}

void _parseVisualChildren(String codec, Uint8List d, Mp4Info info) {
  if (codec == 'dvh1' || codec == 'dvhe' || codec == 'dva1' ||
      codec == 'dvav') {
    info.hdr = HdrFormat.dolbyVision;
  }
  for (final b in _children(d)) {
    if (b.type == 'dvcC' || b.type == 'dvvC' || b.type == 'dvwC') {
      info.hdr = HdrFormat.dolbyVision;
    } else if (b.type == 'colr' && b.data.length >= 10) {
      final kind = String.fromCharCodes(b.data.sublist(0, 4));
      if (kind == 'nclx' || kind == 'nclc') {
        final transfer = ByteData.sublistView(b.data).getUint16(6);
        if (info.hdr != HdrFormat.dolbyVision) {
          if (transfer == 18) info.hdr = HdrFormat.hlg;
          if (transfer == 16) info.hdr = HdrFormat.hdr10;
        }
      }
    }
  }
}
