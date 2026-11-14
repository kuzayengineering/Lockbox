// Gesture tests for the photo viewer: pinch must zoom (not swipe), and a
// one-finger swipe must still move to the next photo.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lockbox/core/crypto.dart';
import 'package:lockbox/core/models.dart';
import 'package:lockbox/core/vault.dart';
import 'package:lockbox/state/app_state.dart';
import 'package:lockbox/ui/file_reader.dart';
import 'package:lockbox/ui/lock_screen.dart';
import 'package:lockbox/ui/viewer_screen.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

void main() {
  late Directory tmp;
  late AppState app;

  setUp(() => tmp = Directory.systemTemp.createTempSync('lockbox_ui_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> openViewer(WidgetTester tester) async {
    await tester.runAsync(() async {
      final dir = p.join(tmp.path, 'vault');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      final jpg = File(p.join(tmp.path, 'a.jpg'))
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 400, height: 300)));
      for (var i = 0; i < 2; i++) {
        v.data.items.add(MediaItem(
          id: 'p$i',
          blobId: await v.storeFile(jpg.path),
          name: 'photo $i.jpg',
          kind: MediaKind.photo,
          mimeType: 'image/jpeg',
          sizeBytes: jpg.lengthSync(),
          addedAt: DateTime(2024, 1, i + 1),
        ));
      }
      await v.save();
      await v.lock();
      app = AppState()..vaultDir = dir;
      await app.unlock('pw');
    });
    final items = [...app.vault.data.items];
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(home: ViewerScreen(items: items, initialIndex: 0)),
    ));
    // Let the photo decrypt (runs in a background isolate).
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
  }

  double photoScale(WidgetTester tester) {
    final t = tester.widget<Transform>(find
        .ancestor(of: find.byType(Hero).first, matching: find.byType(Transform))
        .first);
    return t.transform.getMaxScaleOnAxis();
  }

  testWidgets('pinch zooms the photo instead of swiping', (tester) async {
    await openViewer(tester);
    expect(find.text('photo 0.jpg'), findsOneWidget);
    expect(photoScale(tester), 1.0);

    final c = tester.getCenter(find.byType(PageView));
    final a = await tester.startGesture(c - const Offset(30, 10), pointer: 1);
    final b = await tester.startGesture(c + const Offset(30, 10), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      // Fingers move apart, slightly diagonally (like a real pinch).
      await a.moveBy(const Offset(-12, -4));
      await b.moveBy(const Offset(12, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(photoScale(tester), greaterThan(2.0));
    expect(find.text('photo 0.jpg'), findsOneWidget, reason: 'must not change photo');
    expect(find.byType(ViewerScreen), findsOneWidget, reason: 'must not close');

    // Double-tap zooms back out.
    await tester.tap(find.byType(PageView));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(PageView));
    await tester.pumpAndSettle();
    expect(photoScale(tester), closeTo(1.0, 0.01));

    // Double-tap zooms in again.
    await tester.tap(find.byType(PageView));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(PageView));
    await tester.pumpAndSettle();
    expect(photoScale(tester), closeTo(2.5, 0.01));
    await tester.runAsync(app.lock);
  });

  testWidgets('vertical pinch with a slightly late second finger zooms', (tester) async {
    await openViewer(tester);
    final c = tester.getCenter(find.byType(PageView));
    // First finger lands and drifts a little before the second one lands.
    final a = await tester.startGesture(c - const Offset(10, 40), pointer: 1);
    await a.moveBy(const Offset(0, -6));
    await tester.pump(const Duration(milliseconds: 30));
    final b = await tester.startGesture(c + const Offset(10, 40), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await a.moveBy(const Offset(-2, -12));
      await b.moveBy(const Offset(2, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(find.byType(ViewerScreen), findsOneWidget, reason: 'must not close');
    expect(photoScale(tester), greaterThan(2.0));
    await tester.runAsync(app.lock);
  });

  testWidgets('documents open in the in-app reader', (tester) async {
    await tester.runAsync(() async {
      final dir = p.join(tmp.path, 'vault');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      Future<void> add(String id, String name, String mime, String text) async {
        final f = File(p.join(tmp.path, name))..writeAsStringSync(text);
        v.data.items.add(MediaItem(
          id: id,
          blobId: await v.storeFile(f.path),
          name: name,
          kind: MediaKind.file,
          mimeType: mime,
          sizeBytes: f.lengthSync(),
          addedAt: DateTime(2024, 1, id == 'a' ? 2 : 1),
        ));
      }

      await add('a', 'Trip notes.txt', 'text/plain', 'Day one: arrived at the lake.');
      await add('b', 'Plans.xyz', 'application/octet-stream', 'binary-ish');
      await v.save();
      await v.lock();
      app = AppState()..vaultDir = dir;
      await app.unlock('pw');
    });
    final items = [...app.vault.data.items];
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(home: ViewerScreen(items: items, initialIndex: 0)),
    ));
    await tester.pump();
    expect(find.text('Trip notes.txt'), findsWidgets);
    expect(find.textContaining('Text file'), findsOneWidget);

    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 400)); // page transition
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    expect(find.text('Day one: arrived at the lake.'), findsOneWidget);
    Navigator.of(tester.element(find.byType(FileReaderScreen))).pop();
    await tester.pumpAndSettle();

    // Unknown type: no reader, explains how to use it.
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Plans.xyz'), findsWidgets);
    expect(find.textContaining('can\'t show this kind of file'), findsOneWidget);
    expect(find.text('Open'), findsNothing);
    await tester.runAsync(app.lock);
  });

  testWidgets('top bar shows name and tags; tag list puts item tags first', (tester) async {
    await openViewer(tester);
    final v = app.vault;
    final zebra = v.createTag('Zebra');
    v.createTag('Apple');
    final mango = v.createTag('Mango');
    v.data.items.first.tagIds.addAll({zebra.id, mango.id});
    await tester.runAsync(() => app.changed());
    await tester.pump();
    expect(find.text('photo 0.jpg'), findsOneWidget);
    expect(find.text('Mango · Zebra'), findsOneWidget);

    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();
    final y = {
      for (final n in ['Mango', 'Zebra', 'Apple'])
        n: tester.getTopLeft(find.descendant(
                of: find.byType(FilterChip), matching: find.text(n)))
            .dx,
    };
    // Buttons in a row: item's tags first (left), then the rest.
    expect(y['Mango']! < y['Zebra']!, isTrue);
    expect(y['Zebra']! < y['Apple']!, isTrue, reason: 'tags on the item come first');
    bool selected(String n) => tester
        .widget<FilterChip>(find.ancestor(of: find.text(n), matching: find.byType(FilterChip)))
        .selected;
    expect(selected('Zebra'), isTrue);
    expect(selected('Apple'), isFalse);
    // Tapping a button switches the tag on.
    // Tap in real time so the encrypted save it triggers can finish.
    await tester.runAsync(() async {
      await tester.tap(find.text('Apple'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    expect(selected('Apple'), isTrue);
    expect(app.vault.data.items.first.tagIds.length, 3);
    await tester.runAsync(app.lock);
  });

  testWidgets('locks as soon as the app is hidden, but not during a picker', (tester) async {
    await openViewer(tester);
    final picker = Completer<void>();
    final during = app.external(() => picker.future);
    app.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(app.isUnlocked, isTrue, reason: 'own file picker is open');
    picker.complete();
    await tester.runAsync(() => during);
    app.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(app.isUnlocked, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('opens the chosen start folder after unlocking', (tester) async {
    await tester.runAsync(() async {
      final dir = p.join(tmp.path, 'sv');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      final f = v.createFolder('Work');
      v.data.settings.startFolderId = f.id;
      await v.save();
      await v.lock();
      app = AppState()..vaultDir = dir;
      await app.unlock('pw');
      expect(app.query.folderId, f.id);
      // Folder deleted -> back to Library.
      app.vault.deleteFolder(f.id);
      await app.vault.save();
      await app.lock();
      await app.unlock('pw');
      expect(app.query.folderId, isNull);
      await app.lock();
    });
  });

  testWidgets('lock screen focuses the passcode box (keyboard opens)', (tester) async {
    await tester.runAsync(() async {
      final dir = p.join(tmp.path, 'lv');
      final v = await Vault.create(dir, 'pw', params: KdfParams.testing);
      await v.lock();
      app = AppState()..vaultDir = dir;
    });
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app, child: const MaterialApp(home: LockScreen(setup: false))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    EditableTextState field() => tester.state<EditableTextState>(find.byType(EditableText));
    expect(field().widget.focusNode.hasFocus, isTrue);

    // Wrong passcode: focus comes back afterwards.
    await tester.enterText(find.byType(TextField), 'nope');
    await tester.runAsync(() async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Wrong passcode'), findsOneWidget);
    expect(field().widget.focusNode.hasFocus, isTrue);
  });

  testWidgets('one-finger swipe still moves to the next photo', (tester) async {
    await openViewer(tester);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('photo 1.jpg'), findsOneWidget);
    await tester.runAsync(app.lock);
  });
}
