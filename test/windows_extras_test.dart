// Windows extras: update check (which release is newer) and drag-and-drop
// (dropped folders expand to the files inside).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lockbox/core/updater.dart';
import 'package:lockbox/platform/native.dart';
import 'package:path/path.dart' as p;

Map<String, Object> release(String tag, List<String> assets, {bool draft = false}) => {
      'tag_name': tag,
      'draft': draft,
      'prerelease': false,
      'assets': [
        for (final a in assets)
          {
            'name': a,
            'browser_download_url': 'https://github.com/x/$tag/$a',
            'size': 1234,
            'digest': 'sha256:ABCDEF',
          }
      ],
    };

void main() {
  test('version comparison', () {
    expect(compareVersions('1.0.36', '1.0.35'), greaterThan(0));
    expect(compareVersions('v1.0.9', '1.0.10'), lessThan(0));
    expect(compareVersions('1.0.35', 'v1.0.35'), 0);
    expect(compareVersions('1.1.0', '1.0.99'), greaterThan(0));
  });

  test('finds the newest release that has a Windows installer', () {
    final list = [
      release('v1.0.40', ['Lockbox-android.apk']), // Android only: skipped
      release('v1.0.41', ['Lockbox-windows-setup.exe'], draft: true), // draft: skipped
      release('v1.0.38', ['Lockbox-android.apk', 'Lockbox-windows-setup.exe', 'Lockbox-windows.zip']),
      release('v1.0.36', ['Lockbox-windows-setup.exe']),
    ];
    final u = newerWindowsRelease('1.0.35', list)!;
    expect(u.version, '1.0.38');
    expect(u.url, endsWith('v1.0.38/Lockbox-windows-setup.exe'));
    expect(u.sha256, 'abcdef');
    expect(newerWindowsRelease('1.0.38', list), isNull, reason: 'already newest');
    expect(newerWindowsRelease('1.0.39', list), isNull, reason: 'newer than any installer');
    expect(newerWindowsRelease('1.0.1', {'message': 'rate limited'}), isNull);
  });

  test('dropped folders add every file inside, skipping hidden ones', () {
    final tmp = Directory.systemTemp.createTempSync('lockbox_drop_');
    try {
      File(p.join(tmp.path, 'single.jpg')).writeAsStringSync('x');
      final trip = Directory(p.join(tmp.path, 'Trip'))..createSync();
      File(p.join(trip.path, 'a.mp4')).writeAsStringSync('x');
      File(p.join(trip.path, 'desktop.ini')).writeAsStringSync('x');
      File(p.join(trip.path, '.hidden')).writeAsStringSync('x');
      final day2 = Directory(p.join(trip.path, 'Day 2'))..createSync();
      File(p.join(day2.path, 'b.jpg')).writeAsStringSync('xy');
      Directory(p.join(trip.path, '.git')).createSync();
      File(p.join(trip.path, '.git', 'config')).writeAsStringSync('x');

      final files = Native.pickedFromPaths([p.join(tmp.path, 'single.jpg'), trip.path]);
      expect(files.map((f) => f.name).toList(), ['single.jpg', 'b.jpg', 'a.mp4']);
      final b = files.firstWhere((f) => f.name == 'b.jpg');
      expect(b.path, p.join(day2.path, 'b.jpg'));
      expect(b.originalLocation, day2.path, reason: 'restores back to its own folder');
      expect(b.size, 2);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
