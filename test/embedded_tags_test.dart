// Tags written into a file's own metadata when it is restored, and read back
// when it is added again.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lockbox/core/crypto.dart';
import 'package:lockbox/core/embedded_tags.dart';
import 'package:lockbox/core/models.dart';
import 'package:lockbox/core/mp4_probe.dart';
import 'package:lockbox/core/ultra_hdr.dart';
import 'package:lockbox/core/vault.dart';
import 'package:lockbox/platform/native.dart' show PickedFile;
import 'package:lockbox/state/importer.dart' show Importer;
import 'package:path/path.dart' as p;

ReadAt reader(Uint8List b) => (s, e) async => Uint8List.sublistView(b, s, e);

Future<Uint8List> withTags(Uint8List b, List<String> tags) async {
  final patches = await planTagPatches(b.length, reader(b), tags);
  expect(patches, isNotNull, reason: 'file should accept tags');
  return applyPatches(b, patches!);
}

Future<List<String>> tagsOf(Uint8List b) => readEmbeddedTags(b.length, reader(b));

Uint8List segment(int marker, List<int> payload) {
  final len = payload.length + 2;
  return Uint8List.fromList([0xFF, marker, len >> 8, len & 0xFF, ...payload]);
}

final plainJpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 64, height: 48)));

/// A phone-style Ultra HDR photo: Exif, XMP (gain-map info), MPF table that
/// points at a gain-map JPEG appended after the main picture.
Uint8List ultraHdr({bool xmpAfterMpf = false}) {
  final exif = segment(0xE1, [...'Exif'.codeUnits, 0, 0, ...List.filled(40, 7)]);
  final xmp = segment(0xE1, [
    ...latin1.encode('http://ns.adobe.com/xap/1.0/\u0000'),
    ...utf8.encode('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF '
        'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description '
        'rdf:about="" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" '
        'hdrgm:Version="1.0"/></rdf:RDF></x:xmpmeta>'),
  ]);
  final gainMap = Uint8List.fromList(img.encodeJpg(img.Image(width: 16, height: 12)));
  Uint8List build(int offset) {
    final mpf = segment(0xE2, [
      ...'MPF'.codeUnits, 0, ...'MM'.codeUnits, 0, 42, // TIFF-style header
      offset >> 24 & 255, offset >> 16 & 255, offset >> 8 & 255, offset & 255,
    ]);
    final head = xmpAfterMpf ? [...exif, ...mpf, ...xmp] : [...exif, ...xmp, ...mpf];
    return Uint8List.fromList([0xFF, 0xD8, ...head, ...plainJpeg.sublist(2), ...gainMap]);
  }

  // The offset counts from the TIFF header inside the MPF segment.
  final probe = build(0);
  final tiff = mpfTiff(probe);
  return build(probe.length - gainMap.length - tiff);
}

int mpfTiff(Uint8List b) {
  for (var i = 0; i < b.length - 4; i++) {
    if (b[i] == 0x4D && b[i + 1] == 0x50 && b[i + 2] == 0x46 && b[i + 3] == 0) return i + 4;
  }
  throw StateError('no MPF');
}

/// Where the MPF table says the gain map starts.
int gainMapStart(Uint8List b) {
  final t = mpfTiff(b);
  final o = ByteData.sublistView(b).getUint32(t + 4);
  return t + o;
}

