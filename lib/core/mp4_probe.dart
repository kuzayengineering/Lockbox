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
  int? vuiTransfer;
  for (final b in _children(d)) {
    if (b.type == 'hvcC') {
      vuiTransfer ??= hevcTransferFromHvcc(b.data);
    } else if (b.type == 'vpcC' && b.data.length >= 9) {
      // version+flags(4) profile level bitdepth/chroma primaries TRANSFER
      vuiTransfer ??= b.data[7];
    } else if (b.type == 'dvcC' || b.type == 'dvvC' || b.type == 'dvwC') {
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
  // Container didn't say; use what the video stream itself signals.
  if (info.hdr == HdrFormat.none) {
    if (vuiTransfer == 18) info.hdr = HdrFormat.hlg;
    if (vuiTransfer == 16) info.hdr = HdrFormat.hdr10;
  }
}

// ------------------------------------------------- HEVC SPS colour info

/// Reads transfer_characteristics (16 = PQ/HDR10, 18 = HLG) from the
/// sequence parameter set stored in an `hvcC` box. Null if absent.
int? hevcTransferFromHvcc(Uint8List d) {
  try {
    if (d.length < 23) return null;
    var pos = 22;
    final arrays = d[pos++];
    for (var a = 0; a < arrays; a++) {
      final type = d[pos] & 0x3F;
      final n = (d[pos + 1] << 8) | d[pos + 2];
      pos += 3;
      for (var k = 0; k < n; k++) {
        final len = (d[pos] << 8) | d[pos + 1];
        pos += 2;
        if (type == 33 && len > 2) {
          return _spsTransfer(_unescape(Uint8List.sublistView(d, pos + 2, pos + len)));
        }
        pos += len;
      }
    }
  } catch (_) {}
  return null;
}

/// Removes emulation-prevention bytes (00 00 03 -> 00 00).
Uint8List _unescape(Uint8List b) {
  final out = BytesBuilder(copy: false);
  var zeros = 0;
  for (final x in b) {
    if (zeros >= 2 && x == 3) {
      zeros = 0;
      continue;
    }
    out.addByte(x);
    zeros = x == 0 ? zeros + 1 : 0;
  }
  return out.takeBytes();
}

class _Bits {
  _Bits(this.b);
  final Uint8List b;
  int p = 0;
  int bit() {
    final v = (b[p >> 3] >> (7 - (p & 7))) & 1;
    p++;
    return v;
  }

  int bits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | bit();
    }
    return v;
  }

  void skip(int n) => p += n;

  int ue() {
    var zeros = 0;
    while (bit() == 0) {
      if (++zeros > 31) throw const FormatException('bad exp-golomb');
    }
    return (1 << zeros) - 1 + bits(zeros);
  }

  int se() {
    final k = ue();
    return k.isOdd ? (k + 1) >> 1 : -(k >> 1);
  }
}

int? _spsTransfer(Uint8List sps) {
  final r = _Bits(sps);
  r.skip(4); // sps_video_parameter_set_id
  final maxSubLayersMinus1 = r.bits(3);
  r.skip(1);
  // profile_tier_level
  r.skip(96);
  final subProfile = <bool>[], subLevel = <bool>[];
  for (var i = 0; i < maxSubLayersMinus1; i++) {
    subProfile.add(r.bit() == 1);
    subLevel.add(r.bit() == 1);
  }
  if (maxSubLayersMinus1 > 0) {
    for (var i = maxSubLayersMinus1; i < 8; i++) {
      r.skip(2);
    }
  }
  for (var i = 0; i < maxSubLayersMinus1; i++) {
    if (subProfile[i]) r.skip(88);
    if (subLevel[i]) r.skip(8);
  }
  r.ue(); // sps_seq_parameter_set_id
  final chroma = r.ue();
  if (chroma == 3) r.skip(1);
  r.ue(); // width
  r.ue(); // height
  if (r.bit() == 1) {
    r.ue();
    r.ue();
    r.ue();
    r.ue();
  }
  r.ue(); // bit_depth_luma
  r.ue(); // bit_depth_chroma
  final log2MaxPocLsb = r.ue() + 4;
  final subLayerOrdering = r.bit() == 1;
  for (var i = subLayerOrdering ? 0 : maxSubLayersMinus1; i <= maxSubLayersMinus1; i++) {
    r.ue();
    r.ue();
    r.ue();
  }
  for (var i = 0; i < 6; i++) {
    r.ue(); // block / transform sizes, hierarchy depths
  }
  if (r.bit() == 1) {
    // scaling_list_enabled
    if (r.bit() == 1) {
      for (var sizeId = 0; sizeId < 4; sizeId++) {
        for (var m = 0; m < 6; m += sizeId == 3 ? 3 : 1) {
          if (r.bit() == 0) {
            r.ue();
          } else {
            final coefNum = 64 < (1 << (4 + (sizeId << 1))) ? 64 : (1 << (4 + (sizeId << 1)));
            if (sizeId > 1) r.se();
            for (var i = 0; i < coefNum; i++) {
              r.se();
            }
          }
        }
      }
    }
  }
  r.skip(2); // amp, sao
  if (r.bit() == 1) {
    // pcm
    r.skip(8);
    r.ue();
    r.ue();
    r.skip(1);
  }
  final numSets = r.ue();
  final numDeltaPocs = <int>[];
  for (var idx = 0; idx < numSets; idx++) {
    var inter = false;
    if (idx != 0) inter = r.bit() == 1;
    if (inter) {
      r.skip(1);
      r.ue();
      var count = 0;
      for (var j = 0; j <= numDeltaPocs[idx - 1]; j++) {
        final used = r.bit() == 1;
        final useDelta = used ? true : r.bit() == 1;
        if (useDelta) count++;
      }
      numDeltaPocs.add(count);
    } else {
      final neg = r.ue(), posN = r.ue();
      for (var i = 0; i < neg + posN; i++) {
        r.ue();
        r.skip(1);
      }
      numDeltaPocs.add(neg + posN);
    }
  }
  if (r.bit() == 1) {
    // long_term_ref_pics_present
    final n = r.ue();
    for (var i = 0; i < n; i++) {
      r.skip(log2MaxPocLsb + 1);
    }
  }
  r.skip(2); // temporal mvp, strong intra smoothing
  if (r.bit() == 0) return null; // no VUI
  if (r.bit() == 1) {
    if (r.bits(8) == 255) r.skip(32);
  }
  if (r.bit() == 1) r.skip(1); // overscan
  if (r.bit() == 0) return null; // no video_signal_type
  r.skip(4); // video_format, full_range
  if (r.bit() == 0) return null; // no colour description
  r.skip(8); // primaries
  return r.bits(8);
}
