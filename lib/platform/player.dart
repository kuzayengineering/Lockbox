// One video/audio player interface with two engines:
//  * Android: ExoPlayer (Media3) in a native SurfaceView -> true HDR10/HLG/
//    Dolby Vision output and full 60 fps, decrypting inside the player.
//  * Windows: libmpv (media_kit) fed by the private loopback MediaServer.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;

import '../core/media_server.dart';
import '../core/models.dart';
import '../core/ultra_hdr.dart';
import '../core/vault.dart';
import 'native.dart';

@immutable
class PlaybackState {
  const PlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.ended = false,
    this.width = 0,
    this.height = 0,
    this.volume = 1,
    this.speed = 1,
    this.error,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool playing;
  final bool buffering;
  final bool ended;
  final int width;
  final int height;
  final double volume; // 0..1
  final double speed;
  final String? error;

  PlaybackState copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? playing,
    bool? buffering,
    bool? ended,
    int? width,
    int? height,
    double? volume,
    double? speed,
    String? error,
  }) =>
      PlaybackState(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        buffered: buffered ?? this.buffered,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        ended: ended ?? this.ended,
        width: width ?? this.width,
        height: height ?? this.height,
        volume: volume ?? this.volume,
        speed: speed ?? this.speed,
        error: error ?? this.error,
      );
}

abstract class MediaPlayer {
  static MediaPlayer create(Vault vault, {MediaServer? server}) {
    if (Platform.isAndroid) return _AndroidPlayer(vault);
    return _MpvPlayer(server!);
  }

  ValueListenable<PlaybackState> get state;
  Future<void> open(MediaItem item,
      {bool autoplay = true, bool loop = false, bool muted = false});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<void> setLooping(bool loop);
  Future<void> stop();
  Future<void> dispose();

  /// The video picture. Only one should be on screen at a time.
  Widget buildView();

  /// Call when the user starts / stops dragging the scrub bar. In between,
  /// call [scrubTo] for every movement: frames update in real time.
  Future<void> beginScrub();
  Future<void> scrubTo(Duration to);
  Future<void> endScrub(Duration finalPosition);

  /// JPEG of the video frame at [position] (the paused frame).
  /// If [allowInterrupt] is false, only methods that don't disturb
  /// playback are used (for automatic thumbnails).
  Future<Uint8List?> captureFrame(MediaItem item, Duration position,
      {bool allowInterrupt = true});

  Future<void> togglePlay() =>
      state.value.playing ? pause() : play();

  /// Pauses and moves one frame forward ([direction] = 1) or back (-1).
  /// [fps] is the video's frame rate (defaults to 30 if unknown).
  Future<void> stepFrame(int direction, double? fps) async {
    final frameMs = 1000 / ((fps == null || fps <= 0) ? 30 : fps);
    final s = state.value;
    if (s.playing) await pause();
    // Successive taps build on the last target, not the (lagging) reported
    // position, so each tap moves exactly one frame.
    final now = DateTime.now();
    final base = (_stepTarget != null &&
            _stepAt != null &&
            now.difference(_stepAt!) < const Duration(seconds: 2))
        ? _stepTarget!
        : s.position.inMicroseconds / 1000;
    var target = base + direction * frameMs;
    final maxMs = s.duration.inMilliseconds.toDouble();
    if (target < 0) target = 0;
    if (maxMs > 0 && target > maxMs) target = maxMs;
    _stepTarget = target;
    _stepAt = now;
    await seek(Duration(microseconds: (target * 1000).round()));
  }

  double? _stepTarget;
  DateTime? _stepAt;
}

// ---------------------------------------------------------------- Android

class _AndroidPlayer extends MediaPlayer {
  _AndroidPlayer(this._vault) {
    _sub = const EventChannel('lockbox/player/events')
        .receiveBroadcastStream()
        .listen(_onEvent, onError: (_) {});
  }

  static const _ch = MethodChannel('lockbox/player');
  final Vault _vault;
  final _state = ValueNotifier(const PlaybackState());
  StreamSubscription? _sub;

