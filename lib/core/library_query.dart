// Sorting and filtering of library items.

import 'models.dart';

enum SortField { dateTaken, dateAdded, duration, size, name, resolution }

extension SortFieldLabel on SortField {
  String get label => switch (this) {
        SortField.dateTaken => 'Date taken',
        SortField.dateAdded => 'Date added',
        SortField.duration => 'Video / audio length',
        SortField.size => 'File size',
        SortField.name => 'Name',
        SortField.resolution => 'Resolution',
      };

  bool get isDate => this == SortField.dateTaken || this == SortField.dateAdded;
}

enum TagMatch { any, all }

/// A complete description of what the library grid should show.
/// Every filter is optional; filters combine with AND.
class LibraryQuery {
  const LibraryQuery({
    this.folderId,
    this.includeSubfolders = true,
    this.kinds = const {},
    this.tagIds = const {},
    this.tagMatch = TagMatch.any,
    this.untaggedOnly = false,
    this.favoritesOnly = false,
    this.hdrOnly = false,
    this.highFrameRateOnly = false,
    this.minDurationMs,
    this.maxDurationMs,
    this.minSizeBytes,
    this.maxSizeBytes,
    this.takenAfter,
    this.takenBefore,
    this.text = '',
    this.sort = SortField.dateTaken,
    this.descending = true,
  });

  /// Only items in this folder (null = whole library).
  final String? folderId;
  final bool includeSubfolders;

  /// Empty = all kinds.
  final Set<MediaKind> kinds;
  final Set<String> tagIds;
  final TagMatch tagMatch;
  final bool untaggedOnly;
  final bool favoritesOnly;
  final bool hdrOnly;

  /// 50 fps or more.
  final bool highFrameRateOnly;
  final int? minDurationMs;
  final int? maxDurationMs;
  final int? minSizeBytes;
  final int? maxSizeBytes;
  final DateTime? takenAfter;
  final DateTime? takenBefore;

  /// Case-insensitive search in names, notes and tag names.
  final String text;
  final SortField sort;
  final bool descending;

  /// Number of active filters (not counting folder, search and sort).
  int get activeFilterCount => [
        kinds.isNotEmpty,
        tagIds.isNotEmpty,
        untaggedOnly,
        favoritesOnly,
        hdrOnly,
        highFrameRateOnly,
        minDurationMs != null || maxDurationMs != null,
        minSizeBytes != null || maxSizeBytes != null,
        takenAfter != null || takenBefore != null,
      ].where((x) => x).length;

  LibraryQuery copyWith({
    Object? folderId = _keep,
    bool? includeSubfolders,
    Set<MediaKind>? kinds,
    Set<String>? tagIds,
    TagMatch? tagMatch,
    bool? untaggedOnly,
    bool? favoritesOnly,
    bool? hdrOnly,
    bool? highFrameRateOnly,
    Object? minDurationMs = _keep,
    Object? maxDurationMs = _keep,
    Object? minSizeBytes = _keep,
    Object? maxSizeBytes = _keep,
    Object? takenAfter = _keep,
    Object? takenBefore = _keep,
    String? text,
    SortField? sort,
    bool? descending,
  }) =>
      LibraryQuery(
        folderId: folderId == _keep ? this.folderId : folderId as String?,
        includeSubfolders: includeSubfolders ?? this.includeSubfolders,
        kinds: kinds ?? this.kinds,
        tagIds: tagIds ?? this.tagIds,
        tagMatch: tagMatch ?? this.tagMatch,
        untaggedOnly: untaggedOnly ?? this.untaggedOnly,
        favoritesOnly: favoritesOnly ?? this.favoritesOnly,
        hdrOnly: hdrOnly ?? this.hdrOnly,
        highFrameRateOnly: highFrameRateOnly ?? this.highFrameRateOnly,
        minDurationMs: minDurationMs == _keep
            ? this.minDurationMs
            : minDurationMs as int?,
        maxDurationMs: maxDurationMs == _keep
            ? this.maxDurationMs
            : maxDurationMs as int?,
        minSizeBytes:
            minSizeBytes == _keep ? this.minSizeBytes : minSizeBytes as int?,
        maxSizeBytes:
            maxSizeBytes == _keep ? this.maxSizeBytes : maxSizeBytes as int?,
        takenAfter:
            takenAfter == _keep ? this.takenAfter : takenAfter as DateTime?,
        takenBefore:
            takenBefore == _keep ? this.takenBefore : takenBefore as DateTime?,
        text: text ?? this.text,
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
      );

