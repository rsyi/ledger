/// Weekly auto-planner — generates the week's planned strength rows from
/// the coach program (`coach/program.yaml` `planned` + `warmup_protocol`
/// keys; weights from the working-max controller's chart math (v5
/// `load_policies` + `rpe_chart`), falling back to v4 `weight_fill`
/// reference math) into the device-local PlanStore, where the timeline
/// renders them with Log-now.
///
/// Two layers:
///  - [buildWeekPlannedEntries]: pure core (zero Flutter/IO imports) —
///    program map + week Monday (+ per-lift reference e1rms) in,
///    PlannedEntry-shaped maps out. Each map carries ONLY `date` +
///    `exercise` + `reps` + (when computable) `weight` — NEVER rpe or
///    notes (planned rows must not fabricate performance data), and
///    weight is absent rather than guessed when no reference exists.
///  - [WeekPlanner.ensureCurrentWeek]: thin runner — weekly idempotence
///    via the `week_planner_generated_monday` ledger meta key (stamped
///    `<monday>|plan_v2`; a mismatch regenerates the week today-forward,
///    replacing only still-planned rows); writes through the same
///    PlanStore path coach proposals use.
library;

import 'dart:math' show max;

import 'package:airledger_engine/airledger_engine.dart';
import 'package:intl/intl.dart';

import '../models/planned_entry.dart';
import '../models/view_schema.dart';
import 'plan_store.dart';
import 'accessory_progression.dart'
    show AccessoryRule, suggestAccessoryLoad;
import 'program_current.dart'
    show
        currentVersion,
        programCurrent,
        routineWeekFor,
        strengthWaveCutFor,
        strengthWaveTopReps,
        weekStartDayOf;
import 'program_metrics.dart'
    show StrengthRow, liftReferencesAsOf, mainLiftByExercise;
import 'program_provider.dart';
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';
import 'week_plan.dart' show defaultWeekStart;
import 'wm_tabs.dart'
    show WmSnapshot, activeCapsByLift, currentWorkingMaxesByLift;
import 'working_max.dart'
    show LoadPolicy, loadPolicies, policyForDate, rpePct, warmupRamp;

const List<String> _weekdayKeys = [
  'mon',
  'tue',
  'wed',
  'thu',
  'fri',
  'sat',
  'sun',
];

DateTime _parseDay(Object? s) {
  final d = DateTime.parse(s.toString());
  return DateTime.utc(d.year, d.month, d.day);
}

/// The block containing [day] (inclusive both ends), or null.
Map<Object?, Object?>? _blockFor(Map<Object?, Object?> version, DateTime day) {
  final blocks = version['blocks'];
  if (blocks is! List) return null;
  for (final b in blocks) {
    if (b is! Map) continue;
    final dates = b['dates'];
    if (dates is! List || dates.length < 2) continue;
    final start = _parseDay(dates[0]);
    final end = _parseDay(dates[1]);
    if (!day.isBefore(start) && !day.isAfter(end)) {
      return Map<Object?, Object?>.from(b);
    }
  }
  return null;
}

/// Rounds [x] to the nearest multiple of [step] (5 lb by default in the
/// program). Half rounds away from zero (Dart `num.round`).
num _roundTo(num x, num step) {
  final r = (x / step).round() * step;
  // Prefer int weights (245, not 245.0) so sheets/e1rm math stays clean.
  return r == r.roundToDouble() ? r.round() : r;
}

