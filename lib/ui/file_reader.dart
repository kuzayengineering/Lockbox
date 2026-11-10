// Documents and other files in the viewer.
//
//  * FilePage: the page shown in the swipeable viewer (preview picture or
//    type icon, name, size, and an "Open" button for files Lockbox can show).
//  * FileReaderScreen: full-screen reader for PDFs and text files. The file
//    is decrypted into memory only; text can't be selected or copied and PDF
//    links don't open, so nothing leaves Lockbox.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'common.dart';

class FilePage extends StatelessWidget {
  const FilePage({super.key, required this.item, required this.onTap});
  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = previewOf(item);
    final typeName = switch (preview) {
      Preview.pdf => 'PDF document',
      Preview.text => 'Text file',
      Preview.none => item.extension.isEmpty ? 'File' : '${item.extension.toUpperCase()} file',
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 80, 24, 160),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 220,
              height: 260,
              child: Hero(
                tag: 'media-${item.id}',
                child: item.thumbId != null
                    ? MediaThumb(item, fit: BoxFit.contain)
                    : Icon(itemIcon(item), size: 120, color: Colors.white70),
              ),
            ),
            const SizedBox(height: 20),
            Text(item.name,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 6),
            Text('$typeName · ${formatBytes(item.sizeBytes)}',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 24),
            if (preview != Preview.none)
              FilledButton.icon(
                icon: const Icon(Icons.chrome_reader_mode_outlined),
                label: const Text('Open'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => FileReaderScreen(item: item))),
              )
            else
              const Text(
                'Lockbox can\'t show this kind of file. To use it, tap Restore '
                'below to put a copy back on your device (you can keep a copy '
                'in Lockbox too).',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
          ]),
        ),
      ),
    );
  }
}

class FileReaderScreen extends StatefulWidget {
  const FileReaderScreen({super.key, required this.item});
  final MediaItem item;

  @override
  State<FileReaderScreen> createState() => _FileReaderScreenState();
}

class _FileReaderScreenState extends State<FileReaderScreen> {
  Uint8List? _bytes;
  String? _error;

  static const _maxTextBytes = 2 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().vault.readOriginal(widget.item).then((b) {
      if (mounted) setState(() => _bytes = b);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    Widget body;
    if (_error != null) {
      body = Center(child: Text('Could not open this file.\n$_error', textAlign: TextAlign.center));
    } else if (_bytes == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (previewOf(item) == Preview.pdf) {
      body = PdfViewer.data(
        _bytes!,
        sourceName: 'lockbox-${item.id}',
        params: PdfViewerParams(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          // No copying text out and no opening links: nothing leaves Lockbox.
          textSelectionParams: const PdfTextSelectionParams(enabled: false),
          errorBannerBuilder: (context, error, stack, ref) =>
              Center(child: Text('This PDF can\'t be shown: $error')),
        ),
      );
    } else {
      final b = _bytes!;
      final cut = b.length > _maxTextBytes;
      final text = utf8.decode(cut ? Uint8List.sublistView(b, 0, _maxTextBytes) : b,
          allowMalformed: true);
      final mono = const {'csv', 'tsv', 'json', 'xml', 'log', 'yaml', 'yml', 'ini', 'cfg', 'conf', 'kml', 'gpx'}
          .contains(item.extension);
      body = Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (cut)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('Showing the first ${formatBytes(_maxTextBytes)} of ${formatBytes(b.length)}.',
                    style: TextStyle(color: Theme.of(context).colorScheme.outline)),
              ),
            Text(text, style: TextStyle(fontFamily: mono ? 'monospace' : null, fontSize: mono ? 13 : 15)),
          ]),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(item.name, overflow: TextOverflow.ellipsis)),
      body: body,
    );
  }
}
