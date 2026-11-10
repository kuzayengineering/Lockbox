// Full-screen viewer, modelled on Google Photos:
//  * swipe left/right between items, swipe down to close, swipe up for info
//  * tap to show/hide controls; photos: pinch or double-tap to zoom
//  * videos start automatically, scrub bar, double-tap sides to skip 10 s,
//    speed, loop and mute; HDR/HLG shown in true HDR on Android
//  * frame-by-frame buttons; keyboard on Windows: ← → switch, space
//    play/pause, , . previous/next frame, Esc close, F favorite

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../platform/native.dart';
import '../platform/player.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'file_reader.dart';

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.items, required this.initialIndex});
  final List<MediaItem> items;
  final int initialIndex;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late List<MediaItem> _items = [...widget.items];
  late int _index = widget.initialIndex;
  bool _chrome = true;
  bool _zoomed = false;
  double _drag = 0;
  Timer? _hideTimer;
  final _focus = FocusNode();
  late final AppState _app = context.read<AppState>();

  MediaItem get _item => _items[_index];
  MediaPlayer get _player => _app.player;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _activate());
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_app.isUnlocked && _app.hasPlayer) _player.stop();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _activate() {
    final i = _item;
    if (i.kind != MediaKind.video && i.kind != MediaKind.audio) {
      if (_app.hasPlayer) _player.stop();
    } else {
      final s = _app.settings;
      _player.open(i, autoplay: true, loop: s.loopVideos, muted: s.muteByDefault);
      _scheduleHide();
    }
  }

  void _onPage(int i) {
    setState(() {
      _index = i;
      _zoomed = false;
    });
    _activate();
  }

  void _setChrome(bool v) {
    setState(() => _chrome = v);
    SystemChrome.setEnabledSystemUIMode(v ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
    if (v) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_item.kind != MediaKind.video) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _player.state.value.playing && _item.kind == MediaKind.video) {
        _setChrome(false);
      }
    });
  }

  void _go(int delta) {
    final n = _index + delta;
    if (n < 0 || n >= _items.length) return;
    _pages.animateToPage(n, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// Keyboard shortcuts (Windows). Only the keys used here are claimed;
  /// everything else, including the phone's volume buttons, is passed on.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final media = _item.kind == MediaKind.video || _item.kind == MediaKind.audio;
    final video = _item.kind == MediaKind.video;
    if (k == LogicalKeyboardKey.arrowRight) {
      _go(1);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
    } else if (k == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
    } else if (k == LogicalKeyboardKey.space && media) {
      _player.togglePlay();
    } else if (k == LogicalKeyboardKey.comma && video) {
      _player.stepFrame(-1, _item.fps);
    } else if (k == LogicalKeyboardKey.period && video) {
      _player.stepFrame(1, _item.fps);
    } else if (k == LogicalKeyboardKey.keyF) {
      _app.setFavorite([_item], !_item.favorite).then((_) => setState(() {}));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _afterRemoval() async {
    final removed = _app.vault.itemById(_item.id) == null;
    if (!removed) return setState(() {});
    if (!mounted) return;
    if (_items.length == 1) return Navigator.pop(context);
    setState(() {
      _items = [..._items]..removeAt(_index);
      if (_index >= _items.length) _index = _items.length - 1;
    });
    _pages.jumpToPage(_index);
    _activate();
  }

  @override
  Widget build(BuildContext context) {
    final dismissProgress = (_drag.abs() / 300).clamp(0.0, 1.0);
    final item = _item;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: 1 - dismissProgress),
        body: Stack(children: [
          GestureDetector(
            onVerticalDragUpdate: _zoomed ? null : (d) => setState(() => _drag += d.delta.dy),
            onVerticalDragEnd: _zoomed
                ? null
                : (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (_drag > 120 || v > 900) {
                      Navigator.pop(context);
                    } else if (_drag < -80 || v < -900) {
                      setState(() => _drag = 0);
                      _showInfo();
                    } else {
                      setState(() => _drag = 0);
                    }
                  },
            child: Transform.translate(
              offset: Offset(0, _drag > 0 ? _drag : _drag / 4),
              child: Transform.scale(
                scale: 1 - dismissProgress * 0.25,
                child: PageView.builder(
                  controller: _pages,
                  physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                  onPageChanged: _onPage,
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final it = _items[i];
                    final active = i == _index;
                    return switch (it.kind) {
                      MediaKind.photo => _PhotoPage(
                          key: ValueKey(it.id),
                          item: it,
                          active: active,
                          onTap: () => _setChrome(!_chrome),
                          onZoomChanged: (z) => setState(() => _zoomed = z),
                        ),
                      MediaKind.video => _VideoPage(
                          key: ValueKey(it.id),
                          item: it,
                          active: active,
                          onTap: () => _setChrome(!_chrome),
                        ),
                      MediaKind.audio => _AudioPage(
                          key: ValueKey(it.id),
                          item: it,
                          onTap: () => _setChrome(!_chrome),
                        ),
                      MediaKind.file => FilePage(
                          key: ValueKey(it.id),
                          item: it,
                          onTap: () => _setChrome(!_chrome),
                        ),
                    };
                  },
                ),
              ),
            ),
          ),
          // ---- top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: _chrome && _drag == 0 ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_chrome,
                child: _TopBar(
                  item: item,
                  position: '${_index + 1} / ${_items.length}',
                  onMenu: _menu,
                ),
              ),
            ),
          ),
          // ---- bottom: playback controls + actions
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: _chrome && _drag == 0 ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_chrome,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (item.kind == MediaKind.video || item.kind == MediaKind.audio)
                        _PlaybackBar(item: item, onInteract: _scheduleHide),
                      _ActionRow(item: item, onInfo: _showInfo, onChanged: _afterRemoval),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _menu(String v) async {
    final item = _item;
    switch (v) {
      case 'move':
        final (ok, id) = await pickFolder(context);
        if (ok) await _app.moveTo([item], id);
      case 'rename':
        final name = await promptText(context, title: 'Rename', initial: item.name, ok: 'Rename');
        if (name != null && name.isNotEmpty) await _app.rename(item, name);
      case 'loop':
        await _app.updateSettings((s) => s.loopVideos = !s.loopVideos);
        await _player.setLooping(_app.settings.loopVideos);
    }
    if (mounted) setState(() {});
  }

  Future<void> _showInfo() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _InfoSheet(item: _item),
    );
    if (mounted) setState(() {});
  }
}

