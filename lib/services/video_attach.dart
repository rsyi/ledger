/// Local-video attach flow for `widget: video` fields (2026-10-02).
///
/// Replaces the Google Photos Picker API flow, whose short-lived
/// baseUrl download (~60 min, and flaky before that) kept failing with
/// "the picker link may have expired". The lift clips are already on
/// the phone (Google Photos backs them up FROM the device), so attach
/// now opens the Android SYSTEM photo picker (video only — no runtime
/// permission needed) and stores a reference to the local file:
///
///   pick (MainActivity `video_pick` channel) → content:// URI with a
///   PERSISTED read grant (takePersistableUriPermission) → `video_url`
///   = the URI, `video_media_id` = localMediaIdFor(uri).
///
/// When Android won't persist the grant (some providers/cloud items),
/// the clip is copied into app storage (VideoFileStore path) while the
/// one-shot grant is still live — playback/frames then read the copy.
/// Frames for the RPE estimate are read straight from the URI/copy —
/// nothing is downloaded, nothing expires.
library;

import 'package:flutter/services.dart';

import 'video_ref.dart';

/// User closed the picker / never picked — not an error.
class VideoAttachCancelled implements Exception {
  const VideoAttachCancelled();
  @override
  String toString() => 'Video attach cancelled';
}

/// A real, user-facing attach failure. [message] is phrased for the
/// snackbar (what happened + that a retry is reasonable).
class VideoAttachException implements Exception {
  const VideoAttachException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the platform picker hands back.
class PickedLocalVideo {
  const PickedLocalVideo({
    required this.uri,
    required this.persisted,
    this.mimeType,
    this.name,
    this.sizeBytes,
  });

  final String uri;

  /// True when takePersistableUriPermission succeeded (the URI stays
  /// readable across restarts).
  final bool persisted;
  final String? mimeType;
  final String? name;
  final int? sizeBytes;

  static PickedLocalVideo fromChannel(Map<Object?, Object?> m) {
    final uri = m['uri'];
    if (uri is! String || uri.isEmpty) {
      throw const VideoAttachException(
          'The picker returned no video — tap Attach video to try again.');
    }
    return PickedLocalVideo(
      uri: uri,
      persisted: m['persisted'] == true,
      mimeType: m['mimeType'] as String?,
      name: m['name'] as String?,
      sizeBytes: (m['size'] as num?)?.toInt(),
    );
  }
}

/// Injectable seam over the platform picker.
abstract class LocalVideoPicker {
  /// Opens the system picker (video only). Null = cancelled.
  Future<PickedLocalVideo?> pick();

  /// Streams [uri]'s bytes into [destPath] (native side, no Dart copy).
  Future<void> copyTo(String uri, String destPath);
}

class ChannelLocalVideoPicker implements LocalVideoPicker {
  static const _channel = MethodChannel('com.robertyi.fitness/video_pick');

  @override
  Future<PickedLocalVideo?> pick() async {
    final res = await _channel.invokeMapMethod<Object?, Object?>('pick');
    if (res == null) return null;
    return PickedLocalVideo.fromChannel(res);
  }

  @override
  Future<void> copyTo(String uri, String destPath) =>
      _channel.invokeMethod<void>('copy', {'uri': uri, 'dest': destPath});
}

class VideoAttachResult {
  const VideoAttachResult({
    required this.mediaId,
    required this.url,
    this.cachedPath,
    this.mimeType,
    this.filename,
  });

  /// Stable id derived from the URI (→ `video_media_id`; keys the
  /// thumbnail/clip caches + the RPE estimate).
  final String mediaId;

  /// The local reference (→ `video_url`): a content:// URI.
  final String url;

  /// App-storage copy, set only when the grant couldn't be persisted.
  final String? cachedPath;

  final String? mimeType;
  final String? filename;

  /// What the frame extractor / player should read.
  String get frameSource => frameSourceFor(ref: url, cachedPath: cachedPath)!;
}

class VideoAttachFlow {
  VideoAttachFlow({
    LocalVideoPicker? picker,
    required this.cachePathFor,
  }) : picker = picker ?? ChannelLocalVideoPicker();

  final LocalVideoPicker picker;

  /// App-storage path for a clip copy (VideoFileStore.pathFor).
  final Future<String> Function(String mediaId) cachePathFor;

  /// Throws [VideoAttachCancelled] on cancel, [VideoAttachException] on
  /// a non-video pick or when the clip can't be kept readable.
  Future<VideoAttachResult> pickVideo() async {
    final PickedLocalVideo? picked;
    try {
      picked = await picker.pick();
    } on VideoAttachException {
      rethrow;
    } catch (e) {
      throw VideoAttachException(
          'Couldn\'t open the video picker ($e) — tap Attach video to try '
          'again.');
    }
    if (picked == null) throw const VideoAttachCancelled();
    final mime = picked.mimeType;
    if (mime != null && mime.isNotEmpty && !mime.startsWith('video/')) {
      throw const VideoAttachException(
          'That\'s not a video — pick a video clip and try again.');
    }
    final mediaId = localMediaIdFor(picked.uri);
    String? cached;
    if (!picked.persisted) {
      // No lasting grant: copy NOW while the one-shot grant is live.
      final dest = await cachePathFor(mediaId);
      try {
        await picker.copyTo(picked.uri, dest);
        cached = dest;
      } catch (e) {
        throw VideoAttachException(
            'Couldn\'t keep access to this video (Android didn\'t grant '
            'lasting access and copying it failed: $e) — try again, or pick '
            'it from the Photos tab of the picker.');
      }
    }
    return VideoAttachResult(
      mediaId: mediaId,
      url: picked.uri,
      cachedPath: cached,
      mimeType: mime,
      filename: picked.name,
    );
  }
}
