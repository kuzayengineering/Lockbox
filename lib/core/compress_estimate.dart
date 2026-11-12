// Size estimates for "Make smaller copy" (H.265, variable bit rate).
//
// Target video bit rate = pixels per second x bits per pixel for the chosen
// quality, but never more than the original's own bit rate scaled to the new
// size and frame rate (so a copy is never planned to be bigger than its
// source). Audio is re-encoded at about 128 kbit/s.

import 'dart:math' as math;

enum CompressQuality { high, medium, low }

extension CompressQualityLabel on CompressQuality {
  String get label => switch (this) {
        CompressQuality.high => 'High',
        CompressQuality.medium => 'Medium',
        CompressQuality.low => 'Low',
      };

  String get hint => switch (this) {
        CompressQuality.high => 'Hard to tell apart from the original',
        CompressQuality.medium => 'Good for most viewing',
        CompressQuality.low => 'Smallest; softer detail',
      };

  /// H.265 bits per pixel per frame.
  double get bitsPerPixel => switch (this) {
        CompressQuality.high => 0.08,
        CompressQuality.medium => 0.05,
        CompressQuality.low => 0.03,
      };
}

const int kAudioBitrate = 128000;

/// Standard resolutions offered, by the short side of the picture.
const List<int> kShortSides = [2160, 1440, 1080, 720, 480];
const List<double> kFrameRates = [60, 30, 24];

class CompressPlan {
  CompressPlan({
    required this.width,
    required this.height,
    required this.fps,
    required this.videoBitrate,
    required this.estimatedBytes,
    required this.originalBytes,
  });

  final int width;
  final int height;
  final double fps;
  final int videoBitrate;
  final int estimatedBytes;
  final int originalBytes;

  int get savedBytes => originalBytes - estimatedBytes;
  double get savedFraction => originalBytes <= 0 ? 0 : savedBytes / originalBytes;
  bool get saves => savedFraction >= 0.05;
}

/// Output size for a new short side, keeping the aspect ratio (even numbers,
/// as video encoders require).
(int, int) scaledSize(int width, int height, int? shortSide) {
  if (shortSide == null || shortSide >= math.min(width, height)) {
    return (width, height);
  }
  final k = shortSide / math.min(width, height);
  int even(double v) => (v / 2).round() * 2;
  return width <= height
      ? (shortSide, even(height * k))
      : (even(width * k), shortSide);
}

CompressPlan planCompression({
  required int width,
  required int height,
  required double fps,
  required int durationMs,
  required int originalBytes,
  int? shortSide, // null = keep
  double? targetFps, // null = keep
  required CompressQuality quality,
}) {
  final (w, h) = scaledSize(width, height, shortSide);
  final outFps = targetFps == null ? fps : math.min(targetFps, fps);
  final seconds = math.max(durationMs, 1) / 1000;
  final model = w * h * outFps * quality.bitsPerPixel;
  // The original's video bit rate, scaled to the new pixel and frame rate.
  final origVideo = math.max(originalBytes * 8 / seconds - kAudioBitrate, 100000);
  final scale = (w * h) / math.max(width * height, 1) * (outFps / math.max(fps, 1));
  final cap = origVideo * scale;
  final bitrate = math.max(200000, math.min(model, cap)).round();
  final bytes = ((bitrate + kAudioBitrate) * seconds / 8).round();
  return CompressPlan(
    width: w,
    height: h,
    fps: outFps,
    videoBitrate: bitrate,
    estimatedBytes: bytes,
    originalBytes: originalBytes,
  );
}
