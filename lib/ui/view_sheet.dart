import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';

/// Grid views show names, tags, size and date on the thumbnails only when
/// there are this many (or fewer) per row, so there is room for the text.
const kTextOnTilesColumns = 3;

/// One-line summary of a view, e.g. "Grid, 4 per row · Length, Frame rate".
String describeView(ViewPrefs v) {
  final layout = v.mode == ViewMode.details ? 'Details' : 'Grid, ${v.columns} per row';
  final shown = [for (final f in ViewField.values) if (v.shows(f)) f.label];
  return shown.isEmpty ? layout : '$layout · ${shown.join(', ')}';
}

/// The "View" sheet: Grid or Details, and which details to show.
///
/// Inside a folder, changes are saved for that folder only. In the Library
/// (or with [defaultOnly], from Settings) they change the default view.
Future<void> showViewSheet(BuildContext context, {bool defaultOnly = false}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ViewSheet(defaultOnly: defaultOnly),
  );
}

class _ViewSheet extends StatelessWidget {
  const _ViewSheet({required this.defaultOnly});
  final bool defaultOnly;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.isUnlocked) return const SizedBox.shrink();
    final folder = defaultOnly || app.query.folderId == null
        ? null
        : app.foldersById[app.query.folderId];
    final v = folder == null ? app.settings.defaultView : app.currentView;
    final theme = Theme.of(context);

    void change(void Function(ViewPrefs v) f) => folder == null
        ? app.updateSettings((s) => f(s.defaultView))
        : app.updateView(f);

    final String note;
    if (folder == null) {
      note = 'This is the default view. Folders use it unless you change the view inside them.';
    } else if (app.folderHasOwnView) {
      note = 'This folder has its own view.';
    } else {
      note = 'Using the default view. Changes made here apply to this folder only.';
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(folder == null ? 'Default view' : 'View for “${folder.name}”',
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(note, style: theme.textTheme.bodySmall),
          if (folder != null && app.folderHasOwnView)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Use default view'),
                onPressed: app.resetFolderView,
              ),
            ),
          const SizedBox(height: 16),
          Text('Layout', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<ViewMode>(
            segments: const [
              ButtonSegment(value: ViewMode.grid, icon: Icon(Icons.grid_view), label: Text('Grid')),
              ButtonSegment(
                  value: ViewMode.details, icon: Icon(Icons.view_list), label: Text('Details')),
            ],
            selected: {v.mode},
            onSelectionChanged: (s) => change((x) => x.mode = s.first),
          ),
          if (v.mode == ViewMode.grid) ...[
            const SizedBox(height: 16),
            Text('Per row (or pinch the gallery)', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                for (var c = 1; c <= 6; c++) ButtonSegment(value: c, label: Text('$c')),
              ],
              selected: {v.columns},
              onSelectionChanged: (s) => change((x) => x.columns = s.first),
            ),
          ],
          const SizedBox(height: 16),
          Text('Show', style: theme.textTheme.labelLarge),
          if (v.mode == ViewMode.grid)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                  'File name, tags, size and date appear on the thumbnails when there are '
                  '$kTextOnTilesColumns or fewer per row.',
                  style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final f in ViewField.values)
              FilterChip(
                label: Text(f.label),
                selected: v.shows(f),
                onSelected: (on) => change((x) => on ? x.show.add(f) : x.show.remove(f)),
              ),
          ]),
        ]),
      ),
    );
  }
}
