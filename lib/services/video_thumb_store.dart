/// Local cache of a single representative frame (JPEG) per attached
/// video, keyed by media id. Captured at attach time; for on-device clips
/// (content:// refs) video_preview re-extracts lazily if it's missing.
/// Legacy Google Photos rows can't be re-fetched (the picker's baseUrl
/// died ~60 min after the pick), so their cached frame is the only
/// preview.
///
/// Files live under `<appDocs>/video_thumbs/<mediaId>.jpg` and persist
/// across launches.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class VideoThumbStore {
  VideoThumbStore._();

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/video_thumbs');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _safe(String mediaId) =>
      mediaId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static Future<File> _file(String mediaId) async =>
      File('${(await _dir()).path}/${_safe(mediaId)}.jpg');

  /// Writes [bytes] as the thumbnail for [mediaId]. Best-effort.
  static Future<void> save(String mediaId, Uint8List bytes) async {
    if (mediaId.isEmpty || bytes.isEmpty) return;
    try {
      await (await _file(mediaId)).writeAsBytes(bytes, flush: true);
    } catch (_) {/* best-effort */}
  }

  /// The cached thumbnail file for [mediaId], or null when none exists.
  static Future<File?> load(String? mediaId) async {
    if (mediaId == null || mediaId.isEmpty) return null;
    try {
      final f = await _file(mediaId);
      return await f.exists() ? f : null;
    } catch (_) {
      return null;
    }
  }
}
