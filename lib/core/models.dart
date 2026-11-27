// Data model of a vault's library: media items, folders and tags.
//
// The whole library is kept in memory while the vault is unlocked and saved
// (encrypted) to the vault's index file. Everything here is plain data.

enum MediaKind { photo, video, audio, file }

/// High dynamic range format of a video.
enum HdrFormat { none, hlg, hdr10, dolbyVision, ultraHdr }

extension HdrFormatLabel on HdrFormat {
  String get label => switch (this) {
        HdrFormat.none => 'SDR',
        HdrFormat.hlg => 'HLG',
        HdrFormat.hdr10 => 'HDR10',
        HdrFormat.dolbyVision => 'Dolby Vision',
        HdrFormat.ultraHdr => 'Ultra HDR',
      };
  bool get isHdr => this != HdrFormat.none;
}

class MediaItem {
  MediaItem({
    required this.id,
    required this.blobId,
    required this.name,
    required this.kind,
    required this.mimeType,
    required this.sizeBytes,
    required this.addedAt,
    this.thumbId,
    this.createdAt,
    this.durationMs,
    this.width,
    this.height,
    this.fps,
    this.hdr = HdrFormat.none,
    this.codec,
    this.folderId,
    Set<String>? tagIds,
    this.favorite = false,
    this.note,
    this.originalLocation,
  }) : tagIds = tagIds ?? <String>{};

  final String id;

  /// Name of the encrypted original inside the vault's `blobs` folder.
  final String blobId;

  /// Name of the encrypted thumbnail inside `thumbs`, if one was made.
  String? thumbId;

  /// Original file name (only stored inside the encrypted index).
  String name;
  final MediaKind kind;
  final String mimeType;
  final int sizeBytes;

  /// When the file was added to Lockbox.
  final DateTime addedAt;

  /// When the photo/video was taken, from the file's metadata if available.
  DateTime? createdAt;

  int? durationMs;
  int? width;
  int? height;
  double? fps;
  HdrFormat hdr;
  String? codec;

  /// Folder that holds this item; null = top level ("Library").
  String? folderId;
  final Set<String> tagIds;
  bool favorite;
  String? note;

  /// Where the file was before it was added, so it can be restored there.
  /// Android: shared-storage folder such as "DCIM/Camera/".
  /// Windows: the full folder path.
  String? originalLocation;

  /// Media date used for "date taken" sorting: falls back to date added.
  DateTime get mediaDate => createdAt ?? addedAt;

  int get pixelCount => (width ?? 0) * (height ?? 0);

  bool get isHighFrameRate => (fps ?? 0) >= 50;

  String get extension {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'blob': blobId,
        if (thumbId != null) 'thumb': thumbId,
        'name': name,
        'kind': kind.name,
        'mime': mimeType,
        'size': sizeBytes,
        'added': addedAt.toUtc().millisecondsSinceEpoch,
        if (createdAt != null)
          'created': createdAt!.toUtc().millisecondsSinceEpoch,
        if (durationMs != null) 'dur': durationMs,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (fps != null) 'fps': fps,
        if (hdr != HdrFormat.none) 'hdr': hdr.name,
        if (codec != null) 'codec': codec,
        if (folderId != null) 'folder': folderId,
        if (tagIds.isNotEmpty) 'tags': tagIds.toList(),
        if (favorite) 'fav': true,
        if (note != null) 'note': note,
        if (originalLocation != null) 'orig': originalLocation,
      };

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['id'] as String,
        blobId: j['blob'] as String,
        thumbId: j['thumb'] as String?,
        name: j['name'] as String,
        kind: MediaKind.values.byName(j['kind'] as String),
        mimeType: j['mime'] as String,
        sizeBytes: j['size'] as int,
        addedAt: DateTime.fromMillisecondsSinceEpoch(j['added'] as int,
                isUtc: true)
            .toLocal(),
        createdAt: j['created'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(j['created'] as int,
                    isUtc: true)
                .toLocal(),
        durationMs: j['dur'] as int?,
        width: j['w'] as int?,
        height: j['h'] as int?,
        fps: (j['fps'] as num?)?.toDouble(),
        hdr: j['hdr'] == null
            ? HdrFormat.none
            : HdrFormat.values.byName(j['hdr'] as String),
        codec: j['codec'] as String?,
        folderId: j['folder'] as String?,
        tagIds: {...?(j['tags'] as List?)?.cast<String>()},
        favorite: j['fav'] == true,
        note: j['note'] as String?,
        originalLocation: j['orig'] as String?,
      );
}

