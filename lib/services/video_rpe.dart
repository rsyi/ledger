/// Video-attach + AI-RPE support for `widget: video` fields.
///
/// Pipeline (all seams injectable, pure parts tested):
///
///   attach (video_attach.dart) → download bytes via the picker baseUrl
///   (`=dv`, valid ~60 min — done immediately) → sample ~14 evenly
///   spaced frames (video_frames.dart channel) → Claude vision
///   (LlmClient.completeVision) with set context → parse a strict-JSON
///   estimate → persist device-local (shared_preferences, keyed by the
///   PICKER MEDIA ID — stable before the row exists) + append to the
///   ledger meta `video_rpe_log` for coach context.
///
/// PROPOSE-ONLY contract: the estimate renders as a chip in the form;
/// ONLY a user tap writes the rpe field. Nothing here ever writes rpe,
/// and the working-max controller / weekly review see only what the
/// user saved.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'integrations/photos_picker_gateway.dart' show videoDownloadUrl;
import 'llm_client.dart';
import 'video_attach.dart';
import 'video_frames.dart';

/// Sibling-dim convention for `widget: video` fields: the picker's
/// persistent media-item id is stored next to the URL dim in
/// `<field minus "_url">_media_id` (video_url → video_media_id). When
/// the view has no such dim the id is simply not persisted.
String mediaIdFieldFor(String videoField) {
  final base = videoField.endsWith('_url')
      ? videoField.substring(0, videoField.length - 4)
      : videoField;
  return '${base}_media_id';
}

// ---------------------------------------------------------------- pure

/// Evenly spaced sample timestamps, inset 4% from each end (skips the
/// walk-up/rack fumbling that says nothing about bar speed). Clamped to
/// 1..20 frames; degenerate durations collapse to a single mid frame.
List<int> frameTimestampsMs(int durationMs, {int count = 14}) {
  if (durationMs <= 0) return const [0];
  final start = (durationMs * 0.04).round();
  final end = (durationMs * 0.96).round();
  // ≥100 ms between frames — below that, "frames" are near-duplicates
  // and a blink-length clip collapses to one mid sample.
  final maxFrames = end > start ? (end - start) ~/ 100 + 1 : 1;
  final n = count.clamp(1, 20).clamp(1, maxFrames);
  if (n == 1) return [durationMs ~/ 2];
  final step = (end - start) / (n - 1);
  return [for (var i = 0; i < n; i++) (start + step * i).round()];
}

/// What the estimator knows about the set being filmed. All fields
/// optional — the user may attach before typing anything; the prompt
/// says "unknown" honestly instead of guessing.
class RpeRowContext {
  const RpeRowContext({
    this.exercise,
    this.weight,
    this.reps,
    this.setType,
    this.recentHistory = const [],
  });

  final String? exercise;
  final num? weight;
  final num? reps;
  final String? setType;

  /// Preformatted lines like `2026-09-20: 220×5 @ RPE 8`, newest first.
  final List<String> recentHistory;
}

/// Formats recent same-exercise rows (with an RPE) into prompt lines,
/// newest first, capped. Rows missing date/weight/reps render what
/// they have. Pure — the form passes its already-loaded recent rows.
List<String> recentRpeLines(
  List<Map<String, Object?>> rows, {
  required String? exercise,
  String dateField = 'date',
  int cap = 8,
}) {
  if (exercise == null || exercise.isEmpty) return const [];
  final hits = <(String, String)>[];
  for (final r in rows) {
    if ('${r['exercise'] ?? ''}' != exercise) continue;
    final rpe = '${r['rpe'] ?? ''}'.trim();
    if (rpe.isEmpty) continue;
    final date = '${r[dateField] ?? ''}'.split('T').first.split(' ').first;
    final w = '${r['weight'] ?? '?'}';
    final reps = '${r['reps'] ?? '?'}';
    hits.add((date, '$date: $w×$reps @ RPE $rpe'));
  }
  hits.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final h in hits.take(cap)) h.$2];
}