  @override
  ValueListenable<PlaybackState> get state => _state;

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    Duration ms(Object? v) => Duration(milliseconds: (v as num?)?.toInt() ?? 0);
    _state.value = PlaybackState(
      position: ms(e['position']),
      duration: ms(e['duration']),
      buffered: ms(e['buffered']),
      playing: e['playing'] == true,
      buffering: e['buffering'] == true,
      ended: e['ended'] == true,
      width: (e['width'] as num?)?.toInt() ?? 0,
      height: (e['height'] as num?)?.toInt() ?? 0,
      volume: (e['volume'] as num?)?.toDouble() ?? 1,
      speed: (e['speed'] as num?)?.toDouble() ?? 1,
      error: e['error'] as String?,
    );
  }

  @override
  Future<void> open(MediaItem item,
      {bool autoplay = true, bool loop = false, bool muted = false}) async {
    _state.value = const PlaybackState(buffering: true);
    final key = await _vault.fileKeyFor(item);
    await _ch.invokeMethod('open', {
      'path': _vault.blobPath(item.blobId),
      'key': key,
      'autoplay': autoplay,
      'loop': loop,
      'muted': muted,
    });
    key.fillRange(0, key.length, 0);
  }

  @override
  Future<void> play() => _ch.invokeMethod('play');
  @override
  Future<void> pause() => _ch.invokeMethod('pause');
  @override
  Future<void> seek(Duration to) =>
      _ch.invokeMethod('seek', {'ms': to.inMilliseconds});
  @override
  Future<void> setSpeed(double speed) =>
      _ch.invokeMethod('speed', {'speed': speed});

  @override
  Future<void> beginScrub() => _ch.invokeMethod('scrubStart');
  @override
  Future<void> scrubTo(Duration to) => seek(to);
  @override
  Future<void> endScrub(Duration finalPosition) async {
    await seek(finalPosition);
    await _ch.invokeMethod('scrubEnd');
  }
  @override
  Future<void> setVolume(double volume) =>
      _ch.invokeMethod('volume', {'volume': volume});
  @override
  Future<void> setLooping(bool loop) =>
      _ch.invokeMethod('loop', {'loop': loop});
  @override
  Future<void> stop() => _ch.invokeMethod('stop');

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _ch.invokeMethod('release');
    _state.dispose();
  }

  @override
  Future<Uint8List?> captureFrame(MediaItem item, Duration position,
      {bool allowInterrupt = true}) async {
    // 1. Copy what's on screen (no second decoder needed). On Android 14+
    //    this keeps HDR highlights and is saved as Ultra HDR.
    Uint8List? shown;
    try {
      shown = await _ch.invokeMethod<Uint8List>('captureDisplayed');
    } catch (_) {}
    final shownOk = shown != null && shown.isNotEmpty;
    final wantHdr = item.hdr.isHdr && await Native.androidSdk() >= 34;
    if (shownOk && (!allowInterrupt || !wantHdr || looksUltraHdr(shown))) {
      return shown;
    }
    if (!allowInterrupt) return null;
    // 2. Free the player's decoder, extract the frame from the file (in HDR
    //    if possible), then put the video back where it was (paused).
    final key = await _vault.fileKeyFor(item);
    await _ch.invokeMethod('suspendDecoders');
    try {
      final grabbed = await const MethodChannel('lockbox/native')
          .invokeMethod<Uint8List>('grabFrame', {
        'blob': _vault.blobPath(item.blobId),
        'key': key,
        'positionMs': position.inMilliseconds,
        'hdr': wantHdr,
      });
      if (grabbed != null && (!shownOk || looksUltraHdr(grabbed))) return grabbed;
      return shownOk ? shown : grabbed;
    } catch (_) {
      if (shownOk) return shown;
      rethrow;
    } finally {
      key.fillRange(0, key.length, 0);
      await _ch.invokeMethod('resumeDecoders', {'ms': position.inMilliseconds});
    }
  }

  @override
  Widget buildView() => PlatformViewLink(
        viewType: 'lockbox/video_view',
        surfaceFactory: (context, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        ),
        onCreatePlatformView: (params) {
          // "Expensive" = hybrid composition: the real SurfaceView is used,
          // which is what lets Android show HDR video in true HDR.
          final c = PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: 'lockbox/video_view',
            layoutDirection: TextDirection.ltr,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          );
          c.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
          c.create();
          return c;
        },
      );
}

// ---------------------------------------------------------------- Windows

class _MpvPlayer extends MediaPlayer {
  _MpvPlayer(this._server) {
    final s = _p.stream;
    _subs.addAll([
      s.position.listen((v) => _set(_state.value.copyWith(position: v))),
      s.duration.listen((v) => _set(_state.value.copyWith(duration: v))),
      s.buffer.listen((v) => _set(_state.value.copyWith(buffered: v))),
      s.playing.listen((v) =>
          _set(_state.value.copyWith(playing: v, ended: v ? false : null))),
      s.buffering.listen((v) => _set(_state.value.copyWith(buffering: v))),
      s.completed.listen((v) => _set(_state.value.copyWith(ended: v))),
      s.width.listen((v) => _set(_state.value.copyWith(width: v ?? 0))),
      s.height.listen((v) => _set(_state.value.copyWith(height: v ?? 0))),
      s.volume.listen((v) => _set(_state.value.copyWith(volume: v / 100))),
      s.rate.listen((v) => _set(_state.value.copyWith(speed: v))),
      s.error.listen((v) => _set(_state.value.copyWith(error: v))),
    ]);
  }

