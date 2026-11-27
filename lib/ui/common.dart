// Small shared UI pieces: formatting, thumbnails, badges and dialogs.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

String formatBytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 100 ? 0 : 1)} ${units[u]}';
}

String formatDate(DateTime d) => DateFormat.yMMMd().add_jm().format(d);

String resolutionLabel(MediaItem i) {
  if (i.width == null || i.height == null) return '';
  final short = i.width! < i.height! ? i.width! : i.height!;
  final p = switch (short) {
    >= 2160 => '4K',
    >= 1440 => '1440p',
    >= 1080 => '1080p',
    >= 720 => '720p',
    _ => '${short}p',
  };
  return '${i.width}×${i.height} ($p)';
}

void snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Decrypted thumbnail for an item, with a placeholder while loading.
class MediaThumb extends StatefulWidget {
  const MediaThumb(this.item, {super.key, this.fit = BoxFit.cover});
  final MediaItem item;
  final BoxFit fit;

  @override
  State<MediaThumb> createState() => _ThumbState();
}

class _ThumbState extends State<MediaThumb> {
  Uint8List? _bytes;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MediaThumb old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) _load();
  }

  void _load() {
    final app = context.read<AppState>();
    _bytes = app.cachedThumb(widget.item);
    _done = _bytes != null;
    if (!_done) {
      final id = widget.item.id;
      app.thumbnail(widget.item).then((b) {
        if (mounted && widget.item.id == id) {
          setState(() {
            _bytes = b;
            _done = true;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b != null) {
      return Image.memory(b,
          fit: widget.fit, gaplessPlayback: true, filterQuality: FilterQuality.medium);
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: _done
          ? Icon(itemIcon(widget.item), color: scheme.onSurfaceVariant)
          : null,
    );
  }
}

IconData kindIcon(MediaKind k) => switch (k) {
      MediaKind.photo => Icons.photo_outlined,
      MediaKind.video => Icons.movie_outlined,
      MediaKind.audio => Icons.music_note_outlined,
      MediaKind.file => Icons.insert_drive_file_outlined,
    };

/// Icon for an item, by file type for general files.
IconData itemIcon(MediaItem i) {
  if (i.kind != MediaKind.file) return kindIcon(i.kind);
  final e = i.extension;
  if (e == 'pdf') return Icons.picture_as_pdf_outlined;
  if (const {'doc', 'docx', 'odt', 'rtf', 'txt', 'md', 'log'}.contains(e)) {
    return Icons.description_outlined;
  }
  if (const {'xls', 'xlsx', 'ods', 'csv'}.contains(e)) return Icons.table_chart_outlined;
  if (const {'ppt', 'pptx', 'odp'}.contains(e)) return Icons.slideshow_outlined;
  if (const {'zip', '7z', 'rar', 'gz', 'tar'}.contains(e)) return Icons.folder_zip_outlined;
  if (const {'json', 'xml', 'html', 'htm', 'kml'}.contains(e)) return Icons.code;
  return Icons.insert_drive_file_outlined;
}

/// Files Lockbox can show inside the app.
enum Preview { pdf, text, none }

const _textExt = {
  'txt', 'md', 'csv', 'json', 'xml', 'log', 'ini', 'cfg', 'conf', 'yaml',
  'yml', 'html', 'htm', 'kml', 'gpx', 'srt', 'vtt', 'tsv',
};

Preview previewOf(MediaItem i) {
  if (i.kind != MediaKind.file) return Preview.none;
  if (i.extension == 'pdf' || i.mimeType == 'application/pdf') return Preview.pdf;
  if (_textExt.contains(i.extension) || i.mimeType.startsWith('text/')) {
    return Preview.text;
  }
  return Preview.none;
}

/// Small rounded label shown on thumbnails ("HDR", "60", "1:23").
class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) Icon(icon, size: 12, color: Colors.white),
          if (icon != null && text.isNotEmpty) const SizedBox(width: 2),
          if (text.isNotEmpty)
            Text(text,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
        ]),
      );
}

