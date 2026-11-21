// Gallery view settings: Grid / Details, which details are shown, and
// per-folder views that are remembered.

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
  setUp(() => tmp = Directory.systemTemp.createTempSync('lockbox_view_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('older vaults keep their grid size as the default view', () {
    final s = VaultSettings.fromJson({'cols': 2});
    expect(s.defaultView.columns, 2);
    expect(s.defaultView.mode, ViewMode.grid);
    expect(s.folderViews, isEmpty);
  });

  test('view settings are saved and read back', () {
    final s = VaultSettings()
      ..defaultView = ViewPrefs(mode: ViewMode.details, show: {ViewField.name, ViewField.tags})
      ..folderViews['f1'] = ViewPrefs(columns: 3, show: {ViewField.size});
    final back = VaultSettings.fromJson(s.toJson());
    expect(back.defaultView.mode, ViewMode.details);
    expect(back.defaultView.show, {ViewField.name, ViewField.tags});
    expect(back.folderViews['f1']!.columns, 3);
    expect(back.folderViews['f1']!.show, {ViewField.size});
  });

  testWidgets('changing the view inside a folder affects only that folder', (tester) async {
    await tester.runAsync(() async {
      final dir = p.join(tmp.path, 'v');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      final work = v.createFolder('Work');
      final home = v.createFolder('Home');
      await v.save();
      await v.lock();
      final app = AppState()..vaultDir = dir;
      await app.unlock('pw');

      app.setQuery(app.query.copyWith(folderId: work.id));
      await app.updateView((x) => x.mode = ViewMode.details);
      expect(app.currentView.mode, ViewMode.details);
      expect(app.folderHasOwnView, isTrue);

      // Other folders and the Library are unchanged.
      app.setQuery(app.query.copyWith(folderId: home.id));
      expect(app.currentView.mode, ViewMode.grid);
      expect(app.folderHasOwnView, isFalse);

      // A change in the Library sets the default, which Home follows but Work doesn't.
      app.setQuery(app.query.copyWith(folderId: null));
      await app.updateView((x) => x.columns = 2);
      app.setQuery(app.query.copyWith(folderId: home.id));
      expect(app.currentView.columns, 2);

      // Remembered after locking.
      await app.lock();
      await app.unlock('pw');
      app.setQuery(app.query.copyWith(folderId: work.id));
      expect(app.currentView.mode, ViewMode.details);

      // "Use default view".
      await app.resetFolderView();
      expect(app.currentView.mode, ViewMode.grid);
      expect(app.currentView.columns, 2);

      // Deleting a folder forgets its view.
      await app.updateView((x) => x.mode = ViewMode.details);
      app.vault.deleteFolder(work.id);
      expect(app.settings.folderViews.containsKey(work.id), isFalse);
      await app.lock();
    });
  });

  testWidgets('details and roomy grid show the chosen details', (tester) async {
    late AppState app;
    await tester.runAsync(() async {
      final dir = p.join(tmp.path, 'w');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      final tag = v.tagNamed('Beach');
      v.data.items.add(MediaItem(
        id: 'a',
        blobId: 'none',
        name: 'Sunset walk.mp4',
        kind: MediaKind.video,
        mimeType: 'video/mp4',
        sizeBytes: 50 * 1024 * 1024,
        addedAt: DateTime(2026, 3, 3),
        durationMs: 75000,
        fps: 60,
        hdr: HdrFormat.hlg,
        tagIds: {tag.id},
      ));
      v.data.items.add(MediaItem(
        id: 'b',
        blobId: 'none',
        name: 'Voice memo.m4a',
        kind: MediaKind.audio,
        mimeType: 'audio/mp4',
        sizeBytes: 1000,
        addedAt: DateTime(2026, 3, 3),
        durationMs: 5000,
      ));
      v.data.settings.defaultView =
          ViewPrefs(mode: ViewMode.details, show: {...ViewField.values});
      await v.save();
      await v.lock();
      app = AppState()..vaultDir = dir;
      await app.unlock('pw');
    });
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app, child: const MaterialApp(home: LibraryScreen())));
    await tester.pump();
    expect(find.text('Sunset walk.mp4'), findsOneWidget);
    expect(find.text('Beach'), findsOneWidget);
    expect(find.textContaining('1:15 · 60 fps · 50.0 MB'), findsOneWidget);
    expect(find.text('HLG'), findsOneWidget);

    // Grid at 4 per row: no room for names.
    await tester.runAsync(() => app.updateView((x) {
          x.mode = ViewMode.grid;
          x.columns = 4;
        }));
    await tester.pump();
    expect(find.text('Sunset walk.mp4'), findsNothing);
    expect(find.text('1:15'), findsOneWidget);

    // Zoomed in to 2 per row: the name and tags appear on the thumbnail.
    await tester.runAsync(() => app.updateView((x) => x.columns = 2));
    await tester.pump();
    expect(find.text('Sunset walk.mp4'), findsOneWidget);
    expect(find.text('Beach'), findsOneWidget);

    // Length turned off.
    await tester.runAsync(() => app.updateView((x) => x.show.remove(ViewField.length)));
    await tester.pump();
    expect(find.text('1:15'), findsNothing);

    // Audio always shows its name: zoomed out, and with "File name" off.
    await tester.runAsync(() => app.updateView((x) {
          x.columns = 6;
          x.show.remove(ViewField.name);
        }));
    await tester.pump();
    expect(find.text('Voice memo.m4a'), findsOneWidget);
    expect(find.text('Sunset walk.mp4'), findsNothing);
    await tester.runAsync(() => app.updateView((x) => x.mode = ViewMode.details));
    await tester.pump();
    expect(find.text('Voice memo.m4a'), findsOneWidget);
    expect(find.text('Sunset walk.mp4'), findsNothing);

    await tester.runAsync(() => app.lock());
    await tester.pumpWidget(const SizedBox());
  });
}