String _mmss(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Builds the vision prompt. Frames are attached BEFORE this text in
/// the same user turn, chronological order.
String buildRpePrompt({
  required RpeRowContext ctx,
  required List<int> timestampsMs,
  required int durationMs,
}) {
  final b = StringBuffer()
    ..writeln(
        'You are an experienced strength coach estimating RPE (Rate of '
        'Perceived Exertion, 1-10; 10 = could not have done another rep; '
        'RPE 8 = 2 reps left) from lifting video.')
    ..writeln()
    ..writeln('The ${timestampsMs.length} images are still frames sampled '
        'at even intervals from ONE set (video length ${_mmss(durationMs)}; '
        'frame times: ${timestampsMs.map(_mmss).join(', ')}), in '
        'chronological order.')
    ..writeln()
    ..writeln('Set context:')
    ..writeln('- Exercise: ${ctx.exercise ?? 'unknown'}')
    ..writeln('- Load: ${ctx.weight ?? 'unknown'} lb × '
        '${ctx.reps ?? 'unknown'} reps (as entered by the lifter)')
    ..writeln('- Set intent: ${ctx.setType ?? 'untagged'}');
  if (ctx.recentHistory.isNotEmpty) {
    b.writeln('Recent sets of this lift with the lifter\'s own RPE '
        '(newest first) — calibrate against these:');
    for (final line in ctx.recentHistory) {
      b.writeln('- $line');
    }
  }
  b
    ..writeln()
    ..writeln('Judge only what is visible across the frames:')
    ..writeln('1. Per-rep bar speed impression — concentric slowdown '
        'across equal time steps (position spacing, motion blur), rest '
        'pauses between reps lengthening.')
    ..writeln('2. Last-rep grind — sticking point, fight through the '
        'concentric, form breakdown (hips shooting, back angle change, '
        'uneven lockout, knee cave).')
    ..writeln('3. If the frames do not clearly show a lift, say so — do '
        'NOT invent an estimate.')
    ..writeln()
    ..writeln('Reply with STRICT JSON only — no markdown fences, no '
        'prose outside the JSON:')
    ..writeln('{"rpe": <number 1-10, halves allowed, or null if not '
        'discernible>, "band": [<low>, <high>], '
        '"bar_speed": "<short phrase>", "last_rep": "<short phrase>", '
        '"reasoning": "<ONE sentence, max 25 words>"}');
  return b.toString();
}

/// Parsed estimate. [rpe] null = the model honestly couldn't judge.
class RpeEstimate {
  const RpeEstimate({
    required this.rpe,
    this.low,
    this.high,
    required this.reasoning,
    this.barSpeed,
    this.lastRep,
  });

  final double? rpe;
  final double? low;
  final double? high;
  final String reasoning;
  final String? barSpeed;
  final String? lastRep;

  /// "~8.5 (8–9)" / "~8" — chip label fragment.
  String get display {
    final r = rpe;
    if (r == null) return 'not discernible';
    final core = '~${_trim(r)}';
    if (low != null && high != null) {
      return '$core (${_trim(low!)}–${_trim(high!)})';
    }
    return core;
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : '$v';

  Map<String, Object?> toJson() => {
        'rpe': rpe,
        'low': low,
        'high': high,
        'reasoning': reasoning,
        'bar_speed': barSpeed,
        'last_rep': lastRep,
      };

  static RpeEstimate fromJson(Map<String, dynamic> m) => RpeEstimate(
        rpe: (m['rpe'] as num?)?.toDouble(),
        low: (m['low'] as num?)?.toDouble(),
        high: (m['high'] as num?)?.toDouble(),
        reasoning: '${m['reasoning'] ?? ''}',
        barSpeed: m['bar_speed'] as String?,
        lastRep: m['last_rep'] as String?,
      );
}

/// Parses the model reply: tolerates code fences / stray prose around
/// the JSON object, validates rpe ∈ [1,10] (null allowed), band order.
/// Throws [FormatException] on garbage — callers surface the failure
/// instead of showing a fabricated number.
RpeEstimate parseRpeEstimate(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw FormatException('No JSON object in RPE reply: $raw');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw.substring(start, end + 1));
  } catch (e) {
    throw FormatException('Malformed JSON in RPE reply: $e');
  }
  if (decoded is! Map) {
    throw FormatException('RPE reply is not an object: $raw');
  }
  final m = decoded.cast<String, dynamic>();
  final rpeRaw = m['rpe'];
  double? rpe;
  if (rpeRaw != null) {
    if (rpeRaw is! num) {
      throw FormatException('rpe is not a number: $rpeRaw');
    }
    rpe = rpeRaw.toDouble();
    if (rpe < 1 || rpe > 10) {
      throw FormatException('rpe out of range: $rpe');
    }
  }
  double? low;
  double? high;
  final band = m['band'];
  if (band is List && band.length == 2) {
    final l = band[0];
    final h = band[1];
    if (l is num && h is num && l <= h) {
      low = l.toDouble();
      high = h.toDouble();
    }
  }
  return RpeEstimate(
    rpe: rpe,
    low: low,
    high: high,
    reasoning: '${m['reasoning'] ?? ''}'.trim(),
    barSpeed: m['bar_speed'] as String?,
    lastRep: m['last_rep'] as String?,
  );
}

