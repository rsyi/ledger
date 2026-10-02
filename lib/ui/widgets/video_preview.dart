import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';

import '../../services/video_file_store.dart';
import '../../services/video_frames.dart';
import '../../services/video_ref.dart';
import '../../services/video_rpe.dart' show frameTimestampsMs;
import '../../services/video_thumb_store.dart';
import 'video_player_screen.dart';

/// Plays the clip IN-APP when it's on the device — a cached copy in app
/// storage (legacy Photos-picker downloads, or local picks whose grant
/// couldn't be persisted) or a local content:// reference (system photo
/// picker). Legacy Google Photos links with no cached copy open in the
/// Photos app. Resolution: video_ref.dart playbackTargetFor (tested).
Future<void> playVideo(
    BuildContext context, String url, String? mediaId, {String? title}) async {
  final file = await VideoFileStore.load(mediaId);
  if (!context.mounted) return;
  switch (playbackTargetFor(ref: url, hasCachedFile: file != null)) {
    case VideoPlayback.none:
      return;
    case VideoPlayback.cachedFile:
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(file: file, title: title),
      ));
      return;
    case VideoPlayback.localUri:
      final ref = url.trim();
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ref.startsWith('content://')
            ? VideoPlayerScreen(contentUri: Uri.parse(ref), title: title)
            : VideoPlayerScreen(
                file: File(ref.startsWith('file://')
                    ? Uri.parse(ref).toFilePath()
                    : ref),
                title: title),
      ));
      return;
    case VideoPlayback.external:
      break;
  }
  // Fallback: prefer the Google Photos APP (not the browser). Try
  // launching straight into the package — canResolveActivity() is
  // unreliable here (package-visibility false-negatives sent it to the
  // browser), so we just attempt it and fall back only if it throws.
  const photosPkg = 'com.google.android.apps.photos';
  try {
    await AndroidIntent(
      action: 'android.intent.action.VIEW',
      data: url,
      package: photosPkg,
    ).launch();
    return;
  } catch (_) {/* Photos not installed / can't handle it → default below */}
  try {
    await AndroidIntent(action: 'android.intent.action.VIEW', data: url)
        .launch();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open video: $e')),
      );
    }
  }
}

/// Cached thumbnail for [mediaId]; for LOCAL refs with no cached frame
/// yet (attach-time capture failed / cache cleared), extracts the mid
/// frame from the device clip and caches it. Null = placeholder.
Future<File?> _thumbFor(String url, String? mediaId) async {
  final cached = await VideoThumbStore.load(mediaId);
  if (cached != null || mediaId == null || mediaId.isEmpty) return cached;
  final clip = await VideoFileStore.load(mediaId);
  final src = frameSourceFor(ref: url, cachedPath: clip?.path);
  if (src == null) return null;
  try {
    final x = ChannelFrameExtractor();
    final mid = frameTimestampsMs(await x.durationMs(src), count: 1);
    final frames = await x.framesAt(src, mid, maxWidth: 256);
    if (frames.isEmpty) return null;
    await VideoThumbStore.save(mediaId, frames.first);
    return VideoThumbStore.load(mediaId);
  } catch (_) {
    return null; // clip gone / grant revoked → placeholder
  }
}

/// A tappable video thumbnail (cached frame) with a play glyph. Tap plays
/// the clip in-app (or Google Photos for legacy links). Shows a movie
/// placeholder when no thumbnail is available. Used inline in log rows
/// (small) and the Today highlights strip (larger).
class VideoThumb extends StatelessWidget {
  final String url;
  final String? mediaId;
  final String? label;

  /// Player title when there's no caption [label] (inline thumbs).
  final String? title;
  final double size;

  const VideoThumb({
    super.key,
    required this.url,
    required this.mediaId,
    this.label,
    this.title,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyph = (size * 0.3).clamp(14.0, 30.0);
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(size < 56 ? 7 : 10),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            FutureBuilder<File?>(
              future: _thumbFor(url, mediaId),
              builder: (ctx, snap) {
                final file = snap.data;
                if (file != null) {
                  return Image.file(file,
                      width: size, height: size, fit: BoxFit.cover);
                }
                return Container(
                  width: size,
                  height: size,
                  color: scheme.surfaceContainerHighest,
                  child: Icon(Icons.movie_outlined,
                      color: scheme.onSurfaceVariant, size: glyph),
                );
              },
            ),
            Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                shape: BoxShape.circle,
              ),
              padding: EdgeInsets.all(glyph * 0.22),
              child: Icon(Icons.play_arrow, color: Colors.white, size: glyph),
            ),
          ],
        ),
      ),
    );

    return GestureDetector(
      onTap: () => playVideo(context, url, mediaId, title: label ?? title),
      child: label == null
          ? thumb
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                thumb,
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: SizedBox(
                    width: size,
                    child: Text(label!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
              ],
            ),
    );
  }
}
