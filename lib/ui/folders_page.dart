import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Rename / new folder inside / delete, for a folder.
Future<void> folderAction(BuildContext context, AppState app, Folder f, String action) async {
  switch (action) {
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
        if (!app.showingFolders && app.query.folderId == f.id) {
          app.setQuery(app.query.copyWith(folderId: f.parentId));
        }
        app.vault.deleteFolder(f.id);
        await app.changed();
      }
  }
}

/// Asks for a name and creates a top-level folder.
Future<void> newFolder(BuildContext context, AppState app, {String? parentId}) async {
  final name = await promptText(context, title: 'New folder', ok: 'Create');
  if (name == null || name.isEmpty) return;
  app.vault.createFolder(name, parentId: parentId);
  await app.changed();
}

/// Grid of square folder covers (newest photo or video in each folder).
class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.isUnlocked) return const SizedBox.shrink();
    final data = app.vault.data;
    final rows = folderRows(data.folders);
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.folder_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('No folders yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('Tap “New folder” to make one.', textAlign: TextAlign.center),
          ]),
        ),
      );
    }

    // Item count and cover (newest item) per folder, sub-folders included.
    final byId = app.foldersById;
    final counts = <String, int>{};
    final covers = <String, MediaItem>{};
    for (final i in data.items) {
      var id = i.folderId;
      var guard = 0;
      while (id != null && guard++ < 50) {
        counts[id] = (counts[id] ?? 0) + 1;
        final c = covers[id];
        if (c == null || _coverRank(i, c)) covers[id] = i;
        id = byId[id]?.parentId;
      }
    }

    return LayoutBuilder(builder: (context, box) {
      final cols = (box.maxWidth / 190).floor().clamp(2, 8);
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: 12,
          mainAxisSpacing: 14,
          // square picture + two lines of text
          childAspectRatio: 1 / 1.32,
        ),
        itemCount: rows.length,
        itemBuilder: (context, n) {
          final (f, _) = rows[n];
          final parent = f.parentId == null ? null : byId[f.parentId];
          return _FolderTile(
            folder: f,
            parentName: parent?.name,
            count: counts[f.id] ?? 0,
            cover: covers[f.id],
          );
        },
      );
    });
  }

  /// Photos and videos make better covers than audio or documents; among
  /// equals, the newest wins.
  static bool _coverRank(MediaItem a, MediaItem current) {
    int score(MediaItem i) => (i.kind == MediaKind.photo || i.kind == MediaKind.video) ? 1 : 0;
    if (score(a) != score(current)) return score(a) > score(current);
    return a.mediaDate.isAfter(current.mediaDate);
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.folder, required this.count, this.cover, this.parentName});
  final Folder folder;
  final int count;
  final MediaItem? cover;
  final String? parentName;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Future<void> actions() async {
      final v = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: Text(folder.name, style: Theme.of(ctx).textTheme.titleLarge)),
            ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () => Navigator.pop(ctx, 'rename')),
            ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('New folder inside'),
                onTap: () => Navigator.pop(ctx, 'sub')),
            ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete folder'),
                onTap: () => Navigator.pop(ctx, 'delete')),
          ]),
        ),
      );
      if (v != null && context.mounted) await folderAction(context, app, folder, v);
    }

    final hasPicture = cover != null && cover!.thumbId != null;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => app.openFolderFromFolders(folder.id),
      onLongPress: actions,
      onSecondaryTap: actions,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: hasPicture
                ? MediaThumb(cover!)
                : Container(
                    color: scheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(
                        cover == null ? Icons.folder_outlined : itemIcon(cover!),
                        size: 48,
                        color: scheme.primary),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall),
        Text(
          [if (parentName != null) 'in $parentName', '$count item${count == 1 ? '' : 's'}']
              .join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}
