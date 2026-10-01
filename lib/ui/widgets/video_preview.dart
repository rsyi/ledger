import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';

import '../../services/video_thumb_store.dart';

/// Opens the clip in the system viewer (Google Photos) via its deep link.
Future<void> launchVideo(BuildContext context, String url) async {
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

/// Preview sheet: the cached thumbnail (tap to play) + an explicit open
/// button. Falls back to just the button when no thumbnail was cached.
Future<void> showVideoPreviewSheet(
    BuildContext context, String url, String? mediaId) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: FutureBuilder<File?>(
          future: VideoThumbStore.load(mediaId),
          builder: (ctx, snap) {
            final file = snap.data;
            final theme = Theme.of(ctx);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (file != null)
                  GestureDetector(
                    onTap: () => launchVideo(ctx, url),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Image.file(file, fit: BoxFit.cover),
                          const _PlayGlyph(size: 56),
                        ],
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No preview cached for this clip.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => launchVideo(ctx, url),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play in Google Photos'),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

/// A small tappable video thumbnail with a play glyph — for horizontal
/// highlight strips (e.g. the Today tab). Tap opens the preview sheet.
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
    return GestureDetector(
      onTap: () => showVideoPreviewSheet(context, url, mediaId),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
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
                            color: scheme.onSurfaceVariant),
                      );
                    },
                  ),
                  const _PlayGlyph(size: 28),
                ],
              ),
            ),
          ),
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: SizedBox(
                width: size,
                child: Text(
                  label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlayGlyph extends StatelessWidget {
  final double size;
  const _PlayGlyph({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      padding: EdgeInsets.all(size * 0.14),
      child: Icon(Icons.play_arrow, color: Colors.white, size: size * 0.6),
    );
  }
}