/// Expands the current program version's `planned` lifts into one map per
/// SET for the ISO week containing [weekMonday] (any day of the week is
/// accepted; it's normalised to Monday).
///
/// Returned maps have keys drawn from exactly {date, exercise, reps,
/// weight, top} — never rpe or notes:
///   - `date`     — UTC-midnight [DateTime] of the entry's weekday
///   - `exercise` — the exact logged exercise name (metrics depend on it)
///   - `reps`     — planned reps for that one set
///   - `weight`   — only when computable; never guessed
///   - `top`      — true on wave top-set rows (`reps: top` in the
///     program); consumers ignore it when persisting.
///
/// Weight fill, v3 (working-max controller, spec §0: percentages hang off
/// the working max): when the lift has an entry in [workingMaxes] and a
/// load policy covers the date, a working set's weight is
///   working max × rpe_chart[policy target RPE][reps]
/// (target = the policy's upper target RPE, undercut by its cap_rpe and
/// by [capRpeByLift] — the post-drop / pain cap), rounded to
/// `rounding_lb`. This is the same §4 prescription math as
/// buildPrescription.
///
/// Fallback (v2, when the lift has no working max or no policy applies):
/// the lift's entry in [references] (42-day reference e1rm, see
/// [liftReferencesAsOf]) × `weight_fill.pct_by_reps[reps]`, rounded.
/// Absent when neither path is computable — never guessed.
///
/// Warm-ups (program v4 `warmup_protocol`): each planned exercise's sets
/// are preceded — once per exercise per day — by the ramp rows: fixed
/// `weight_lb` steps as-is; `pct_top` steps at that fraction of the day's
/// TOP working weight for the exercise, rounded, and dropped unless
/// strictly above `min_above_lb` when declared (the deadlift 135 rule).
/// The whole ramp is skipped when the working weight is unknown.
///
/// `sets: N` items expand into N entries (one row per set convention).
/// Alternation-aware: when a day's `planned` is an a/b map, parity comes
/// from `planned_alternation.anchor_monday` — whole ISO weeks since the
/// anchor, even (incl. 0) = `a`, odd = `b`.
///
/// Strength wave (program.yaml v10 `strength_wave`, final post-cut
/// spec): a planned item with `reps: top` resolves to the wave's
/// prescribed top reps for the week (5/3/1; light week = the wave-
/// restart 5, test week = the block-result single) via
/// [strengthWaveTopReps]; when no wave is in force the row is SKIPPED
/// (never guessed). Volume multipliers on NON-top rows, sets scaled to
/// max(1, round(sets × m)):
///   * wave deload (`deload_volume_multiplier`) on light/test weeks in
///     wave blocks — the deload is reduced volume, not just intensity;
///   * `emphasis_volume.climbing_block_lifting_multiplier` (midpoint)
///     in climbing-emphasis blocks — heavies (top sets) preserved;
///   * `volume_ramp` (midpoint, ACCESSORY rows only — exercises
///     outside the four main lifts) keyed to whole weeks since its
///     anchor_monday: the post-cut weeks 1-2 ease-in.
///
/// Cut wave (program.yaml v11 `strength_wave_cut`, approved cut-
/// training revision 2026-09-28, plan_v5): on block-0 days the wave is
/// CALENDAR-anchored ([strengthWaveCutFor]); `reps: top` resolves to
/// the wave week's reps (5/4/3; deload 5) and the top's weight is the
/// working max × the wave's DECLARED pct (weeks 1-3 = chart[8][reps],
/// deload 0.70) — undercut by any active RPE cap via min(pct,
/// chart[cap target][reps]). Deload weeks scale NON-top rows by the
/// wave's `deload_volume_multiplier` (halved, min 1 set). Planned
/// items may also carry an explicit `pct` (the v11 %TM volume slots,
/// e.g. bench 4x8 @ 0.68): those price at working max × pct (same cap
/// undercut) and NEVER fall back to the reference-e1rm path — a %-of-
/// TM row without a TM is honestly weightless.
///
/// Weeks that fall outside every block (pre-program) and days without a
/// `planned` key produce nothing. Malformed structures are skipped, never
/// thrown on.
List<Map<String, Object?>> buildWeekPlannedEntries(
  Map<Object?, Object?> program,
  DateTime weekMonday, {
  Map<String, double> references = const {},
  Map<String, double> workingMaxes = const {},
  Map<String, double> capRpeByLift = const {},
  List<StrengthRow> accessoryHistory = const [],
}) {
  final version = currentVersion(program);
  if (version == null) return const [];

  // Accounting week window (v7 week_start — saturday runs Sat–Fri so
  // the planner window matches the rollup/strip weeks). Normalised to
  // the week's start day.
  final wsDay = weekStartDayOf(version);
  final day0 = DateTime.utc(weekMonday.year, weekMonday.month, weekMonday.day);
  final weekStart =
      day0.subtract(Duration(days: (day0.weekday - wsDay) % 7));
  // Program STRUCTURE stays Monday-anchored: parity/alternation is
  // resolved at the Monday contained in the window (the one owning its
  // Mon–Fri) — identical to the week start for Monday-start weeks.
  final anchorMonday =
      weekStart.add(Duration(days: (DateTime.monday - weekStart.weekday) % 7));

  // a/b parity for this week. Defaults to 'a' when no anchor is declared.
  var parity = 'a';
  final alternation = version['planned_alternation'];
  if (alternation is Map && alternation['anchor_monday'] != null) {
    final anchor = _parseDay(alternation['anchor_monday']);
    final weeks = anchorMonday.difference(anchor).inDays ~/ 7;
    parity = weeks.isEven ? 'a' : 'b';
  }

  // Weight-fill config (v4). Missing/malformed → no weights ever filled.
  final weightFill = version['weight_fill'];
  final pctByReps = weightFill is Map && weightFill['pct_by_reps'] is Map
      ? weightFill['pct_by_reps'] as Map
      : const {};
  final fillRounding = weightFill is Map && weightFill['rounding_lb'] is num
      ? weightFill['rounding_lb'] as num
      : 5;

  // Warm-up config (v4). Missing/malformed → no warm-up rows.
  final warmup = version['warmup_protocol'];

  // v3: load policies for the working-max weight path (empty list when
  // the program predates v5 → wm path never fires).
  final policies = workingMaxes.isEmpty
      ? const <LoadPolicy>[]
      : loadPolicies(version);

  /// Working weight for one planned set, or null (never guessed).
  /// [policy] is the day's load policy — non-null only on the v3 path.
  /// [pct] (plan_v5) is an explicit fraction of the working max (%TM
  /// volume slots + cut-wave tops): priced wm × min(pct, chart[policy
  /// target after caps][reps]) — caps always undercut — and NEVER
  /// falls back to the reference path (a %TM row without a TM stays
  /// weightless).
  num? workingWeight(String exercise, num reps, LoadPolicy? policy,
      {num? pct}) {
    final lift = mainLiftByExercise[exercise];
    // v3: the working max is the weight authority when present.
    final wm = lift == null ? null : workingMaxes[lift];
    if (wm != null && (policy != null || pct != null)) {
      double? target;
      if (policy != null) {
        target = policy.targetRpeHigh;
        if (policy.capRpe != null && policy.capRpe! < target) {
          target = policy.capRpe!;
        }
      }
      final cap = capRpeByLift[lift];
      if (cap != null && (target == null || cap < target)) target = cap;
      if (pct != null) {
        var frac = pct.toDouble();
        if (target != null) {
          final capFrac = rpePct(target, reps.toInt());
          if (capFrac < frac) frac = capFrac;
        }
        return _roundTo(wm * frac, fillRounding);
      }
      return _roundTo(wm * rpePct(target!, reps.toInt()), fillRounding);
    }
    if (pct != null) return null; // %TM without a TM: never guess
    // v2 fallback: reference e1rm × pct_by_reps.
    final ref = lift == null ? null : references[lift];
    if (ref == null) return null;
    final p = pctByReps[reps] ?? pctByReps[reps.toInt()];
    if (p is! num) return null;
    return _roundTo(ref * p, fillRounding);
  }

  /// Warm-up rows for [exercise] on [day], ramping to [top] (the day's
  /// top working weight). Empty when no protocol applies. Ramp semantics
  /// live in [warmupRamp] (working_max.dart), shared with the §4
  /// prescription builder.
  List<Map<String, Object?>> warmupRows(
      DateTime day, String exercise, num top) {
    final steps = warmupRamp(warmup, mainLiftByExercise[exercise], top);
    return [
      for (final s in steps)
        {'date': day, 'exercise': exercise, 'reps': s.reps, 'weight': s.weight},
    ];
  }

  // Volume multipliers (program.yaml v10). Midpoint of a [lo, hi] band;
  // scalars pass through.
  double? midOf(Object? v) {
    if (v is num) return v.toDouble();
    if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
      return ((v[0] as num) + (v[1] as num)) / 2;
    }
    return null;
  }

  // Accessory double-progression config (program.yaml v12; defaults
  // when absent). Suggestions need history — empty history means no
  // accessory weights, exactly the pre-v12 behavior.
  final accessoryRule = AccessoryRule.fromVersion(version);

  final wave = version['strength_wave'];
  final entries = <Map<String, Object?>>[];
  for (var i = 0; i < 7; i++) {
    final day = weekStart.add(Duration(days: i));
    final block = _blockFor(version, day);
    if (block == null) continue; // outside every block: nothing to plan
    final blockN = block['n'];
    final blockNInt = blockN is num ? blockN.toInt() : null;
    // v12 routine merge (base week + phase_overrides), legacy
    // two-template fallback inside routineWeekFor.
    final template = routineWeekFor(version, blockNInt);
    if (template is! Map) continue;
    // Template lookup by the day's ACTUAL weekday (the window may not
    // start on Monday, but the template is keyed mon..sun).
    final dayMap = template[_weekdayKeys[day.weekday - 1]];
    if (dayMap is! Map) continue;
    Object? planned = dayMap['planned'];
    if (planned is Map) planned = planned[parity]; // alternation day
    if (planned is! List) continue;

    // The day's slice (week type + week-in-block) feeds both the load
    // policy and the strength wave.
    final slice = programCurrent(program, null, day);
    final weekType = slice?.weekType;
    final weekInBlock = slice?.weekInBlock ?? 0;

    // The day's load policy (v3 weight path). Week-type overrides
    // (light/test) come through programCurrent's resolution.
    LoadPolicy? dayPolicy;
    if (policies.isNotEmpty) {
      dayPolicy = policyForDate(
        policies,
        date: day,
        block: blockNInt,
        weekType: weekType,
      );
    }

    // Cut wave (v11, block 0): calendar-anchored top reps + pct.
    final cutWave = strengthWaveCutFor(version, blockN: blockNInt, day: day);

    // Non-top volume multipliers for this day (v10; all default 1.0 —
    // pre-v10 programs untouched). v11: the cut wave's deload week
    // halves non-top volume the same way.
    final waveApplies = wave is Map &&
        (wave['applies_to_blocks'] as List?)?.contains(blockNInt) == true;
    var nonTopMult = 1.0;
    if (waveApplies && (weekType == 'light' || weekType == 'test')) {
      nonTopMult *= midOf(wave['deload_volume_multiplier']) ?? 1.0;
    }
    if (cutWave?.deload == true) {
      final cw = version['strength_wave_cut'];
      nonTopMult *=
          midOf(cw is Map ? cw['deload_volume_multiplier'] : null) ?? 0.5;
    }
    if (block['emphasis']?.toString() == 'climbing') {
      final ev = version['emphasis_volume'];
      nonTopMult *=
          midOf(ev is Map ? ev['climbing_block_lifting_multiplier'] : null) ??
              1.0;
    }
    var accessoryRampMult = 1.0;
    final ramp = version['volume_ramp'];
    if (ramp is Map && ramp['anchor_monday'] != null) {
      final anchor = _parseDay(ramp['anchor_monday']);
      final dayMonday = day.subtract(Duration(days: day.weekday - 1));
      final rampWeek = dayMonday.difference(anchor).inDays ~/ 7 + 1;
      final byWeek = ramp['multipliers_by_week'];
      if (rampWeek >= 1 && byWeek is Map) {
        accessoryRampMult =
            midOf(byWeek['$rampWeek'] ?? byWeek[rampWeek]) ?? 1.0;
      }
    }

    // Pass 1: expand working sets (with weights where computable).
    final working = <Map<String, Object?>>[];
    for (final item in planned) {
      if (item is! Map) continue;
      final exercise = item['exercise'];
      final rawReps = item['reps'];
      final rawPct = item['pct'];
      num? reps;
      num? pct = rawPct is num ? rawPct : null;
      var isTop = false;
      if (rawReps is num) {
        reps = rawReps;
      } else if (rawReps?.toString() == 'top') {
        // Wave-prescribed top reps; no wave in force → skip, never
        // guess. Post-cut wave first (block-anchored), then the cut
        // wave (calendar-anchored; carries its own pricing pct).
        isTop = true;
        reps = strengthWaveTopReps(
          version,
          blockN: blockNInt,
          weekInBlock: weekInBlock,
          weekType: weekType,
        );
        if (reps == null && cutWave != null) {
          reps = cutWave.reps;
          pct = cutWave.pct;
        }
      }
      if (exercise is! String || exercise.isEmpty || reps == null) continue;
      final rawSets = item['sets'];
      var sets = rawSets is num && rawSets >= 1 ? rawSets.toInt() : 1;
      final isAccessory = mainLiftByExercise[exercise] == null;
      if (!isTop) {
        var m = nonTopMult;
        // The ramp eases ACCESSORIES only — main-lift back-offs follow
        // the wave/RPE targets, not the ramp.
        if (isAccessory) m *= accessoryRampMult;
        if (m != 1.0) sets = max(1, (sets * m).round());
      }
      var weight = workingWeight(exercise, reps, dayPolicy, pct: pct);
      // Accessory double progression (v12): suggest the next load from
      // the last logged comparable session — +step when every set hit
      // the top of the range (`reps_hi`) at <= 2 RIR, −5% after an
      // avg-RPE>9 session, else hold. No history / bodyweight work →
      // no weight (never guessed).
      if (weight == null && isAccessory && pct == null) {
        final repsHi = item['reps_hi'];
        weight = suggestAccessoryLoad(
          exercise: exercise,
          history: accessoryHistory,
          asOf: day,
          repRangeHigh: repsHi is num ? repsHi.toInt() : null,
          rule: accessoryRule,
        )?.weightLb;
      }
      for (var s = 0; s < sets; s++) {
        // ONLY exercise + reps + optional weight (+ date). Never
        // rpe/notes — those describe what happened, and nothing has
        // happened yet. Weight is filled only from a real reference.
        working.add({
          'date': day,
          'exercise': exercise,
          'reps': reps,
          'weight': ?weight,
          if (isTop) 'top': true,
        });
      }
    }

    // Pass 2: splice each exercise's warm-up ramp before its first
    // working set. Top = the exercise's heaviest filled working weight
    // this day; exercises with no filled weight get no warm-ups (we
    // can't ramp toward an unknown top).
    final tops = <String, num>{};
    for (final w in working) {
      final weight = w['weight'];
      if (weight is! num) continue;
      final ex = w['exercise'] as String;
      if (tops[ex] == null || weight > tops[ex]!) tops[ex] = weight;
    }
    final warmedUp = <String>{};
    for (final w in working) {
      final ex = w['exercise'] as String;
      final top = tops[ex];
      // Warm-up ramps are a MAIN-LIFT protocol (bar work, plate math);
      // accessories with double-progression weights never get one.
      if (top != null &&
          mainLiftByExercise[ex] != null &&
          warmedUp.add(ex)) {
        entries.addAll(warmupRows(day, ex, top));
      }
      entries.add(w);
    }
  }
  return entries;
}

