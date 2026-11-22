// Leaving Lockbox while a system screen (file picker) is open must lock it,
// and an import cut short by locking must never lose a file.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:lockbox/core/crypto.dart';
import 'package:lockbox/core/vault.dart';
import 'package:lockbox/platform/native.dart';
import 'package:lockbox/state/app_state.dart';
import 'package:lockbox/state/importer.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lockbox_leave_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('leaving while the file picker is open locks Lockbox', (tester) async {
    await tester.runAsync(() async {
      final dir = p.join(tmp.path, 'v');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      await v.lock();
      final app = AppState()..vaultDir = dir;
      await app.unlock('pw');

      // Picker opens: Lockbox itself is paused, which alone must not lock.
      final picker = Completer<List<PickedFile>>();
      final picking = app.external(() => picker.future);
      app.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(app.isUnlocked, isTrue);

      // The person presses Home from the picker.
      Native.simulateLeft();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(app.isUnlocked, isFalse);

      // Coming back and finishing the pick doesn't unlock anything.
      picker.complete([PickedFile(name: 'a.txt', path: '/nowhere/a.txt')]);
      await picking;
      expect(app.isUnlocked, isFalse);
    });
  });

  test('an import cut short by locking never loses a file', () async {
    final dir = p.join(tmp.path, 'v2');
    final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
    final files = [
      for (var i = 0; i < 6; i++)
        PickedFile(
            name: 'note $i.txt',
            path: (File(p.join(tmp.path, 'note $i.txt'))..writeAsStringSync('hello $i')).path),
    ];
    Future<void>? locking;
    await Importer(v).run(files, deleteOriginals: true, onProgress: (n, total, _) {
      if (n == 2) locking ??= v.lock(); // locks part-way through
    });
    await locking;

    final reopened = await Vault.open(dir, 'pw');
    final stored = reopened.data.items.map((i) => i.name).toSet();
    for (final f in files) {
      final originalKept = File(f.path!).existsSync();
      expect(originalKept || stored.contains(f.name), isTrue,
          reason: '${f.name}: deleted but not saved in Lockbox');
    }
    expect(stored.length, lessThan(files.length), reason: 'import stopped when locked');
    await reopened.lock();
  });
}
