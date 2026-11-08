// A tiny streaming server used for playback on Windows.
//
// The video player (libmpv) needs to read the decrypted file with seeking.
// Instead of ever writing a decrypted copy to disk, this server decrypts
// byte ranges on the fly and hands them to the player over a connection
// that only exists inside this computer (127.0.0.1).
//
// Protection:
//   * bound to the loopback interface only (not reachable from the network)
//   * every URL contains a random 256-bit token; requests without it get 404
//   * runs in its own isolate so decryption never stutters the UI
//   * stopped as soon as the vault locks
//
// Android does not use this: its native player decrypts directly.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'blob_format.dart';
import 'crypto.dart';

class MediaServer {
  MediaServer._(this.port, this._token, this._control, this._isolate);

  final int port;
  final String _token;
  final SendPort _control;
  final Isolate _isolate;

  String urlFor(String blobId, {String? mimeType}) {
    final q = mimeType == null ? '' : '?m=${Uri.encodeQueryComponent(mimeType)}';
    return 'http://127.0.0.1:$port/$_token/$blobId$q';
  }

  static Future<MediaServer> start(String vaultDir, Uint8List masterKey) async {
    final token = randomId(32);
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _serverMain,
      _ServerArgs(ready.sendPort, vaultDir, Uint8List.fromList(masterKey),
          token),
      debugName: 'lockbox-media-server',
    );
    final msg = await ready.first as List;
    return MediaServer._(msg[0] as int, token, msg[1] as SendPort, isolate);
  }

  Future<void> stop() async {
    _control.send('stop');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _ServerArgs {
  _ServerArgs(this.reply, this.vaultDir, this.key, this.token);
  final SendPort reply;
  final String vaultDir;
  final Uint8List key;
  final String token;
}

final RegExp _blobIdPattern = RegExp(r'^[0-9a-f]{32}$');

Future<void> _serverMain(_ServerArgs args) async {
  final master = await AesKey.fromBytes(args.key);
  args.key.fillRange(0, args.key.length, 0);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final control = ReceivePort();
  control.listen((msg) async {
    if (msg == 'stop') {
      await server.close(force: true);
      master.wipe();
      control.close();
    }
  });
  args.reply.send([server.port, control.sendPort]);
  server.listen((req) => _handle(req, args, master));
}

Future<void> _handle(HttpRequest req, _ServerArgs args, AesKey master) async {
  final res = req.response;
  final segs = req.uri.pathSegments;
  if (segs.length != 2 ||
      !bytesEqual(segs[0].codeUnits, args.token.codeUnits) ||
      !_blobIdPattern.hasMatch(segs[1]) ||
      (req.method != 'GET' && req.method != 'HEAD')) {
    res.statusCode = HttpStatus.notFound;
    await res.close();
    return;
  }
  final id = segs[1];
  final path = p.join(args.vaultDir, 'blobs', id.substring(0, 2), id);
  BlobReader? reader;
  try {
    reader = await BlobReader.open(path, master);
    final len = reader.length;
    var start = 0;
    var end = len - 1; // inclusive
    var partial = false;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final r = parseRange(range, len);
      if (r == null) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$len');
        await res.close();
        return;
      }
      start = r.$1;
      end = r.$2;
      partial = true;
    }
    res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..contentType = ContentType.parse(
          req.uri.queryParameters['m'] ?? 'application/octet-stream')
      ..contentLength = len == 0 ? 0 : end - start + 1;
    if (partial) {
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$len');
    }
    if (req.method == 'HEAD' || len == 0) {
      await res.close();
      return;
    }
    await res.addStream(reader.stream(start, end + 1));
    await res.close();
  } catch (_) {
    // Client went away (normal when seeking) or file problem.
    try {
      res.statusCode = HttpStatus.internalServerError;
    } catch (_) {}
    try {
      await res.close();
    } catch (_) {}
  } finally {
    await reader?.close();
  }
}

/// Parses an HTTP Range header ("bytes=a-b", "bytes=a-", "bytes=-n").
/// Returns inclusive (start, end) or null if unsatisfiable.
(int, int)? parseRange(String header, int length) {
  final m = RegExp(r'^bytes=(\d*)-(\d*)').firstMatch(header.trim());
  if (m == null || length == 0) return null;
  final a = m.group(1)!, b = m.group(2)!;
  int start, end;
  if (a.isEmpty) {
    if (b.isEmpty) return null;
    final n = int.parse(b);
    if (n == 0) return null;
    start = n >= length ? 0 : length - n;
    end = length - 1;
  } else {
    start = int.parse(a);
    end = b.isEmpty ? length - 1 : int.parse(b);
    if (end >= length) end = length - 1;
  }
  if (start > end || start >= length) return null;
  return (start, end);
}
