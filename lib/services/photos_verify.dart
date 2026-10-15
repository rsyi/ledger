/// AUTOMATIC VERIFICATION of Google Photos clip links (2026-10-14).
///
/// The user's ask: "really hard to validate that the things are linked
/// correctly". A time match alone (photos_link.dart: the clip's own
/// recording time vs the item's createTime, ±2 min) can pick the wrong
/// clip of a burst, or a stray video from the same minutes. So inside
/// the picker session — while the item's baseUrl is valid (~60 min) —
/// we download the item's THUMBNAIL (`=w256-h256`, never video bytes),
/// cut frames of the row's local clip at 0 / 10 / 50 % and compare them
/// with a masked 64-bit dHash (image_hash.dart). Best distance wins (the
/// Photos thumbnail is an early frame, not necessarily frame 0).
///
/// THRESHOLDS (evidence 2026-10-14; test/image_hash_test.dart pins the
/// committed fixtures): 18 real clips cut from three videos (a static
/// tripod talking-head, a screen recording, a webcam call), cloud thumb
/// emulated at 0 s / 1 s / mid (lanczos + gamma 1.06 + saturation 1.1 +
/// q≈55) against local frames (bilinear, q≈75):
///   same clip           54 pairs: max 10, 51 of 54 ≤ 2;
///   different scene    612 pairs: min 15, p5 21, median 29.
/// → verified at ≤ [kVerifyMaxBits] = 12 (mid-gap). Different clips from
/// the SAME tripod spot score 0–26 (mostly < 10): the image check
/// catches wrong scene / wrong angle / wrong day, it cannot tell two
/// sets filmed from one spot apart — the ±2 min recording-time match
/// does that.
///
/// DECISION TABLE ([decideLink]):
/// ```text
///   time match | image evidence             | action  | check
///   -----------+----------------------------+---------+------------------
///   no         | —                          | review  | (manual on Link)
///   yes        | none (no local clip/thumb) | link    | unverified
///   yes        | inconclusive (flat frames) | link    | unverified
///   yes        | aspect mismatch            | review  | mismatch:-:<id>
///   yes        | ≤ 12 bits                  | link    | verified:<bits>
///   yes        | > 12 bits                  | review  | mismatch:<bits>:<id>
/// ```
/// A review-screen "Link anyway" / manual pick → `manual[:<bits>]`.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'image_hash.dart';
import 'integrations/photos_picker_gateway.dart';
import 'video_frames.dart';

/// Max masked-dHash distance (of 64) that counts as the same clip.
const kVerifyMaxBits = 12;

/// Fewer confident bits than this = both images are flat (black frame,
/// lens cap, blown-out wall): the distance proves nothing.
const kMinConfidentBits = 16;

/// Relative aspect-ratio tolerance (thumbnail rounding is ≤ 1 px of 256).
const kAspectTolerance = 0.12;

/// Thumbnail size fetched for verification (`=w256-h256` keeps aspect).
const kVerifyThumbPx = 256;

// ------------------------------------------------------------- the check

enum LinkStatus { verified, unverified, manual, mismatch }

/// The `<base>_photos_check` cell: `verified:4`, `unverified`,
/// `manual`, `manual:23`, `mismatch:31:<item id>` (`-` = aspect
/// mismatch, no distance). A mismatch carries the Photos item id
/// because the row is NOT linked — the review screen needs it to show
/// the cloud thumbnail and to "Link anyway".
class LinkCheck {
  const LinkCheck(this.status, {this.bits, this.itemId});

  final LinkStatus status;
  final int? bits;
  final String? itemId;

  bool get needsReview =>
      status == LinkStatus.unverified || status == LinkStatus.mismatch;

  String encode() => switch (status) {
        LinkStatus.verified => 'verified:${bits ?? 0}',
        LinkStatus.unverified => 'unverified',
        LinkStatus.manual => bits == null ? 'manual' : 'manual:$bits',
        LinkStatus.mismatch => 'mismatch:${bits ?? '-'}:${itemId ?? ''}',
      };

  /// Null for blank (links made before verification existed — shown as
  /// unverified by the review screen) and unknown values.
  static LinkCheck? parse(Object? raw) {
    final s = raw?.toString().trim() ?? '';
    if (s.isEmpty) return null;
    final parts = s.split(':');
    final status = switch (parts.first) {
      'verified' => LinkStatus.verified,
      'unverified' => LinkStatus.unverified,
      'manual' => LinkStatus.manual,
      'mismatch' => LinkStatus.mismatch,
      _ => null,
    };
    if (status == null) return null;
    final bits = parts.length > 1 ? int.tryParse(parts[1]) : null;
    final id = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null;
    return LinkCheck(status, bits: bits, itemId: id);
  }

