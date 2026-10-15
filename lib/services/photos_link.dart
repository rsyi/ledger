/// Retroactive Google Photos LINKING for attached clips (2026-10-14).
///
/// Attach is offline (local system picker → content:// ref). The clips
/// are auto-backed-up to Google Photos by the phone, so a row can gain a
/// DURABLE link later: the user multi-selects clips in the Photos Picker
/// (photos_picker_gateway.dart), and each picked item is matched to the
/// row(s) it was attached to:
///
///   tier 0 METADATA — the row's `<base>_taken_at` within ±2 min of the
///     item's createTime AND |duration − `<base>_duration_ms`| ≤ 1 s
///     when both are known (the Picker API exposes no duration today,
///     so in practice the time decides);
///   tier 1 LOGGED TIME — rows without recording metadata (attached
///     before 2026-10-14): same day as the row's date AND createTime
///     within ±10 min of the set's start_time / end_time;
///   tier 2 SAME DAY — no metadata and no logged time: same day only —
///     never automatic, always offered for review.
///
/// Assignment is ONE-TO-ONE (an item links one clip, a clip one item),
/// greedy by (tier, |Δt|). A pair is taken automatically only when it is
/// CLEARLY best: no other free candidate (for the item, or competing for
/// the clip) within the tier's margin (15 s metadata / 2 min logged
/// time). Everything else is returned as ambiguous (with candidates) or
/// unmatched, for the review sheet.
///
/// Rows sharing one clip (same media id / ref) are ONE candidate; a link
/// writes all of them. `video_media_id` keeps its meaning (the device
/// cache key + RPE-estimate key); the durable identity lives in
/// `<base>_photos_url` = `photos.google.com/lr/photo/<persistent item id>`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:android_intent_plus/android_intent.dart';
import 'package:intl/intl.dart';

import 'integrations/photos_picker_gateway.dart';
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
    this.loggedTimes = const [],
    this.hasThumb = false,
  });

  final String key;
  final List<Map<String, Object?>> rows;

  /// Recording time, local wall clock (null on pre-metadata rows).
  final DateTime? takenAt;
  final int? durationMs;

  /// The logged day (date only).
  final DateTime? date;

  /// start_time / end_time of the rows, on [date], local.
  final List<DateTime> loggedTimes;
  final bool hasThumb;

  /// "Barbell Squat 315×3 · Oct 12, 5:41 PM" — review-sheet label.
  String get label {
    final r = rows.first;
    final ex = r['exercise']?.toString().trim() ?? '';
    final w = r['weight']?.toString().trim() ?? '';
    final reps = r['reps']?.toString().trim() ?? '';
    final load = w.isNotEmpty && reps.isNotEmpty ? ' $w×$reps' : '';
    final when = takenAt ??
        (loggedTimes.isEmpty ? date : loggedTimes.first);
    final whenStr = when == null
        ? ''
        : (takenAt != null || loggedTimes.isNotEmpty)
            ? DateFormat('MMM d, h:mm a').format(when)
            : DateFormat('MMM d').format(when);
    final head = '${ex.isEmpty ? 'Clip' : ex}$load';
    return whenStr.isEmpty ? head : '$head · $whenStr';
  }
}