/// One coach-context log entry (meta `video_rpe_log`, newest first).
Map<String, Object?> rpeLogEntry({
  required String mediaId,
  required RpeRowContext ctx,
  required RpeEstimate estimate,
  required DateTime at,
}) =>
    {
      'media_id': mediaId,
      'at': at.toIso8601String(),
      'exercise': ctx.exercise,
      'weight': ctx.weight,
      'reps': ctx.reps,
      'estimate': estimate.rpe,
      'band': estimate.low == null || estimate.high == null
          ? null
          : [estimate.low, estimate.high],
      'reasoning': estimate.reasoning,
      // Filled at save time: the rpe the USER logged (null until then).
      // accepted = final == estimate; a differing value is an override —
      // both are signal for the coach (is the model calibrated?).
      'final_rpe': null,
    };

/// Applies the save-time outcome to the newest matching log entry.
/// Returns true when an entry was updated. Pure (operates on the
/// decoded list in place).
bool applyRpeOutcome(
  List<dynamic> log, {
  required String mediaId,
  required Object? finalRpe,
}) {
  for (final e in log) {
    if (e is Map && e['media_id'] == mediaId) {
      e['final_rpe'] =
          finalRpe is num ? finalRpe : num.tryParse('${finalRpe ?? ''}');
      return true;
    }
  }
  return false;
}

// -------------------------------------------------------------- states

sealed class RpeEstimateState {
  const RpeEstimateState();
}

class RpeEstimatePending extends RpeEstimateState {
  const RpeEstimatePending();
}

class RpeEstimateReady extends RpeEstimateState {
  const RpeEstimateReady(this.estimate);
  final RpeEstimate estimate;
}

class RpeEstimateFailed extends RpeEstimateState {
  const RpeEstimateFailed(this.message);
  final String message;
}

// ------------------------------------------------------------- service

/// App-global holder for the video pipeline (HeartRateService.instance
/// precedent — avoids threading a rarely-used dependency through every
/// screen between home and the form). Null when the Google web client
/// id isn't configured; the form then renders the attach affordance
/// disabled with a hint. [llm]/[modelName] null (disable_post_log or no
/// Anthropic model) = attach works, estimation quietly disabled.
class VideoRpeService extends ChangeNotifier {
  VideoRpeService({
    required this.flow,
    this.llm,
    this.modelName,
    FrameExtractor? extractor,
    this.metaGet,
    this.metaSet,
    this.frameCount = 14,
    this.logCap = 20,
  }) : _extractor = extractor ?? ChannelFrameExtractor();

  static VideoRpeService? instance;