class Folder {
  Folder({required this.id, required this.name, this.parentId});
  final String id;
  String name;
  String? parentId;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, if (parentId != null) 'parent': parentId};

  factory Folder.fromJson(Map<String, dynamic> j) => Folder(
      id: j['id'] as String,
      name: j['name'] as String,
      parentId: j['parent'] as String?);
}

class Tag {
  Tag({required this.id, required this.name, this.color = 0xFF5C6BC0});
  final String id;
  String name;

  /// ARGB colour value.
  int color;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color};

  factory Tag.fromJson(Map<String, dynamic> j) => Tag(
      id: j['id'] as String,
      name: j['name'] as String,
      color: (j['color'] as int?) ?? 0xFF5C6BC0);
}

/// User preferences stored inside the encrypted index.
/// [VaultSettings.startFolderId] value meaning "open the Folders page".
const kStartFoldersPage = '@folders';

class VaultSettings {
  VaultSettings({
    this.autoLockSeconds = 30,
    this.gridColumns = 4,
    this.loopVideos = false,
    this.muteByDefault = false,
    this.restoreFolder,
    this.restoreFolderLabel,
    this.deleteOriginalsOnImport = true,
    this.keepCopyOnRestore = false,
    this.autoTagFromNames = true,
    this.tagRulesVersion = 0,
    this.hdrScanVersion = 0,
    this.saveFramesAsHeif = false,
    this.startFolderId,
    this.tagsInFiles = true,
    ViewPrefs? defaultView,
    Map<String, ViewPrefs>? folderViews,
  })  : defaultView = defaultView ?? ViewPrefs(columns: gridColumns),
        folderViews = folderViews ?? {};

  /// How the gallery looks when a folder has no view of its own.
  ViewPrefs defaultView;

  /// Folder id → that folder's own view (set by changing the view inside it).
  Map<String, ViewPrefs> folderViews;

  /// How long the app may be in the background before it locks.
  /// 0 = lock immediately.
  int autoLockSeconds;
  int gridColumns;
  bool loopVideos;
  bool muteByDefault;

  /// Default place restored files go (Android: folder access handle chosen
  /// in Settings; Windows: folder path). Null = Pictures/Movies/Music
  /// "Lockbox" folders.
  String? restoreFolder;
  String? restoreFolderLabel;

  /// "Move" files into Lockbox (delete the unprotected originals).
  bool deleteOriginalsOnImport;

  /// When restoring, keep the file in Lockbox too.
  bool keepCopyOnRestore;

  /// Add tags from the words in a file's name when it is imported.
  bool autoTagFromNames;

  /// Which clean-up of automatic tags has already run (see AppState).
  int tagRulesVersion;

  /// Whether existing photos have been checked for Ultra HDR.
  int hdrScanVersion;

  /// Save frames of HDR videos as 10-bit HDR HEIF instead of JPEG.
  bool saveFramesAsHeif;

  /// Folder shown first after unlocking (null = Library,
  /// [kStartFoldersPage] = the Folders page).
  String? startFolderId;

  /// Write a file's tags into its own metadata when restoring it (photos
  /// and videos), so they come back if the file is added again.
  bool tagsInFiles;

  Map<String, dynamic> toJson() => {
        'autoLock': autoLockSeconds,
        'cols': gridColumns,
        'loop': loopVideos,
        'mute': muteByDefault,
        if (restoreFolder != null) 'restoreDir': restoreFolder,
        if (restoreFolderLabel != null) 'restoreDirLabel': restoreFolderLabel,
        'delOrig': deleteOriginalsOnImport,
        'keepOnRestore': keepCopyOnRestore,
        'autoTag': autoTagFromNames,
        'tagRules': tagRulesVersion,
        'hdrScan': hdrScanVersion,
        'frameHeif': saveFramesAsHeif,
        if (startFolderId != null) 'startFolder': startFolderId,
        'tagsInFiles': tagsInFiles,
        'view': defaultView.toJson(),
        if (folderViews.isNotEmpty)
          'folderViews': {for (final e in folderViews.entries) e.key: e.value.toJson()},
      };

