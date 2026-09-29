/// Injectable seam over the MainActivity `video_frames` platform
/// channel (MediaMetadataRetriever). Chosen over the video_thumbnail
/// plugin: same underlying Android API, but one-frame-per-call only and
/// another version pin to babysit — the ~40-line channel keeps frame
/// count/size/quality under our control with zero new dependencies.
library;

import 'package:flutter/services.dart';

abstract class FrameExtractor {
  /// Video duration in milliseconds (0 when the container is garbled).
  Future<int> durationMs(String path);

  /// JPEG bytes for the frames closest to [timestampsMs], in order.
  /// Unreadable timestamps are skipped (result may be shorter).
  Future<List<Uint8List>> framesAt(
    String path,
    List<int> timestampsMs, {
    int maxWidth = 512,
    int quality = 70,
  });
}

class ChannelFrameExtractor implements FrameExtractor {
  static const _channel = MethodChannel('com.robertyi.fitness/video_frames');

  @override
  Future<int> durationMs(String path) async {
    final res = await _channel
        .invokeMapMethod<String, Object?>('probe', {'path': path});
    return (res?['durationMs'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<Uint8List>> framesAt(
    String path,
    List<int> timestampsMs, {
    int maxWidth = 512,
    int quality = 70,
  }) async {
    final res = await _channel.invokeListMethod<Object?>('frames', {
      'path': path,
      'timestampsMs': timestampsMs,
      'maxWidth': maxWidth,
      'quality': quality,
    });
    return [
      for (final f in res ?? const [])
        if (f is Uint8List) f,
    ];
  }
}
