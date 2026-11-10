import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/library_query.dart';
import '../core/models.dart';
import '../platform/native.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'filter_sheet.dart';
import 'settings_screen.dart';
import 'viewer_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _searching = false;
  final _search = TextEditingController();

  // pinch-to-zoom on the grid
  final _pointers = <int, Offset>{};
  double? _pinchStart;
  int _pinchCols = 4;

  AppState get app => context.read<AppState>();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.isUnlocked) return const SizedBox.shrink();
    final wide = MediaQuery.of(context).size.width >= 900;
    final selecting = app.selection.isNotEmpty;
    final folder = app.query.folderId == null ? null : app.foldersById[app.query.folderId];
    final items = app.results;

    final scaffold = Scaffold(
      drawer: wide ? null : const Drawer(child: _Sidebar()),
      appBar: selecting ? _selectionBar(app) : _normalBar(app, folder),
      floatingActionButton: selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _import,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add'),
            ),
      body: Column(children: [
        const TaskBanner(),
        _FilterChips(query: app.query),
        Expanded(
          child: items.isEmpty
              ? _empty(app)
              : Listener(
                  onPointerDown: (e) => _pointers[e.pointer] = e.position,
                  onPointerMove: (e) => _onPointerMove(e, app),
                  onPointerUp: (e) => _endPointer(e.pointer, app),
                  onPointerCancel: (e) => _endPointer(e.pointer, app),
                  child: _Grid(items: items, columns: app.settings.gridColumns),
                ),
        ),
      ]),
    );
    if (!wide) return scaffold;
    return Row(children: [
      const SizedBox(width: 300, child: Material(child: _Sidebar())),
      const VerticalDivider(width: 1),
      Expanded(child: scaffold),
    ]);
  }

  // ----------------------------------------------------------- pinch zoom

  double _spread() {
    final pts = _pointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _onPointerMove(PointerMoveEvent e, AppState app) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length != 2) return;
    if (_pinchStart == null) {
      _pinchStart = _spread();
      _pinchCols = app.settings.gridColumns;
      return;
    }
    final ratio = _spread() / _pinchStart!;
    var cols = _pinchCols;
    if (ratio > 1.3) cols = _pinchCols - 1;
    if (ratio > 1.8) cols = _pinchCols - 2;
    if (ratio < 0.75) cols = _pinchCols + 1;
    if (ratio < 0.5) cols = _pinchCols + 2;
    cols = cols.clamp(1, 8);
    if (cols != app.settings.gridColumns) {
      app.settings.gridColumns = cols;
      app.changed(save: false);
    }
  }

  void _endPointer(int id, AppState app) {
    _pointers.remove(id);
    if (_pinchStart != null && _pointers.length < 2) {
      _pinchStart = null;
      app.changed();
    }
  }

  // ----------------------------------------------------------- app bars

  PreferredSizeWidget _normalBar(AppState app, Folder? folder) {
    final q = app.query;
    return AppBar(
      title: _searching
          ? TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                  hintText: 'Search names, tags, notes', border: InputBorder.none),
              onChanged: (v) => app.setQuery(q.copyWith(text: v)),
            )
          : Text(folder?.name ?? 'Library'),
      actions: [
        IconButton(
          tooltip: _searching ? 'Close search' : 'Search',
          icon: Icon(_searching ? Icons.close : Icons.search),
          onPressed: () {
            setState(() => _searching = !_searching);
            if (!_searching) {
              _search.clear();
              app.setQuery(q.copyWith(text: ''));
            }
          },
        ),
        PopupMenuButton<Object>(
          tooltip: 'Sort',
          icon: const Icon(Icons.sort),
          itemBuilder: (_) => [
            for (final f in SortField.values)
              CheckedPopupMenuItem(value: f, checked: q.sort == f, child: Text(f.label)),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(
                value: 'desc',
                checked: q.descending,
                child: Text(q.sort.isDate ? 'Newest first' : 'Largest / longest first')),
          ],
          onSelected: (v) {
            if (v is SortField) app.setQuery(q.copyWith(sort: v));
            if (v == 'desc') app.setQuery(q.copyWith(descending: !q.descending));
          },
        ),
        IconButton(
          tooltip: 'Filter',
          onPressed: () => showFilterSheet(context),
          icon: Badge(
            isLabelVisible: q.activeFilterCount > 0,
            label: Text('${q.activeFilterCount}'),
            child: const Icon(Icons.filter_list),
          ),
        ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'select':
                app.selectAll();
              case 'settings':
                Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
              case 'lock':
                app.lock();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'select', child: Text('Select all')),
            PopupMenuItem(value: 'settings', child: Text('Settings')),
            PopupMenuItem(value: 'lock', child: Text('Lock now')),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _selectionBar(AppState app) {
    final sel = app.selectedItems;
    final allFav = sel.isNotEmpty && sel.every((i) => i.favorite);
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: app.clearSelection),
      title: Text('${app.selection.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Tags',
          icon: const Icon(Icons.sell_outlined),
          onPressed: () => editTags(context, sel),
        ),
        IconButton(
          tooltip: 'Move to folder',
          icon: const Icon(Icons.drive_file_move_outline),
          onPressed: () async {
            final (ok, id) = await pickFolder(context);
            if (ok) {
              await app.moveTo(sel, id);
              app.clearSelection();
            }
          },
        ),
        IconButton(
          tooltip: allFav ? 'Unfavorite' : 'Favorite',
          icon: Icon(allFav ? Icons.favorite : Icons.favorite_border),
          onPressed: () => app.setFavorite(sel, !allFav),
        ),
        IconButton(
          tooltip: 'Restore to device',
          icon: const Icon(Icons.lock_open_outlined),
          onPressed: () async {
            await restoreItems(context, sel);
            app.clearSelection();
          },
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final ok = await confirm(context,
                title: 'Delete ${sel.length} item(s)?',
                message: 'They will be permanently erased from Lockbox. '
                    'This cannot be undone.',
                ok: 'Delete',
                danger: true);
            if (ok) await app.deleteItems(sel.map((i) => i.id));
          },
        ),
        IconButton(
          tooltip: 'Select all',
          icon: const Icon(Icons.select_all),
          onPressed: app.selectAll,
        ),
      ],
    );
  }

  Widget _empty(AppState app) {
    final filtered = app.query.activeFilterCount > 0 || app.query.text.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(filtered ? Icons.filter_alt_off_outlined : Icons.lock_outline,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(filtered ? 'Nothing matches these filters' : 'Your vault is empty',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            filtered
                ? 'Try removing some filters.'
                : 'Tap “Add” to move photos, videos, audio and any other files into Lockbox. '
                    'They are encrypted on this device.',
            textAlign: TextAlign.center,
          ),
          if (filtered) ...[
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: () => app.setQuery(app.query.clearFilters()),
                child: const Text('Clear filters')),
          ],
        ]),
      ),
    );
  }

  Future<void> _import() async {
    final files = await app.external(Native.pickMedia);
    if (files.isEmpty || !mounted) return;
    var delete = app.settings.deleteOriginalsOnImport;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Add ${files.length} file(s) to Lockbox'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            RadioGroup<bool>(
              groupValue: delete,
              onChanged: (v) => setS(() => delete = v ?? true),
              child: const Column(children: [
                RadioListTile<bool>(
                  value: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Move into Lockbox'),
                  subtitle: Text('Originals are deleted so only the protected copy remains'),
                ),
                RadioListTile<bool>(
                  value: false,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Copy into Lockbox'),
                  subtitle: Text('Originals stay where they are'),
                ),
              ]),
            ),
            if (app.settings.autoTagFromNames)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Words in file names will be added as tags.',
                    style: TextStyle(fontSize: 12)),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (go != true) return;
    if (delete != app.settings.deleteOriginalsOnImport) {
      app.settings.deleteOriginalsOnImport = delete;
    }
    final r = await app.importFiles(files, deleteOriginals: delete);
    if (!mounted) return;
    final parts = ['Added ${r.added}'];
    if (r.originalsKept > 0) {
      parts.add('${r.originalsKept} original(s) could not be deleted – remove them manually');
    }
    if (r.failures.isNotEmpty) parts.add('${r.failures.length} failed');
    snack(context, parts.join(' · '));
    if (r.failures.isNotEmpty) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Some files were not added'),
          content: SingleChildScrollView(
            child: Text(r.failures.entries.map((e) => '${e.key}: ${e.value}').join('\n\n')),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    }
  }
}