  @override
  bool operator ==(Object other) =>
      other is LinkCheck &&
      other.status == status &&
      other.bits == bits &&
      other.itemId == itemId;

  @override
  int get hashCode => Object.hash(status, bits, itemId);

  @override
  String toString() => encode();
}

// ------------------------------------------------------------ comparison

class ImageComparison {
  const ImageComparison({
    this.bits,
    this.confident = 64,
    this.aspectMismatch = false,
    this.rotated = false,
    this.bestFrame,
  });

  /// Best masked distance over the local frames (null on aspect
  /// mismatch — nothing comparable).
  final int? bits;
  final int confident;
  final bool aspectMismatch;

  /// The local frames matched only after a 90° turn (an extractor that
  /// ignored the rotation flag) — still the same clip.
  final bool rotated;

  /// Index of the best local frame.
  final int? bestFrame;

  bool get inconclusive =>
      !aspectMismatch && (bits == null || confident < kMinConfidentBits);
  bool get matches => !inconclusive && !aspectMismatch && bits! <= kVerifyMaxBits;
}

bool _aspectClose(double a, double b) =>
    (math.log(a / b)).abs() <= math.log(1 + kAspectTolerance);

/// Compares the cloud thumbnail with the local frames. A frame whose
/// orientation differs from the cloud thumbnail is also tried turned
/// ±90°; if nothing has a compatible aspect ratio → aspect mismatch.
ImageComparison compareClipImages(GrayImage cloud, List<GrayImage> local) {
  if (local.isEmpty) return const ImageComparison();
  final c = ClipSignature.of(cloud);
  ({int bits, int confident})? best;
  int? bestIdx;
  var bestRotated = false;
  for (var i = 0; i < local.length; i++) {
    final f = local[i];
    final variants = <(GrayImage, bool)>[
      if (_aspectClose(f.aspect, cloud.aspect)) (f, false),
      if (_aspectClose(1 / f.aspect, cloud.aspect)) ...[
        (f.rotated90(), true),
        (f.rotated90(clockwise: false), true),
      ],
    ];
    for (final (img, rot) in variants) {
      final d = signatureDistance(c, ClipSignature.of(img));
      if (best == null || d.bits < best.bits) {
        best = d;
        bestIdx = i;
        bestRotated = rot;
      }
    }
  }
  if (best == null) return const ImageComparison(aspectMismatch: true);
  return ImageComparison(
    bits: best.bits,
    confident: best.confident,
    rotated: bestRotated,
    bestFrame: bestIdx,
  );
}

// -------------------------------------------------------------- decision

enum LinkAction { link, review }

class VerifyDecision {
  const VerifyDecision(this.action, this.check);
  final LinkAction action;

  /// What to store in `<base>_photos_check`; null = nothing (review of
  /// an unconfirmed time match — the user's choice decides).
  final LinkCheck? check;
}

/// The decision table in the library doc.
VerifyDecision decideLink({
  required bool timeMatched,
  required String itemId,
  ImageComparison? comparison,
}) {
  if (!timeMatched) return const VerifyDecision(LinkAction.review, null);
  final c = comparison;
  if (c == null || c.inconclusive) {
    return const VerifyDecision(
        LinkAction.link, LinkCheck(LinkStatus.unverified));
  }
  if (c.matches) {
    return VerifyDecision(
        LinkAction.link, LinkCheck(LinkStatus.verified, bits: c.bits));
  }
  return VerifyDecision(LinkAction.review,
      LinkCheck(LinkStatus.mismatch, bits: c.bits, itemId: itemId));
}

/// The check for an ALREADY-LINKED clip re-picked by exact item id
/// ("Re-check links"): same evidence, but the link itself is kept — a
/// mismatch only flags it (red) for the user to Unlink. No evidence
/// keeps whatever was stored ([previous]), else unverified.
LinkCheck recheckResult(
    {required String itemId, ImageComparison? comparison, LinkCheck? previous}) {
  final c = comparison;
  if (c == null || c.inconclusive) {
    return previous ?? const LinkCheck(LinkStatus.unverified);
  }
  if (c.matches) return LinkCheck(LinkStatus.verified, bits: c.bits);
  return LinkCheck(LinkStatus.mismatch, bits: c.bits, itemId: itemId);
}

