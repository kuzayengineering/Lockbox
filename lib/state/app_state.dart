// The app's central state: which vault is open, what the library grid shows,
// selection, background tasks and auto-lock.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/backup.dart';
import '../core/crypto.dart' show randomId;
import '../core/library_query.dart';
import '../core/media_server.dart';
import '../core/models.dart';
import '../core/vault.dart';
import '../platform/native.dart';
import '../platform/player.dart';
import 'importer.dart';

enum Phase { loading, setup, locked, unlocked }

enum RestoreDestination { original, defaultFolder, chooseFolder }

class TaskProgress {
  const TaskProgress(this.label, {this.done = 0, this.total = 0});
  final String label;
  final int done;
  final int total;
  double? get fraction => total <= 0 ? null : done / total;
}

class RestoreResult {
  int restored = 0;
  final failures = <String, String>{};
  final locations = <String>{};
  bool cancelled = false;
}

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState() {
    WidgetsBinding.instance.addObserver(this);
  }

  Phase phase = Phase.loading;
  String? vaultDir;
  Vault? _vault;
  MediaServer? _server;
  MediaPlayer? _player;

  /// Progress of the current long task (import, restore, backup), if any.
  final task = ValueNotifier<TaskProgress?>(null);

  Vault get vault => _vault!;
  bool get isUnlocked => _vault != null && !_vault!.isLocked;
  VaultSettings get settings => vault.data.settings;

  // ----------------------------------------------------------- startup

  Future<File> get _configFile async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'config.json'));

  Future<void> init() async {
    if (Native.isAndroid) {
      vaultDir = p.join((await getApplicationSupportDirectory()).path, 'vault');
    } else {
      try {
        final cfg = await _configFile;
        if (cfg.existsSync()) {
          vaultDir = (jsonDecode(await cfg.readAsString()) as Map)['vaultDir']
              as String?;
        }
      } catch (_) {}
    }
    phase = vaultDir != null && Vault.existsAt(vaultDir!)
        ? Phase.locked
        : Phase.setup;
    notifyListeners();
  }

  /// Suggested vault location on Windows.
  Future<String> defaultVaultDir() async {
    if (Native.isAndroid) {
      return p.join((await getApplicationSupportDirectory()).path, 'vault');
    }
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'Lockbox Vault');
  }

  Future<void> _rememberVaultDir(String dir) async {
    vaultDir = dir;
    if (Native.isAndroid) return;
    final cfg = await _configFile;
    await cfg.parent.create(recursive: true);
    await cfg.writeAsString(jsonEncode({'vaultDir': dir}));
  }

  /// Windows: switch to a different existing vault folder.
  Future<bool> useExistingVault(String dir) async {
    if (!Vault.existsAt(dir)) return false;
    await _rememberVaultDir(dir);
    phase = Phase.locked;
    notifyListeners();
    return true;
  }

  Future<void> createVault(String passphrase, {String? dir}) async {
    final d = dir ?? await defaultVaultDir();
    final v = await Vault.create(d, passphrase);
    await _rememberVaultDir(d);
    await _opened(v);
  }

  /// Throws [WrongPassphraseException] on a bad passphrase.
  Future<void> unlock(String passphrase) async {
    final v = await Vault.open(vaultDir!, passphrase);
    await _opened(v);
  }

  Future<void> _opened(Vault v) async {
    _vault = v;
    // One-time clean-up of tags like "PXL_2026110612030045" that the first
    // version of the file-name rule created.
    if (v.data.settings.tagRulesVersion < 1) {
      v.removeInvalidAutoTags();
      v.data.settings.tagRulesVersion = 1;
      await v.save();
    }
    if (!Native.isAndroid) {
      _server = await MediaServer.start(v.directory, v.masterKey.bytes);
    }
    selection.clear();
    query = LibraryQuery(sort: SortField.dateTaken);
    _invalidate();
    phase = Phase.unlocked;
    notifyListeners();
  }

  Future<void> lock() async {
    if (_vault == null) return;
    final v = _vault!;
    _vault = null;
    await _player?.dispose();
    _player = null;
    await _server?.stop();
    _server = null;
    _thumbs.clear();
    _thumbLoads.clear();
    selection.clear();
    _results = null;
    await v.lock();
    phase = Phase.locked;
    notifyListeners();
  }

  /// The shared video/audio player (created on first use).
  MediaPlayer get player =>
      _player ??= MediaPlayer.create(vault, server: _server);

  // ----------------------------------------------------------- auto-lock

  DateTime? _backgroundSince;
  int _externalActivity = 0;

  /// Runs [action] (e.g. a system file picker) without auto-locking while
  /// the other screen is open.
  Future<T> external<T>(Future<T> Function() action) async {
    _externalActivity++;
    try {
      return await action();
    } finally {
      _externalActivity--;
      _backgroundSince = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isUnlocked || _externalActivity > 0) return;
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _backgroundSince ??= DateTime.now();
        _player?.pause();
        if (settings.autoLockSeconds == 0) lock();
      case AppLifecycleState.resumed:
        final since = _backgroundSince;
        _backgroundSince = null;
        if (since != null &&
            DateTime.now().difference(since).inSeconds >=
                settings.autoLockSeconds) {
          lock();
        }
      default:
        break;
    }
  }

  // ----------------------------------------------------------- library

  LibraryQuery query = const LibraryQuery();
  List<MediaItem>? _results;
  final selection = <String>{};

  List<MediaItem> get results {
    if (_results != null) return _results!;
    final v = vault;
    final scope = query.folderId == null
        ? null
        : (query.includeSubfolders
            ? v.folderAndDescendants(query.folderId!)
            : {query.folderId!});
    return _results = query.apply(v.data.items,
        folderScope: scope, tagsById: tagsById);
  }

  Map<String, Tag> get tagsById => {for (final t in vault.data.tags) t.id: t};
  Map<String, Folder> get foldersById =>
      {for (final f in vault.data.folders) f.id: f};

  void _invalidate() => _results = null;

  void setQuery(LibraryQuery q) {
    query = q;
    _invalidate();
    notifyListeners();
  }

  /// Call after changing items/folders/tags directly.
  Future<void> changed({bool save = true}) async {
    _invalidate();
    notifyListeners();
    if (save) await vault.save();
  }

  void toggleSelect(String id) {
    selection.contains(id) ? selection.remove(id) : selection.add(id);
    notifyListeners();
  }

  void selectAll() {
    selection.addAll(results.map((i) => i.id));
    notifyListeners();
  }

  void clearSelection() {
    selection.clear();
    notifyListeners();
  }

  List<MediaItem> get selectedItems =>
      vault.data.items.where((i) => selection.contains(i.id)).toList();

  Future<void> setFavorite(Iterable<MediaItem> items, bool fav) async {
    for (final i in items) {
      i.favorite = fav;
    }
    await changed();
  }

  Future<void> addTag(Iterable<MediaItem> items, String tagId) async {
    for (final i in items) {
      i.tagIds.add(tagId);
    }
    await changed();
  }

  Future<void> removeTag(Iterable<MediaItem> items, String tagId) async {
    for (final i in items) {
      i.tagIds.remove(tagId);
    }
    await changed();
  }

  Future<void> moveTo(Iterable<MediaItem> items, String? folderId) async {
    for (final i in items) {
      i.folderId = folderId;
    }
    await changed();
  }

  Future<void> rename(MediaItem item, String name) async {
    item.name = name;
    await changed();
  }

  Future<void> deleteItems(Iterable<String> ids) async {
    final set = ids.toSet();
    for (final id in set) {
      _thumbs.remove(id);
    }
    selection.removeAll(set);
    await vault.deleteItems(set);
    await changed(save: false);
  }

  /// Fills in a missing duration once the player knows it.
  Future<void> learnDuration(MediaItem item, Duration d) async {
    if (item.durationMs == null && d > Duration.zero) {
      item.durationMs = d.inMilliseconds;
      await changed();
    }
  }

  // ----------------------------------------------------------- thumbnails

  final _thumbs = <String, Uint8List?>{}; // insertion-ordered = LRU
  final _thumbLoads = <String, Future<Uint8List?>>{};
  static const _thumbCacheSize = 600;

  Uint8List? cachedThumb(MediaItem i) {
    final t = _thumbs.remove(i.id);
    if (t != null) _thumbs[i.id] = t; // mark recently used
    return t;
  }

  Future<Uint8List?> thumbnail(MediaItem item) {
    if (_thumbs.containsKey(item.id)) return Future.value(cachedThumb(item));
    return _thumbLoads[item.id] ??= () async {
      final v = _vault;
      final bytes = v == null ? null : await v.readThumbnail(item);
      _thumbLoads.remove(item.id);
      if (_vault != v) return null; // locked meanwhile
      _thumbs[item.id] = bytes;
      while (_thumbs.length > _thumbCacheSize) {
        _thumbs.remove(_thumbs.keys.first);
      }
      return bytes;
    }();
  }

  // ----------------------------------------------------------- import

  Future<ImportResult> importFiles(List<PickedFile> files,
      {required bool deleteOriginals}) async {
    task.value = TaskProgress('Adding ${files.length} file(s)…', total: files.length);
    try {
      return await external(() => Importer(vault).run(
            files,
            deleteOriginals: deleteOriginals,
            folderId: query.folderId,
            onProgress: (d, t, name) {
              task.value = TaskProgress('Encrypting $name', done: d, total: t);
              changed(save: false); // show items as they arrive
            },
          ));
    } finally {
      task.value = null;
      await changed(save: false);
    }
  }

  // ----------------------------------------------------------- save frame

  /// Saves the paused frame of [video] as a photo in the "Screenshots"
  /// folder inside Lockbox. It is dated like the source video (plus the
  /// moment in the video) and gets the same tags.
  Future<MediaItem?> saveFrame(MediaItem video, Duration position) async {
    final jpeg = await _capture(video, position);
    if (jpeg == null || jpeg.isEmpty) return null;
    final v = vault;
    final folder = v.topFolderNamed('Screenshots');
    final blobId = await v.storeBytes(jpeg);
    final thumb = await photoThumbnail(jpeg);
    final dims = await imageSize(jpeg);
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${two(position.inMinutes)}m${two(position.inSeconds % 60)}s';
    final base = video.name.contains('.')
        ? video.name.substring(0, video.name.lastIndexOf('.'))
        : video.name;
    final item = MediaItem(
      id: randomId(8),
      blobId: blobId,
      thumbId: thumb == null ? null : await v.storeThumbnail(thumb),
      name: '$base frame $stamp.jpg',
      kind: MediaKind.photo,
      mimeType: 'image/jpeg',
      sizeBytes: jpeg.length,
      addedAt: DateTime.now(),
      createdAt: video.mediaDate.add(position),
      width: dims?.$1,
      height: dims?.$2,
      folderId: folder.id,
      tagIds: {...video.tagIds},
      note: 'Frame at ${formatClock(position)} of “${video.name}”',
    );
    v.data.items.add(item);
    await changed();
    return item;
  }

  final _thumbFixing = <String>{};

  /// Frame grabs run one at a time: two at once compete for the video
  /// decoder, which made the first "Save frame" fail.
  Future<void> _captureQueue = Future.value();

  Future<Uint8List?> _capture(MediaItem video, Duration position,
      {bool allowInterrupt = true}) {
    final next = _captureQueue.then((_) =>
        player.captureFrame(video, position, allowInterrupt: allowInterrupt));
    _captureQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Gives a video without a thumbnail one, taken from the playing video.
  Future<void> thumbnailFromPlayback(MediaItem video, Duration position) async {
    if (video.thumbId != null || !_thumbFixing.add(video.id)) return;
    try {
      final jpeg = await _capture(video, position, allowInterrupt: false);
      if (jpeg == null || jpeg.isEmpty) return;
      final thumb = await photoThumbnail(jpeg);
      if (thumb == null || !isUnlocked) return;
      video.thumbId = await vault.storeThumbnail(thumb);
      _thumbs.remove(video.id);
      await changed();
    } catch (_) {
      // try again next time it's played
    } finally {
      _thumbFixing.remove(video.id);
    }
  }

  static String formatClock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0
        ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
        : '${d.inMinutes}:${two(d.inSeconds % 60)}';
  }

  // ----------------------------------------------------------- restore

  /// Where restored files go when no default is set in Settings.
  String get builtInRestoreLabel => Native.isAndroid
      ? 'Pictures, Movies or Music › Lockbox'
      : _windowsDefaultRestoreDir;

  String get _windowsDefaultRestoreDir => p.join(
      Platform.environment['USERPROFILE'] ?? '.', 'Pictures', 'Lockbox Restored');

  String get defaultRestoreLabel =>
      settings.restoreFolderLabel ?? builtInRestoreLabel;

  /// Takes files out of Lockbox back into normal storage.
  Future<RestoreResult> restore(
    List<MediaItem> items,
    RestoreDestination dest, {
    required bool keepCopy,
  }) async {
    final r = RestoreResult();
    String? chosen;
    if (dest == RestoreDestination.chooseFolder) {
      chosen = await external(() => Native.pickFolder(title: 'Restore to…'));
      if (chosen == null) return r..cancelled = true;
    }
    final done = <String>[];
    task.value = TaskProgress('Restoring…', total: items.length);
    try {
      for (var n = 0; n < items.length; n++) {
        final item = items[n];
        task.value = TaskProgress('Restoring ${item.name}', done: n, total: items.length);
        try {
          final where = await _restoreOne(item, dest, chosen);
          r.locations.add(where);
          r.restored++;
          done.add(item.id);
        } catch (e) {
          r.failures[item.name] = e.toString();
        }
      }
      if (!keepCopy && done.isNotEmpty) await deleteItems(done);
    } finally {
      task.value = null;
    }
    return r;
  }

  Future<String> _restoreOne(
      MediaItem item, RestoreDestination dest, String? chosen) async {
    final s = settings;
    if (Native.isAndroid) {
      String? folder;
      String? rel;
      switch (dest) {
        case RestoreDestination.original:
          rel = item.originalLocation;
          if (rel == null) folder = s.restoreFolder;
        case RestoreDestination.defaultFolder:
          folder = s.restoreFolder;
        case RestoreDestination.chooseFolder:
          folder = chosen;
      }
      final key = await vault.fileKeyFor(item);
      try {
        return await external(() => Native.restoreFromVaultAndroid(
              blobPath: vault.blobPath(item.blobId),
              key: key,
              name: item.name,
              mime: item.mimeType,
              kind: item.kind.name,
              relativePath: rel,
              folder: folder,
            ));
      } finally {
        key.fillRange(0, key.length, 0);
      }
    }
    final defaultDir = s.restoreFolder ?? _windowsDefaultRestoreDir;
    final dir = switch (dest) {
      RestoreDestination.original => (item.originalLocation != null &&
              Directory(item.originalLocation!).existsSync())
          ? item.originalLocation!
          : defaultDir,
      RestoreDestination.defaultFolder => defaultDir,
      RestoreDestination.chooseFolder => chosen!,
    };
    await Directory(dir).create(recursive: true);
    await vault.exportItem(item, Native.uniquePath(dir, item.name));
    return dir;
  }

  Future<bool> chooseDefaultRestoreFolder() async {
    final f = await external(
        () => Native.pickFolder(title: 'Default restore folder', persist: true));
    if (f == null) return false;
    settings
      ..restoreFolder = f
      ..restoreFolderLabel = Native.folderLabel(f);
    await changed();
    return true;
  }

  Future<void> clearDefaultRestoreFolder() async {
    settings
      ..restoreFolder = null
      ..restoreFolderLabel = null;
    await changed();
  }

  // ----------------------------------------------------------- backups

  /// Writes the whole vault into one .lockbox file chosen by the user.
  /// Returns false if cancelled.
  Future<bool> backUp() async {
    final name =
        'Lockbox backup ${DateFormat('yyyy-MM-dd HHmm').format(DateTime.now())}.$kBackupExtension';
    final dest = await external(
        () => Native.createForWrite(name, 'application/octet-stream'));
    if (dest == null) return false;
    await vault.save();
    task.value = const TaskProgress('Backing up…');
    try {
      await external(() => writeBackup(
            vaultDir: vault.directory,
            relativePaths: vault.allFilesRelative(),
            destPath: dest.path,
            atomic: dest.handle == null,
            onProgress: (d, t) =>
                task.value = TaskProgress('Backing up…', done: d, total: t),
          ));
    } finally {
      await Native.close(dest);
      task.value = null;
    }
    return true;
  }

  /// Restores a backup into a new, empty vault (first-run screen).
  /// Returns false if cancelled.
  Future<bool> restoreFromBackup({String? intoDir}) async {
    final picked = await external(Native.pickFile);
    if (picked == null) return false;
    final dir = intoDir ?? await defaultVaultDir();
    final opened = await Native.open(picked);
    task.value = const TaskProgress('Restoring backup…');
    try {
      if (Directory(dir).existsSync() && !Vault.existsAt(dir)) {
        // Leftovers from an earlier failed attempt.
        final d = Directory(dir);
        if (d.listSync().isNotEmpty) await d.delete(recursive: true);
      }
      await restoreBackup(
        backupPath: opened.path,
        destDir: dir,
        onProgress: (d, t) =>
            task.value = TaskProgress('Restoring backup…', done: d, total: t),
      );
    } catch (_) {
      try {
        if (!Vault.existsAt(dir)) await Directory(dir).delete(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      await Native.close(opened);
      task.value = null;
    }
    await _rememberVaultDir(dir);
    phase = Phase.locked;
    notifyListeners();
    return true;
  }

  // ----------------------------------------------------------- settings

  Future<void> updateSettings(void Function(VaultSettings s) change) async {
    change(settings);
    await changed();
  }

  Future<bool> changePassphrase(String current, String next) async {
    if (!await vault.verifyPassphrase(current)) return false;
    await vault.changePassphrase(next);
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