// ------------------------------------------------------------------- grid

class _Grid extends StatelessWidget {
  const _Grid({required this.items, required this.columns});
  final List<MediaItem> items;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final q = app.query;
    final sections = <(String?, List<int>)>[];
    if (q.sort.isDate) {
      final byMonth = columns >= 6;
      String? last;
      for (var i = 0; i < items.length; i++) {
        final d = q.sort == SortField.dateAdded ? items[i].addedAt : items[i].mediaDate;
        final label = byMonth ? _monthLabel(d) : _dayLabel(d);
        if (label != last) {
          sections.add((label, []));
          last = label;
        }
        sections.last.$2.add(i);
      }
    } else {
      sections.add((null, [for (var i = 0; i < items.length; i++) i]));
    }
    final gap = columns >= 6 ? 1.0 : 2.0;
    return Scrollbar(
      child: CustomScrollView(
        slivers: [
          for (final (label, idx) in sections) ...[
            if (label != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
                  child: Text(label, style: Theme.of(context).textTheme.titleSmall),
                ),
              ),
            SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns, mainAxisSpacing: gap, crossAxisSpacing: gap),
              delegate: SliverChildBuilderDelegate(
                (context, n) => _Tile(items: items, index: idx[n]),
                childCount: idx.length,
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

  static String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (d.year == now.year) return DateFormat('EEE, MMM d').format(d);
    return DateFormat('EEE, MMM d, y').format(d);
  }

  static String _monthLabel(DateTime d) => DateFormat('MMMM y').format(d);
}

class _Tile extends StatelessWidget {
  const _Tile({required this.items, required this.index});
  final List<MediaItem> items;
  final int index;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final item = items[index];
    final selected = app.selection.contains(item.id);
    final selecting = app.selection.isNotEmpty;
    final small = app.settings.gridColumns >= 6;
    return GestureDetector(
      onTap: () {
        if (selecting) {
          app.toggleSelect(item.id);
        } else {
          Navigator.of(context).push(PageRouteBuilder(
            opaque: false,
            barrierColor: Colors.transparent,
            transitionDuration: const Duration(milliseconds: 250),
            reverseTransitionDuration: const Duration(milliseconds: 200),
            pageBuilder: (_, a, _) => FadeTransition(
              opacity: a,
              child: ViewerScreen(items: items, initialIndex: index),
            ),
          ));
        }
      },
      onLongPress: () => app.toggleSelect(item.id),
      child: Stack(fit: StackFit.expand, children: [
        AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.all(selected ? 10 : 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(selected ? 10 : 0),
            child: Hero(
              tag: 'media-${item.id}',
              child: item.kind == MediaKind.file && item.thumbId == null
                  ? _FileTile(item: item, small: small)
                  : MediaThumb(item),
            ),
          ),
        ),
        if (!small) ...[
          Positioned(
            top: 4,
            left: 4,
            child: Row(children: [
              if (item.hdr.isHdr)
                Badge2(switch (item.hdr) {
                  HdrFormat.dolbyVision => 'DV',
                  HdrFormat.ultraHdr => 'HDR',
                  _ => item.hdr.label,
                }),
              if (item.hdr.isHdr && item.isHighFrameRate) const SizedBox(width: 3),
              if (item.isHighFrameRate) Badge2('${item.fps!.round()}'),
            ]),
          ),
          if (item.kind == MediaKind.file && item.thumbId != null)
            Positioned(
              bottom: 4,
              right: 4,
              child: Badge2(item.extension.toUpperCase(), icon: itemIcon(item)),
            ),
          if (item.kind == MediaKind.video || item.kind == MediaKind.audio)
            Positioned(
              bottom: 4,
              right: 4,
              child: Badge2(
                item.durationMs == null ? '' : formatDuration(Duration(milliseconds: item.durationMs!)),
                icon: item.kind == MediaKind.audio ? Icons.music_note : Icons.play_arrow,
              ),
            ),
          if (item.favorite)
            const Positioned(
              bottom: 4,
              left: 4,
              child: Icon(Icons.favorite, size: 16, color: Colors.white),
            ),
        ],
        if (selecting)
          Positioned(
            top: 4,
            right: 4,
            child: Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? Theme.of(context).colorScheme.primary : Colors.white,
            ),
          ),
      ]),
    );
  }
}

