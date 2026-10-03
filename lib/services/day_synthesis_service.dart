import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/model_config.dart';
import '../models/view_schema.dart';
import 'analytics_engine.dart';
import 'app_settings.dart' show AppSettings;
import 'day_status.dart';
import 'day_synthesis.dart';
import 'llm_client.dart';
import 'program_current.dart';
import 'program_observed.dart' show observedWeightStats;
import 'program_provider.dart';
import 'warehouse_connector.dart';
import 'week_state_loader.dart';
import 'weight_series.dart' show loadDailyWeighIns;
import 'whoop_activity.dart';
import 'program_week.dart' show dayOnly;
import 'wilks.dart' show contemporaneousBodyweightLbs;

/// The synthesis plus the small tally the post-log notification reads. The
/// synthesis text is what the card shows; the tally lets a notification
/// say "2 of 4 lifts hit; climbing still to come" without re-running the
/// LLM.
class DaySynthesisResult {
  final String text;
  final DateTime generatedAt;
  final int liftsHit;
  final int liftsPlanned;
  final bool climbToCome;

  /// [DaySynthesisContext.fingerprint] of the context this read was
  /// generated from — a stored read is stale once the live context's
  /// fingerprint differs. '' = unknown (always stale).
  final String fingerprint;

  const DaySynthesisResult({
    required this.text,
    required this.generatedAt,
    required this.liftsHit,
    required this.liftsPlanned,
    required this.climbToCome,
    this.fingerprint = '',
  });

  Map<String, Object?> toJson() => {
        'text': text,
        'generated_at': generatedAt.toIso8601String(),
        'lifts_hit': liftsHit,
        'lifts_planned': liftsPlanned,
        'climb_to_come': climbToCome,
        'fingerprint': fingerprint,
      };