  /// Same folder, search and sort, but no filters.
  LibraryQuery clearFilters() => LibraryQuery(
        folderId: folderId,
        includeSubfolders: includeSubfolders,
        text: text,
        sort: sort,
        descending: descending,
      );

  /// Applies the query. [folderScope] must contain the ids of the folder and
  /// (if [includeSubfolders]) all its descendants; pass null when
  /// [folderId] is null.
  List<MediaItem> apply(
    Iterable<MediaItem> items, {
    Set<String>? folderScope,
    Map<String, Tag> tagsById = const {},
  }) {
    final needle = text.trim().toLowerCase();
    final result = items.where((i) {
      if (folderId != null) {
        final scope = folderScope ?? {folderId!};
        if (!scope.contains(i.folderId)) return false;
      }
      if (kinds.isNotEmpty && !kinds.contains(i.kind)) return false;
      if (favoritesOnly && !i.favorite) return false;
      if (untaggedOnly && i.tagIds.isNotEmpty) return false;
      if (tagIds.isNotEmpty) {
        final ok = tagMatch == TagMatch.all
            ? tagIds.every(i.tagIds.contains)
            : tagIds.any(i.tagIds.contains);
        if (!ok) return false;
      }
      if (hdrOnly && !i.hdr.isHdr) return false;
      if (highFrameRateOnly && !i.isHighFrameRate) return false;
      if (minDurationMs != null || maxDurationMs != null) {
        final d = i.durationMs;
        if (d == null) return false;
        if (minDurationMs != null && d < minDurationMs!) return false;
        if (maxDurationMs != null && d > maxDurationMs!) return false;
      }
      if (minSizeBytes != null && i.sizeBytes < minSizeBytes!) return false;
      if (maxSizeBytes != null && i.sizeBytes > maxSizeBytes!) return false;
      if (takenAfter != null && i.mediaDate.isBefore(takenAfter!)) {
        return false;
      }
      if (takenBefore != null && !i.mediaDate.isBefore(takenBefore!)) {
        return false;
      }
      if (needle.isNotEmpty) {
        final hay = StringBuffer(i.name.toLowerCase());
        if (i.note != null) hay.write(' ${i.note!.toLowerCase()}');
        for (final t in i.tagIds) {
          final tag = tagsById[t];
          if (tag != null) hay.write(' ${tag.name.toLowerCase()}');
        }
        if (!hay.toString().contains(needle)) return false;
      }
      return true;
    }).toList();

    int cmp(MediaItem a, MediaItem b) {
      final c = switch (sort) {
        SortField.dateTaken => a.mediaDate.compareTo(b.mediaDate),
        SortField.dateAdded => a.addedAt.compareTo(b.addedAt),
        SortField.duration => (a.durationMs ?? -1).compareTo(b.durationMs ?? -1),
        SortField.size => a.sizeBytes.compareTo(b.sizeBytes),
        SortField.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        SortField.resolution => a.pixelCount.compareTo(b.pixelCount),
      };
      // Stable tie-break so the order never "jumps".
      final r = c != 0 ? c : a.addedAt.compareTo(b.addedAt);
      return descending ? -r : r;
    }

    result.sort(cmp);
    return result;
  }
}

const Object _keep = Object();
