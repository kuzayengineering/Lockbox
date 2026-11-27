// Windows update check: asks GitHub for Lockbox's releases, finds the
// newest one with a Windows installer, downloads it and checks it against
// the SHA-256 fingerprint GitHub publishes for it.
//
// Only the public release list and the installer are fetched. Nothing about
// the person or their vault is sent (the request carries a generic
// "Lockbox-updater" user agent and no account or token).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

const kReleasesUrl = 'https://api.github.com/repos/kuzayengineering/Lockbox/releases?per_page=30';
const kWindowsInstaller = 'Lockbox-windows-setup.exe';

class UpdateInfo {
  UpdateInfo({required this.version, required this.url, required this.size, this.sha256});
  final String version;
  final String url;
  final int size;

  /// Lower-case hex, if GitHub published one.
  final String? sha256;
}

/// Compares "1.0.35" style versions: <0 if a is older than b.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
        for (final x in v.replaceFirst(RegExp('^v'), '').split('.')) int.tryParse(x) ?? 0
      ];
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 4; i++) {
    final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// The newest release with a Windows installer, if it is newer than
/// [current]. [releasesJson] is GitHub's release list (newest first).
UpdateInfo? newerWindowsRelease(String current, Object? releasesJson) {
  if (releasesJson is! List) return null;
  for (final r in releasesJson) {
    if (r is! Map || r['draft'] == true || r['prerelease'] == true) continue;
    final tag = r['tag_name'];
    final assets = r['assets'];
    if (tag is! String || assets is! List) continue;
    for (final a in assets) {
      if (a is! Map || a['name'] != kWindowsInstaller) continue;
      if (compareVersions(tag, current) <= 0) return null;
      final digest = a['digest'];
      return UpdateInfo(
        version: tag.replaceFirst(RegExp('^v'), ''),
        url: a['browser_download_url'] as String,
        size: (a['size'] as num?)?.toInt() ?? 0,
        sha256: digest is String && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
      );
    }
  }
  return null;
}

HttpClient _client() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 10)
  ..userAgent = 'Lockbox-updater';

/// Checks GitHub for a newer Windows version than [current].
Future<UpdateInfo?> checkForUpdate(String current) async {
  final client = _client();
  try {
    final req = await client.getUrl(Uri.parse(kReleasesUrl));
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    return newerWindowsRelease(current, jsonDecode(body));
  } finally {
    client.close(force: true);
  }
}

class UpdateCheckFailed implements Exception {
  UpdateCheckFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads the installer to a temporary folder and verifies it.
/// Returns its path.
Future<String> downloadUpdate(UpdateInfo u, {void Function(double fraction)? onProgress}) async {
  final dir = await Directory.systemTemp.createTemp('lockbox_update_');
  final path = p.join(dir.path, kWindowsInstaller);
  final client = _client();
  final sink = File(path).openWrite();
  final hash = Sha256().newHashSink();
  var done = 0;
  try {
    final req = await client.getUrl(Uri.parse(u.url));
    final res = await req.close();
    if (res.statusCode != 200) throw UpdateCheckFailed('Download failed (HTTP ${res.statusCode}).');
    final total = res.contentLength > 0 ? res.contentLength : u.size;
    await for (final part in res.timeout(const Duration(seconds: 60))) {
      sink.add(part);
      hash.add(part);
      done += part.length;
      if (total > 0) onProgress?.call(done / total);
    }
    await sink.close();
    hash.close();
  } catch (e) {
    await sink.close();
    await dir.delete(recursive: true);
    rethrow;
  } finally {
    client.close(force: true);
  }
  if (u.size > 0 && done != u.size) {
    await dir.delete(recursive: true);
    throw UpdateCheckFailed('The download was incomplete.');
  }
  if (u.sha256 != null) {
    final got = (await hash.hash()).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (got != u.sha256) {
      await dir.delete(recursive: true);
      throw UpdateCheckFailed('The download did not match GitHub\'s fingerprint, so it was not installed.');
    }
  }
  return path;
}

/// Starts the installer quietly; it closes Lockbox, updates it and opens
/// it again. The caller should exit straight after.
Future<void> runInstaller(String path) => Process.start(
      path,
      ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
      mode: ProcessStartMode.detached,
    );