// ------------------------------------------------------------------ dialogs

Future<String?> promptText(BuildContext context,
    {required String title, String initial = '', String? hint, String ok = 'OK'}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(ok)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context,
    {required String title, required String message, String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Lets the user tick/untick tags for [items]; can create new tags.
Future<void> editTags(BuildContext context, List<MediaItem> items) async {
  final app = context.read<AppState>();
  // Order fixed when the list opens: tags already on the item(s) first, then
  // the rest, each alphabetically. Tags created here go to the very top.
  int byName(Tag a, Tag b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
  bool onAny(Tag t) => items.any((i) => i.tagIds.contains(t.id));
  final order = <String>[
    ...(app.vault.data.tags.where(onAny).toList()..sort(byName)).map((t) => t.id),
    ...(app.vault.data.tags.where((t) => !onAny(t)).toList()..sort(byName)).map((t) => t.id),
  ];
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final byId = {for (final t in app.vault.data.tags) t.id: t};
      final fresh = byId.keys.where((id) => !order.contains(id)).toList();
      final tags = [
        for (final id in [...fresh.reversed, ...order])
          if (byId[id] != null) byId[id]!,
      ];
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              title: Text(items.length == 1 ? 'Tags' : 'Tags for ${items.length} items',
                  style: Theme.of(ctx).textTheme.titleLarge),
              trailing: FilledButton.tonalIcon(
                icon: const Icon(Icons.add),
                label: const Text('New tag'),
                onPressed: () async {
                  final name = await promptText(ctx, title: 'New tag', ok: 'Create');
                  if (name == null || name.isEmpty) return;
                  final t = app.vault.tagNamed(name);
                  await app.addTag(items, t.id);
                  setS(() {});
                },
              ),
            ),
            if (tags.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No tags yet. Create one above.'),
              ),
            // Grid of tag buttons: highlighted = on the item. With several
            // items selected, a tag on only some of them shows a "–".
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final t in tags)
                    Builder(builder: (ctx) {
                      final count = items.where((i) => i.tagIds.contains(t.id)).length;
                      final on = count == items.length;
                      final some = count > 0 && !on;
                      return FilterChip(
                        key: ValueKey('tag-${t.id}'),
                        showCheckmark: false,
                        selected: on,
                        selectedColor: Theme.of(ctx).colorScheme.primaryContainer,
                        avatar: some
                            ? const Icon(Icons.remove, size: 16)
                            : CircleAvatar(radius: 6, backgroundColor: Color(t.color)),
                        label: Text(t.name),
                        onSelected: (_) async {
                          on ? await app.removeTag(items, t.id) : await app.addTag(items, t.id);
                          setS(() {});
                        },
                      );
                    }),
                ]),
              ),
            ),
          ]),
        ),
      );
    }),
  );
}

/// Picks a folder (or the top level). Returns false if cancelled.
/// Picks a folder: (picked?, folder id or null for Library). With
/// [offerFoldersPage], the Folders page is a choice too ([kStartFoldersPage]).
Future<(bool, String?)> pickFolder(BuildContext context,
    {String title = 'Move to', bool offerFoldersPage = false}) async {
  final app = context.read<AppState>();
  final r = await showModalBottomSheet<(bool, String?)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final rows = folderRows(app.vault.data.folders);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text(title, style: Theme.of(ctx).textTheme.titleLarge)),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(offerFoldersPage ? 'Library' : 'Library (no folder)'),
              onTap: () => Navigator.pop(ctx, (true, null)),
            ),
            if (offerFoldersPage)
              ListTile(
                leading: const Icon(Icons.folder_copy_outlined),
                title: const Text('Folders page'),
                subtitle: const Text('All your folders as a grid'),
                onTap: () => Navigator.pop(ctx, (true, kStartFoldersPage)),
              ),
            for (final (f, depth) in rows)
              ListTile(
                contentPadding: EdgeInsets.only(left: 16.0 + depth * 20, right: 16),
                leading: const Icon(Icons.folder_outlined),
                title: Text(f.name),
                onTap: () => Navigator.pop(ctx, (true, f.id)),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder…'),
              onTap: () async {
                final name = await promptText(ctx, title: 'New folder', ok: 'Create');
                if (name == null || name.isEmpty) return;
                final f = app.vault.createFolder(name);
                await app.changed();
                if (ctx.mounted) Navigator.pop(ctx, (true, f.id));
              },
            ),
          ]),
        ),
      );
    },
  );
  return r ?? (false, null);
}

