/// Retroactive Google Photos LINKING for attached clips (2026-10-14).
///
/// Attach is offline (local system picker → content:// ref). The clips
/// are auto-backed-up to Google Photos by the phone, so a row can gain a
/// DURABLE link later: the user multi-selects clips in the Photos Picker
/// (photos_picker_gateway.dart), and each picked item is matched to the
/// row(s) it was attached to by TIMESTAMPS OF THE VIDEO ONLY (user,
/// 2026-10-14: "use the timestamp of the google photos video and the
/// timestamp of the logged set VIDEO" — the set's logged start/end time
/// is NOT evidence and is never used):
///
///   tier 0 METADATA — the row's `<base>_taken_at` (the clip's own
///     recording time) within ±2 min of the item's createTime AND
///     |duration − `<base>_duration_ms`| ≤ 1 s when both are known (the
///     Picker API exposes no duration today, so in practice the time
///     decides). Clips attached before recording metadata existed get
///     `<base>_taken_at` BACKFILLED from the local file when the link
///     screen opens ([probeClipMetadata] / [timestampBackfillRows]);
///   NO TIMESTAMP — the clip's file is gone, so no recording time can
///     be read: same logged DAY only, never automatic — offered for a
///     manual Link/Skip review with the cloud thumbnail.
///
/// Assignment is ONE-TO-ONE (an item links one clip, a clip one item),
/// greedy by |Δt|. A pair is taken automatically only when it is
/// CLEARLY best: no other free candidate (for the item, or competing for
/// the clip) within 15 s. Everything else is returned as ambiguous (with
/// candidates) or unmatched, for the review sheet. Time matches are then
/// image-VERIFIED before linking (photos_verify.dart).
///
/// Rows sharing one clip (same media id / ref) are ONE candidate; a link
/// writes all of them. `video_media_id` keeps its meaning (the device
/// cache key + RPE-estimate key); the durable identity lives in
/// `<base>_photos_url` = `photos.google.com/lr/photo/<persistent item id>`
/// and how it was checked in `<base>_photos_check`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:android_intent_plus/android_intent.dart';
import 'package:intl/intl.dart';

import 'integrations/photos_picker_gateway.dart';
import 'photos_verify.dart' show LinkCheck, LinkStatus;
import 'video_durable.dart';
import 'video_frames.dart';
import 'video_ref.dart';

// ------------------------------------------------------------ candidates

/// One attached clip that may be linked (≥ 1 rows sharing it).
class ClipCandidate {
  ClipCandidate({
    required this.key,
    required this.rows,
    this.takenAt,
    this.durationMs,
    this.date,
    this.hasThumb = false,
    this.check,
  });

  final String key;
  final List<Map<String, Object?>> rows;

  /// Recording time, local wall clock (null on pre-metadata rows).
  final DateTime? takenAt;
  final int? durationMs;

  /// The logged day (date only).
  final DateTime? date;

  final bool hasThumb;

  /// The stored `<base>_photos_check` (null = never checked).
  final LinkCheck? check;

  /// The first row's `<base>_media_id` (device cache key), if any.
  String? mediaId(String videoField) {
    for (final r in rows) {
      final m = r['${videoFieldBase(videoField)}_media_id']?.toString().trim();
      if (m != null && m.isNotEmpty) return m;
    }
    return null;
  }

  /// "Barbell Squat 315×3 · Oct 12, 5:41 PM" — review-sheet label
  /// (recording time when known, else just the logged day).
  String get label {
    final r = rows.first;
    final ex = r['exercise']?.toString().trim() ?? '';
    final w = _num(r['weight']);
    final reps = _num(r['reps']);
    final load = w.isNotEmpty && reps.isNotEmpty ? ' $w×$reps' : '';
    final sets = rows.length > 1 ? ' (${rows.length} sets)' : '';
    final whenStr = takenAt != null
        ? DateFormat('MMM d, h:mm a').format(takenAt!)
        : date != null
            ? DateFormat('MMM d').format(date!)
            : '';
    final head = '${ex.isEmpty ? 'Clip' : ex}$load$sets';
    return whenStr.isEmpty ? head : '$head · $whenStr';
  }

  static String _num(Object? v) {
    if (v is double && v == v.roundToDouble()) return v.toInt().toString();
    return v?.toString().trim() ?? '';
  }
}