/// Thin runner around [buildWeekPlannedEntries]. Call fire-and-forget from
/// the home-screen bootstrap after SyncScheduler.init; never throws.
class WeekPlanner {
  /// Ledger meta key holding the generation stamp of the last week we
  /// generated: `<yyyy-MM-dd monday>|plan_v2`. Matching stamp = this week
  /// is done, do nothing (so logged or user-deleted rows are never touched
  /// or re-created). A mismatched stamp for the same Monday (e.g. the
  /// pre-weight `plan_v1` bare-monday value) triggers [regenerateWeek].
  static const metaGeneratedKey = 'week_planner_generated_monday';

  /// Planner generation suffix in the meta stamp. Bump when the generated
  /// row shape changes and existing weeks should be upgraded in place
  /// (v3: working-max weight math replaced the reference-e1rm fill;
  /// v4: strength-wave top reps + planned accessories + volume
  /// multipliers, program.yaml v10; v5: cut wave `strength_wave_cut` +
  /// %TM `pct` rows + cut deload halving, program.yaml v11; v6: v12
  /// routine merge + accessory double-progression weights).
  static const planVersion = 'plan_v6';

  /// Ledger meta key the runner writes the last swallowed error into.
  static const metaErrorKey = 'week_planner_error';

  /// Timeline group header for generated rows (same mechanism as template
  /// / coach-proposal grouping: PlannedEntry.templateName).
  static const templateLabel = 'program: week plan';