  final MediaServer _server;
  final mk.Player _p = mk.Player(
      configuration: const mk.PlayerConfiguration(title: 'Lockbox'));
  late final mkv.VideoController _vc = mkv.VideoController(_p,
      configuration: const mkv.VideoControllerConfiguration(
          enableHardwareAcceleration: true));
  final _state = ValueNotifier(const PlaybackState());
  final _subs = <StreamSubscription>[];

  void _set(PlaybackState s) => _state.value = s;

  @override
  ValueListenable<PlaybackState> get state => _state;

  @override
  Future<void> open(MediaItem item,
      {bool autoplay = true, bool loop = false, bool muted = false}) async {
    _state.value = const PlaybackState(buffering: true);
    await _p.setPlaylistMode(loop ? mk.PlaylistMode.single : mk.PlaylistMode.none);
    await _p.setVolume(muted ? 0 : 100);
    await _p.setRate(1);
    await _p.open(
        mk.Media(_server.urlFor(item.blobId, mimeType: item.mimeType)),
        play: autoplay);
  }

  @override
  Future<void> play() async {
    if (_state.value.ended) await _p.seek(Duration.zero);
    await _p.play();
  }

  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> seek(Duration to) => _p.seek(to);
  @override
  Future<void> setSpeed(double speed) => _p.setRate(speed);

  // While dragging, jump to the nearest keyframe (instant), skipping
  // requests that arrive while one is still being processed; the exact
  // frame is shown when the finger/mouse is released.
  bool _scrubBusy = false;
  Duration? _scrubPending;

  @override
  Future<void> beginScrub() async {}

  @override
  Future<void> scrubTo(Duration to) async {
    _scrubPending = to;
    if (_scrubBusy) return;
    _scrubBusy = true;
    try {
      while (_scrubPending != null) {
        final t = _scrubPending!;
        _scrubPending = null;
        final native = _p.platform;
        if (native is mk.NativePlayer) {
          await native.command(
              ['seek', (t.inMilliseconds / 1000).toStringAsFixed(3), 'absolute+keyframes']);
        } else {
          await _p.seek(t);
        }
      }
    } finally {
      _scrubBusy = false;
    }
  }

  @override
  Future<void> endScrub(Duration finalPosition) async {
    _scrubPending = null;
    await _p.seek(finalPosition);
  }
  @override
  Future<void> setVolume(double volume) => _p.setVolume(volume * 100);
  @override
  Future<void> setLooping(bool loop) =>
      _p.setPlaylistMode(loop ? mk.PlaylistMode.single : mk.PlaylistMode.none);
  @override
  Future<void> stop() => _p.stop();

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _p.dispose();
    _state.dispose();
  }

  @override
  Future<Uint8List?> captureFrame(MediaItem item, Duration position,
      {bool allowInterrupt = true}) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      final shot = await _p.screenshot(format: 'image/jpeg');
      if (shot != null && shot.isNotEmpty) return shot;
      await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
    }
    return null;
  }

  @override
  Widget buildView() => mkv.Video(
        controller: _vc,
        controls: mkv.NoVideoControls,
        fill: Colors.black,
      );
}

/// Windows only: makes a thumbnail + reads duration/size of a plaintext
/// video file (during import) using libmpv. Never takes longer than ~15 s:
/// a video that can't be decoded quickly just gets no thumbnail.
Future<({Uint8List? jpeg, int? durationMs, int? width, int? height})>
    mpvProbe(String path) async {
  final p = mk.Player();
  final vc = mkv.VideoController(p);
  ({Uint8List? jpeg, int? durationMs, int? width, int? height}) current(
          Uint8List? jpeg) =>
      (
        jpeg: jpeg,
        durationMs: p.state.duration == Duration.zero
            ? null
            : p.state.duration.inMilliseconds,
        width: p.state.width,
        height: p.state.height,
      );
  try {
    return await () async {
      await p.setVolume(0);
      await p.open(mk.Media(Uri.file(path).toString()), play: false);
      await vc.waitUntilFirstFrameRendered;
      if (p.state.duration > const Duration(seconds: 3)) {
        await p.seek(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      return current(await p.screenshot(format: 'image/jpeg'));
    }()
        .timeout(const Duration(seconds: 15));
  } catch (_) {
    return current(null);
  } finally {
    unawaited(p.dispose().timeout(const Duration(seconds: 5), onTimeout: () {}));
  }
}