  final VideoAttachFlow flow;
  final LlmClient? llm;
  final String? modelName;
  final FrameExtractor _extractor;
  final int frameCount;
  final int logCap;

  /// Ledger meta seam (null on non-engine builds → no coach log).
  final Future<String?> Function(String key)? metaGet;
  final Future<void> Function(String key, String value)? metaSet;

  static const kLogMetaKey = 'video_rpe_log';
  static const _prefsPrefix = 'video_rpe:';

  final Map<String, RpeEstimateState> _states = {};

  bool get canEstimate => llm != null && modelName != null;

  /// In-memory state for the chip; null = never started this session
  /// (check [load] for a persisted estimate from a past session).
  RpeEstimateState? stateFor(String mediaId) => _states[mediaId];

  /// Persisted estimate from any session (edit-mode reopen).
  Future<RpeEstimate?> load(String mediaId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefsPrefix$mediaId');
    if (raw == null) return null;
    try {
      return RpeEstimate.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// Runs the full estimate pipeline for a freshly attached video.
  /// Never throws — failures land in [stateFor] as [RpeEstimateFailed]
  /// (the chip shows them; the form stays usable).
  Future<void> estimate({
    required VideoAttachResult video,
    required RpeRowContext ctx,
  }) async {
    final llm = this.llm;
    final model = modelName;
    if (llm == null || model == null) return;
    _states[video.mediaId] = const RpeEstimatePending();
    notifyListeners();
    File? tmp;
    try {
      // Immediately — the baseUrl dies ~60 min after the pick.
      final bytes = await flow.gateway.download(
        videoDownloadUrl(video.baseUrl),
      );
      final dir = await getTemporaryDirectory();
      tmp = File(
          '${dir.path}/rpe_${video.mediaId.hashCode.toRadixString(16)}.mp4');
      await tmp.writeAsBytes(bytes, flush: true);
      final duration = await _extractor.durationMs(tmp.path);
      final timestamps = frameTimestampsMs(duration, count: frameCount);
      final frames = await _extractor.framesAt(tmp.path, timestamps);
      if (frames.isEmpty) {
        throw StateError('No frames could be extracted from the video');
      }
      final raw = await llm.completeVision(
        model,
        buildRpePrompt(
          ctx: ctx,
          timestampsMs: timestamps.take(frames.length).toList(),
          durationMs: duration,
        ),
        frames,
      );
      final est = parseRpeEstimate(raw);
      await _persist(video.mediaId, est, ctx);
      _states[video.mediaId] = RpeEstimateReady(est);
    } catch (e) {
      _states[video.mediaId] = RpeEstimateFailed('$e');
    } finally {
      try {
        await tmp?.delete();
      } catch (_) {/* best-effort */}
    }
    notifyListeners();
  }

  Future<void> _persist(
      String mediaId, RpeEstimate est, RpeRowContext ctx) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefsPrefix$mediaId', jsonEncode(est.toJson()));
    final set = metaSet;
    if (set == null) return;
    final log = await _readLog();
    log.insert(
      0,
      rpeLogEntry(
          mediaId: mediaId, ctx: ctx, estimate: est, at: DateTime.now()),
    );
    await set(kLogMetaKey, jsonEncode(log.take(logCap).toList()));
  }

  /// Save-time hook: records the rpe the user actually logged next to
  /// the estimate (accepted vs overridden — coach calibration signal).
  Future<void> recordOutcome(String mediaId, Object? finalRpe) async {
    final set = metaSet;
    if (set == null) return;
    try {
      final log = await _readLog();
      if (applyRpeOutcome(log, mediaId: mediaId, finalRpe: finalRpe)) {
        await set(kLogMetaKey, jsonEncode(log));
      }
    } catch (_) {/* never block a save on bookkeeping */}
  }

  Future<List<dynamic>> _readLog() async {
    final get = metaGet;
    if (get == null) return [];
    try {
      final raw = await get(kLogMetaKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : [];
    } catch (_) {
      return [];
    }
  }
}
