import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';

import '../../services/video_file_store.dart';
import '../../services/video_thumb_store.dart';
import 'video_player_screen.dart';

/// Plays the clip: IN-APP when the full file is cached locally, otherwise
/// falls back to the Google Photos deep link (older attaches made before
/// clip-caching, or when the cache was evicted).
Future<void> playVideo(
    BuildContext context, String url, String? mediaId, {String? title}) async {
  final file = await VideoFileStore.load(mediaId);
  if (!context.mounted) return;
  if (file != null) {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(file: file, title: title),
    ));
    return;
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

/// A tappable video thumbnail (cached frame) with a play glyph. Tap plays
/// the clip in-app (or Google Photos as fallback). Shows a movie
/// placeholder when no thumbnail was cached. Used inline in log rows
/// (small) and the Today highlights strip (larger).
class VideoThumb extends StatelessWidget {
  final String url;
  final String? mediaId;
  final String? label;
  final double size;

  const VideoThumb({
    super.key,
    required this.url,
    required this.mediaId,
    this.label,
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
              future: VideoThumbStore.load(mediaId),
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
      onTap: () => playVideo(context, url, mediaId, title: label),
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