DateTime? _asDate(Object? v) {
  if (v is DateTime) return v;
  final s = v?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// Time-of-day strings as the app writes them (`h:mm:ss a` from the
/// now-button) or hand-typed 24 h forms → offset from midnight.
Duration? parseTimeOfDay(Object? raw) {
  final s = raw?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  for (final fmt in const ['h:mm:ss a', 'h:mm a', 'H:mm:ss', 'H:mm']) {
    try {
      final t = DateFormat(fmt).parseStrict(s);
      return Duration(hours: t.hour, minutes: t.minute, seconds: t.second);
    } catch (_) {/* next */}
  }
  return null;
}

/// Builds the linkable candidates of [rows] for [videoField]: unlinked
/// clips (video_ref.dart unlinkedClips), each with its metadata + logged
/// times. [linkedItemIds] collects the Photos item ids already linked
/// anywhere (so re-picking a linked clip is a no-op).
List<ClipCandidate> linkCandidates(
  Iterable<Map<String, Object?>> rows,
  String videoField, {
  String dateField = 'date',
}) {
  final out = <ClipCandidate>[];
  unlinkedClips(rows, videoField).forEach((key, group) {
    DateTime? taken;
    int? duration;
    DateTime? date;
    var hasThumb = false;
    final times = <DateTime>[];
    for (final r in group) {
      taken ??= _asDate(r[takenAtFieldFor(videoField)]);
      duration ??= num.tryParse(
              r[durationFieldFor(videoField)]?.toString() ?? '')
          ?.toInt();
      final d = _asDate(r[dateField]);
      if (d != null) date ??= DateTime(d.year, d.month, d.day);
      hasThumb = hasThumb ||
          (r[thumbFieldFor(videoField)]?.toString().trim().isNotEmpty ??
              false);
      if (d != null) {
        for (final f in const ['start_time', 'end_time']) {
          final tod = parseTimeOfDay(r[f]);
          if (tod != null) times.add(DateTime(d.year, d.month, d.day).add(tod));
        }
      }
    }
    out.add(ClipCandidate(
      key: key,
      rows: group,
      takenAt: taken,
      durationMs: duration,
      date: date,
      loggedTimes: times,
      hasThumb: hasThumb,
    ));
  });
  return out;
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

// --------------------------------------------------------------- matcher

enum MatchBasis { metadata, loggedTime, sameDay }

class ClipMatch {
  const ClipMatch(this.item, this.clip, this.basis, this.delta);
  final PickedMediaItem item;
  final ClipCandidate clip;
  final MatchBasis basis;

  /// |createTime − key time| (null for [MatchBasis.sameDay]).
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
const kLoggedTimeWindow = Duration(minutes: 10);
const _margins = {
  MatchBasis.metadata: Duration(seconds: 15),
  MatchBasis.loggedTime: Duration(minutes: 2),
};

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
  final day = clip.date;
  if (day == null || !_sameDay(ct, day)) return null;
  if (clip.loggedTimes.isEmpty) {
    return ClipMatch(item, clip, MatchBasis.sameDay, null);
  }
  Duration? best;
  for (final t in clip.loggedTimes) {
    final d = ct.difference(t).abs();
    if (best == null || d < best) best = d;
  }
  if (best! > kLoggedTimeWindow) return null;
  return ClipMatch(item, clip, MatchBasis.loggedTime, best);
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
  // An item with ANY metadata candidate is decided by metadata alone: if
  // that was ambiguous it goes to review, never to a looser tier.
  final metaItems = {
    for (final p in pairs)
      if (p.basis == MatchBasis.metadata) p.item.id,
  };
  for (final basis in const [MatchBasis.metadata, MatchBasis.loggedTime]) {
    final margin = _margins[basis]!;
    final tier = [for (final p in pairs) if (p.basis == basis) p];
    for (final p in tier) {
      if (usedItems.contains(p.item.id) || usedClips.contains(p.clip.key)) {
        continue;
      }
      if (basis != MatchBasis.metadata && metaItems.contains(p.item.id)) {
        continue;
      }
      // Competitors among still-free pairs of this tier.
      final rival = tier.any((q) =>
          !identical(q, p) &&
          !usedItems.contains(q.item.id) &&
          !usedClips.contains(q.clip.key) &&
          (q.item.id == p.item.id || q.clip.key == p.clip.key) &&
          q.delta! - p.delta! < margin);
      if (rival) continue; // left for review
      matched.add(p);
      usedItems.add(p.item.id);
      usedClips.add(p.clip.key);
    }
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
}) {
  final urlField = photosUrlFieldFor(videoField);
  final thumbField = thumbFieldFor(videoField);
  return [
    for (final r in clip.rows)
      {
        ...r,
        if (hasDim(urlField)) urlField: photosProductUrl(item.id),
        if (thumbDataUri != null &&
            hasDim(thumbField) &&
            (r[thumbField]?.toString().trim().isEmpty ?? true))
          thumbField: thumbDataUri,
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