  /// Replaces the target week's remaining (still-planned) week-plan rows
  /// with freshly generated ones, today-forward. Returns the entries it
  /// added (already written to PlanStore).
  ///
  /// "Remaining" = entries still in PlanStore with our [templateLabel] and
  /// a date inside the target week. Rows the user already logged were
  /// removed from PlanStore at log time and live in the ledger — they are
  /// never touched or re-created for past days (past = before [today]).
  /// Planned entries from other templates/weeks are left alone.
  ///
  /// Split out from [ensureCurrentWeek] (which adds the meta stamping and
  /// error swallowing) so the replace semantics are unit-testable without
  /// an FFI-backed ledger repo.
  static Future<List<PlannedEntry>> regenerateWeek({
    required ViewSchema strengthView,
    required Map<Object?, Object?> program,
    required Map<String, double> references,
    required DateTime targetMonday,
    required DateTime today,
    Map<String, double> workingMaxes = const {},
    Map<String, double> capRpeByLift = const {},
    List<StrengthRow> accessoryHistory = const [],
  }) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final monday = DateTime.utc(
      targetMonday.year,
      targetMonday.month,
      targetMonday.day,
    );
    final weekDays = {
      for (var i = 0; i < 7; i++) fmt.format(monday.add(Duration(days: i))),
    };
    await PlanStore.removeWhere(
      strengthView,
      (e) =>
          e.templateName == templateLabel &&
          weekDays.contains(fmt.format(e.date)),
    );