// ------------------------------------------------------------------ pages

class _PhotoPage extends StatefulWidget {
  const _PhotoPage(
      {super.key,
      required this.item,
      required this.active,
      required this.onTap,
      required this.onZoomChanged});
  final MediaItem item;
  final bool active;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> with SingleTickerProviderStateMixin {
  Uint8List? _full;
  bool _failed = false;
  bool _triedConvert = false;
  final _tc = TransformationController();
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _zoomAnim;
  Offset _tapPos = Offset.zero;
  bool _zoomed = false;
  bool _hdrCapable = false;
  bool _nativeZoomed = false;
  Size _size = Size.zero;

  bool get _hdrOverlay => _hdrCapable && widget.active && _full != null;

  void _onHdrEvent(String method, Object? args) {
    if (!mounted || !_hdrOverlay) return;
    if (method == 'zoomed') {
      final z = args == true;
      setState(() => _nativeZoomed = z);
      widget.onZoomChanged(z);
    } else if (method == 'tap') {
      widget.onTap();
    }
  }

  // Pinch / pan state
  Matrix4 _startMatrix = Matrix4.identity();
  Offset _startFocal = Offset.zero;

  /// Keeps the zoomed picture covering the screen (no empty margins).
  Matrix4 _bounded(double s, Offset t) {
    final minX = _size.width - _size.width * s;
    final minY = _size.height - _size.height * s;
    final x = t.dx.clamp(minX, 0.0);
    final y = t.dy.clamp(minY, 0.0);
    return Matrix4.identity()
      ..translateByDouble(x, y, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _anim.stop();
    _startMatrix = _tc.value.clone();
    _startFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final s0 = _startMatrix.getMaxScaleOnAxis();
    // One finger on an un-zoomed photo is a swipe, not a pan.
    if (d.pointerCount < 2 && s0 <= 1.01) return;
    final t0 = Offset(_startMatrix.storage[12], _startMatrix.storage[13]);
    final contentPoint = (_startFocal - t0) / s0; // what was under the fingers
    final s = (s0 * d.scale).clamp(1.0, 8.0);
    _tc.value = _bounded(s, d.localFocalPoint - contentPoint * s);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_tc.value.getMaxScaleOnAxis() < 1.05) _animateTo(Matrix4.identity());
  }

  void _animateTo(Matrix4 end) {
    _zoomAnim = Matrix4Tween(begin: _tc.value, end: end)
        .animate(CurveTween(curve: Curves.easeOut).animate(_anim));
    _anim.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    _anim.addListener(() => _tc.value = _zoomAnim!.value);
    if (widget.item.hdr == HdrFormat.ultraHdr) {
      Native.hdrPhotoDisplay().then((ok) {
        if (mounted && ok) setState(() => _hdrCapable = true);
      });
    }
    _tc.addListener(() {
      final z = _tc.value.getMaxScaleOnAxis() > 1.01;
      if (z != _zoomed) {
        setState(() => _zoomed = z);
        widget.onZoomChanged(z);
      }
    });
    context.read<AppState>().vault.readOriginal(widget.item).then((b) {
      if (mounted) setState(() => _full = b);
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    if (Native.hdrListener == _onHdrEvent) Native.hdrListener = null;
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_hdrOverlay) {
      // The native HDR view zooms itself.
      final dpr = MediaQuery.of(context).devicePixelRatio;
      Native.hdrZoomAt(_tapPos.dx * dpr, _tapPos.dy * dpr);
      return;
    }
    _animateTo(_zoomed ? Matrix4.identity() : _bounded(2.5, _tapPos * -1.5));
  }

  Future<void> _convert() async {
    if (_triedConvert || _full == null) return;
    _triedConvert = true;
    final jpeg = await Native.toJpeg(_full!);
    if (!mounted) return;
    setState(() {
      if (jpeg != null) {
        _full = jpeg;
      } else {
        _failed = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cacheW = (mq.size.width * mq.devicePixelRatio * 2.5).round();
    final thumb = MediaThumb(widget.item, fit: BoxFit.contain);
    Widget content;
    if (_full == null) {
      content = Stack(fit: StackFit.expand, children: [
        thumb,
        if (_failed)
          const Center(child: Text('Could not open this photo', style: TextStyle(color: Colors.white))),
      ]);
    } else {
      content = Image.memory(
        _full!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        cacheWidth: cacheW,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, sync) =>
            frame == null && !sync ? Stack(fit: StackFit.expand, children: [thumb, child]) : child,
        errorBuilder: (context, _, _) {
          _convert();
          return Stack(fit: StackFit.expand, children: [
            thumb,
            if (_failed)
              const Center(
                child: Text('This image format can\'t be shown on this device',
                    style: TextStyle(color: Colors.white)),
              ),
          ]);
        },
      );
    }
    final viewer = LayoutBuilder(builder: (context, c) {
      _size = c.biggest;
      return RawGestureDetector(
        // With the HDR view on top, two-finger gestures go to it instead.
        gestures: _hdrOverlay ? const {} : {
          _PinchRecognizer: GestureRecognizerFactoryWithHandlers<_PinchRecognizer>(
            () => _PinchRecognizer(debugOwner: this),
            (r) => r
              ..onStart = _onScaleStart
              ..onUpdate = _onScaleUpdate
              ..onEnd = _onScaleEnd,
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onDoubleTapDown: (d) => _tapPos = d.localPosition,
          onDoubleTap: _toggleZoom,
          child: ClipRect(
            child: ValueListenableBuilder<Matrix4>(
              valueListenable: _tc,
              builder: (context, m, child) => Transform(transform: m, child: child),
              child: SizedBox.expand(
                  child: Hero(tag: 'media-${widget.item.id}', child: content)),
            ),
          ),
        ),
      );
    });
    // Ultra HDR photo on an HDR phone: the native view shows the real HDR
    // picture on top and does its own zooming (see _HdrPhotoView).
    if (!_hdrOverlay) return viewer;
    Native.hdrListener = _onHdrEvent;
    return Stack(fit: StackFit.expand, children: [
      viewer,
      _HdrPhotoView(bytes: _full!, zoomed: _nativeZoomed),
    ]);
  }
}

/// Pinch recognizer that claims the touch the moment a second finger lands,
/// so zooming always beats the gallery's swipe gestures.
class _PinchRecognizer extends ScaleGestureRecognizer {
  _PinchRecognizer({super.debugOwner});

  final _down = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _down.add(event.pointer);
    if (_down.length >= 2) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _down.remove(event.pointer);
    }
    super.handleEvent(event);
  }

  @override
  void rejectGesture(int pointer) {
    _down.remove(pointer);
    super.rejectGesture(pointer);
  }
}

/// Android native view that shows an Ultra HDR photo in real HDR.
///
/// One-finger gestures stay with the gallery (swipe, swipe down, tap,
/// double-tap). A second finger hands the touch to the native view, which
/// zooms; while zoomed it receives every touch.
class _HdrPhotoView extends StatelessWidget {
  const _HdrPhotoView({required this.bytes, required this.zoomed});
  final Uint8List bytes;
  final bool zoomed;

  @override
  Widget build(BuildContext context) => PlatformViewLink(
        viewType: 'lockbox/hdr_image',
        surfaceFactory: (context, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: zoomed
              ? <Factory<OneSequenceGestureRecognizer>>{
                  Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
                }
              : <Factory<OneSequenceGestureRecognizer>>{
                  Factory<OneSequenceGestureRecognizer>(_PinchRecognizer.new),
                },
          hitTestBehavior: PlatformViewHitTestBehavior.translucent,
        ),
        onCreatePlatformView: (params) {
          final c = PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: 'lockbox/hdr_image',
            layoutDirection: TextDirection.ltr,
            creationParams: {'bytes': bytes},
            creationParamsCodec: const StandardMessageCodec(),
          );
          c.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
          c.create();
          return c;
        },
      );
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({super.key, required this.item, required this.active, required this.onTap});
  final MediaItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  int _skip = 0; // -1 / +1 shows the skip indicator
  Timer? _skipTimer;

  @override
  void dispose() {
    _skipTimer?.cancel();
    super.dispose();
  }

  void _doubleTap(TapDownDetails d, BoxConstraints c) {
    final player = context.read<AppState>().player;
    final third = c.maxWidth / 3;
    final s = player.state.value;
    if (d.localPosition.dx < third) {
      player.seek(s.position - const Duration(seconds: 10) < Duration.zero
          ? Duration.zero
          : s.position - const Duration(seconds: 10));
      _showSkip(-1);
    } else if (d.localPosition.dx > third * 2) {
      final to = s.position + const Duration(seconds: 10);
      player.seek(s.duration > Duration.zero && to > s.duration ? s.duration : to);
      _showSkip(1);
    } else {
      player.togglePlay();
    }
  }

  void _showSkip(int dir) {
    setState(() => _skip = dir);
    _skipTimer?.cancel();
    _skipTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _skip = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final thumb = Hero(tag: 'media-${widget.item.id}', child: MediaThumb(widget.item, fit: BoxFit.contain));
    if (!widget.active) return SizedBox.expand(child: thumb);
    final player = app.player;
    return LayoutBuilder(builder: (context, c) {
      TapDownDetails? down;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: (d) => down = d,
        onDoubleTap: () => down == null ? null : _doubleTap(down!, c),
        child: Stack(fit: StackFit.expand, children: [
          ValueListenableBuilder<PlaybackState>(
            valueListenable: player.state,
            builder: (context, s, _) {
              if (s.playing &&
                  widget.item.thumbId == null &&
                  s.position > const Duration(milliseconds: 800)) {
                WidgetsBinding.instance.addPostFrameCallback(
                    (_) => app.thumbnailFromPlayback(widget.item, s.position));
              }
              if (s.duration > Duration.zero && widget.item.durationMs == null) {
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => app.learnDuration(widget.item, s.duration));
              }
              final started = s.width > 0 && (s.position > Duration.zero || s.playing);
              return Stack(fit: StackFit.expand, children: [
                if (!started) thumb,
                Opacity(opacity: started ? 1 : 0.01, child: player.buildView()),
                if (s.buffering && !started)
                  const Center(child: CircularProgressIndicator(color: Colors.white)),
                if (s.error != null && !started && !s.buffering)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Can\'t play this video on this device.\n${s.error}',
                          textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                    ),
                  ),
              ]);
            },
          ),
          if (_skip != 0)
            Align(
              alignment: _skip < 0 ? const Alignment(-0.7, 0) : const Alignment(0.7, 0),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_skip < 0 ? Icons.fast_rewind : Icons.fast_forward, color: Colors.white, size: 32),
                  const Text('10 s', style: TextStyle(color: Colors.white)),
                ]),
              ),
            ),
        ]),
      );
    });
  }
}