// ------------------------------------------------------------- evidence

/// Frame timestamps for verification: 0 %, 10 %, 50 % (deduped; just
/// frame 0 when the duration is unknown).
List<int> verifyTimestampsMs(int? durationMs) {
  final d = durationMs ?? 0;
  if (d <= 0) return const [0];
  return {0, d ~/ 10, d ~/ 2}.toList();
}

class VerifyEvidence {
  const VerifyEvidence({
    this.cloudThumb,
    this.localFrames = const [],
    this.comparison,
  });

  /// The `=w256-h256` thumbnail (also saved in [PhotosThumbStore]).
  final Uint8List? cloudThumb;
  final List<Uint8List> localFrames;

  /// Null when either side is missing (→ unverified).
  final ImageComparison? comparison;

  Uint8List? get bestLocalFrame {
    final i = comparison?.bestFrame;
    if (i != null && i < localFrames.length) return localFrames[i];
    return localFrames.isEmpty ? null : localFrames.first;
  }
}

/// Collects the evidence for one (item, clip) pair. Never throws: any
/// failed piece just leaves that side empty (→ unverified, not a block).
class ClipVerifier {
  ClipVerifier({
    required this.frames,
    required this.download,
    PhotosThumbStore? thumbStore,
    this.decode = decodeGray,
  }) : thumbStore = thumbStore ?? PhotosThumbStore.instance;

  final FrameExtractor frames;

  /// Authenticated GET of a thumbnail URL (gateway.download).
  final Future<Uint8List> Function(String url) download;
  final PhotosThumbStore thumbStore;
  final Future<GrayImage?> Function(Uint8List bytes) decode;

  /// The item's verification thumbnail: fetched (baseUrl live) and
  /// saved by item id, else whatever an earlier session saved.
  Future<Uint8List?> cloudThumb(PickedMediaItem item) async {
    final base = item.baseUrl;
    if (base != null) {
      try {
        final b = await download(thumbnailUrl(base, px: kVerifyThumbPx));
        if (b.isNotEmpty) {
          await thumbStore.save(item.id, b);
          return b;
        }
      } catch (_) {/* expired / offline → stored copy */}
    }
    return thumbStore.load(item.id);
  }

  Future<VerifyEvidence> evidence(
    PickedMediaItem item, {
    String? localSource,
    int? durationMs,
  }) async {
    final cloud = await cloudThumb(item);
    var local = <Uint8List>[];
    if (localSource != null) {
      try {
        var d = durationMs;
        if (d == null || d <= 0) d = await frames.durationMs(localSource);
        local = await frames.framesAt(localSource, verifyTimestampsMs(d),
            maxSide: kVerifyThumbPx, quality: 80);
      } catch (_) {/* clip gone / grant revoked */}
    }
    ImageComparison? cmp;
    if (cloud != null && local.isNotEmpty) {
      final cg = await decode(cloud);
      final lg = [
        for (final f in local) ?await decode(f),
      ];
      if (cg != null && lg.isNotEmpty) cmp = compareClipImages(cg, lg);
    }
    return VerifyEvidence(cloudThumb: cloud, localFrames: local, comparison: cmp);
  }
}

// ------------------------------------------------------ cloud thumb store

/// Verification thumbnails of Photos items, kept on the device (NOT in
/// the sheet) so the review screen can show "what Google Photos has"
/// long after the picker's baseUrl died:
/// `<appSupport>/photos_thumbs/<item id>.jpg`.
class PhotosThumbStore {
  PhotosThumbStore({Future<Directory> Function()? dir})
      : _dirFn = dir ?? _defaultDir;

  static PhotosThumbStore instance = PhotosThumbStore();

  final Future<Directory> Function() _dirFn;

  static Future<Directory> _defaultDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/photos_thumbs');
  }

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<File> _file(String id) async {
    final d = await _dirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return File('${d.path}/${_safe(id)}.jpg');
  }

  Future<void> save(String itemId, Uint8List bytes) async {
    if (itemId.isEmpty || bytes.isEmpty) return;
    try {
      await (await _file(itemId)).writeAsBytes(bytes, flush: true);
    } catch (_) {/* best-effort */}
  }

  Future<Uint8List?> load(String? itemId) async {
    if (itemId == null || itemId.isEmpty) return null;
    try {
      final f = await _file(itemId);
      return await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }
}
