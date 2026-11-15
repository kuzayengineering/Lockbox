// Frame stepping must stop on the last real frame (seeking to the very end
// leaves the player with nothing to show, which flickers).


import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lockbox/core/models.dart';
import 'package:lockbox/platform/player.dart';

class FakePlayer extends MediaPlayer {
  final seeks = <int>[];
  final _state = ValueNotifier(const PlaybackState(
      position: Duration(milliseconds: 800), duration: Duration(milliseconds: 1000)));

  @override
  ValueListenable<PlaybackState> get state => _state;
  @override
  Future<void> seek(Duration to) async {
    seeks.add(to.inMilliseconds);
    _state.value = _state.value.copyWith(position: to);
  }

  @override
  Future<void> open(MediaItem item, {bool autoplay = true, bool loop = false, bool muted = false}) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setLooping(bool loop) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Widget buildView() => const SizedBox();
  @override
  Future<void> beginScrub() async {}
  @override
  Future<void> scrubTo(Duration to) async {}
  @override
  Future<void> endScrub(Duration finalPosition) async {}
  @override
  Future<Uint8List?> captureFrame(MediaItem item, Duration position,
          {bool allowInterrupt = true}) async =>
      null;
}

void main() {
  test('stepping forward stops on the last frame; back still works', () async {
    final p = FakePlayer(); // 1 s video at 10 fps: last frame starts at 900 ms
    await p.stepFrame(1, 10); // 900
    await p.stepFrame(1, 10); // already on the last frame: no seek
    await p.stepFrame(1, 10); // still none
    expect(p.seeks, [900]);
    await p.stepFrame(-1, 10);
    expect(p.seeks, [900, 800]);
  });

  test('stepping back stops at the start', () async {
    final p = FakePlayer();
    for (var i = 0; i < 12; i++) {
      await p.stepFrame(-1, 10);
    }
    expect(p.seeks.last, 0);
    expect(p.seeks.where((s) => s == 0).length, 1, reason: 'no repeated seeks at 0');
  });
}
