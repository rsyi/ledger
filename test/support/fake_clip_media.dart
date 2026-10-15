import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:airledger/services/photos_verify.dart';
import 'package:airledger/services/video_frames.dart';
import 'package:airledger/ui/widgets/clip_media_access.dart';

/// Fixture JPEG bytes (test/fixtures/clip_verify).
Uint8List fixture(String name) =>
    File('test/fixtures/clip_verify/$name.jpg').readAsBytesSync();

/// In-memory cloud thumbnail store (no disk IO inside FakeAsync).
class MemThumbStore extends PhotosThumbStore {
  final map = <String, Uint8List>{};
  @override
  Future<void> save(String itemId, Uint8List bytes) async =>
      map[itemId] = bytes;
  @override
  Future<Uint8List?> load(String? itemId) async => map[itemId];
}

/// Frames per source path ("content://1" → gymA_local_*), probes per
/// source; missing source = unreadable.
class FakeFrames implements FrameExtractor {
  FakeFrames({this.frames = const {}, this.probes = const {}});
  final Map<String, List<String>> frames;
  final Map<String, Map<String, Object?>> probes;
  @override
  Future<int> durationMs(String path) async => 8000;
  @override
  Future<Map<String, Object?>> probe(String path) async =>
      probes[path] ?? (throw StateError('unreadable'));
  @override
  Future<List<Uint8List>> framesAt(String path, List<int> ts,
      {int maxWidth = 512, int? maxSide, int quality = 70}) async {
    final f = frames[path];
    if (f == null) throw StateError('unreadable');
    return [for (final n in f) fixture(n)];
  }
}

class FakeClipMedia implements ClipMediaAccess {
  FakeClipMedia({
    FakeFrames? frames,
    this.sources = const {},
    this.thumbs = const {},
    MemThumbStore? cloud,
  })  : frames = frames ?? FakeFrames(),
        cloudThumbs = cloud ?? MemThumbStore();

  @override
  final FakeFrames frames;
  @override
  final MemThumbStore cloudThumbs;

  /// row id → local source.
  final Map<String, String> sources;

  /// row id → local thumb fixture name.
  final Map<String, String> thumbs;
  final played = <String>[];
  final opened = <String>[];

  @override
  Future<String?> localSource(
          Map<String, Object?> row, String videoField) async =>
      sources[row['id']];

  @override
  Future<Uint8List?> localThumb(
      Map<String, Object?> row, String videoField) async {
    final n = thumbs[row['id']];
    return n == null ? null : fixture(n);
  }

  @override
  Future<void> playLocal(BuildContext context, String source,
      {String? title}) async =>
      played.add(source);

  @override
  Future<void> openPhotos(BuildContext context, String url) async =>
      opened.add(url);
}