    final todayDay = DateTime.utc(today.year, today.month, today.day);
    final entries = <PlannedEntry>[];
    final built = buildWeekPlannedEntries(
      program,
      monday,
      references: references,
      workingMaxes: workingMaxes,
      capRpeByLift: capRpeByLift,
      accessoryHistory: accessoryHistory,
    );
    for (final e in built) {
      final date = e['date'] as DateTime;
      if (date.isBefore(todayDay)) continue; // today-forward only
      entries.add(PlannedEntry.create(
        view: strengthView,
        date: DateTime(date.year, date.month, date.day),
        values: {
          'exercise': e['exercise'],
          'reps': e['reps'],
          'weight': ?e['weight'],
        },
        templateName: templateLabel,
      ));
    }
    if (entries.isNotEmpty) {
      await PlanStore.addAll(strengthView, entries);
    }
    return entries;
  }

  /// Ensures the current week's planned rows exist (once per week per
  /// [planVersion]).
  ///
  /// Week selection follows [defaultWeekStart]: the Monday of this ISO
  /// week — except on Sundays, when it targets the UPCOMING week (the
  /// app-wide "on Sunday you plan next week" convention).
  ///
  /// Working maxes come from [wmSnapshotOf] (the app passes
  /// `WmStore.snapshot` — a direct read of the append-only tabs); a null/
  /// failed snapshot silently falls back to the reference-e1rm path, so
  /// the planner still fills weights before the tabs exist. Per-lift
  /// references come from the local strength history read through
  /// [connector] (the same list path every screen uses); a failed
  /// read aborts the run (error meta, retried next launch) rather than
  /// generating a weightless week. First run mid-week only adds entries
  /// dated today or later — no backfilling of already-past days. A stamp
  /// mismatch for an already-generated week (planner upgrade, e.g.
  /// plan_v2 → plan_v3) replaces only the week's still-planned rows via
  /// [regenerateWeek]. Skips silently (without stamping) when
  /// program.yaml is missing or unparseable. Any error is swallowed into
  /// the [metaErrorKey] meta.
  static Future<void> ensureCurrentWeek({
    required EngineLedgerRepository repo,
    required WarehouseConnector connector,
    required ProgramProvider provider,
    required ViewSchema strengthView,
    Future<WmSnapshot?> Function()? wmSnapshotOf,
    DateTime Function() now = DateTime.now,
  }) async {
    try {
      final today = now();
      // Program first: the target week's START depends on the program's
      // week_start (v7 — saturday windows run Sat–Fri). The 1 h doc
      // cache makes the always-load cheap.
      final docs = await provider.load();
      final program = docs.program;
      if (program == null) return; // no/bad program.yaml: retry next launch
      final targetMonday = defaultWeekStart(
        today,
        weekStartDay: weekStartDayOf(currentVersion(program)),
      );
      final mondayStr = DateFormat('yyyy-MM-dd').format(targetMonday);
      final stamp = '$mondayStr|$planVersion';
      if (await repo.metaGet(metaGeneratedKey) == stamp) return;

      final rows = await connector.list(strengthView);
      final history = [for (final r in rows) ?_strengthRow(r)];
      final references = liftReferencesAsOf(history, today);

      // v3 inputs — best-effort: any failure leaves both maps empty and
      // the reference fallback carries the week.
      var workingMaxes = const <String, double>{};
      var capRpeByLift = const <String, double>{};
      if (wmSnapshotOf != null) {
        try {
          final snap = await wmSnapshotOf();
          if (snap != null) {
            workingMaxes = currentWorkingMaxesByLift(snap.workingMax);
            final version = currentVersion(program);
            final policies =
                version == null ? const <LoadPolicy>[] : loadPolicies(version);
            capRpeByLift = activeCapsByLift(
              snap,
              (d) => policies.isEmpty
                  ? null
                  : policyForDate(
                      policies,
                      date: d,
                      block: programCurrent(program, null, d)
                          ?.block['number'] as int?,
                      weekType: programCurrent(program, null, d)?.weekType,
                    ),
            );
          }
        } catch (_) {
          // Tabs unreadable — reference fallback.
        }
      }

      await regenerateWeek(
        strengthView: strengthView,
        program: program,
        references: references,
        targetMonday: targetMonday,
        today: today,
        workingMaxes: workingMaxes,
        capRpeByLift: capRpeByLift,
        accessoryHistory: history,
      );
      // Mark the week done even when empty (e.g. pre-program week) so we
      // don't re-evaluate on every launch.
      await repo.metaSet(metaGeneratedKey, stamp);
    } catch (e) {
      try {
        await repo.metaSet(metaErrorKey, e.toString());
      } catch (_) {
        // Meta write failed too — nothing left to do; stay silent.
      }
    }
  }

  /// Maps a ledger strength [Record] into a [StrengthRow] for reference
  /// math. Null when the row lacks a parseable date/exercise/weight/reps
  /// (isometric holds etc. — they never qualify anyway).
  static StrengthRow? _strengthRow(Record r) {
    final rawDate = r['date'];
    final date = rawDate is DateTime
        ? rawDate
        : DateTime.tryParse(rawDate?.toString() ?? '');
    final exercise = r['exercise']?.toString();
    final weight = _num(r['weight']);
    final reps = _num(r['reps']);
    if (date == null || exercise == null || exercise.isEmpty) return null;
    if (weight == null || reps == null) return null;
    final rpe = _num(r['rpe']);
    return StrengthRow(
      date: date,
      exercise: exercise,
      weight: weight.toDouble(),
      reps: reps.round(),
      rpe: rpe?.toDouble(),
    );
  }

  static num? _num(Object? v) =>
      v is num ? v : num.tryParse(v?.toString() ?? '');
}