/// Grid tile for a document without a picture: type icon, extension, name.
class _FileTile extends StatelessWidget {
  const _FileTile({required this.item, required this.small});
  final MediaItem item;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(6),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(itemIcon(item), size: small ? 22 : 36, color: scheme.primary),
        if (item.extension.isNotEmpty)
          Text(item.extension.toUpperCase(),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: scheme.primary)),
        if (!small) ...[
          const SizedBox(height: 4),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------ filter chips

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.query});
  final LibraryQuery query;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final q = query;
    final tags = app.tagsById;
    final chips = <Widget>[];
    void add(String label, LibraryQuery Function() remove) => chips.add(Padding(
          padding: const EdgeInsets.only(right: 6),
          child: InputChip(label: Text(label), onDeleted: () => app.setQuery(remove())),
        ));
    if (q.kinds.isNotEmpty) {
      add(q.kinds.map((k) => '${k.name[0].toUpperCase()}${k.name.substring(1)}s').join(' + '),
          () => q.copyWith(kinds: {}));
    }
    for (final t in q.tagIds) {
      add('#${tags[t]?.name ?? '?'}', () => q.copyWith(tagIds: {...q.tagIds}..remove(t)));
    }
    if (q.tagIds.length > 1) {
      add(q.tagMatch == TagMatch.all ? 'All tags' : 'Any tag',
          () => q.copyWith(tagMatch: q.tagMatch == TagMatch.all ? TagMatch.any : TagMatch.all));
    }
    if (q.untaggedOnly) add('Untagged', () => q.copyWith(untaggedOnly: false));
    if (q.favoritesOnly) add('Favorites', () => q.copyWith(favoritesOnly: false));
    if (q.hdrOnly) add('HDR', () => q.copyWith(hdrOnly: false));
    if (q.highFrameRateOnly) add('60 fps', () => q.copyWith(highFrameRateOnly: false));
    if (q.minDurationMs != null || q.maxDurationMs != null) {
      add('Length', () => q.copyWith(minDurationMs: null, maxDurationMs: null));
    }
    if (q.minSizeBytes != null || q.maxSizeBytes != null) {
      add('Size', () => q.copyWith(minSizeBytes: null, maxSizeBytes: null));
    }
    if (q.takenAfter != null || q.takenBefore != null) {
      add('Dates', () => q.copyWith(takenAfter: null, takenBefore: null));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          ...chips,
          TextButton(onPressed: () => app.setQuery(q.clearFilters()), child: const Text('Clear')),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- sidebar

class _Sidebar extends StatelessWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.isUnlocked) return const SizedBox.shrink();
    final q = app.query;
    final data = app.vault.data;
    final totalSize = data.items.fold<int>(0, (a, i) => a + i.sizeBytes);
    final inDrawer = Scaffold.maybeOf(context)?.hasDrawer ?? false;
    void go(LibraryQuery nq) {
      app.setQuery(nq);
      if (inDrawer) Navigator.of(context).maybePop();
    }

    final tags = [...data.tags]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final counts = <String, int>{};
    for (final i in data.items) {
      for (final t in i.tagIds) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }

    return SafeArea(
      child: ListView(padding: EdgeInsets.zero, children: [
        ListTile(
          leading: Image.asset('assets/icon/emblem.png',
              width: 40, height: 40, filterQuality: FilterQuality.medium),
          title: Text('Lockbox', style: Theme.of(context).textTheme.titleLarge),
          subtitle: Text('${data.items.length} items · ${formatBytes(totalSize)}'),
        ),
        const Divider(),
        _NavTile(
          icon: Icons.photo_library_outlined,
          label: 'Library',
          selected: q.folderId == null && !q.favoritesOnly && q.kinds.isEmpty && q.tagIds.isEmpty,
          onTap: () => go(LibraryQuery(sort: q.sort, descending: q.descending)),
        ),
        _NavTile(
          icon: Icons.favorite_border,
          label: 'Favorites',
          selected: q.favoritesOnly,
          onTap: () => go(q.clearFilters().copyWith(folderId: null, favoritesOnly: true)),
        ),
        _NavTile(
          icon: Icons.photo_outlined,
          label: 'Photos',
          selected: q.kinds.length == 1 && q.kinds.contains(MediaKind.photo),
          onTap: () => go(q.clearFilters().copyWith(folderId: null, kinds: {MediaKind.photo})),
        ),
        _NavTile(
          icon: Icons.movie_outlined,
          label: 'Videos',
          selected: q.kinds.length == 1 && q.kinds.contains(MediaKind.video),
          onTap: () => go(q.clearFilters().copyWith(folderId: null, kinds: {MediaKind.video})),
        ),
        _NavTile(
          icon: Icons.music_note_outlined,
          label: 'Audio',
          selected: q.kinds.length == 1 && q.kinds.contains(MediaKind.audio),
          onTap: () => go(q.clearFilters().copyWith(folderId: null, kinds: {MediaKind.audio})),
        ),
        _NavTile(
          icon: Icons.insert_drive_file_outlined,
          label: 'Files',
          selected: q.kinds.length == 1 && q.kinds.contains(MediaKind.file),
          onTap: () => go(q.clearFilters().copyWith(folderId: null, kinds: {MediaKind.file})),
        ),
        const Divider(),
        _SectionHeader('Folders', onAdd: () async {
          final name = await promptText(context, title: 'New folder', ok: 'Create');
          if (name == null || name.isEmpty) return;
          app.vault.createFolder(name, parentId: q.folderId);
          await app.changed();
        }),
        for (final (f, depth) in folderRows(data.folders))
          _NavTile(
            icon: Icons.folder_outlined,
            label: f.name,
            indent: depth,
            selected: q.folderId == f.id,
            count: data.items.where((i) => i.folderId == f.id).length,
            onTap: () => go(q.copyWith(folderId: f.id)),
            menu: _folderMenu(context, app, f),
          ),
        if (data.folders.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 16, 8),
            child: Text('No folders yet', style: TextStyle(fontSize: 13)),
          ),
        const Divider(),
        _SectionHeader('Tags', onAdd: () async {
          final name = await promptText(context, title: 'New tag', ok: 'Create');
          if (name == null || name.isEmpty) return;
          app.vault.tagNamed(name);
          await app.changed();
        }),
        if (tags.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 16, 8),
            child: Text('Tags are added from file names automatically', style: TextStyle(fontSize: 13)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in tags)
              GestureDetector(
                onLongPress: () => _tagActions(context, app, t),
                onSecondaryTap: () => _tagActions(context, app, t),
                child: FilterChip(
                  avatar: CircleAvatar(backgroundColor: Color(t.color), radius: 6),
                  label: Text('${t.name} ${counts[t.id] ?? 0}'),
                  selected: q.tagIds.contains(t.id),
                  onSelected: (on) {
                    final s = {...q.tagIds};
                    on ? s.add(t.id) : s.remove(t.id);
                    app.setQuery(q.copyWith(tagIds: s));
                  },
                ),
              ),
          ]),
        ),
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('Settings'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('Lock now'),
          onTap: app.lock,
        ),
      ]),
    );
  }

  Widget _folderMenu(BuildContext context, AppState app, Folder f) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (v) async {
          switch (v) {
            case 'rename':
              final name = await promptText(context, title: 'Rename folder', initial: f.name, ok: 'Rename');
              if (name != null && name.isNotEmpty) {
                f.name = name;
                await app.changed();
              }
            case 'sub':
              final name = await promptText(context, title: 'New folder inside ${f.name}', ok: 'Create');
              if (name != null && name.isNotEmpty) {
                app.vault.createFolder(name, parentId: f.id);
                await app.changed();
              }
            case 'delete':
              if (!context.mounted) return;
              final ok = await confirm(context,
                  title: 'Delete folder “${f.name}”?',
                  message: 'Its files and sub-folders are kept and move up one level.',
                  ok: 'Delete folder');
              if (ok) {
                if (app.query.folderId == f.id) app.setQuery(app.query.copyWith(folderId: f.parentId));
                app.vault.deleteFolder(f.id);
                await app.changed();
              }
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'sub', child: Text('New folder inside')),
          PopupMenuItem(value: 'delete', child: Text('Delete folder')),
        ],
      );

  Future<void> _tagActions(BuildContext context, AppState app, Tag t) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('#${t.name}', style: Theme.of(ctx).textTheme.titleLarge)),
          ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename tag'),
              onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Colour'),
            subtitle: Wrap(spacing: 8, children: [
              for (final c in const [
                0xFF5C6BC0, 0xFF26A69A, 0xFFEF5350, 0xFFAB47BC, 0xFFFFA726,
                0xFF42A5F5, 0xFF66BB6A, 0xFFEC407A, 0xFF8D6E63, 0xFF78909C,
              ])
                GestureDetector(
                  onTap: () => Navigator.pop(ctx, 'color:$c'),
                  child: CircleAvatar(radius: 12, backgroundColor: Color(c)),
                ),
            ]),
          ),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete tag'),
              subtitle: const Text('Files keep everything else'),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (v == null || !context.mounted) return;
    if (v == 'rename') {
      final name = await promptText(context, title: 'Rename tag', initial: t.name, ok: 'Rename');
      if (name != null && name.isNotEmpty) t.name = name;
    } else if (v == 'delete') {
      app.setQuery(app.query.copyWith(tagIds: {...app.query.tagIds}..remove(t.id)));
      app.vault.deleteTag(t.id);
    } else if (v.startsWith('color:')) {
      t.color = int.parse(v.substring(6));
    }
    await app.changed();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {required this.onAdd});
  final String title;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
        child: Row(children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.labelLarge)),
          IconButton(icon: const Icon(Icons.add, size: 20), tooltip: 'New', onPressed: onAdd),
        ]),
      );
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.indent = 0,
    this.count,
    this.menu,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int indent;
  final int? count;
  final Widget? menu;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: 8.0 + indent * 16, right: 8),
        child: ListTile(
          dense: true,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          selected: selected,
          selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
          leading: Icon(icon),
          title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (count != null) Text('$count'),
            ?menu,
          ]),
          onTap: onTap,
        ),
      );
}