/// Folders in tree order with their depth.
List<(Folder, int)> folderRows(List<Folder> folders) {
  final out = <(Folder, int)>[];
  void add(String? parent, int depth) {
    final kids = folders.where((f) => f.parentId == parent).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    for (final k in kids) {
      out.add((k, depth));
      if (depth < 20) add(k.id, depth + 1);
    }
  }

  add(null, 0);
  return out;
}

/// "Unlock" files back into normal storage: asks where to put them.
Future<void> restoreItems(BuildContext context, List<MediaItem> items) async {
  final app = context.read<AppState>();
  var dest = RestoreDestination.original;
  var keep = app.settings.keepCopyOnRestore;
  final single = items.length == 1 ? items.first : null;
  final unknown = items.where((i) => i.originalLocation == null).length;
  final String origLabel;
  if (single != null) {
    origLabel = single.originalLocation ??
        'Unknown for this file – it will go to the default restore folder (${app.defaultRestoreLabel})';
  } else if (unknown == 0) {
    origLabel = 'Where each file came from';
  } else if (unknown == items.length) {
    origLabel = 'Unknown for these files – they will go to the default restore folder';
  } else {
    origLabel = 'Where each file came from ($unknown unknown – default restore folder)';
  }
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      Widget option(RestoreDestination d, IconData icon, String title, String sub) =>
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(sub),
            trailing: Icon(dest == d ? Icons.radio_button_checked : Icons.radio_button_off,
                color: dest == d ? Theme.of(ctx).colorScheme.primary : null),
            onTap: () => setS(() => dest = d),
            contentPadding: EdgeInsets.zero,
          );
      return AlertDialog(
        title: Text(items.length == 1 ? 'Restore file' : 'Restore ${items.length} files'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Puts a normal, unencrypted copy back on this device.'),
            const SizedBox(height: 8),
            option(
              RestoreDestination.original,
              Icons.undo,
              'Original location',
              origLabel,
            ),
            option(RestoreDestination.defaultFolder, Icons.folder_special_outlined,
                'Default restore folder', app.defaultRestoreLabel),
            option(RestoreDestination.chooseFolder, Icons.drive_folder_upload_outlined,
                'Choose a folder…', 'Pick any folder now'),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep a copy in Lockbox'),
              subtitle: Text(keep
                  ? 'File stays protected in Lockbox too'
                  : 'File is removed from Lockbox after restoring'),
              value: keep,
              onChanged: (v) => setS(() => keep = v),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
        ],
      );
    }),
  );
  if (go != true || !context.mounted) return;
  final r = await app.restore(items, dest, keepCopy: keep);
  if (!context.mounted || r.cancelled) return;
  final where = r.locations.length == 1 ? ' to ${r.locations.first}' : '';
  final failed = r.failures.isEmpty ? '' : ' · ${r.failures.length} failed';
  snack(context, 'Restored ${r.restored} file(s)$where$failed');
  if (r.failures.isNotEmpty) {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Some files were not restored'),
        content: SingleChildScrollView(
            child: Text(r.failures.entries.map((e) => '${e.key}: ${e.value}').join('\n\n'))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }
}

/// Bar showing the progress of the current long task.
class TaskBanner extends StatelessWidget {
  const TaskBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return ValueListenableBuilder<TaskProgress?>(
      valueListenable: app.task,
      builder: (context, t, _) {
        if (t == null) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: t.fraction),
            ]),
          ),
        );
      },
    );
  }
}
