/// Durable clip extras captured OFFLINE at attach time (2026-10-14).
///
/// The `video_url` content:// reference dies with the app (reinstall
/// drops the persisted grant) or the clip (deleted from the phone). So
/// at attach we also write, into synced sibling dims (video_ref.dart
/// convention):
///   - `<base>_thumb`: a small JPEG (long side ≤ 200 px, ≤ 10 KB) as a
///     data URI — the preview survives reinstall / a new phone;
///   - `<base>_taken_at` + `<base>_duration_ms`: the clip's recording
///     time + length — the keys retroactive Google Photos linking
///     (photos_link.dart) matches picked items on.
/// Nothing here touches the network.
library;

import 'dart:typed_data';

import 'video_frames.dart';
import 'video_ref.dart';

/// Recording metadata of an attached clip. Every field optional — an
/// honest null beats a guessed timestamp (a wrong one mis-links clips).
class ClipMetadata {
  const ClipMetadata({this.takenAt, this.durationMs, this.sizeBytes});

  /// Local wall-clock recording time.
  final DateTime? takenAt;
  final int? durationMs;
  final int? sizeBytes;
}

/// Parses MediaMetadataRetriever METADATA_KEY_DATE
/// ("20261014T153012.000Z", "20261014T153012Z", "20261014T153012") —
/// MP4 creation_time, UTC. Epoch-zero placeholders (1904 / 1970) and
/// garbage → null. Returned in LOCAL time.
DateTime? parseRetrieverDate(String? raw) {
  final s = raw?.trim() ?? '';
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(?:\.(\d+))?Z?$')
      .firstMatch(s);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  if (year < 2000) return null;
  final ms = m.group(7) == null
      ? 0
      : int.parse(m.group(7)!.padRight(3, '0').substring(0, 3));
  final utc = DateTime.utc(
    year,
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
    ms,
  );
  return utc.toLocal();
}

/// Merges the picker's MediaStore columns (DATE_TAKEN epoch-ms,
/// DURATION ms, SIZE) with the retriever [probe] (`durationMs`, `date`).
/// MediaStore wins when sane (it's what Google Photos also keys on);
/// the container metadata is the fallback.
ClipMetadata clipMetadataFrom({
  int? dateTakenMs,
  int? pickerDurationMs,
  int? sizeBytes,
  Map<String, Object?>? probe,
}) {
  DateTime? taken;
  if (dateTakenMs != null && dateTakenMs > 0) {
    final t = DateTime.fromMillisecondsSinceEpoch(dateTakenMs);
    if (t.year >= 2000) taken = t;
  }
  taken ??= parseRetrieverDate(probe?['date']?.toString());
  int? duration =
      pickerDurationMs != null && pickerDurationMs > 0 ? pickerDurationMs : null;
  final probed = (probe?['durationMs'] as num?)?.toInt();
  duration ??= probed != null && probed > 0 ? probed : null;
  return ClipMetadata(
    takenAt: taken,
    durationMs: duration,
    sizeBytes: sizeBytes != null && sizeBytes > 0 ? sizeBytes : null,
  );
}

/// (long side px, JPEG quality) attempts, best first. The first one
/// under the byte budget wins; 200 px @ 70 is the design target.
const kThumbLadder = <(int, int)>[(200, 70), (200, 55), (160, 50), (120, 40)];

/// A durable thumbnail for [source]: the mid frame, walked down
/// [kThumbLadder] until it fits [maxBytes]. Null when no frame can be
/// read or nothing fits (the row then just has no synced thumb).
Future<Uint8List?> durableThumbJpeg(
  FrameExtractor x,
  String source, {
  required int durationMs,
  int maxBytes = kThumbMaxBytes,
}) async {
  final mid = durationMs > 0 ? durationMs ~/ 2 : 0;
  for (final (side, q) in kThumbLadder) {
    final frames = await x.framesAt(source, [mid], maxSide: side, quality: q);
    if (frames.isEmpty) return null; // unreadable — no point retrying
    if (frames.first.length <= maxBytes) return frames.first;
  }
  return null;
}

/// What attach writes into the synced siblings.
class DurableClipExtras {
  const DurableClipExtras({this.thumbJpeg, this.metadata = const ClipMetadata()});

  final Uint8List? thumbJpeg;
  final ClipMetadata metadata;

  /// Sibling field values for [videoField], limited to the dims the view
  /// declares ([hasDim]) — an unknown key never reaches the engine
  /// (old schemas without the siblings stay valid).
  Map<String, Object?> fieldsFor(
      String videoField, bool Function(String dim) hasDim) {
    final out = <String, Object?>{};
    void put(String f, Object? v) {
      if (v != null && hasDim(f)) out[f] = v;
    }

    final t = thumbJpeg;
    put(thumbFieldFor(videoField), t == null ? null : encodeThumbDataUri(t));
    put(takenAtFieldFor(videoField), metadata.takenAt);
    put(durationFieldFor(videoField), metadata.durationMs);
    return out;
  }
}

/// Every durable sibling of [videoField] (cleared together when the
/// clip is removed from a row).
List<String> durableSiblingFields(String videoField) => [
      thumbFieldFor(videoField),
      takenAtFieldFor(videoField),
      durationFieldFor(videoField),
      photosUrlFieldFor(videoField),
    ];

/// Offline capture: probe the clip (duration + container date), merge
/// the picker's MediaStore columns, cut the budgeted thumbnail. Never
/// throws — a failed probe/frame just leaves those pieces null.
Future<DurableClipExtras> captureDurableExtras({
  required FrameExtractor extractor,
  required String source,
  int? dateTakenMs,
  int? pickerDurationMs,
  int? sizeBytes,
}) async {
  Map<String, Object?>? probe;
  try {
    probe = await extractor.probe(source);
  } catch (_) {/* metadata is best-effort */}
  final meta = clipMetadataFrom(
    dateTakenMs: dateTakenMs,
    pickerDurationMs: pickerDurationMs,
    sizeBytes: sizeBytes,
    probe: probe,
  );
  Uint8List? thumb;
  try {
    thumb = await durableThumbJpeg(extractor, source,
        durationMs: meta.durationMs ?? 0);
  } catch (_) {/* no synced thumb is acceptable */}
  return DurableClipExtras(thumbJpeg: thumb, metadata: meta);
}