DateTime? _asDate(Object? v) {
  if (v is DateTime) return v;
  final s = v?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// Builds the linkable candidates of [rows] for [videoField]: unlinked
/// clips (video_ref.dart unlinkedClips), each with its recording
/// metadata.
List<ClipCandidate> linkCandidates(
  Iterable<Map<String, Object?>> rows,
  String videoField, {
  String dateField = 'date',
}) =>
    [
      for (final e in unlinkedClips(rows, videoField).entries)
        _candidate(e.key, e.value, videoField, dateField),
    ];

ClipCandidate _candidate(String key, List<Map<String, Object?>> group,
    String videoField, String dateField) {
  DateTime? taken;
  int? duration;
  DateTime? date;
  LinkCheck? check;
  var hasThumb = false;
  for (final r in group) {
    taken ??= _asDate(r[takenAtFieldFor(videoField)]);
    duration ??=
        num.tryParse(r[durationFieldFor(videoField)]?.toString() ?? '')
            ?.toInt();
    final d = _asDate(r[dateField]);
    if (d != null) date ??= DateTime(d.year, d.month, d.day);
    check ??= LinkCheck.parse(r[photosCheckFieldFor(videoField)]);
    hasThumb = hasThumb ||
        (r[thumbFieldFor(videoField)]?.toString().trim().isNotEmpty ?? false);
  }
  return ClipCandidate(
    key: key,
    rows: group,
    takenAt: taken,
    durationMs: duration,
    date: date,
    hasThumb: hasThumb,
    check: check,
  );
}

/// LINKED clips keyed by their Photos item id (rows grouped per clip) —
/// "Re-check links" re-verifies an item picked again by EXACT id, and
/// the review screen lists them.
Map<String, ClipCandidate> linkedClipsByItemId(
  Iterable<Map<String, Object?>> rows,
  String videoField, {
  String dateField = 'date',
}) {
  final groups = <String, List<Map<String, Object?>>>{};
  final ids = <String, String>{};
  for (final r in rows) {
    final ref = r[videoField]?.toString().trim() ?? '';
    final url = effectivePhotosUrl(
      ref: ref,
      photosUrl: r[photosUrlFieldFor(videoField)]?.toString(),
    );
    final id = photosItemIdOf(url);
    if (id == null) continue;
    final key = ref.isEmpty ? 'photos:$id' : clipKeyOf(r, videoField);
    groups.putIfAbsent(key, () => []).add(r);
    ids.putIfAbsent(key, () => id);
  }
  return {
    for (final e in groups.entries)
      ids[e.key]!: _candidate(e.key, e.value, videoField, dateField),
  };
}

/// Photos item ids already linked on any row (constructed deep links in
/// `<base>_photos_url`, or legacy `video_url` Photos links).
Set<String> linkedItemIds(
    Iterable<Map<String, Object?>> rows, String videoField) {
  final out = <String>{};
  for (final r in rows) {
    final url = effectivePhotosUrl(
      ref: r[videoField]?.toString(),
      photosUrl: r[photosUrlFieldFor(videoField)]?.toString(),
    );
    final id = photosItemIdOf(url);
    if (id != null) out.add(id);
  }
  return out;
}

// --------------------------------------------------------- review list

/// One clip on the "Linked clips" review screen.
class LinkReviewEntry {
  const LinkReviewEntry({
    required this.clip,
    required this.itemId,
    required this.linked,
    this.legacy = false,
  });

  final ClipCandidate clip;

  /// The Photos item (the link's id, or a mismatch's candidate).
  final String itemId;

  /// False = a persisted image MISMATCH on an unlinked clip.
  final bool linked;

  /// The link IS the row's `video_url` (2026-09-28..10-01 attach) — it
  /// can't be unlinked (that link is the clip itself).
  final bool legacy;

  LinkCheck? get check => clip.check;

  /// Unverified (incl. never checked) and mismatches need a look.
  bool get needsReview => check == null || check!.needsReview;
}

/// Every linked clip + every persisted mismatch, newest first.
List<LinkReviewEntry> linkReviewEntries(
  Iterable<Map<String, Object?>> rows,
  String videoField, {
  String dateField = 'date',
}) {
  final out = <LinkReviewEntry>[
    for (final e in linkedClipsByItemId(rows, videoField,
            dateField: dateField)
        .entries)
      LinkReviewEntry(
        clip: e.value,
        itemId: e.key,
        linked: true,
        legacy: (e.value.rows.first[photosUrlFieldFor(videoField)]
                    ?.toString()
                    .trim() ??
                '')
            .isEmpty,
      ),
    for (final c in linkCandidates(rows, videoField, dateField: dateField))
      if (c.check?.status == LinkStatus.mismatch && c.check?.itemId != null)
        LinkReviewEntry(clip: c, itemId: c.check!.itemId!, linked: false),
  ];
  DateTime? when(LinkReviewEntry e) => e.clip.takenAt ?? e.clip.date;
  out.sort((a, b) {
    final x = when(a), y = when(b);
    if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
    return y.compareTo(x);
  });
  return out;
}

// --------------------------------------------------------------- matcher

/// [metadata] = recording-time match (may auto-link); [noTimestamp] =
/// the clip has no readable recording time — same logged day, REVIEW
/// ONLY (never automatic).
enum MatchBasis { metadata, noTimestamp }

class ClipMatch {
  const ClipMatch(this.item, this.clip, this.basis, this.delta);
  final PickedMediaItem item;
  final ClipCandidate clip;
  final MatchBasis basis;

  /// |createTime − recording time| (null for [MatchBasis.noTimestamp]).
  final Duration? delta;
}

class AmbiguousPick {
  const AmbiguousPick(this.item, this.candidates);
  final PickedMediaItem item;

  /// Free eligible clips, best first.
  final List<ClipMatch> candidates;
}

class LinkMatchResult {
  const LinkMatchResult({
    required this.matched,
    required this.ambiguous,
    required this.unmatched,
    required this.alreadyLinked,
    required this.nonVideo,
  });

  final List<ClipMatch> matched;
  final List<AmbiguousPick> ambiguous;
  final List<PickedMediaItem> unmatched;
  final List<PickedMediaItem> alreadyLinked;
  final int nonVideo;
}

const kMetadataWindow = Duration(minutes: 2);
const kDurationTolerance = Duration(seconds: 1);
/// A metadata pair auto-links only when no rival is within this.
const kMetadataMargin = Duration(seconds: 15);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Eligibility of one (item, clip) pair; null = not a candidate.
/// [itemDurationMs] is separate from the item because the Picker API
/// has no duration — kept so a future source can supply one.
ClipMatch? scorePair(PickedMediaItem item, ClipCandidate clip,
    {int? itemDurationMs}) {
  final ct = item.createTime?.toLocal();
  if (ct == null) return null;
  final taken = clip.takenAt;
  if (taken != null) {
    final d = ct.difference(taken).abs();
    if (d > kMetadataWindow) return null;
    final cd = clip.durationMs;
    if (cd != null &&
        itemDurationMs != null &&
        (cd - itemDurationMs).abs() > kDurationTolerance.inMilliseconds) {
      return null;
    }
    return ClipMatch(item, clip, MatchBasis.metadata, d);
  }
  // No recording time: the set's logged time is NOT evidence (user
  // directive) — same day only, for manual review.
  final day = clip.date;
  if (day == null || !_sameDay(ct, day)) return null;
  return ClipMatch(item, clip, MatchBasis.noTimestamp, null);
}

/// Matches picked [items] to [clips] one-to-one (see library doc).
LinkMatchResult matchPickedClips(
  List<PickedMediaItem> items,
  List<ClipCandidate> clips, {
  Set<String> alreadyLinkedIds = const {},
  Map<String, int> itemDurationsMs = const {},
}) {
  final already = <PickedMediaItem>[];
  final live = <PickedMediaItem>[];
  var nonVideo = 0;
  final seen = <String>{};
  for (final it in items) {
    if (!seen.add(it.id)) continue; // duplicate pick
    if (!it.isVideo) {
      nonVideo++;
    } else if (alreadyLinkedIds.contains(it.id)) {
      already.add(it);
    } else {
      live.add(it);
    }
  }

  final pairs = <ClipMatch>[
    for (final it in live)
      for (final c in clips)
        ?scorePair(it, c, itemDurationMs: itemDurationsMs[it.id]),
  ];
  int cmp(ClipMatch a, ClipMatch b) {
    final t = a.basis.index.compareTo(b.basis.index);
    if (t != 0) return t;
    return (a.delta ?? Duration.zero).compareTo(b.delta ?? Duration.zero);
  }

  pairs.sort(cmp);

  final usedItems = <String>{};
  final usedClips = <String>{};
  final matched = <ClipMatch>[];
  // Only recording-time pairs can auto-link; no-timestamp pairs are
  // review candidates, never automatic.
  final tier = [
    for (final p in pairs)
      if (p.basis == MatchBasis.metadata) p,
  ];
  for (final p in tier) {
    if (usedItems.contains(p.item.id) || usedClips.contains(p.clip.key)) {
      continue;
    }
    // Competitors among still-free recording-time pairs.
    final rival = tier.any((q) =>
        !identical(q, p) &&
        !usedItems.contains(q.item.id) &&
        !usedClips.contains(q.clip.key) &&
        (q.item.id == p.item.id || q.clip.key == p.clip.key) &&
        q.delta! - p.delta! < kMetadataMargin);
    if (rival) continue; // left for review
    matched.add(p);
    usedItems.add(p.item.id);
    usedClips.add(p.clip.key);
  }

  final ambiguous = <AmbiguousPick>[];
  final unmatched = <PickedMediaItem>[];
  for (final it in live) {
    if (usedItems.contains(it.id)) continue;
    final cands = [
      for (final p in pairs)
        if (p.item.id == it.id && !usedClips.contains(p.clip.key)) p,
    ];
    if (cands.isEmpty) {
      unmatched.add(it);
    } else {
      ambiguous.add(AmbiguousPick(it, cands));
    }
  }
  return LinkMatchResult(
    matched: matched,
    ambiguous: ambiguous,
    unmatched: unmatched,
    alreadyLinked: already,
    nonVideo: nonVideo,
  );
}

// ----------------------------------------------------------------- apply

/// The updated rows for linking [clip] to [item]: `<base>_photos_url` =
/// the constructed deep link on every row of the clip, plus
/// [thumbDataUri] on rows that have no synced thumbnail yet. Only dims
/// the view declares ([hasDim]) are written. Pure.
List<Map<String, Object?>> linkedRows(
  ClipCandidate clip,
  PickedMediaItem item,
  String videoField, {
  required bool Function(String dim) hasDim,
  String? thumbDataUri,
  LinkCheck? check,
}) {
  final urlField = photosUrlFieldFor(videoField);
  final thumbField = thumbFieldFor(videoField);
  final checkField = photosCheckFieldFor(videoField);
  return [
    for (final r in clip.rows)
      {
        ...r,
        if (hasDim(urlField)) urlField: photosProductUrl(item.id),
        if (check != null && hasDim(checkField)) checkField: check.encode(),
        if (thumbDataUri != null &&
            hasDim(thumbField) &&
            (r[thumbField]?.toString().trim().isEmpty ?? true))
          thumbField: thumbDataUri,
      },
  ];
}

/// [clip]'s rows with only `<base>_photos_check` set to [check] (a
/// re-check of a linked clip, or a persisted mismatch on an unlinked
/// one). Empty when the view has no check dim. Pure.
List<Map<String, Object?>> checkedRows(
  ClipCandidate clip,
  String videoField,
  LinkCheck? check, {
  required bool Function(String dim) hasDim,
}) {
  final f = photosCheckFieldFor(videoField);
  if (!hasDim(f)) return const [];
  return [
    for (final r in clip.rows) {...r, f: check?.encode()},
  ];
}

/// UNLINK: [clip]'s rows with `<base>_photos_url` + `<base>_photos_check`
/// cleared (the clip is unlinked again and reappears in "N clips not
/// linked"). The synced thumbnail stays — it describes the local clip.
/// A legacy row whose `video_url` IS the Photos link is left alone (that
/// link is the clip itself). Pure.
List<Map<String, Object?>> unlinkedRows(
  ClipCandidate clip,
  String videoField, {
  required bool Function(String dim) hasDim,
}) {
  final urlField = photosUrlFieldFor(videoField);
  final checkField = photosCheckFieldFor(videoField);
  return [
    for (final r in clip.rows)
      {
        ...r,
        if (hasDim(urlField)) urlField: null,
        if (hasDim(checkField)) checkField: null,
      },
  ];
}

// ------------------------------------------------- timestamp backfill

/// The recording metadata of a local clip [source] (content URI or app
/// cache path): MediaStore DATE_TAKEN (`dateTaken`, content:// only)
/// else the container creation date; 1904/1970 sentinels rejected
/// (video_durable.dart clipMetadataFrom). Null when unreadable.
Future<ClipMetadata?> probeClipMetadata(
    FrameExtractor x, String source) async {
  try {
    final probe = await x.probe(source);
    return clipMetadataFrom(
      dateTakenMs: (probe['dateTaken'] as num?)?.toInt(),
      probe: probe,
    );
  } catch (_) {
    return null; // grant revoked / file gone
  }
}

/// [clip]'s rows with `<base>_taken_at` (and `<base>_duration_ms` where
/// blank) filled from [meta]; null when [meta] has no recording time or
/// the view can't store it. Pure.
List<Map<String, Object?>>? timestampBackfillRows(
  ClipCandidate clip,
  ClipMetadata? meta,
  String videoField, {
  required bool Function(String dim) hasDim,
}) {
  final taken = meta?.takenAt;
  final tf = takenAtFieldFor(videoField);
  if (taken == null || !hasDim(tf)) return null;
  final df = durationFieldFor(videoField);
  return [
    for (final r in clip.rows)
      {
        ...r,
        tf: taken,
        if (meta!.durationMs != null &&
            hasDim(df) &&
            (r[df]?.toString().trim().isEmpty ?? true))
          df: meta.durationMs,
      },
  ];
}

// ------------------------------------------------------------------ flow

class PhotosLinkCancelled implements Exception {
  const PhotosLinkCancelled();
}

/// Orchestration over the injectable gateway: session → open the Photos
/// picker (multi-select) → poll until set → list items → cleanup. Plus a
/// budgeted thumbnail fetch. No video bytes, ever.
class PhotosLinkFlow {
  PhotosLinkFlow({
    required this.gateway,
    Future<void> Function(String pickerUri)? launchPicker,
    this.defaultPollInterval = const Duration(seconds: 3),
    this.maxWait = const Duration(minutes: 15),
  }) : _launchPicker = launchPicker ?? _launchViaIntent;

  final PhotosPickerGateway gateway;
  final Future<void> Function(String pickerUri) _launchPicker;
  final Duration defaultPollInterval;
  final Duration maxWait;

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  Future<List<PickedMediaItem>> pick() async {
    _cancelled = false;
    final session = PickerSession.fromJson(await gateway.createSession());
    if (session.pickerUri.isEmpty) {
      throw StateError('Picker session came back without a pickerUri');
    }
    try {
      await _launchPicker(autoclosePickerUri(session.pickerUri));
      final interval = session.pollInterval ?? defaultPollInterval;
      var budget = session.timeoutIn ?? maxWait;
      if (budget > maxWait) budget = maxWait;
      var waited = Duration.zero;
      var set = session.mediaItemsSet;
      while (!set) {
        if (_cancelled) throw const PhotosLinkCancelled();
        if (waited >= budget) {
          throw StateError(
              'Timed out waiting for a selection in Google Photos — try '
              'again.');
        }
        await Future<void>.delayed(interval);
        waited += interval;
        if (_cancelled) throw const PhotosLinkCancelled();
        set = PickerSession.fromJson(await gateway.getSession(session.id))
            .mediaItemsSet;
      }
      return parsePickedItems(await gateway.listMediaItems(session.id));
    } finally {
      try {
        await gateway.deleteSession(session.id);
      } catch (_) {/* best-effort */}
    }
  }

  /// A thumbnail for [item] as a synced data URI (≤ kThumbMaxBytes):
  /// 200 px, then 120 px if that's over budget. Null when there's no
  /// baseUrl, the fetch fails, or nothing fits. Must run within ~60 min
  /// of the pick (baseUrl lifetime).
  Future<Uint8List?> fetchThumb(PickedMediaItem item) async {
    final base = item.baseUrl;
    if (base == null) return null;
    for (final px in const [200, 120]) {
      try {
        final bytes = await gateway.download(thumbnailUrl(base, px: px));
        if (bytes.isNotEmpty && bytes.length <= kThumbMaxBytes) return bytes;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Future<void> _launchViaIntent(String pickerUri) => AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: pickerUri,
      ).launch();
}

/// App-global holder (VideoRpeService.instance precedent). Set by home
/// when the build has a Google web client id; null → the link screen
/// explains that Google sign-in isn't configured.
class PhotosLinkService {
  PhotosLinkService(this.flow);
  static PhotosLinkService? instance;
  final PhotosLinkFlow flow;
}