  factory VaultSettings.fromJson(Map<String, dynamic>? j) => VaultSettings(
        autoLockSeconds: (j?['autoLock'] as int?) ?? 30,
        gridColumns: ((j?['cols'] as int?) ?? 4).clamp(1, 6),
        loopVideos: (j?['loop'] as bool?) ?? false,
        muteByDefault: (j?['mute'] as bool?) ?? false,
        restoreFolder: j?['restoreDir'] as String?,
        restoreFolderLabel: j?['restoreDirLabel'] as String?,
        deleteOriginalsOnImport: (j?['delOrig'] as bool?) ?? true,
        keepCopyOnRestore: (j?['keepOnRestore'] as bool?) ?? false,
        autoTagFromNames: (j?['autoTag'] as bool?) ?? true,
        tagRulesVersion: (j?['tagRules'] as int?) ?? 0,
        hdrScanVersion: (j?['hdrScan'] as int?) ?? 0,
        saveFramesAsHeif: (j?['frameHeif'] as bool?) ?? false,
        startFolderId: j?['startFolder'] as String?,
        tagsInFiles: (j?['tagsInFiles'] as bool?) ?? true,
        defaultView: j?['view'] is Map
            ? ViewPrefs.fromJson((j!['view'] as Map).cast<String, dynamic>())
            : null,
        folderViews: {
          if (j?['folderViews'] is Map)
            for (final e in (j!['folderViews'] as Map).entries)
              if (e.value is Map)
                e.key as String: ViewPrefs.fromJson((e.value as Map).cast<String, dynamic>()),
        },
      );
}

/// Everything stored in the encrypted index file.
class LibraryData {
  LibraryData({
    List<MediaItem>? items,
    List<Folder>? folders,
    List<Tag>? tags,
    VaultSettings? settings,
    DateTime? createdAt,
  })  : items = items ?? [],
        folders = folders ?? [],
        tags = tags ?? [],
        settings = settings ?? VaultSettings(),
        createdAt = createdAt ?? DateTime.now();

  final List<MediaItem> items;
  final List<Folder> folders;
  final List<Tag> tags;
  final VaultSettings settings;
  final DateTime createdAt;

  static const int schemaVersion = 1;

  Map<String, dynamic> toJson() => {
        'schema': schemaVersion,
        'created': createdAt.toUtc().millisecondsSinceEpoch,
        'items': [for (final i in items) i.toJson()],
        'folders': [for (final f in folders) f.toJson()],
        'tags': [for (final t in tags) t.toJson()],
        'settings': settings.toJson(),
      };

  factory LibraryData.fromJson(Map<String, dynamic> j) => LibraryData(
        createdAt: j['created'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(j['created'] as int,
                    isUtc: true)
                .toLocal(),
        items: [
          for (final i in (j['items'] as List? ?? const []))
            MediaItem.fromJson((i as Map).cast<String, dynamic>())
        ],
        folders: [
          for (final f in (j['folders'] as List? ?? const []))
            Folder.fromJson((f as Map).cast<String, dynamic>())
        ],
        tags: [
          for (final t in (j['tags'] as List? ?? const []))
            Tag.fromJson((t as Map).cast<String, dynamic>())
        ],
        settings: VaultSettings.fromJson(
            (j['settings'] as Map?)?.cast<String, dynamic>()),
      );
}


// ------------------------------------------------------------- gallery view

enum ViewMode { grid, details }

/// Details that can be shown in the gallery.
enum ViewField {
  name('File name'),
  length('Length'),
  fps('Frame rate'),
  tags('Tags'),
  size('File size'),
  date('Date taken'),
  hdr('HDR badge');

  const ViewField(this.label);
  final String label;
}

/// How the gallery is laid out: grid or details list, how many per row,
/// and which details are shown.
class ViewPrefs {
  ViewPrefs({this.mode = ViewMode.grid, int columns = 4, Set<ViewField>? show})
      : columns = columns.clamp(1, 6),
        show = show ?? {ViewField.length, ViewField.fps, ViewField.hdr};

  ViewMode mode;
  int columns;
  Set<ViewField> show;

  bool shows(ViewField f) => show.contains(f);

  ViewPrefs copy() => ViewPrefs(mode: mode, columns: columns, show: {...show});

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'cols': columns,
        'show': [for (final f in show) f.name],
      };

  factory ViewPrefs.fromJson(Map<String, dynamic> j) => ViewPrefs(
        mode: j['mode'] == 'details' ? ViewMode.details : ViewMode.grid,
        columns: (j['cols'] as int?) ?? 4,
        show: j['show'] is List
            ? {
                for (final n in j['show'] as List)
                  for (final f in ViewField.values)
                    if (f.name == n) f
              }
            : null,
      );
}
