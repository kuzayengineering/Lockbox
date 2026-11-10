// Tests for Lockbox's storage engine. Run with:  flutter test
// (first time only: dart run webcrypto:setup)

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lockbox/core/auto_tag.dart';
import 'package:lockbox/core/backup.dart';
import 'package:lockbox/core/blob_format.dart';
import 'package:lockbox/core/crypto.dart';
import 'package:lockbox/core/library_query.dart';
import 'package:lockbox/core/media_server.dart';
import 'package:lockbox/core/models.dart';
import 'package:lockbox/core/mp4_probe.dart';
import 'package:lockbox/core/ultra_hdr.dart';
import 'package:lockbox/core/vault.dart';
import 'package:lockbox/state/importer.dart' show classify;
import 'package:path/path.dart' as p;

Uint8List _data(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('lockbox_'));
  tearDown(() async => tmp.delete(recursive: true));

  group('blob format', () {
    test('round trips many sizes and random ranges', () async {
      final key = await AesKey.fromBytes(randomBytes(32));
      const cs = 1 << 12;
      for (final n in [0, 1, cs - 1, cs, cs + 1, cs * 3, cs * 5 + 17]) {
        final data = _data(n, n);
        final path = p.join(tmp.path, 'b$n');
        // Feed in odd-sized pieces to exercise buffering.
        final pieces = <List<int>>[];
        for (var i = 0; i < n; i += 1000) {
          pieces.add(data.sublist(i, min(i + 1000, n)));
        }
        await writeBlob(
          source: Stream.fromIterable(pieces),
          length: n,
          destPath: path,
          masterKey: key,
          chunkShift: 12,
        );
        expect(File(path).lengthSync(),
            kBlobHeaderLength + n + 16 * max(1, (n + cs - 1) ~/ cs));
        final r = await BlobReader.open(path, key);
        expect(await r.readAll(), data);
        final rnd = Random(n);
        for (var t = 0; t < 20 && n > 0; t++) {
          final a = rnd.nextInt(n);
          final b = a + rnd.nextInt(n - a + 1);
          expect(await r.read(a, b), data.sublist(a, b));
        }
        final streamed = <int>[];
        await for (final s in r.stream(n ~/ 3)) {
          streamed.addAll(s);
        }
        expect(streamed, data.sublist(n ~/ 3));
        await r.close();
      }
    });

    test('detects tampering and wrong keys', () async {
      final key = await AesKey.fromBytes(randomBytes(32));
      final path = p.join(tmp.path, 'x');
      await encryptBytesToBlob(
          bytes: _data(10000), destPath: path, masterKey: key);
      final other = await AesKey.fromBytes(randomBytes(32));
      await expectLater(BlobReader.open(path, other),
          throwsA(isA<DecryptionException>()));

      final bytes = File(path).readAsBytesSync();
      bytes[kBlobHeaderLength + 5] ^= 1;
      File(path).writeAsBytesSync(bytes);
      final r = await BlobReader.open(path, key);
      await expectLater(r.readAll(), throwsA(isA<DecryptionException>()));
      await r.close();

      // Changing the declared length breaks the key unwrap.
      bytes[kBlobHeaderLength + 5] ^= 1;
      bytes[8] ^= 1;
      File(path).writeAsBytesSync(bytes);
      await expectLater(BlobReader.open(path, key),
          throwsA(isA<DecryptionException>()));
    });

    test('rejects source of wrong length', () async {
      final key = await AesKey.fromBytes(randomBytes(32));
      expect(
        () => writeBlob(
            source: Stream.value(_data(10)),
            length: 11,
            destPath: p.join(tmp.path, 'bad'),
            masterKey: key),
        throwsA(isA<BlobFormatException>()),
      );
    });
  });

  group('vault', () {
    test('create, store, reopen, wrong passphrase', () async {
      final dir = p.join(tmp.path, 'vault');
      final v = await Vault.create(dir, 'correct horse battery',
          params: KdfParams.testing);
      final src = File(p.join(tmp.path, 'clip.mp4'))
        ..writeAsBytesSync(_data(700000));
      final blobId = await v.storeFile(src.path);
      final thumbId = await v.storeThumbnail(_data(5000, 9));
      final folder = v.createFolder('Trips');
      final tag = v.createTag('Beach');
      v.data.items.add(MediaItem(
        id: 'i1',
        blobId: blobId,
        thumbId: thumbId,
        name: 'clip.mp4',
        kind: MediaKind.video,
        mimeType: 'video/mp4',
        sizeBytes: 700000,
        addedAt: DateTime(2024, 1, 2),
        hdr: HdrFormat.hlg,
        fps: 59.94,
        folderId: folder.id,
        tagIds: {tag.id},
      ));
      await v.save();
      await v.lock();
      expect(v.isLocked, isTrue);

      // Nothing readable on disk.
      final idx = File(p.join(dir, kIndexFileName)).readAsBytesSync();
      expect(String.fromCharCodes(idx).contains('clip'), isFalse);

      await expectLater(Vault.open(dir, 'wrong'),
          throwsA(isA<WrongPassphraseException>()));
      final v2 = await Vault.open(dir, 'correct horse battery');
      final item = v2.data.items.single;
      expect(item.name, 'clip.mp4');
      expect(item.hdr, HdrFormat.hlg);
      expect(item.fps, 59.94);
      expect(item.tagIds, {tag.id});
      expect(v2.data.folders.single.name, 'Trips');
      expect(await v2.readOriginal(item), src.readAsBytesSync());
      expect(await v2.readThumbnail(item), _data(5000, 9));

      final out = p.join(tmp.path, 'exported.mp4');
      await v2.exportItem(item, out);
      expect(File(out).readAsBytesSync(), src.readAsBytesSync());

      expect(await v2.verifyPassphrase('correct horse battery'), isTrue);
      expect(await v2.verifyPassphrase('nope'), isFalse);
      await v2.changePassphrase('new pass phrase', params: KdfParams.testing);
      await v2.lock();
      await expectLater(Vault.open(dir, 'correct horse battery'),
          throwsA(isA<WrongPassphraseException>()));
      final v3 = await Vault.open(dir, 'new pass phrase');
      expect(v3.data.items.length, 1);

      await v3.deleteItems(['i1']);
      expect(File(v3.blobPath(blobId)).existsSync(), isFalse);
      expect(File(v3.thumbPath(thumbId)).existsSync(), isFalse);
    });

    test('falls back to backup index if main index is damaged', () async {
      final dir = p.join(tmp.path, 'vault');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      v.createTag('A');
      await v.save();
      v.createTag('B');
      await v.save();
      final f = File(p.join(dir, kIndexFileName));
      final b = f.readAsBytesSync();
      b[b.length - 3] ^= 0xFF;
      f.writeAsBytesSync(b);
      final v2 = await Vault.open(dir, 'pw');
      expect(v2.data.tags.map((t) => t.name), ['A']);
    });

    test('folder deletion and descendants', () async {
      final v = await Vault.create(p.join(tmp.path, 'v'), 'pw',
          params: KdfParams.testing);
      final a = v.createFolder('A');
      final b = v.createFolder('B', parentId: a.id);
      final c = v.createFolder('C', parentId: b.id);
      expect(v.folderAndDescendants(a.id), {a.id, b.id, c.id});
      v.deleteFolder(b.id);
      expect(c.parentId, a.id);
    });
  });

  group('backup', () {
    test('round trip and restored vault opens', () async {
      final dir = p.join(tmp.path, 'vault');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      final src = File(p.join(tmp.path, 'a.jpg'))..writeAsBytesSync(_data(3000));
      final blob = await v.storeFile(src.path);
      v.data.items.add(MediaItem(
          id: 'x',
          blobId: blob,
          name: 'a.jpg',
          kind: MediaKind.photo,
          mimeType: 'image/jpeg',
          sizeBytes: 3000,
          addedAt: DateTime.now()));
      await v.save();
      final bk = p.join(tmp.path, 'b.lockbox');
      await writeBackup(
          vaultDir: dir, relativePaths: v.allFilesRelative(), destPath: bk);
      final dest = p.join(tmp.path, 'restored');
      expect(await restoreBackup(backupPath: bk, destDir: dest), 2);
      final r = await Vault.open(dest, 'pw');
      expect(await r.readOriginal(r.data.items.single), src.readAsBytesSync());
    });

    test('rejects path traversal', () async {
      final bk = File(p.join(tmp.path, 'evil.lockbox'));
      final name = '../../evil'.codeUnits;
      final b = BytesBuilder()
        ..add([...kPackMagic, 1, 0, 0, 0])
        ..add([name.length, 0])
        ..add(name)
        ..add(Uint8List(8))
        ..add([0, 0]);
      bk.writeAsBytesSync(b.toBytes());
      expect(
          () => restoreBackup(
              backupPath: bk.path, destDir: p.join(tmp.path, 'out')),
          throwsA(isA<BackupFormatException>()));
    });
  });

  group('library query', () {
    MediaItem item(String id,
            {MediaKind kind = MediaKind.photo,
            int size = 100,
            int? dur,
            DateTime? created,
            Set<String>? tags,
            HdrFormat hdr = HdrFormat.none,
            double? fps,
            String? folder}) =>
        MediaItem(
          id: id,
          blobId: id,
          name: '$id.bin',
          kind: kind,
          mimeType: 'x',
          sizeBytes: size,
          addedAt: DateTime(2024, 1, int.parse(id.substring(1))),
          createdAt: created,
          durationMs: dur,
          tagIds: tags,
          hdr: hdr,
          fps: fps,
          folderId: folder,
        );
    final items = [
      item('i1', size: 500, created: DateTime(2020)),
      item('i2',
          kind: MediaKind.video,
          size: 900,
          dur: 60000,
          tags: {'t1'},
          hdr: HdrFormat.hlg,
          fps: 60,
          folder: 'f1'),
      item('i3',
          kind: MediaKind.video,
          size: 50,
          dur: 5000,
          tags: {'t1', 't2'},
          fps: 30,
          folder: 'f2'),
      item('i4', kind: MediaKind.audio, size: 300, dur: 200000, tags: {'t2'}),
    ];
    List<String> ids(LibraryQuery q, {Set<String>? scope}) =>
        q.apply(items, folderScope: scope).map((i) => i.id).toList();

    test('sorting', () {
      expect(ids(const LibraryQuery(sort: SortField.size)),
          ['i2', 'i1', 'i4', 'i3']);
      expect(
          ids(const LibraryQuery(sort: SortField.duration, descending: false)),
          ['i1', 'i3', 'i2', 'i4']);
      expect(ids(const LibraryQuery(sort: SortField.dateTaken)),
          ['i4', 'i3', 'i2', 'i1']);
      expect(ids(const LibraryQuery(sort: SortField.dateAdded, descending: false)),
          ['i1', 'i2', 'i3', 'i4']);
    });

    test('combined filters', () {
      expect(ids(const LibraryQuery(kinds: {MediaKind.video})), ['i3', 'i2']);
      expect(ids(const LibraryQuery(tagIds: {'t1', 't2'}, tagMatch: TagMatch.all)),
          ['i3']);
      expect(ids(const LibraryQuery(tagIds: {'t1', 't2'})), ['i4', 'i3', 'i2']);
      expect(ids(const LibraryQuery(hdrOnly: true)), ['i2']);
      expect(ids(const LibraryQuery(highFrameRateOnly: true)), ['i2']);
      expect(
          ids(const LibraryQuery(
              kinds: {MediaKind.video, MediaKind.audio},
              minDurationMs: 10000,
              maxSizeBytes: 400)),
          ['i4']);
      expect(ids(const LibraryQuery(untaggedOnly: true)), ['i1']);
      expect(ids(const LibraryQuery(folderId: 'f1'), scope: {'f1', 'f2'}),
          ['i3', 'i2']);
      expect(ids(const LibraryQuery(text: 'i3')), ['i3']);
      expect(ids(LibraryQuery(takenBefore: DateTime(2021))), ['i1']);
    });
  });

  group('mp4 probe', () {
    Uint8List box(String type, List<int> payload) {
      final b = Uint8List(8 + payload.length);
      ByteData.sublistView(b).setUint32(0, b.length);
      b.setRange(4, 8, type.codeUnits);
      b.setRange(8, b.length, payload);
      return b;
    }

    Uint8List u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
    Uint8List u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v);

    test('reads duration, fps, size, rotation, HLG, date', () async {
      final created = DateTime.utc(2023, 7, 4, 12);
      final secs1904 = created.difference(DateTime.utc(1904)).inSeconds;
      final mvhd = box('mvhd', [
        0, 0, 0, 0, ...u32(secs1904), ...u32(secs1904), ...u32(1000),
        ...u32(10000), ...List.filled(80, 0)
      ]);
      final matrix = [
        ...u32(0), ...u32(0x10000), ...u32(0), //
        ...u32(0xFFFF0000), ...u32(0), ...u32(0),
        ...u32(0), ...u32(0), ...u32(0x40000000)
      ];
      final tkhd = box('tkhd', [
        0, 0, 0, 3, ...List.filled(36, 0), ...matrix,
        ...u32(3840 << 16), ...u32(2160 << 16)
      ]);
      final mdhd = box('mdhd',
          [0, 0, 0, 0, ...u32(0), ...u32(0), ...u32(60000), ...u32(600000), 0, 0, 0, 0]);
      final hdlr = box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...'vide'.codeUnits, ...List.filled(13, 0)]);
      final colr = box('colr', [...'nclx'.codeUnits, ...u16(9), ...u16(18), ...u16(9), 0x80]);
      final entry = box('hvc1', [
        ...List.filled(24, 0), ...u16(3840), ...u16(2160), ...List.filled(50, 0),
        ...colr
      ]);
      final stsd = box('stsd', [0, 0, 0, 0, ...u32(1), ...entry]);
      // 600 frames of 1000 ticks at 60000 Hz = 60 fps
      final stts = box('stts', [0, 0, 0, 0, ...u32(1), ...u32(600), ...u32(1000)]);
      final stbl = box('stbl', [...stsd, ...stts]);
      final minf = box('minf', stbl);
      final mdia = box('mdia', [...mdhd, ...hdlr, ...minf]);
      final trak = box('trak', [...tkhd, ...mdia]);
      final moov = box('moov', [...mvhd, ...trak]);
      final ftyp = box('ftyp', [...'isom'.codeUnits, 0, 0, 0, 0]);
      final mdat = box('mdat', List.filled(5000, 7));
      final f = File(p.join(tmp.path, 'v.mp4'))
        ..writeAsBytesSync([...ftyp, ...mdat, ...moov]);

      final info = (await probeMp4(f.path))!;
      expect(info.durationMs, 10000);
      expect(info.fps, 60);
      expect(info.rotation, 90);
      expect(info.width, 2160);
      expect(info.height, 3840);
      expect(info.hdr, HdrFormat.hlg);
      expect(info.videoCodec, 'hvc1');
      expect(info.createdAt!.toUtc(), created);
    });

    test('real HEVC files: HDR read from the video stream', () async {
      final hlg = (await probeMp4('test/fixtures/hlg_60fps_no_colr.mp4'))!;
      expect(hlg.hdr, HdrFormat.hlg);
      expect(hlg.fps, 60);
      expect((hlg.width, hlg.height), (320, 180));
      final pq = (await probeMp4('test/fixtures/pq_30fps_no_colr.mp4'))!;
      expect(pq.hdr, HdrFormat.hdr10);
      expect(pq.fps, 30);
      final sdr = (await probeMp4('test/fixtures/sdr_hevc.mp4'))!;
      expect(sdr.hdr, HdrFormat.none);
    });

    test('non-mp4 returns null', () async {
      final f = File(p.join(tmp.path, 'x.jpg'))
        ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(100, 1)]);
      expect(await probeMp4(f.path), isNull);
    });
  });

  group('auto tags', () {
    test('words from file names: spaces needed, digits/underscores ignored', () {
      expect(tagWordsFromFileName('Beach trip with Sam 2024 (2).mp4'),
          ['Beach', 'trip', 'with', 'Sam']);
      // Phone camera names: no spaces -> no tags at all.
      expect(tagWordsFromFileName('PXL_2026110612030045.mp4'), isEmpty);
      expect(tagWordsFromFileName('IMG_20240101_123456.jpg'), isEmpty);
      expect(tagWordsFromFileName('Beach.jpg'), isEmpty);
      // Words with digits or underscores are skipped, the rest kept.
      expect(tagWordsFromFileName('PXL_20261106 Sam birthday.mp4'), ['Sam', 'birthday']);
      expect(tagWordsFromFileName('4K HDR clip.mov'), ['HDR', 'clip']);
      expect(tagWordsFromFileName('20240101 123456.jpg'), isEmpty);
      expect(tagWordsFromFileName('Dog  dog - DOG, park.heic'), ['Dog', 'park']);
      expect(tagWordsFromFileName("Jean-Luc's party.jpg"), ["Jean-Luc's", 'party']);
    });

    test('clean-up removes old auto tags with digits, keeps hand-made ones', () async {
      final v = await Vault.create(p.join(tmp.path, 'v2'), 'pw',
          params: KdfParams.testing);
      MediaItem item(String id, String name) => MediaItem(
          id: id,
          blobId: id,
          name: name,
          kind: MediaKind.video,
          mimeType: 'video/mp4',
          sizeBytes: 1,
          addedAt: DateTime.now());
      final a = item('a', 'PXL_2026110612030045.mp4');
      final b = item('b', 'Holiday.mp4');
      v.data.items.addAll([a, b]);
      final bad = v.createTag('PXL_2026110612030045');
      final manual = v.createTag('Trip 2024'); // made by hand, has a digit
      final good = v.createTag('Holiday');
      a.tagIds.addAll({bad.id, manual.id});
      b.tagIds.addAll({good.id, manual.id});
      expect(v.removeInvalidAutoTags(), 1);
      expect(v.data.tags.map((t) => t.name), ['Trip 2024', 'Holiday']);
      expect(a.tagIds, {manual.id});
    });

    test('reuses existing tags regardless of case', () async {
      final v = await Vault.create(p.join(tmp.path, 'v'), 'pw',
          params: KdfParams.testing);
      final existing = v.createTag('beach');
      final item = MediaItem(
          id: 'a',
          blobId: 'a',
          name: 'Beach sunset 2023.jpg',
          kind: MediaKind.photo,
          mimeType: 'image/jpeg',
          sizeBytes: 1,
          addedAt: DateTime.now());
      v.autoTag(item);
      expect(v.data.tags.map((t) => t.name), ['beach', 'sunset']);
      expect(item.tagIds.contains(existing.id), isTrue);
      expect(item.tagIds.length, 2);
    });
  });

  group('ultra hdr', () {
    Uint8List jpegWith(String text) => Uint8List.fromList(
        [0xFF, 0xD8, 0xFF, 0xE1, ...text.codeUnits, ...List.filled(50, 0)]);

    test('recognises gain-map JPEGs', () {
      expect(looksUltraHdr(jpegWith('<x hdrgm:Version="1.0"/>')), isTrue);
      expect(looksUltraHdr(jpegWith('urn:iso:std:iso:ts:21496:-1')), isTrue);
      expect(looksUltraHdr(jpegWith('plain exif data')), isFalse);
      expect(looksUltraHdr(Uint8List.fromList('hdrgm:'.codeUnits)), isFalse); // not a JPEG
    });

    test('scan marks existing Ultra HDR photos once', () async {
      final v = await Vault.create(p.join(tmp.path, 'hv'), 'pw',
          params: KdfParams.testing);
      Future<MediaItem> add(String id, Uint8List bytes) async {
        final f = File(p.join(tmp.path, '$id.jpg'))..writeAsBytesSync(bytes);
        final i = MediaItem(
            id: id,
            blobId: await v.storeFile(f.path),
            name: '$id.jpg',
            kind: MediaKind.photo,
            mimeType: 'image/jpeg',
            sizeBytes: bytes.length,
            addedAt: DateTime.now());
        v.data.items.add(i);
        return i;
      }

      final hdr = await add('a', jpegWith('<x hdrgm:Version="1.0"/>'));
      final sdr = await add('b', jpegWith('nothing special'));
      expect(await v.scanUltraHdrPhotos(), 1);
      expect(hdr.hdr, HdrFormat.ultraHdr);
      expect(sdr.hdr, HdrFormat.none);
      expect(await v.scanUltraHdrPhotos(), 0);
      expect(
          const LibraryQuery(hdrOnly: true).apply(v.data.items).map((i) => i.id),
          ['a']);
    });
  });

  group('any file type', () {
    test('classify', () {
      expect(classify('a.jpg', null), (MediaKind.photo, 'image/jpeg'));
      expect(classify('a.MOV', null), (MediaKind.video, 'video/quicktime'));
      expect(classify('Report.pdf', null), (MediaKind.file, 'application/pdf'));
      expect(classify('sheet.xlsx', null).$1, MediaKind.file);
      expect(classify('weird.qqq', 'application/x-thing'),
          (MediaKind.file, 'application/x-thing'));
      expect(classify('noext', null), (MediaKind.file, 'application/octet-stream'));
      expect(classify('clip', 'video/mp4'), (MediaKind.video, 'video/mp4'));
    });

    test('files filter', () {
      MediaItem it(String id, MediaKind k) => MediaItem(
          id: id, blobId: id, name: id, kind: k, mimeType: 'x', sizeBytes: 1,
          addedAt: DateTime(2024));
      final items = [it('p', MediaKind.photo), it('f', MediaKind.file)];
      expect(const LibraryQuery(kinds: {MediaKind.file}).apply(items).map((i) => i.id), ['f']);
      final j = MediaItem.fromJson(it('f', MediaKind.file).toJson());
      expect(j.kind, MediaKind.file);
    });
  });

  group('media server', () {
    test('parseRange', () {
      expect(parseRange('bytes=0-', 100), (0, 99));
      expect(parseRange('bytes=10-19', 100), (10, 19));
      expect(parseRange('bytes=-10', 100), (90, 99));
      expect(parseRange('bytes=90-500', 100), (90, 99));
      expect(parseRange('bytes=100-', 100), isNull);
    });

    test('serves decrypted ranges only with the token', () async {
      final dir = p.join(tmp.path, 'vault');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      final data = _data(600000);
      final src = File(p.join(tmp.path, 'm.mp4'))..writeAsBytesSync(data);
      final blob = await v.storeFile(src.path);
      final server = await MediaServer.start(dir, v.masterKey.bytes);
      final client = HttpClient();
      try {
        final url = Uri.parse(server.urlFor(blob, mimeType: 'video/mp4'));
        var req = await client.getUrl(url);
        req.headers.set('Range', 'bytes=300000-300099');
        var res = await req.close();
        expect(res.statusCode, 206);
        expect(res.headers.value('content-range'), 'bytes 300000-300099/600000');
        final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(body, data.sublist(300000, 300100));

        req = await client.getUrl(url.replace(path: '/wrongtoken/$blob'));
        res = await req.close();
        expect(res.statusCode, 404);
        await res.drain<void>();
      } finally {
        client.close(force: true);
        await server.stop();
      }
    });
  });
}