class _AudioPage extends StatelessWidget {
  const _AudioPage({super.key, required this.item, required this.onTap});
  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final player = context.read<AppState>().player;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 240,
            height: 240,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: item.thumbId != null
                  ? Hero(tag: 'media-${item.id}', child: MediaThumb(item))
                  : Container(
                      color: Colors.white10,
                      child: const Icon(Icons.music_note, size: 120, color: Colors.white54),
                    ),
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(item.name,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18)),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<PlaybackState>(
            valueListenable: player.state,
            builder: (_, s, _) => IconButton.filled(
              iconSize: 48,
              onPressed: player.togglePlay,
              icon: Icon(s.playing ? Icons.pause : Icons.play_arrow),
            ),
          ),
        ]),
      ),
    );
  }
}

// --------------------------------------------------------------- chrome

class _TopBar extends StatelessWidget {
  const _TopBar({required this.item, required this.position, required this.onMenu});
  final MediaItem item;
  final String position;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: Row(children: [
            const BackButton(color: Colors.white),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(formatDate(item.mediaDate),
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
                Text(
                  [
                    position,
                    if (item.hdr.isHdr) item.hdr.label,
                    if (item.fps != null && item.kind == MediaKind.video) '${item.fps!.round()} fps',
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ]),
            ),
            PopupMenuButton<String>(
              iconColor: Colors.white,
              onSelected: onMenu,
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'move', child: Text('Move to folder')),
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (item.kind == MediaKind.video || item.kind == MediaKind.audio)
                  CheckedPopupMenuItem(
                      value: 'loop', checked: app.settings.loopVideos, child: const Text('Loop')),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _PlaybackBar extends StatefulWidget {
  const _PlaybackBar({required this.item, required this.onInteract});
  final MediaItem item;
  final VoidCallback onInteract;

  @override
  State<_PlaybackBar> createState() => _PlaybackBarState();
}

class _PlaybackBarState extends State<_PlaybackBar> {
  double? _scrub; // milliseconds while dragging
  bool _wasPlaying = false;

  static const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  bool _saving = false;

  Future<void> _saveFrame(Duration at) async {
    if (_saving) return;
    final app = context.read<AppState>();
    setState(() => _saving = true);
    try {
      final saved = await app.saveFrame(widget.item, at);
      if (!mounted) return;
      final note = app.player.lastCaptureNote;
      final String msg;
      if (saved == null) {
        msg = 'Couldn\'t capture this frame – please try again';
      } else if (saved.hdr == HdrFormat.ultraHdr) {
        msg = 'Frame saved to Screenshots (Ultra HDR'
            '${note == null || note.isEmpty ? '' : ', $note'})';
      } else if (note != null && note.isNotEmpty) {
        msg = 'Frame saved to Screenshots (standard photo: $note)';
      } else {
        msg = 'Frame saved to Screenshots in Lockbox';
      }
      snack(context, msg);
    } catch (e) {
      final msg = e is PlatformException ? (e.message ?? e.code) : e.toString();
      if (mounted) snack(context, 'Couldn\'t capture this frame: $msg');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<AppState>().player;
    return ValueListenableBuilder<PlaybackState>(
      valueListenable: player.state,
      builder: (context, s, _) {
        final dur = s.duration.inMilliseconds.toDouble();
        final pos = (_scrub ?? s.position.inMilliseconds.toDouble()).clamp(0.0, dur <= 0 ? 0.0 : dur);
        const white = TextStyle(color: Colors.white, fontSize: 12);
        final isVideo = widget.item.kind == MediaKind.video;
        Widget btn(IconData icon, String tip, VoidCallback onTap, {double size = 26}) => IconButton(
              color: Colors.white,
              iconSize: size,
              tooltip: tip,
              icon: Icon(icon),
              onPressed: () {
                onTap();
                widget.onInteract();
              },
            );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Row 1: scrubber with times
            Row(children: [
              Text(formatDuration(Duration(milliseconds: pos.round())), style: white),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      min: 0,
                      max: dur <= 0 ? 1 : dur,
                      value: dur <= 0 ? 0 : pos,
                      onChangeStart: (v) {
                        _wasPlaying = s.playing;
                        player.pause();
                        player.beginScrub();
                        setState(() => _scrub = v);
                      },
                      onChanged: (v) {
                        setState(() => _scrub = v);
                        player.scrubTo(Duration(milliseconds: v.round()));
                      },
                      onChangeEnd: (v) async {
                        await player.endScrub(Duration(milliseconds: v.round()));
                        if (_wasPlaying) await player.play();
                        setState(() => _scrub = null);
                        widget.onInteract();
                      },
                    ),
                  ),
                ),
              ),
              Text(formatDuration(s.duration), style: white),
            ]),
            // Row 2: buttons
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              PopupMenuButton<double>(
                tooltip: 'Speed',
                onSelected: player.setSpeed,
                itemBuilder: (_) => [
                  for (final sp in _speeds)
                    CheckedPopupMenuItem(
                        value: sp, checked: (s.speed - sp).abs() < 0.01, child: Text('${sp}x')),
                ],
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Text('${s.speed == s.speed.roundToDouble() ? s.speed.toInt() : s.speed}x',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              // Frame tools only appear while the video is paused.
              if (isVideo && !s.playing)
                btn(Icons.skip_previous_outlined, 'Previous frame',
                    () => player.stepFrame(-1, widget.item.fps)),
              btn(s.playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  s.playing ? 'Pause' : 'Play', player.togglePlay,
                  size: 44),
              if (isVideo && !s.playing)
                btn(Icons.skip_next_outlined, 'Next frame',
                    () => player.stepFrame(1, widget.item.fps)),
              if (isVideo && !s.playing)
                IconButton(
                  color: Colors.white,
                  disabledColor: Colors.white38,
                  tooltip: 'Save frame to Lockbox',
                  icon: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.photo_camera_outlined),
                  onPressed: s.position > Duration.zero && !_saving
                      ? () => _saveFrame(s.position)
                      : null,
                ),
              btn(s.volume == 0 ? Icons.volume_off : Icons.volume_up,
                  s.volume == 0 ? 'Unmute' : 'Mute',
                  () => player.setVolume(s.volume == 0 ? 1 : 0)),
            ]),
          ]),
        );
      },
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.item, required this.onInfo, required this.onChanged});
  final MediaItem item;
  final VoidCallback onInfo;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    Widget action(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, color: Colors.white),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
              ]),
            ),
          ),
        );
    return Row(children: [
      action(item.favorite ? Icons.favorite : Icons.favorite_border, 'Favorite',
          () => app.setFavorite([item], !item.favorite)),
      action(Icons.sell_outlined, 'Tags', () => editTags(context, [item])),
      action(Icons.info_outline, 'Info', onInfo),
      action(Icons.lock_open_outlined, 'Restore', () async {
        await restoreItems(context, [item]);
        await onChanged();
      }),
      action(Icons.delete_outline, 'Delete', () async {
        final ok = await confirm(context,
            title: 'Delete this item?',
            message: 'It will be permanently erased from Lockbox.',
            ok: 'Delete',
            danger: true);
        if (!ok) return;
        await app.deleteItems([item.id]);
        await onChanged();
      }),
    ]);
  }
}

