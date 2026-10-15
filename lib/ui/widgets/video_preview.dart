import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';

import '../../services/video_attach.dart';
import '../../services/video_file_store.dart';
import '../../services/video_frames.dart';
import '../../services/video_ref.dart';
import '../../services/video_rpe.dart' show frameTimestampsMs;
import '../../services/video_thumb_store.dart';
import 'video_player_screen.dart';

/// Plays a clip, falling back in the durable-clips order (video_ref
/// resolvePlayback, tested): the on-device clip (content:// ref still
/// readable) → the app-storage copy → the Google Photos link
/// ([photosUrl], or a legacy photos.google.com `video_url`) in the Photos
/// app → a thumbnail-only sheet ([thumbData], the synced
/// `<base>_thumb`) with a "Link to Google Photos" hint.
Future<void> playVideo(BuildContext context, String url, String? mediaId,
    {String? title, String? photosUrl, String? thumbData}) async {
  final ref = url.trim();
  final file = await VideoFileStore.load(mediaId);
  var readable = false;
  if (isLocalVideoRef(ref)) {
    readable = ref.startsWith('content://')
        ? await ChannelLocalVideoPicker.canRead(ref)
        : await File(ref.startsWith('file://')
                ? Uri.parse(ref).toFilePath()
                : ref)
            .exists();
  }
  if (!context.mounted) return;
  var target = ref;
  switch (resolvePlayback(
    ref: ref,
    localReadable: readable,
    hasCachedFile: file != null,
    photosUrl: photosUrl,
  )) {
    case VideoPlayback.none:
      return;
    case VideoPlayback.localUri:
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
    case VideoPlayback.cachedFile:
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(file: file, title: title),
      ));
      return;
    case VideoPlayback.thumbnailOnly:
      await _showThumbnailOnly(context, thumbData, title);
      return;
    case VideoPlayback.photos:
      target = effectivePhotosUrl(ref: ref, photosUrl: photosUrl)!;
    case VideoPlayback.external:
      break;
  }
  final launchUrl = target;
  // Fallback: prefer the Google Photos APP (not the browser). Try
  // launching straight into the package — canResolveActivity() is
  // unreliable here (package-visibility false-negatives sent it to the
  // browser), so we just attempt it and fall back only if it throws.
  const photosPkg = 'com.google.android.apps.photos';
  try {
    await AndroidIntent(
      action: 'android.intent.action.VIEW',
      data: launchUrl,
      package: photosPkg,
    ).launch();
    return;
  } catch (_) {/* Photos not installed / can't handle it → default below */}
  try {
    await AndroidIntent(action: 'android.intent.action.VIEW', data: launchUrl)
        .launch();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open video: $e')),
      );
    }
  }
}

/// The clip is neither on this phone nor linked to Google Photos: show
/// what survives (the synced thumbnail) + how to make it durable.
Future<void> _showThumbnailOnly(
    BuildContext context, String? thumbData, String? title) {
  final bytes = decodeThumbDataUri(thumbData);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title ?? 'Clip unavailable'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bytes != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(bytes, fit: BoxFit.cover),
              ),
            ),
          const Text(
            'This clip is no longer on this phone and isn\'t linked to '
            'Google Photos yet. Link it from the strength log: tap the '
            'link icon ("Link clips to Google Photos") and pick it.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Thumbnail for a clip, best first: the local frame cache → the synced
/// `<base>_thumb` ([thumbData] — survives reinstall / a new phone;
/// decoded once into the cache) → a fresh mid frame from the on-device
/// clip (cached). Null = placeholder.
Future<File?> _thumbFor(String url, String? mediaId, String? thumbData) async {
  final cached = await VideoThumbStore.load(mediaId);
  if (cached != null) return cached;
  final synced = decodeThumbDataUri(thumbData);
  if (synced != null) {
    final key = (mediaId == null || mediaId.isEmpty)
        ? 'synced_${fnv1a32Hex(thumbData!)}'
        : mediaId;
    await VideoThumbStore.save(key, synced);
    return VideoThumbStore.load(key);
  }
  if (mediaId == null || mediaId.isEmpty) return null;
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

  /// The row's durable siblings (video_ref.dart): the synced thumbnail
  /// data URI and the Google Photos link — playback/preview fallbacks.
  final String? thumbData;
  final String? photosUrl;

  const VideoThumb({
    super.key,
    required this.url,
    required this.mediaId,
    this.label,
    this.title,
    this.size = 96,
    this.thumbData,
    this.photosUrl,
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
              future: _thumbFor(url, mediaId, thumbData),
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
      onTap: () => playVideo(context, url, mediaId,
          title: label ?? title, photosUrl: photosUrl, thumbData: thumbData),
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