  static DaySynthesisResult? tryFromJson(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, Object?>;
      return DaySynthesisResult(
        text: m['text'] as String,
        generatedAt: DateTime.parse(m['generated_at'] as String),
        liftsHit: (m['lifts_hit'] as num?)?.toInt() ?? 0,
        liftsPlanned: (m['lifts_planned'] as num?)?.toInt() ?? 0,
        climbToCome: m['climb_to_come'] as bool? ?? false,
        fingerprint: m['fingerprint'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Produces the day synthesis: assembles today's context from the ledger +
/// program, calls the LLM behind the existing [LlmClient] seam, and caches
/// the result per-day in `shared_preferences`. Never throws — every read
/// degrades to an honest empty/partial context, and an LLM failure returns
/// null (the card keeps showing the last synthesis + a hint).
///
/// Disabled when [llm] is null (disable_post_log / no Anthropic model).
class DaySynthesisService {
  final LlmClient? llm;
  final String? modelName;

  final ViewSchema? mealsView;
  final WarehouseConnector? mealsRepo;
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;
  final ViewSchema? cardioView;
  final WarehouseConnector? cardioRepo;
  final ViewSchema? climbingView;
  final WarehouseConnector? climbingRepo;

  /// Objective recovery (Whoop → `recovery` view): last night's sleep +
  /// recovery score + HRV, fed into the synthesis so advice can factor
  /// readiness. Read the same way the dashboard reads it (a writable
  /// gsheets view via the connector). Null → the recovery line is omitted.
  final ViewSchema? recoveryView;
  final WarehouseConnector? recoveryRepo;

  /// Weight view/repo (+ optional analytics) feed the 7-day-average
  /// bodyweight that prices the cut's per-lb protein band into an
  /// absolute g/day target — same machinery the GOALS surface uses.
  final ViewSchema? weightView;
  final WarehouseConnector? weightRepo;
  final AnalyticsEngine? analytics;

  /// Whoop workouts (`whoop_workouts` view): today's Whoop-detected
  /// activity (climbs/runs/lifts/etc), so the synthesis can say a session
  /// happened even when nothing else logged it. Null → the ACTIVITY line
  /// is omitted.
  final ViewSchema? workoutsView;
  final WarehouseConnector? workoutsRepo;

  /// `program_moves` — today's program includes items moved IN from
  /// another day and drops items moved OUT; skip rows mark items
  /// SKIPPED. Null → the plain routine.
  final ViewSchema? programMovesView;
  final WarehouseConnector? programMovesRepo;

  /// Calisthenics log — credits skill items (handstand, muscle-ups)
  /// exactly as the Today card does. Null → strength sets only.
  final ViewSchema? calisthenicsView;
  final WarehouseConnector? calisthenicsRepo;

  final ProgramProvider? provider;
  final DateTime Function() now;

  DaySynthesisService({
    required this.llm,
    required this.modelName,
    required this.mealsView,
    required this.mealsRepo,
    required this.strengthView,
    required this.strengthRepo,
    required this.cardioView,
    required this.cardioRepo,
    required this.climbingView,
    required this.climbingRepo,
    this.recoveryView,
    this.recoveryRepo,
    this.weightView,
    this.weightRepo,
    this.analytics,
    this.workoutsView,
    this.workoutsRepo,
    this.programMovesView,
    this.programMovesRepo,
    this.calisthenicsView,
    this.calisthenicsRepo,
    required this.provider,
    this.now = DateTime.now,
  });

  bool get enabled => llm != null && modelName != null;

  static const _prefsKey = 'day_synthesis';

  /// Cache-content version. BUMP whenever a change upstream of the LLM
  /// (the assembled context, the target resolution, the prompt) would
  /// make an already-stored synthesis wrong. On read, a stored synthesis
  /// tagged with an older version is ignored → regenerated. v2 (bump
  /// 2026-09-30): busts caches written before the cut macro-target fix
  /// (commit 7573f0c) that still say "no macro targets set today". v3
  /// (bump 2026-09-30): the prompt now carries a recovery/sleep line, so
  /// caches written without it are regenerated to factor readiness. v4
  /// (2026-10-01): Whoop activity line + climb credit. v5 (2026-10-02):
  /// program_moves — moved-in items join today's program, moved-out
  /// ones leave it. v6 (2026-10-02): the PROGRAM STATUS block (the Today
  /// card's own per-item state) replaces the routine-prose program lines
  /// — a read written from the old prompt could nudge a DONE climb — and
  /// stored reads carry a context fingerprint.
  static const _cacheVersion = 6;

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// The cached synthesis for today, or null if none / a different day.
  Future<DaySynthesisResult?> cached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, Object?>;
      // Ignore caches written before a content-affecting fix (missing
      // version = pre-versioning = older than v2's macro-target fix).
      if ((m['v'] as num?)?.toInt() != _cacheVersion) return null;
      if (m['day'] != _dayKey(now())) return null; // stale — new day
      return DaySynthesisResult.tryFromJson(jsonEncode(m['result']));
    } catch (_) {
      return null;
    }
  }

  Future<void> _store(DaySynthesisResult r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'v': _cacheVersion,
          'day': _dayKey(now()),
          'result': r.toJson(),
        }),
      );
    } catch (_) {/* best-effort */}
  }

  /// Assembles today's context. Public so the notification driver can read
  /// the tally without an LLM call.
  Future<DaySynthesisContext> buildContext() async {
    final clock = now();
    final dayStart = DateTime(clock.year, clock.month, clock.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    final meals = <SynthMeal>[];
    if (mealsView != null && mealsRepo != null) {
      try {
        for (final r in await mealsRepo!.list(mealsView!)) {
          final eaten = _date(r['eaten_at']);
          if (eaten == null) continue;
          if (eaten.isBefore(dayStart) || !eaten.isBefore(dayEnd)) continue;
          meals.add(SynthMeal(
            calories: _num(r['calories']),
            proteinG: _num(r['protein_g']),
            carbsG: _num(r['carbs_g']),
            fatG: _num(r['fat_g']),
            atHour: eaten.hour,
          ));
        }
      } catch (_) {/* honest empty */}
    }

    // Objective recovery (Whoop): last night's row (the most recent
    // recovery date at/ before today) + a 7-day-average recovery score
    // trend anchor. Read like the dashboard reads it.
    var recovery = const SynthRecovery();
    if (recoveryView != null && recoveryRepo != null) {
      try {
        recovery = buildSynthRecovery(
          await recoveryRepo!.list(recoveryView!),
          clock,
        );
      } catch (_) {/* honest empty — recovery line omitted */}
    }

    // Current 7-day-average bodyweight (lb) — prices the cut's per-lb
    // protein band. Same resolution the GOALS surface uses: 7d avg, then
    // the contemporaneous weigh-in as a fallback. Null when no weigh-ins.
    double? bodyweightLb;
    if (weightView != null && weightRepo != null) {
      try {
        final series = await loadDailyWeighIns(
          analytics: analytics,
          view: weightView,
          repo: weightRepo,
        );
        final daily = series.daily;
        if (daily.isNotEmpty) {
          bodyweightLb = observedWeightStats(daily, clock).bw7dAvg ??
              contemporaneousBodyweightLbs(daily, clock);
        }
      } catch (_) {/* honest null — falls back to per-lb text */}
    }

    // Targets from the slice + TODAY'S PROGRAM STATUS from the shared
    // WeekStateLoader → DayStatus — the exact per-item state the Today
    // card shows (sets, calisthenics, Whoop/Kaya climb credit, 4x4,
    // moves, skips). One resolution, so the read can't disagree with it.
    DayStatus? status;
    var activities = const <WhoopActivity>[];
    var climbCount = 0;
    var targets = SynthTargets(bodyweightLb: bodyweightLb);
    var phase = '';
    final p = provider;
    if (p != null) {
      try {
        final docs = await p.load();
        if (docs.program != null) {
          final slice = programCurrent(docs.program!, docs.phase, clock);
          if (slice != null) {
            targets = SynthTargets(
              // Recomp phase exposes absolute grams; the cut exposes the
              // relative per-lb band + a soft (non-slice) carb floor.
              proteinGDay: _pair(slice.targetsInForce['protein_g_day']),
              proteinGPerLb: _pair(slice.targetsInForce['protein_g_per_lb']),
              bodyweightLb: bodyweightLb,
              carbsGDay: _pair(slice.targetsInForce['carbs_g_day']),
              fatGDayMin: _num(slice.targetsInForce['fat_g_day_min']),
            );
            phase = slice.block['emphasis']?.toString() ?? '';
          }
          final state = await WeekStateLoader(
            loadDocs: () async => docs,
            programMovesView: programMovesView,
            programMovesRepo: programMovesRepo,
            strengthView: strengthView,
            strengthRepo: strengthRepo,
            workoutsView: workoutsView,
            workoutsRepo: workoutsRepo,
            cardioView: cardioView,
            cardioRepo: cardioRepo,
            climbingView: climbingView,
            climbingRepo: climbingRepo,
            calisthenicsView: calisthenicsView,
            calisthenicsRepo: calisthenicsRepo,
            now: now,
            weekStartSetting: () => AppSettings.weekStartSetting.value,
          ).load(dayStart, withMissed: true);
          if (state != null) {
            status = state.dayStatus(
              trackSets: strengthView != null && strengthRepo != null,
            );
            activities = [
              for (final a in state.whoop)
                if (dayOnly(a.date) == dayStart) a,
            ];
            climbCount =
                state.kayaDays.where((d) => dayOnly(d) == dayStart).length;
          }
        }
      } catch (_) {/* no program → still synthesize what's logged */}
    }

    return DaySynthesisContext(
      hour: clock.hour,
      phase: phase,
      status: status,
      logged: SynthLogged(meals: meals, climbCount: climbCount),
      targets: targets,
      recovery: recovery,
      activities: activities,
    );
  }

  /// Runs the synthesis: builds context, calls the LLM, caches + returns
  /// the result. Returns null when disabled or the call fails (the card
  /// keeps the previous synthesis). [context] may be supplied to reuse an
  /// already-built context.
  Future<DaySynthesisResult?> generate({DaySynthesisContext? context}) async {
    if (!enabled) return null;
    final c = context ?? await buildContext();
    final prompt = buildDaySynthesisPrompt(c);
    String text;
    try {
      text = await llm!.complete(modelName!, prompt);
    } catch (_) {
      return null;
    }
    if (text.trim().isEmpty) return null;
    final result = DaySynthesisResult(
      text: text.trim(),
      generatedAt: now(),
      liftsHit: c.liftsHit,
      liftsPlanned: c.liftsPlanned,
      climbToCome: c.climbToCome,
      fingerprint: c.fingerprint,
    );
    await _store(result);
    return result;
  }

  /// Regenerates ONLY when the live context's fingerprint differs from
  /// the stored read's (or nothing is stored) — any set logged, Whoop /
  /// integration sync, calisthenics set, move, skip, macro bucket or
  /// recovery change makes the stored read stale. Returns the new read,
  /// or null when it is still fresh / disabled / the LLM failed.
  Future<DaySynthesisResult?> refreshIfStale() async {
    if (!enabled) return null;
    final c = await buildContext();
    if (await isFresh(c)) return null;
    return generate(context: c);
  }

  /// True when today's stored read was generated from a context with the
  /// same fingerprint as [c] (nothing it depends on has changed).
  Future<bool> isFresh(DaySynthesisContext c) async {
    final stored = await cached();
    return stored != null &&
        stored.fingerprint.isNotEmpty &&
        stored.fingerprint == c.fingerprint;
  }

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static List<double>? _pair(Object? v) {
    if (v is List && v.length >= 2) {
      final a = _num(v[0]);
      final b = _num(v[1]);
      if (a != null && b != null) return [a, b];
    }
    return null;
  }
}

