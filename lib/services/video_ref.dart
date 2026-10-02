/// Pure parsing of a `widget: video` field value (`video_url`).
///
/// Two generations of values live in the ledger:
///   - LOCAL (2026-10-02+): a `content://` URI from the Android system
///     photo picker (with a persisted read grant), or a file path. The
///     clip is read straight off the device — no download, no expiry.
///   - GOOGLE PHOTOS (2026-09-28 → 10-01, legacy): a constructed
///     photos.google.com deep link from the retired Photos Picker API
///     flow. Those rows keep working: in-app playback from the clip
///     cached at attach time when present, else open in the Photos app.
library;

import 'dart:convert';

enum VideoRefKind { none, local, googlePhotos, other }

VideoRefKind videoRefKind(String? ref) {
  final s = ref?.trim() ?? '';
  if (s.isEmpty) return VideoRefKind.none;
  if (s.startsWith('content://') ||
      s.startsWith('file://') ||
      s.startsWith('/')) {
    return VideoRefKind.local;
  }
  final host = Uri.tryParse(s)?.host ?? '';
  if (host == 'photos.google.com' || host == 'photos.app.goo.gl') {
    return VideoRefKind.googlePhotos;
  }
  return VideoRefKind.other;
}

bool isLocalVideoRef(String? ref) => videoRefKind(ref) == VideoRefKind.local;

/// 32-bit FNV-1a over the UTF-8 bytes, lowercase hex (8 chars).
String fnv1a32Hex(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// Stable `video_media_id` for a local reference: the URI's (decoded,
/// sanitized, ≤40-char) last path segment — the picker/MediaStore item
/// id, readable in the sheet — plus an FNV hash of the FULL URI so two
/// providers sharing an item id never collide. Filename-safe (it keys
/// the thumbnail/clip caches and the RPE estimate prefs).
String localMediaIdFor(String uri) {
  final parsed = Uri.tryParse(uri);
  final segs = parsed?.pathSegments.where((s) => s.isNotEmpty).toList() ??
      const <String>[];
  var seg = segs.isEmpty ? '' : Uri.decodeComponent(segs.last);
  seg = seg.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_');
  if (seg.length > 40) seg = seg.substring(0, 40);
  final hash = fnv1a32Hex(uri);
  return seg.isEmpty ? 'local_$hash' : 'local_${seg}_$hash';
}

/// Short "where does this clip live" label for the attached-video tile.
String videoRefLabel(String ref) {
  switch (videoRefKind(ref)) {
    case VideoRefKind.local:
      return 'on this phone';
    case VideoRefKind.googlePhotos:
      return 'Google Photos';
    case VideoRefKind.none:
      return '';
    case VideoRefKind.other:
      final host = Uri.tryParse(ref.trim())?.host ?? '';
      return host.isEmpty ? ref.trim() : host;
  }
}

enum VideoPlayback { none, cachedFile, localUri, external }

/// Where tapping a clip should go. A cached copy in app storage always
/// wins (legacy Photos-picker downloads + local picks whose grant
/// couldn't be persisted); else a local ref plays in-app from its URI;
/// else the link opens externally (Google Photos app for legacy rows).
VideoPlayback playbackTargetFor({
  required String? ref,
  required bool hasCachedFile,
}) {
  final kind = videoRefKind(ref);
  if (kind == VideoRefKind.none) return VideoPlayback.none;
  if (hasCachedFile) return VideoPlayback.cachedFile;
  if (kind == VideoRefKind.local) return VideoPlayback.localUri;
  return VideoPlayback.external;
}

/// What to hand the frame extractor (MediaMetadataRetriever accepts a
/// path or a content URI): the cached copy when there is one, else the
/// local ref itself; null for remote-only refs (nothing to read).
String? frameSourceFor({required String ref, String? cachedPath}) {
  if (cachedPath != null && cachedPath.isNotEmpty) return cachedPath;
  return isLocalVideoRef(ref) ? ref.trim() : null;
}
