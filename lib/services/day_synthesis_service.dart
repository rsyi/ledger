import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/model_config.dart';
import '../models/view_schema.dart';
import 'analytics_engine.dart';
import 'day_synthesis.dart';
import 'llm_client.dart';
import 'plan_store.dart';
import 'program_current.dart';
import 'program_observed.dart' show observedWeightStats;
import 'program_provider.dart';
import 'today_program_call.dart';
import 'warehouse_connector.dart';
import 'week_state_loader.dart';
import 'weight_series.dart' show loadDailyWeighIns;
import 'whoop_activity.dart';
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

  const DaySynthesisResult({
    required this.text,
    required this.generatedAt,
    required this.liftsHit,
    required this.liftsPlanned,
    required this.climbToCome,
  });

  Map<String, Object?> toJson() => {
        'text': text,
        'generated_at': generatedAt.toIso8601String(),
        'lifts_hit': liftsHit,
        'lifts_planned': liftsPlanned,
        'climb_to_come': climbToCome,
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
  /// another day and drops items moved OUT. Null → the plain routine.
  final ViewSchema? programMovesView;
  final WarehouseConnector? programMovesRepo;

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
  /// ones leave it.
  static const _cacheVersion = 5;

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

    final sets = <SynthSet>[];
    if (strengthView != null && strengthRepo != null) {
      try {
        for (final r in await strengthRepo!.list(strengthView!)) {
          if (!_sameDay(_date(r['date']), dayStart)) continue;
          final ex = r['exercise']?.toString().trim();
          if (ex == null || ex.isEmpty) continue;
          sets.add(SynthSet(
            exercise: ex,
            weight: _num(r['weight']),
            reps: _num(r['reps'])?.round(),
          ));
        }
      } catch (_) {/* honest empty */}
    }

    var did4x4 = false;
    if (cardioView != null && cardioRepo != null) {
      try {
        for (final r in await cardioRepo!.list(cardioView!)) {
          if (!_sameDay(_date(r['date']), dayStart)) continue;
          final type = r['type']?.toString().toLowerCase() ?? '';
          if (type.contains('4x4') || type.contains('4 x 4')) did4x4 = true;
        }
      } catch (_) {/* honest empty */}
    }

    var climbCount = 0;
    if (climbingView != null && climbingRepo != null) {
      try {
        for (final r in await climbingRepo!.list(climbingView!)) {
          if (_sameDay(_date(r['date']), dayStart)) climbCount++;
        }
      } catch (_) {/* honest empty */}
    }

    // Whoop-detected activity (climbs/runs/lifts/etc) for today — a
    // session Whoop saw counts as done even if nothing else logged it.
    var activities = const <WhoopActivity>[];
    if (workoutsView != null && workoutsRepo != null) {
      try {
        activities = [
          for (final a in whoopActivitiesFromRecords(
              await workoutsRepo!.list(workoutsView!)))
            if (_sameDay(a.date, dayStart)) a,
        ];
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

    // Program call + routine prose + targets from the slice.
    var program = const SynthProgramDay();
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
            final call = todayProgramCallByView(
              docs.program!,
              docs.phase,
              clock,
            );
            final planned = <String>[];
            if (strengthView != null) {
              try {
                for (final e in await PlanStore.loadForDate(
                  strengthView!,
                  clock,
                )) {
                  final ex = e.values['exercise']?.toString().trim();
                  if (ex != null && ex.isNotEmpty) planned.add(ex);
                }
              } catch (_) {/* honest empty */}
            }
            program = SynthProgramDay(
              morning: slice.todayTemplate['morning']?.toString() ?? '',
              afternoon: slice.todayTemplate['afternoon']?.toString() ?? '',
              plannedLifts: planned,
              wants4x4: call.containsKey('cardio'),
              climbCall: call['climbing'],
            );
            // Moves: today's effective items (shared loader — moves read
            // only; the logged work is already in hand above).
            if (programMovesView != null && programMovesRepo != null) {
              try {
                final state = await WeekStateLoader(
                  loadDocs: () async => docs,
                  programMovesView: programMovesView,
                  programMovesRepo: programMovesRepo,
                ).load(clock);
                if (state != null) {
                  program = synthProgramWithMoves(
                    program,
                    state.day,
                    loggedToday: [for (final s in sets) s.exercise],
                    climbed: climbCount > 0 ||
                        activities.any((a) => a.kind == ActivityKind.climb),
                    did4x4: did4x4,
                  );
                }
              } catch (_) {/* honest: the unmoved routine */}
            }
          }
        }
      } catch (_) {/* no program → still synthesize what's logged */}
    }

    return DaySynthesisContext(
      hour: clock.hour,
      phase: phase,
      program: program,
      logged: SynthLogged(
        meals: meals,
        sets: sets,
        did4x4: did4x4,
        climbCount: climbCount,
      ),
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
      liftsHit: c.liftsDone.length,
      liftsPlanned: c.liftsPlanned.length,
      climbToCome: c.climbToCome,
    );
    await _store(result);
    return result;
  }

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  static bool _sameDay(DateTime? d, DateTime day) =>
      d != null && d.year == day.year && d.month == day.month && d.day == day.day;

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