/// Pure: pick last night's recovery (the most recent row dated at/before
/// [clock]) from the recovery view's rows and compute a 7-day-average
/// recovery score anchor. Rows dated in the future are ignored. Returns
/// an empty [SynthRecovery] when there's no usable row. Exposed for a
/// direct context-assembly test.
SynthRecovery buildSynthRecovery(
  List<Map<String, Object?>> rows,
  DateTime clock,
) {
  final today = DateTime(clock.year, clock.month, clock.day);
  // (day, row) pairs with a parseable date not in the future.
  final dated = <({DateTime day, Map<String, Object?> row})>[];
  for (final r in rows) {
    final d = DaySynthesisService._date(r['date']);
    if (d == null) continue;
    final day = DateTime(d.year, d.month, d.day);
    if (day.isAfter(today)) continue;
    dated.add((day: day, row: r));
  }
  if (dated.isEmpty) return const SynthRecovery();
  dated.sort((a, b) => b.day.compareTo(a.day)); // newest first
  final latest = dated.first;

  // 7-day-average recovery score over the window ending at the latest
  // row's day (inclusive). A short window / sparse data still averages
  // whatever scores are present.
  final windowStart = latest.day.subtract(const Duration(days: 6));
  final scores = <double>[];
  for (final e in dated) {
    if (e.day.isBefore(windowStart)) break; // sorted desc
    final s = DaySynthesisService._num(e.row['recovery_score']);
    if (s != null) scores.add(s);
  }
  final avg = scores.isEmpty
      ? null
      : scores.reduce((a, b) => a + b) / scores.length;

  String two(int n) => n.toString().padLeft(2, '0');
  return SynthRecovery(
    day: '${latest.day.year.toString().padLeft(4, '0')}-'
        '${two(latest.day.month)}-${two(latest.day.day)}',
    sleepHours: DaySynthesisService._num(latest.row['sleep_hours']),
    recoveryScore: DaySynthesisService._num(latest.row['recovery_score']),
    hrvMs: DaySynthesisService._num(latest.row['hrv_ms']),
    recoveryScore7dAvg: avg,
  );
}

/// Convenience: which chat/vision Anthropic model to synthesize with.
/// Mirrors home_screen's `_chatModel` selection.
String? synthesisModelName(List<ModelConfig> models) {
  for (final m in models) {
    if (m.vendor == ModelVendor.anthropic) return m.name;
  }
  return null;
}
