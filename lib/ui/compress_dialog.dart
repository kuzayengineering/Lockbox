// "Make smaller copy" of a video: options with a live size estimate, then a
// progress dialog. Android only (uses the phone's hardware video encoder).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/compress_estimate.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Returns true if a copy was made.
Future<bool> showMakeSmallerCopy(BuildContext context, MediaItem video) async {
  final app = context.read<AppState>();
  final w = video.width, h = video.height, dur = video.durationMs;
  if (w == null || h == null || dur == null || dur <= 0) {
    snack(context, 'This video\'s size or length is unknown, so it can\'t be converted.');
    return false;
  }
  final fps = video.fps ?? 30;
  final short = math.min(w, h);
  final sides = [for (final s in kShortSides) if (s < short) s];
  final rates = [for (final r in kFrameRates) if (r < fps - 0.5) r];

  int? side; // null = original
  double? rate; // null = original
  var quality = CompressQuality.medium;
  var keepHdr = video.hdr.isHdr;
  var deleteOriginal = false;

  String resLabel(int s) => switch (s) {
        2160 => '4K',
        _ => '${s}p',
      };

  final go = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final plan = planCompression(
        width: w,
        height: h,
        fps: fps,
        durationMs: dur,
        originalBytes: video.sizeBytes,
        shortSide: side,
        targetFps: rate,
        quality: quality,
      );
      final theme = Theme.of(ctx);
      Widget header(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
            child: Text(t, style: theme.textTheme.titleSmall),
          );
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Text('Make smaller copy', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Now: ${resLabel(short)} · ${fps.round()} fps'
                '${video.hdr.isHdr ? ' · ${video.hdr.label}' : ''} · ${formatBytes(video.sizeBytes)}',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
              header('Resolution'),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: const Text('Original'),
                    selected: side == null,
                    onSelected: (_) => setS(() => side = null)),
                for (final s in sides)
                  ChoiceChip(
                      label: Text(resLabel(s)),
                      selected: side == s,
                      onSelected: (_) => setS(() => side = s)),
              ]),
              header('Frame rate'),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: Text('Original (${fps.round()})'),
                    selected: rate == null,
                    onSelected: (_) => setS(() => rate = null)),
                for (final r in rates)
                  ChoiceChip(
                      label: Text('${r.round()} fps'),
                      selected: rate == r,
                      onSelected: (_) => setS(() => rate = r)),
              ]),
              header('Quality'),
              SegmentedButton<CompressQuality>(
                segments: [
                  for (final q in CompressQuality.values)
                    ButtonSegment(value: q, label: Text(q.label)),
                ],
                selected: {quality},
                onSelectionChanged: (v) => setS(() => quality = v.first),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(quality.hint, style: TextStyle(color: theme.colorScheme.outline)),
              ),
              if (video.hdr.isHdr)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep HDR'),
                  subtitle: Text(keepHdr
                      ? 'Bright highlights kept (${video.hdr.label})'
                      : 'Converted to a normal (SDR) video'),
                  value: keepHdr,
                  onChanged: (v) => setS(() => keepHdr = v),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Delete the original'),
                subtitle: Text(deleteOriginal
                    ? 'The original is erased once the copy is saved'
                    : 'Keep both'),
                value: deleteOriginal,
                onChanged: (v) => setS(() => deleteOriginal = v),
              ),
              const SizedBox(height: 8),
              Card(
                color: plan.saves
                    ? theme.colorScheme.secondaryContainer
                    : theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Estimated size: ≈ ${formatBytes(plan.estimatedBytes)}',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(plan.saves
                        ? 'Saves ≈ ${formatBytes(plan.savedBytes)} '
                            '(${(plan.savedFraction * 100).round()}%)'
                        : 'Little or no saving with these settings – try a lower '
                            'resolution, frame rate or quality.'),
                    const SizedBox(height: 4),
                    Text(
                      '${plan.width}×${plan.height} · ${plan.fps.round()} fps · '
                      '${(plan.videoBitrate / 1e6).toStringAsFixed(1)} Mbit/s (variable)',
                      style: TextStyle(color: theme.colorScheme.outline, fontSize: 12),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              Text('Keep Lockbox open while converting – leaving it locks the app '
                  'and stops the conversion.',
                  style: TextStyle(color: theme.colorScheme.outline, fontSize: 12)),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.compress),
                label: const Text('Make smaller copy'),
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      );
    }),
  );
  if (go != true || !context.mounted) return false;

  final plan = planCompression(
    width: w,
    height: h,
    fps: fps,
    durationMs: dur,
    originalBytes: video.sizeBytes,
    shortSide: side,
    targetFps: rate,
    quality: quality,
  );
  // Progress dialog (closed when the work finishes).
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Making smaller copy…'),
        content: ValueListenableBuilder<double?>(
          valueListenable: app.compressProgress,
          builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: p),
            const SizedBox(height: 8),
            Text(p == null ? 'Starting…' : '${(p * 100).round()}%'),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => app.cancelSmallerCopy(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );
  try {
    final copy = await app.makeSmallerCopy(
      video,
      plan,
      shortSide: side,
      fps: rate,
      keepHdr: keepHdr,
      deleteOriginal: deleteOriginal,
    );
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      final saved = video.sizeBytes - copy.sizeBytes;
      snack(
          context,
          saved > 0
              ? 'Smaller copy saved: ${formatBytes(copy.sizeBytes)} (saved ${formatBytes(saved)})'
              : 'Copy saved: ${formatBytes(copy.sizeBytes)} (no space saved)');
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      final cancelled = e is PlatformException && e.code == 'cancelled';
      snack(
          context,
          cancelled
              ? 'Cancelled'
              : 'Couldn\'t make a smaller copy: ${e is PlatformException ? e.message : e}');
    }
    return false;
  }
}