void main() {
  test('JPEG: tags are written, read back, changed and removed', () async {
    expect(await tagsOf(plainJpeg), isEmpty);
    final a = await withTags(plainJpeg, ['Beach', 'Mom & Dad', '<b>']);
    expect(await tagsOf(a), ['Beach', 'Mom & Dad', '<b>']);
    expect(img.decodeJpg(a), isNotNull, reason: 'still a valid picture');

    final b = await withTags(a, ['Summer']);
    expect(await tagsOf(b), ['Summer']);
    expect(latin1.decode(b).split('http://ns.adobe.com/xap/1.0/').length, 2,
        reason: 'one XMP segment, updated in place');

    final c = await withTags(b, []);
    expect(await tagsOf(c), isEmpty);
    expect(await planTagPatches(c.length, reader(c), []), isEmpty, reason: 'nothing to do');
  });

  test('Ultra HDR JPEG keeps its gain map and HDR information', () async {
    final orig = ultraHdr();
    final origGain = orig.sublist(gainMapStart(orig));
    expect(origGain.sublist(0, 2), [0xFF, 0xD8]);

    final tagged = await withTags(orig, ['Beach', 'Sunset']);
    expect(await tagsOf(tagged), ['Beach', 'Sunset']);
    expect(tagged.sublist(gainMapStart(tagged)), origGain, reason: 'MPF still finds the gain map');
    expect(looksUltraHdr(tagged), isTrue);
    expect(latin1.decode(tagged), contains('hdrgm:Version="1.0"'));
    expect(img.decodeJpg(tagged), isNotNull);

    // XMP placed after the MPF table can't grow safely: the file is left alone.
    final risky = ultraHdr(xmpAfterMpf: true);
    expect(await planTagPatches(risky.length, reader(risky), ['Beach']), isNull);
  });

  test('MP4 videos: tags appended without changing the video', () async {
    for (final name in ['hlg_60fps_no_colr.mp4', 'pq_30fps_no_colr.mp4', 'sdr_hevc.mp4']) {
      final orig = File('test/fixtures/$name').readAsBytesSync();
      final tagged = await withTags(orig, ['Trip', 'Family']);
      expect(tagged.sublist(0, orig.length), orig, reason: '$name: original bytes untouched');
      expect(await tagsOf(tagged), ['Trip', 'Family']);

      // Changing the tags replaces the box at the end instead of adding another.
      final again = await withTags(tagged, ['Trip']);
      expect(await tagsOf(again), ['Trip']);
      expect(again.length, lessThan(tagged.length));
      expect(again.sublist(0, orig.length), orig);

      // Still reads as the same video.
      final f1 = File(p.join(Directory.systemTemp.path, 'a_$name'))..writeAsBytesSync(orig);
      final f2 = File(p.join(Directory.systemTemp.path, 'b_$name'))..writeAsBytesSync(again);
      final i1 = (await probeMp4(f1.path))!, i2 = (await probeMp4(f2.path))!;
      expect([i2.durationMs, i2.width, i2.height, i2.fps, i2.hdr],
          [i1.durationMs, i1.width, i1.height, i1.fps, i1.hdr]);
      f1.deleteSync();
      f2.deleteSync();
    }
  });

  test('other files are left alone', () async {
    final txt = Uint8List.fromList(utf8.encode('just some notes, nothing to see here'));
    expect(await planTagPatches(txt.length, reader(txt), ['A']), isNull);
    expect(await tagsOf(txt), isEmpty);
  });

  test('restore writes tags; adding the file again brings them back', () async {
    final tmp = Directory.systemTemp.createTempSync('lockbox_et_');
    try {
      final v = await Vault.create(p.join(tmp.path, 'v'), 'pw', params: KdfParams.testing);
      final src = File(p.join(tmp.path, 'IMG_0001.jpg'))..writeAsBytesSync(ultraHdr());
      final item = MediaItem(
          id: 'x',
          blobId: await v.storeFile(src.path),
          name: 'IMG_0001.jpg',
          kind: MediaKind.photo,
          mimeType: 'image/jpeg',
          sizeBytes: src.lengthSync(),
          addedAt: DateTime.now(),
          tagIds: {v.tagNamed('Beach').id, v.tagNamed('Grandma').id});
      v.data.items.add(item);

      // Restore (the Windows path: decrypt with the edits applied).
      final r = await v.openOriginal(item);
      final patches = (await planTagPatches(r.length, r.read, ['Beach', 'Grandma']))!;
      await r.close();
      final out = p.join(tmp.path, 'restored.jpg');
      await v.exportItem(item, out, patches: patches);
      await v.deleteItems(['x']);

      // Add it back: tags return even though the name has none.
      await Importer(v).run([PickedFile(name: 'IMG_0001.jpg', path: out, size: File(out).lengthSync())],
          deleteOriginals: false, autoTag: true);
      final back = v.data.items.single;
      final names = {for (final t in v.data.tags) t.id: t.name};
      expect(back.tagIds.map((id) => names[id]).toSet(), {'Beach', 'Grandma'});
      expect(back.hdr, HdrFormat.ultraHdr);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
