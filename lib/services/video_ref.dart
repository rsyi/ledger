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
///
/// DURABLE CLIPS (2026-10-14): a local ref dies on reinstall (grant
/// gone) or when the clip is deleted, so rows also carry synced
/// siblings — a small thumbnail, recording time + duration (captured
/// offline at attach, video_durable.dart) and, once the user links it
/// (photos_link.dart), a Google Photos deep link. Playback falls back
/// local → app copy → Photos link → thumbnail-only ([resolvePlayback]).
library;

import 'dart:convert';
import 'dart:typed_data';

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

/// Where tapping a clip goes. Fallback ORDER (durable-clips design,
/// 2026-10-14): the on-device clip → the app-storage copy → the Google
/// Photos link (opens the Photos app) → a thumbnail-only state with a
/// "Link to Google Photos" hint (the clip is gone from this phone and
/// was never linked). [external] is for any other link kind.
enum VideoPlayback { none, localUri, cachedFile, photos, external, thumbnailOnly }

/// The durable Google Photos link for a clip: the row's
/// `<base>_photos_url` when set, else a legacy row whose `video_url` IS
/// a photos.google.com link (those count as linked). Null = unlinked.
String? effectivePhotosUrl({required String? ref, String? photosUrl}) {
  final p = photosUrl?.trim() ?? '';
  if (p.isNotEmpty) return p;
  if (videoRefKind(ref) == VideoRefKind.googlePhotos) return ref!.trim();
  return null;
}

/// Resolves [VideoPlayback] in the fallback order above. [localReadable]
/// = the local ref still opens (content grant alive / file exists);
/// meaningless for non-local refs.
VideoPlayback resolvePlayback({
  required String? ref,
  required bool localReadable,
  required bool hasCachedFile,
  String? photosUrl,
}) {
  final kind = videoRefKind(ref);
  if (kind == VideoRefKind.none) return VideoPlayback.none;
  if (kind == VideoRefKind.local && localReadable) {
    return VideoPlayback.localUri;
  }
  if (hasCachedFile) return VideoPlayback.cachedFile;
  if (effectivePhotosUrl(ref: ref, photosUrl: photosUrl) != null) {
    return VideoPlayback.photos;
  }
  if (kind == VideoRefKind.other) return VideoPlayback.external;
  return VideoPlayback.thumbnailOnly;
}

// ------------------------------------------------- durable clip siblings
//
// Sibling-dim CONVENTION for a `widget: video` field `<base>_url`
// (video_url → base "video"), extending `<base>_media_id`
// (video_rpe.dart mediaIdFieldFor):
//   <base>_thumb        small JPEG thumbnail as a data URI (synced — the
//                       preview survives reinstall / a new phone)
//   <base>_taken_at     clip recording time (local wall clock, datetime)
//   <base>_duration_ms  clip duration in ms
//   <base>_photos_url   durable Google Photos link (retroactive linking)
// All app-written (editable:false, autofill:false). A view without a
// sibling simply doesn't persist that piece.

String videoFieldBase(String videoField) => videoField.endsWith('_url')
    ? videoField.substring(0, videoField.length - 4)
    : videoField;

String thumbFieldFor(String videoField) => '${videoFieldBase(videoField)}_thumb';
String takenAtFieldFor(String videoField) =>
    '${videoFieldBase(videoField)}_taken_at';
String durationFieldFor(String videoField) =>
    '${videoFieldBase(videoField)}_duration_ms';
String photosUrlFieldFor(String videoField) =>
    '${videoFieldBase(videoField)}_photos_url';

/// Dims holding bulk blobs (the base64 thumbnail) — kept OUT of LLM
/// prompt dumps, detail rows and history summaries (a ~10 KB cell per
/// clip would swamp a coach context).
bool isBlobDim(String name) => name.endsWith('_thumb');

/// Per-clip thumbnail budget: ≤ 10 KB of JPEG → ≤ ~13.7k base64 chars,
/// far under the 50k-char Sheets cell limit.
const kThumbMaxBytes = 10 * 1024;
const kThumbDataUriPrefix = 'data:image/jpeg;base64,';

/// Data-URI form for the synced `<base>_thumb` cell. The `data:` prefix
/// also keeps the cell Sheets-safe under USER_ENTERED (never a leading
/// `=`/`+`, never number/date-shaped) and self-describing.
String encodeThumbDataUri(List<int> jpeg) =>
    '$kThumbDataUriPrefix${base64Encode(jpeg)}';

/// Decodes a `<base>_thumb` cell (data URI or bare base64). Null when
/// blank / garbled.
Uint8List? decodeThumbDataUri(String? cell) {
  var s = cell?.trim() ?? '';
  if (s.isEmpty) return null;
  final comma = s.startsWith('data:') ? s.indexOf(',') : -1;
  if (s.startsWith('data:')) {
    if (comma < 0) return null;
    s = s.substring(comma + 1);
  }
  try {
    final b = base64Decode(s);
    return b.isEmpty ? null : b;
  } catch (_) {
    return null;
  }
}

/// True when [row]'s clip in [videoField] is linked to Google Photos.
bool isClipLinked(Map<String, Object?> row, String videoField) =>
    effectivePhotosUrl(
      ref: row[videoField]?.toString(),
      photosUrl: row[photosUrlFieldFor(videoField)]?.toString(),
    ) !=
    null;

/// Stable per-clip key: rows sharing one attached clip (same media id,
/// else same ref) are ONE clip for counting + linking.
String clipKeyOf(Map<String, Object?> row, String videoField,
    {String? mediaIdField}) {
  final mid = row[mediaIdField ?? '${videoFieldBase(videoField)}_media_id']
          ?.toString()
          .trim() ??
      '';
  return mid.isNotEmpty ? 'mid:$mid' : 'ref:${row[videoField]?.toString().trim()}';
}

/// Rows with a clip in [videoField] that is NOT yet linked to Google
/// Photos, grouped per clip ([clipKeyOf]), in input order.
Map<String, List<Map<String, Object?>>> unlinkedClips(
    Iterable<Map<String, Object?>> rows, String videoField) {
  final out = <String, List<Map<String, Object?>>>{};
  for (final r in rows) {
    final ref = r[videoField]?.toString().trim() ?? '';
    if (ref.isEmpty || isClipLinked(r, videoField)) continue;
    out.putIfAbsent(clipKeyOf(r, videoField), () => []).add(r);
  }
  return out;
}

/// "N clips not linked" count (distinct clips, not rows).
int unlinkedClipCount(
        Iterable<Map<String, Object?>> rows, String videoField) =>
    unlinkedClips(rows, videoField).length;

/// What to hand the frame extractor (MediaMetadataRetriever accepts a
/// path or a content URI): the cached copy when there is one, else the
/// local ref itself; null for remote-only refs (nothing to read).
String? frameSourceFor({required String ref, String? cachedPath}) {
  if (cachedPath != null && cachedPath.isNotEmpty) return cachedPath;
  return isLocalVideoRef(ref) ? ref.trim() : null;
}
