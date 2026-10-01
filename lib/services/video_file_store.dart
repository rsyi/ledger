/// Local cache of the FULL attached video (mp4) per picker media id, so
/// the clip can play IN-APP later. Saved at attach time because the
/// Google Photos deep link isn't a streamable media URL and the picker's
/// download URL expires ~60 min after the pick.
///
/// Files live under `<appDocs>/video_clips/<mediaId>.mp4`. Capped by count
/// (oldest evicted) so lift footage doesn't grow without bound.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class VideoFileStore {
  VideoFileStore._();

  /// Keep at most this many clips on device; oldest are evicted on save.
  static const int maxClips = 60;

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/video_clips');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _safe(String mediaId) =>
      mediaId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static Future<File> _file(String mediaId) async =>
      File('${(await _dir()).path}/${_safe(mediaId)}.mp4');

  /// Writes the clip [bytes] for [mediaId], then prunes old clips beyond
  /// [maxClips]. Best-effort.
  static Future<void> save(String mediaId, Uint8List bytes) async {
    if (mediaId.isEmpty || bytes.isEmpty) return;
    try {
      await (await _file(mediaId)).writeAsBytes(bytes, flush: true);
      await _prune();
    } catch (_) {/* best-effort */}
  }

  /// The cached clip file for [mediaId], or null when none exists.
  static Future<File?> load(String? mediaId) async {
    if (mediaId == null || mediaId.isEmpty) return null;
    try {
      final f = await _file(mediaId);
      return await f.exists() ? f : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _prune() async {
    try {
      final dir = await _dir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList();
      if (files.length <= maxClips) return;
      files.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified));
      for (final f in files.take(files.length - maxClips)) {
        try {
          await f.delete();
        } catch (_) {/* best-effort */}
      }
    } catch (_) {/* best-effort */}
  }
}
