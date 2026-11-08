import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/library_query.dart';
import '../core/models.dart';
import '../state/app_state.dart';

/// Bottom sheet that edits all filters at once. Filters combine (AND).
Future<void> showFilterSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _FilterSheet(),
    );

class _FilterSheet extends StatefulWidget {
  const _FilterSheet();
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

// Length presets in seconds (null = no limit).
const _durations = <(String, int?, int?)>[
  ('Any length', null, null),
  ('Under 30 s', null, 30),
  ('30 s – 2 min', 30, 120),
  ('2 – 10 min', 120, 600),
  ('Over 10 min', 600, null),
];

const _mb = 1024 * 1024;
const _sizes = <(String, int?, int?)>[
  ('Any size', null, null),
  ('Under 5 MB', null, 5 * _mb),
  ('5 – 100 MB', 5 * _mb, 100 * _mb),
  ('100 MB – 1 GB', 100 * _mb, 1024 * _mb),
  ('Over 1 GB', 1024 * _mb, null),
];

class _FilterSheetState extends State<_FilterSheet> {
  late LibraryQuery q = context.read<AppState>().query;

  void _set(LibraryQuery n) {
    setState(() => q = n);
    context.read<AppState>().setQuery(n);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final tags = [...app.vault.data.tags]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
          child: Text(t, style: theme.textTheme.titleSmall),
        );
    final durIndex = _durations.indexWhere((d) =>
        d.$2 == (q.minDurationMs == null ? null : q.minDurationMs! ~/ 1000) &&
        d.$3 == (q.maxDurationMs == null ? null : q.maxDurationMs! ~/ 1000));
    final sizeIndex =
        _sizes.indexWhere((s) => s.$2 == q.minSizeBytes && s.$3 == q.maxSizeBytes);
    final df = DateFormat.yMMMd();

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Row(children: [
              Expanded(child: Text('Filters', style: theme.textTheme.titleLarge)),
              TextButton(onPressed: () => _set(q.clearFilters()), child: const Text('Clear all')),
            ]),
            header('Type'),
            Wrap(spacing: 8, children: [
              for (final k in MediaKind.values)
                FilterChip(
                  label: Text(switch (k) {
                    MediaKind.photo => 'Photos',
                    MediaKind.video => 'Videos',
                    MediaKind.audio => 'Audio',
                  }),
                  selected: q.kinds.contains(k),
                  onSelected: (on) {
                    final s = {...q.kinds};
                    on ? s.add(k) : s.remove(k);
                    _set(q.copyWith(kinds: s));
                  },
                ),
            ]),
            header('Video quality'),
            Wrap(spacing: 8, children: [
              FilterChip(
                label: const Text('HDR / HLG / Dolby Vision'),
                selected: q.hdrOnly,
                onSelected: (v) => _set(q.copyWith(hdrOnly: v)),
              ),
              FilterChip(
                label: const Text('60 fps or more'),
                selected: q.highFrameRateOnly,
                onSelected: (v) => _set(q.copyWith(highFrameRateOnly: v)),
              ),
              FilterChip(
                label: const Text('Favorites'),
                selected: q.favoritesOnly,
                onSelected: (v) => _set(q.copyWith(favoritesOnly: v)),
              ),
            ]),
            header('Tags'),
            if (tags.isEmpty) const Text('No tags yet.'),
            Wrap(spacing: 8, runSpacing: 4, children: [
              FilterChip(
                label: const Text('Untagged'),
                selected: q.untaggedOnly,
                onSelected: (v) => _set(q.copyWith(untaggedOnly: v)),
              ),
              for (final t in tags)
                FilterChip(
                  avatar: CircleAvatar(backgroundColor: Color(t.color), radius: 6),
                  label: Text(t.name),
                  selected: q.tagIds.contains(t.id),
                  onSelected: (on) {
                    final s = {...q.tagIds};
                    on ? s.add(t.id) : s.remove(t.id);
                    _set(q.copyWith(tagIds: s));
                  },
                ),
            ]),
            if (q.tagIds.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SegmentedButton<TagMatch>(
                  segments: const [
                    ButtonSegment(value: TagMatch.any, label: Text('Any of these tags')),
                    ButtonSegment(value: TagMatch.all, label: Text('All of these tags')),
                  ],
                  selected: {q.tagMatch},
                  onSelectionChanged: (s) => _set(q.copyWith(tagMatch: s.first)),
                ),
              ),
            header('Length (video & audio)'),
            Wrap(spacing: 8, children: [
              for (var i = 0; i < _durations.length; i++)
                ChoiceChip(
                  label: Text(_durations[i].$1),
                  selected: durIndex == i,
                  onSelected: (_) => _set(q.copyWith(
                    minDurationMs: _durations[i].$2 == null ? null : _durations[i].$2! * 1000,
                    maxDurationMs: _durations[i].$3 == null ? null : _durations[i].$3! * 1000,
                  )),
                ),
            ]),
            header('File size'),
            Wrap(spacing: 8, children: [
              for (var i = 0; i < _sizes.length; i++)
                ChoiceChip(
                  label: Text(_sizes[i].$1),
                  selected: sizeIndex == i,
                  onSelected: (_) =>
                      _set(q.copyWith(minSizeBytes: _sizes[i].$2, maxSizeBytes: _sizes[i].$3)),
                ),
            ]),
            header('Date taken'),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(q.takenAfter == null ? 'From…' : df.format(q.takenAfter!)),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2100),
                      initialDate: q.takenAfter ?? DateTime.now(),
                    );
                    if (d != null) _set(q.copyWith(takenAfter: d));
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(q.takenBefore == null
                      ? 'To…'
                      : df.format(q.takenBefore!.subtract(const Duration(days: 1)))),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2100),
                      initialDate: DateTime.now(),
                    );
                    // inclusive end date
                    if (d != null) _set(q.copyWith(takenBefore: d.add(const Duration(days: 1))));
                  },
                ),
              ),
              if (q.takenAfter != null || q.takenBefore != null)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => _set(q.copyWith(takenAfter: null, takenBefore: null)),
                ),
            ]),
            if (q.folderId != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include sub-folders'),
                value: q.includeSubfolders,
                onChanged: (v) => _set(q.copyWith(includeSubfolders: v)),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Show ${app.results.length} item(s)'),
            ),
          ],
        ),
      ),
    );
  }
}
