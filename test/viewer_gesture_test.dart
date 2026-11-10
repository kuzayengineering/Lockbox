// Gesture tests for the photo viewer: pinch must zoom (not swipe), and a
// one-finger swipe must still move to the next photo.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lockbox/core/crypto.dart';
import 'package:lockbox/core/models.dart';
import 'package:lockbox/core/vault.dart';
import 'package:lockbox/state/app_state.dart';
import 'package:lockbox/ui/file_reader.dart';
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
    expect(find.text('1 / 2'), findsOneWidget);
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
    expect(find.text('1 / 2'), findsOneWidget, reason: 'must not change photo');
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
    expect(find.text('Trip notes.txt'), findsOneWidget);
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
    expect(find.text('Plans.xyz'), findsOneWidget);
    expect(find.textContaining('can\'t show this kind of file'), findsOneWidget);
    expect(find.text('Open'), findsNothing);
    await tester.runAsync(app.lock);
  });

  testWidgets('one-finger swipe still moves to the next photo', (tester) async {
    await openViewer(tester);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.runAsync(app.lock);
  });
}
