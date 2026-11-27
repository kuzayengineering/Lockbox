// Folders page (grid of folders, can be the start screen) and the
// Google Photos–style fast scroller on long lists.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lockbox/core/crypto.dart';
import 'package:lockbox/core/models.dart';
import 'package:lockbox/core/vault.dart';
import 'package:lockbox/state/app_state.dart';
import 'package:lockbox/ui/library_screen.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lockbox_folders_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppState> vaultWith(int items, {bool startOnFolders = false}) async {
    late AppState app;
    final dir = p.join(tmp.path, 'v$items');
    final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
    final family = v.createFolder('Family');
    v.createFolder('Work');
    v.createFolder('Italy', parentId: family.id);
    for (var i = 0; i < items; i++) {
      v.data.items.add(MediaItem(
          id: 'i$i',
          blobId: 'x',
          name: 'IMG_$i.jpg',
          kind: MediaKind.photo,
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
          addedAt: DateTime(2026, 11, 20).subtract(Duration(days: i ~/ 4)),
          folderId: family.id));
    }
    if (startOnFolders) v.data.settings.startFolderId = kStartFoldersPage;
    await v.save();
    await v.lock();
    app = AppState()..vaultDir = dir;
    await app.unlock('pw');
    return app;
  }

  Future<void> show(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app, child: const MaterialApp(home: LibraryScreen())));
    await tester.pump();
  }

  testWidgets('Folders page as start screen; open a folder and come back', (tester) async {
    late AppState app;
    await tester.runAsync(() async => app = await vaultWith(5, startOnFolders: true));
    await show(tester, app);
    expect(app.showingFolders, isTrue);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Italy'), findsOneWidget);
    expect(find.text('in Family · 0 items'), findsOneWidget);
    expect(find.text('5 items'), findsOneWidget); // Family

    await tester.tap(find.text('Work'));
    await tester.pump();
    expect(app.showingFolders, isFalse);
    expect(app.query.folderId, isNotNull);

    // The back arrow (and Android's back button) return to the Folders page.
    await tester.tap(find.byTooltip('Folders'));
    await tester.pump();
    expect(app.showingFolders, isTrue);
    await tester.tap(find.text('Work'));
    await tester.pump();
    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(handled, isTrue);
    expect(app.showingFolders, isTrue);

    await tester.runAsync(() => app.lock());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('fast scroller appears only on long lists', (tester) async {
    final handle = find.byKey(const ValueKey('fast-scroll-handle'));
    for (final (count, expectHandle) in [(12, false), (800, true)]) {
      late AppState app;
      await tester.runAsync(() async => app = await vaultWith(count));
      await show(tester, app);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -150));
      await tester.pump();
      expect(handle, expectHandle ? findsOneWidget : findsNothing, reason: '$count items');
      if (expectHandle) {
        // Dragging the handle down jumps far through the list.
        final controller = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        final before = controller.offset;
        await tester.drag(handle, const Offset(0, 300));
        await tester.pump();
        expect(controller.offset, greaterThan(before + 2000));
      }
      await tester.pump(const Duration(seconds: 2)); // handle fades away
      await tester.runAsync(() => app.lock());
      await tester.pumpWidget(const SizedBox());
    }
  });
}
