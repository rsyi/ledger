import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Minimal in-app player for a lift clip on the device — a cached file
/// in app storage OR a local content:// URI (system photo picker ref):
/// autoplay + loop, tap to play/pause, a scrubber, and a close button.
/// Black full-screen.
class VideoPlayerScreen extends StatefulWidget {
  final File? file;
  final Uri? contentUri;
  final String? title;
  const VideoPlayerScreen({super.key, this.file, this.contentUri, this.title})
      : assert(file != null || contentUri != null);

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _c;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _c = widget.file != null
        ? VideoPlayerController.file(widget.file!)
        : VideoPlayerController.contentUri(widget.contentUri!);
    _c.initialize().then((_) {
      _c.setLooping(true);
      _c.play();
      if (mounted) setState(() => _ready = true);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _c.value.isPlaying ? _c.pause() : _c.play());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: widget.title == null ? null : Text(widget.title!),
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                    widget.file == null
                        ? 'Couldn\'t play this clip — it may have been '
                            'deleted from the phone, or access was revoked. '
                            'Re-attach it from the edit form.\n\n$_error'
                        : 'Couldn\'t play this clip: $_error',
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center),
              )
            : !_ready
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: _toggle,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              AspectRatio(
                                aspectRatio: _c.value.aspectRatio == 0
                                    ? 16 / 9
                                    : _c.value.aspectRatio,
                                child: VideoPlayer(_c),
                              ),
                              // Tap hint when paused.
                              ValueListenableBuilder(
                                valueListenable: _c,
                                builder: (_, VideoPlayerValue v, _) =>
                                    v.isPlaying
                                        ? const SizedBox.shrink()
                                        : Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black
                                                  .withValues(alpha: 0.45),
                                              shape: BoxShape.circle,
                                            ),
                                            padding: const EdgeInsets.all(14),
                                            child: const Icon(Icons.play_arrow,
                                                color: Colors.white, size: 44),
                                          ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      VideoProgressIndicator(_c, allowScrubbing: true),
                    ],
                  ),
      ),
    );
  }
}
