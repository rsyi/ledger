import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/photos_verify.dart';
import '../../services/video_attach.dart';
import '../../services/video_file_store.dart';
import '../../services/video_frames.dart';
import '../../services/video_ref.dart';
import '../../services/video_thumb_store.dart';
import 'video_player_screen.dart';
import 'video_preview.dart' show openPhotosLink;

/// Device access the clip-linking screens need, behind one seam (tests
/// inject a fake): where a row's LOCAL clip can be read, its local
/// thumbnail, the frame extractor, the saved cloud thumbnails, and the
/// two playback paths (in-app player for the local clip; the Google
/// Photos app for the cloud copy).
abstract class ClipMediaAccess {
  FrameExtractor get frames;
  PhotosThumbStore get cloudThumbs;

  /// The app-storage copy, else the local ref when it still opens
  /// (grant alive, clip not deleted); null = no local clip.
  Future<String?> localSource(Map<String, Object?> row, String videoField);

  /// Local frame cache, else the synced `<base>_thumb`.
  Future<Uint8List?> localThumb(Map<String, Object?> row, String videoField);

  Future<void> playLocal(BuildContext context, String source, {String? title});
  Future<void> openPhotos(BuildContext context, String url);
}

class DeviceClipMediaAccess implements ClipMediaAccess {
  DeviceClipMediaAccess({FrameExtractor? frames, PhotosThumbStore? cloudThumbs})
      : frames = frames ?? ChannelFrameExtractor(),
        cloudThumbs = cloudThumbs ?? PhotosThumbStore.instance;

  @override
  final FrameExtractor frames;
  @override
  final PhotosThumbStore cloudThumbs;

  String? _mid(Map<String, Object?> row, String videoField) {
    final m = row['${videoFieldBase(videoField)}_media_id']?.toString().trim();
    return (m == null || m.isEmpty) ? null : m;
  }

  @override
  Future<String?> localSource(
      Map<String, Object?> row, String videoField) async {
    final cached = await VideoFileStore.load(_mid(row, videoField));
    if (cached != null) return cached.path;
    final ref = row[videoField]?.toString().trim() ?? '';
    if (!isLocalVideoRef(ref)) return null;
    if (ref.startsWith('content://')) {
      return await ChannelLocalVideoPicker.canRead(ref) ? ref : null;
    }
    final path = ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;
    return await File(path).exists() ? path : null;
  }

  @override
  Future<Uint8List?> localThumb(
      Map<String, Object?> row, String videoField) async {
    try {
      final f = await VideoThumbStore.load(_mid(row, videoField));
      if (f != null) return await f.readAsBytes();
    } catch (_) {/* fall through to the synced thumb */}
    return decodeThumbDataUri(row[thumbFieldFor(videoField)]?.toString());
  }

  @override
  Future<void> playLocal(BuildContext context, String source,
      {String? title}) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => source.startsWith('content://')
            ? VideoPlayerScreen(contentUri: Uri.parse(source), title: title)
            : VideoPlayerScreen(file: File(source), title: title),
      ));

  @override
  Future<void> openPhotos(BuildContext context, String url) =>
      openPhotosLink(context, url);
}