class _InfoSheet extends StatelessWidget {
  const _InfoSheet({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final tags = app.tagsById;
    final folder = item.folderId == null ? null : app.foldersById[item.folderId];
    Widget row(IconData icon, String title, String? value) => value == null || value.isEmpty
        ? const SizedBox.shrink()
        : ListTile(dense: true, leading: Icon(icon), title: Text(title), subtitle: Text(value));
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            title: Text(item.name, style: Theme.of(context).textTheme.titleMedium),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final n = await promptText(context, title: 'Rename', initial: item.name, ok: 'Rename');
                if (n != null && n.isNotEmpty) await app.rename(item, n);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in item.tagIds)
                if (tags[t] != null)
                  Chip(
                    avatar: CircleAvatar(backgroundColor: Color(tags[t]!.color), radius: 6),
                    label: Text(tags[t]!.name),
                    onDeleted: () => app.removeTag([item], t),
                  ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Tag'),
                onPressed: () => editTags(context, [item]),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          row(Icons.event, 'Taken', item.createdAt == null ? 'Unknown' : formatDate(item.createdAt!)),
          row(Icons.add_circle_outline, 'Added to Lockbox', formatDate(item.addedAt)),
          row(Icons.timer_outlined, 'Length',
              item.durationMs == null ? null : formatDuration(Duration(milliseconds: item.durationMs!))),
          row(Icons.aspect_ratio, 'Resolution', resolutionLabel(item)),
          row(Icons.slow_motion_video, 'Frame rate',
              item.fps == null ? null : '${item.fps!.toStringAsFixed(item.fps! % 1 == 0 ? 0 : 2)} fps'),
          row(Icons.hdr_on, 'Dynamic range',
              item.kind == MediaKind.video || item.hdr.isHdr ? item.hdr.label : null),
          row(Icons.memory, 'Format', [item.mimeType, ?item.codec].join(' · ')),
          row(Icons.storage, 'Size', formatBytes(item.sizeBytes)),
          row(Icons.folder_outlined, 'Lockbox folder', folder?.name ?? 'Library'),
          row(Icons.history, 'Original location', item.originalLocation),
          ListTile(
            dense: true,
            leading: const Icon(Icons.notes),
            title: const Text('Note'),
            subtitle: Text(item.note ?? 'Add a private note'),
            onTap: () async {
              final n = await promptText(context, title: 'Note', initial: item.note ?? '', ok: 'Save');
              if (n == null) return;
              item.note = n.isEmpty ? null : n;
              await app.changed();
            },
          ),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }
}
