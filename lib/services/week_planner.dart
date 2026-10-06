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
///  - [WeekPlanner.ensureCurrentWeek]: thin runner — keeps the ROLLING
///    next 7 days (today-forward) of planner-owned PlanStore rows equal
///    to what the Program screen shows, via per-day content signatures
///    ([planDaySignature], meta `week_planner_day_signatures`): a day is
///    rewritten only when what the program prescribes for it changed
///    (program version, TMs/caps, references, accessory progression,
///    planner version) — otherwise user deletions/logs stand. Writes
///    through the same PlanStore path coach proposals use; only rows
///    tagged [WeekPlanner.templateLabel] are ever touched.
library;

import 'dart:convert' show jsonDecode, jsonEncode, utf8;
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
import 'program_moves.dart' show ProgramMove;
import 'program_provider.dart';
import 'program_week.dart' show dayOnly;
import 'resolved_week.dart';
import 'effective_plan.dart' show effectivePricedWeek;
import 'app_settings.dart' show effectiveWeekStartDay;
import 'week_start.dart' show weekStartOf;
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';
import 'wm_tabs.dart'
    show WmSnapshot, activeCapsByLift, currentWorkingMaxesByLift;
import 'working_sets.dart' show warmupIndices;
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
/// weight, top, reps_hi, pct, warmup} — never rpe or notes:
///   - `date`     — UTC-midnight [DateTime] of the entry's weekday
///   - `exercise` — the exact logged exercise name (metrics depend on it)
///   - `reps`     — planned reps for that one set
///   - `weight`   — only when computable; never guessed
///   - `top`      — true on wave top-set rows (`reps: top` in the
///     program); consumers ignore it when persisting.
///   - `reps_hi`  — DISPLAY marker: top of the planned rep range
///     (accessory double-progression rows); never persisted.
///   - `pct`      — DISPLAY marker: the declared fraction of the
///     working max the row was priced at (cut-wave tops + %TM volume
///     slots); never persisted.
///   - `warmup`   — DISPLAY marker: true on warm-up ramp rows so the
///     routine screen can list working sets only; never persisted.
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
///
/// Window ([snapToWeekStart], 2026-09-28 Saturday-regression fix): by
/// default the 7-day window is snapped BACK to the program's accounting
/// week start (v7 `week_start: saturday` → Sat–Fri, matching the
/// PlanStore/rollup windows). Callers that display a fixed Mon–Sun week
/// (the Program routine screen) pass `snapToWeekStart: false` to plan
/// exactly [weekMonday]..+6 — otherwise the displayed Saturday falls
/// OUTSIDE the snapped Sat–Fri window and renders as a rest day. Every
/// day's content is resolved from the day itself (template weekday,
/// block, wave), so the two windows agree on their overlap.
List<Map<String, Object?>> buildWeekPlannedEntries(
  Map<Object?, Object?> program,
  DateTime weekMonday, {
  Map<String, double> references = const {},
  Map<String, double> workingMaxes = const {},
  Map<String, double> capRpeByLift = const {},
  List<StrengthRow> accessoryHistory = const [],
  bool snapToWeekStart = true,
  int? weekStartDay,
}) {
  final version = currentVersion(program);
  if (version == null) return const [];

  // Accounting week window (snap mode only): [weekStartDay] — the
  // resolved week start (week_start.dart) — else the program's
  // `week_start` default. Normalised to the week's start day.
  final wsDay = weekStartDay ?? weekStartDayOf(version);
  final day0 = DateTime.utc(weekMonday.year, weekMonday.month, weekMonday.day);
  final weekStart = snapToWeekStart
      ? day0.subtract(Duration(days: (day0.weekday - wsDay) % 7))
      : day0;
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
        {
          'date': day,
          'exercise': exercise,
          'reps': s.reps,
          'weight': s.weight,
          'warmup': true,
        },
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
      final repsHi = item['reps_hi'];
      for (var s = 0; s < sets; s++) {
        // ONLY exercise + reps + optional weight (+ date) get
        // persisted. Never rpe/notes — those describe what happened,
        // and nothing has happened yet. Weight is filled only from a
        // real reference. top/reps_hi/pct are display markers for the
        // routine screen (plannedValuesOf drops them).
        working.add({
          'date': day,
          'exercise': exercise,
          'reps': reps,
          'weight': ?weight,
          if (isTop) 'top': true,
          if (repsHi is num && repsHi != reps) 'reps_hi': repsHi,
          'pct': ?pct,
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

/// The persisted values for one [buildWeekPlannedEntries] entry: ONLY
/// exercise + reps + (when computable) weight — never rpe/notes — plus
/// `set_type: warmup` on warm-up ramp rows, so logging a planned ramp
/// row records it as a warm-up (and the timeline renders it muted).
/// Display markers (top/reps_hi/pct/warmup) are dropped.
Map<String, Object?> plannedValuesOf(Map<String, Object?> e) => {
      'exercise': e['exercise'],
      'reps': e['reps'],
      'weight': ?e['weight'],
      if (e['warmup'] == true) 'set_type': 'warmup',
    };

/// Stable content signature of one day's built entries (FNV-1a 32 over
/// the persisted shape + [WeekPlanner.planVersion]). Equal signatures ⇒
/// the program prescribes the same rows for that day, so the planner
/// leaves the day's PlanStore rows (and the user's deletions) alone.
///
/// [moveKeys] (plan_v9): the day's program_moves fingerprint —
/// [dayMoveKeys] — so a new move or skip touching the day rewrites it
/// even when the priced rows happen not to change (a skipped climb).
String planDaySignature(List<Map<String, Object?>> dayEntries,
    {String moveKeys = ''}) {
  final b = StringBuffer(WeekPlanner.planVersion);
  if (moveKeys.isNotEmpty) b.write('\n#moves $moveKeys');
  for (final e in dayEntries) {
    final v = plannedValuesOf(e);
    b.write('\n${v['exercise']}|${v['reps']}|${v['weight'] ?? ''}|'
        '${v['set_type'] ?? ''}');
  }
  var h = 0x811c9dc5;
  for (final byte in utf8.encode(b.toString())) {
    h ^= byte;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// Stable fingerprint of every active move / skip touching [day] (moved
/// in, moved out, or skipped there) — folded into [planDaySignature].
String dayMoveKeys(
  DateTime day,
  Map<String, ProgramMove> moves,
  Map<String, ProgramMove> skips,
) {
  final d = dayOnly(day);
  final keys = <String>[
    for (final m in moves.values)
      if (dayOnly(m.from) == d || dayOnly(m.to) == d)
        'm:${m.key}>${m.to.year}-${m.to.month}-${m.to.day}',
    for (final e in skips.entries)
      if (dayOnly(e.value.to) == d) 's:${e.key}',
  ]..sort();
  return keys.join(',');
}

/// [built] (one day's entries) minus the sets already LOGGED that day,
/// so regenerating a partly-trained day never re-plans done work. Each
/// logged set consumes the first still-unconsumed built row of the same
/// exercise (case-insensitive) and the same kind — warm-up vs working,
/// per the shared working_sets rule ([warmupIndices]: set_type warmup or
/// an untagged ramp set). Extra logged sets beyond the plan consume
/// nothing further.
List<Map<String, Object?>> remainingAfterLogged(
  List<Map<String, Object?>> built,
  List<Map<String, Object?>> loggedThatDay,
) {
  final warm = warmupIndices(loggedThatDay);
  final budget = <String, int>{};
  String key(Object? exercise, bool warmup) =>
      '${exercise?.toString().trim().toLowerCase() ?? ''}|$warmup';
  for (var i = 0; i < loggedThatDay.length; i++) {
    final k = key(loggedThatDay[i]['exercise'], warm.contains(i));
    budget[k] = (budget[k] ?? 0) + 1;
  }
  final out = <Map<String, Object?>>[];
  for (final e in built) {
    final k = key(e['exercise'], e['warmup'] == true);
    final left = budget[k] ?? 0;
    if (left > 0) {
      budget[k] = left - 1;
      continue;
    }
    out.add(e);
  }
  return out;
}

/// Thin runner around [buildWeekPlannedEntries]. Call fire-and-forget from
/// the home-screen bootstrap after SyncScheduler.init; never throws.
class WeekPlanner {
  /// Ledger meta key holding the per-day content signatures of the last
  /// sync: JSON `{yyyy-MM-dd: signature}` over the rolling window. A day
  /// whose freshly built signature matches is left untouched (so logged
  /// or user-deleted rows are never re-created); a mismatch (or no
  /// stored signature) rewrites that day's planner-owned rows.
  static const metaDaySignaturesKey = 'week_planner_day_signatures';

  /// Planner generation tag, folded into every day signature — bumping
  /// it rewrites the whole window once (v3: working-max weight math;
  /// v4: strength-wave tops + accessories + volume multipliers; v5: cut
  /// wave + %TM rows; v6: v12 routine merge + accessory double
  /// progression; v7: v13 two-loop TM; v8: rolling Mon–Sun-priced
  /// window, per-day signatures, warm-up rows stamped set_type warmup;
  /// v9: program_moves applied — moved work planned on its target day,
  /// moved-out + skipped work not planned, moves/skips fingerprinted).
  /// v10 (2026-10-03): the CONFIGURED week (week_start.dart — Sat–Fri for
  /// the user) instead of hard-coded Mon–Sun; moves may pull next week's
  /// items forward (resolved_week.dart).
  static const planVersion = 'plan_v10';

  /// Ledger meta key the runner writes the last swallowed error into.
  static const metaErrorKey = 'week_planner_error';

  /// Timeline group header for generated rows (same mechanism as template
  /// / coach-proposal grouping: PlannedEntry.templateName).
  static const templateLabel = 'program: week plan';

  /// How many days (today-forward) the planner keeps in sync.
  static const horizonDays = 7;

  /// Brings the planner-owned PlanStore rows for [today] .. today +
  /// [horizon] − 1 in line with the CURRENT program, and returns the new
  /// per-day signature map to persist (window days only — older days
  /// drop out).
  ///
  /// Each day is priced exactly as the Program screen prices it:
  /// [buildWeekPlannedEntries] over the day's own [weekStartDay] week with
  /// `snapToWeekStart: false` (the accounting-week snap is what used to
  /// leave the displayed Saturday/Sunday unplanned). A day is rewritten
  /// only when its [planDaySignature] differs from [storedSignatures]:
  /// its rows tagged [templateLabel] are removed and replaced by the
  /// built rows minus the sets already logged that day
  /// ([remainingAfterLogged] over [loggedRows]). Coach proposals, user
  /// entries (any other templateName) and days outside the window are
  /// never touched.
  ///
  /// Moves (plan_v9; pull-forward plan_v10): [moves] = every
  /// `program_moves` row (moves AND skips). Each week is resolved by
  /// [resolveProgramWeek] + [effectivePricedWeek] (the Program screen's
  /// exact transform — moved items keep their
  /// home-day pricing and bring their warm-up ramps), and each day's
  /// signature folds in [dayMoveKeys]. [phase] feeds the prose
  /// prescription the moves key on (`prescribedWeek`).
  static Future<Map<String, String>> syncPlannedDays({
    required ViewSchema strengthView,
    required Map<Object?, Object?> program,
    required DateTime today,
    Map<Object?, Object?>? phase,
    List<ProgramMove> moves = const [],
    Map<String, String> storedSignatures = const {},
    List<Map<String, Object?>> loggedRows = const [],
    Map<String, double> references = const {},
    Map<String, double> workingMaxes = const {},
    Map<String, double> capRpeByLift = const {},
    List<StrengthRow> accessoryHistory = const [],
    int horizon = horizonDays,
    int weekStartDay = DateTime.monday,
  }) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final day0 = DateTime.utc(today.year, today.month, today.day);
    final days = [
      for (var i = 0; i < horizon; i++) day0.add(Duration(days: i)),
    ];

    // Price each configured week touching the window once.
    final byDay = <String, List<Map<String, Object?>>>{
      for (final d in days) fmt.format(d): <Map<String, Object?>>[],
    };
    final starts = {for (final d in days) weekStartOf(d, weekStartDay)};
    final moveKeysByDay = <String, String>{};
    final warmupProtocol = currentVersion(program)?['warmup_protocol'];
    for (final start in starts) {
      final rw = resolveProgramWeek(
        (program: program, phase: phase, strategy: null),
        start,
        moves,
        weekStartDay: weekStartDay,
      );
      final built = effectivePricedWeek(
        rw,
        (s) => buildWeekPlannedEntries(
          program,
          s,
          references: references,
          workingMaxes: workingMaxes,
          capRpeByLift: capRpeByLift,
          accessoryHistory: accessoryHistory,
          snapToWeekStart: false,
        ),
        warmupProtocol: warmupProtocol,
      );
      if (rw.moves.isNotEmpty || rw.skips.isNotEmpty) {
        for (final d in rw.days) {
          moveKeysByDay[fmt.format(d)] = dayMoveKeys(d, rw.moves, rw.skips);
        }
      }
      for (final e in built) {
        byDay[fmt.format(e['date'] as DateTime)]?.add(e);
      }
    }

    // Logged sets per window day (for remainingAfterLogged).
    final loggedByDay = <String, List<Map<String, Object?>>>{};
    for (final r in loggedRows) {
      final raw = r['date'];
      final d = raw is DateTime
          ? raw
          : DateTime.tryParse(raw?.toString() ?? '');
      if (d == null) continue;
      final k = fmt.format(d);
      if (byDay.containsKey(k)) (loggedByDay[k] ??= []).add(r);
    }

    final signatures = <String, String>{};
    final rewrite = <String>{};
    final added = <PlannedEntry>[];
    for (final d in days) {
      final k = fmt.format(d);
      final sig =
          planDaySignature(byDay[k]!, moveKeys: moveKeysByDay[k] ?? '');
      // MID-SESSION FREEZE (2026-10-05): a day the planner already wrote
      // (stored signature) that has a logged set is a session in
      // progress — never rewrite it. A reprice mid-workout (app resume
      // after the camera/video picker; today's own sets feeding the
      // accessory progression / references) used to swap every planned
      // row for fresh localIds under the open Log screen, so the next
      // stale chip tap logged a set whose twin stayed planned
      // (duplicates). The stored signature carries forward; program
      // changes reach the day again only if its logged sets go away.
      final stored = storedSignatures[k];
      if (stored != null && (loggedByDay[k]?.isNotEmpty ?? false)) {
        signatures[k] = stored;
        continue;
      }
      signatures[k] = sig;
      if (stored == sig) continue;
      rewrite.add(k);
      for (final e in remainingAfterLogged(
          byDay[k]!, loggedByDay[k] ?? const [])) {
        added.add(PlannedEntry.create(
          view: strengthView,
          date: DateTime(d.year, d.month, d.day),
          values: plannedValuesOf(e),
          templateName: templateLabel,
        ));
      }
    }
    if (rewrite.isNotEmpty) {
      await PlanStore.removeWhere(
        strengthView,
        (e) =>
            e.templateName == templateLabel &&
            rewrite.contains(fmt.format(e.date)),
      );
      if (added.isNotEmpty) await PlanStore.addAll(strengthView, added);
    }
    return signatures;
  }

  /// Converts one program-built entry map (from [buildWeekPlannedEntries])
  /// into a persistable [PlannedEntry] on [date] ([plannedValuesOf]:
  /// exercise / reps / weight, plus set_type warmup on ramp rows —
  /// warm-ups are part of the session, so they're planned too).
  static PlannedEntry _plannedFrom(
    ViewSchema view,
    Map<String, Object?> e,
    DateTime date,
  ) =>
      PlannedEntry.create(
        view: view,
        date: DateTime(date.year, date.month, date.day),
        values: plannedValuesOf(e),
        templateName: templateLabel,
      );

  /// Manual "Schedule this week" (Program screen): writes the whole
  /// displayed [weekStart] week's planned strength rows into
  /// PlanStore, replacing any still-planned program rows already in that
  /// window (same replace semantics as [syncPlannedDays] but user-invoked,
  /// with NO today-forward cutoff — a user scheduling a week wants every
  /// day, including earlier ones). Returns the entries it added.
  ///
  /// The week is priced for EXACTLY the displayed seven days
  /// (`snapToWeekStart: false`), matching the routine screen's window.
  static Future<List<PlannedEntry>> scheduleWeek({
    required ViewSchema strengthView,
    required Map<Object?, Object?> program,
    required DateTime weekStart,
    Map<String, double> references = const {},
    Map<String, double> workingMaxes = const {},
    Map<String, double> capRpeByLift = const {},
    List<StrengthRow> accessoryHistory = const [],
  }) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final start = DateTime.utc(weekStart.year, weekStart.month, weekStart.day);
    final weekDays = {
      for (var i = 0; i < 7; i++) fmt.format(start.add(Duration(days: i))),
    };
    await PlanStore.removeWhere(
      strengthView,
      (e) =>
          e.templateName == templateLabel &&
          weekDays.contains(fmt.format(e.date)),
    );
    final built = buildWeekPlannedEntries(
      program,
      start,
      references: references,
      workingMaxes: workingMaxes,
      capRpeByLift: capRpeByLift,
      accessoryHistory: accessoryHistory,
      snapToWeekStart: false,
    );
    final entries = <PlannedEntry>[
      for (final e in built)
        _plannedFrom(strengthView, e, e['date'] as DateTime),
    ];
    if (entries.isNotEmpty) await PlanStore.addAll(strengthView, entries);
    return entries;
  }

  /// Manual "Add to log" for ONE day (Program screen day card): takes the
  /// program's session for [sourceDay] and writes it into PlanStore dated
  /// [targetDay] (default: [sourceDay] itself). Existing still-planned
  /// program rows on [targetDay] are replaced. Returns the entries added
  /// (empty when the source day is a rest day — nothing to schedule).
  static Future<List<PlannedEntry>> scheduleDay({
    required ViewSchema strengthView,
    required Map<Object?, Object?> program,
    required DateTime sourceDay,
    required DateTime targetDay,
    Map<String, double> references = const {},
    Map<String, double> workingMaxes = const {},
    Map<String, double> capRpeByLift = const {},
    List<StrengthRow> accessoryHistory = const [],
  }) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final src = DateTime.utc(sourceDay.year, sourceDay.month, sourceDay.day);
    // Price the source day in its own ISO (Mon-anchored) window, then
    // pick just it — every day resolves from itself, so any window works.
    final srcMonday = src.subtract(Duration(days: src.weekday - 1));
    final built = buildWeekPlannedEntries(
      program,
      srcMonday,
      references: references,
      workingMaxes: workingMaxes,
      capRpeByLift: capRpeByLift,
      accessoryHistory: accessoryHistory,
      snapToWeekStart: false,
    ).where((e) => e['date'] == src).toList();

    final target =
        DateTime.utc(targetDay.year, targetDay.month, targetDay.day);
    await PlanStore.removeWhere(
      strengthView,
      (e) =>
          e.templateName == templateLabel &&
          fmt.format(e.date) == fmt.format(target),
    );
    final entries = <PlannedEntry>[
      for (final e in built) _plannedFrom(strengthView, e, target),
    ];
    if (entries.isNotEmpty) await PlanStore.addAll(strengthView, entries);
    return entries;
  }

  /// Keeps the rolling next [horizonDays] of planner-owned PlanStore rows
  /// in sync with the CURRENT program ([syncPlannedDays]). Runs on every
  /// home bootstrap/reload (fire-and-forget); cheap and idempotent — an
  /// unchanged day's signature means no writes. Concurrent calls share
  /// one in-flight run (two overlapping runs would double-add rows).
  ///
  /// Root cause this replaces (2026-10-02): the old runner stamped
  /// `<week start>|plan_vN` once per ACCOUNTING week (Sat–Fri) and never
  /// looked again, so program.yaml edits (v14/v15 Thursday work), TM
  /// recomputes and accessory progressions after the week's first launch
  /// never reached the timeline — and the snapped Sat–Fri window left the
  /// Program screen's Saturday/Sunday unplanned until the next week.
  ///
  /// Working maxes come from [wmSnapshotOf] (the app passes
  /// `WmStore.snapshot`). When it's given but yields nothing (offline
  /// before the first successful read) the run is SKIPPED — pricing
  /// without TMs would rewrite every main-lift day weightless and then
  /// back again. Per-lift references + accessory history + the day's
  /// logged sets come from the local strength rows via [connector].
  /// Skips silently when program.yaml is missing or unparseable. Any
  /// error is swallowed into the [metaErrorKey] meta.
  static Future<void> ensureCurrentWeek({
    required EngineLedgerRepository repo,
    required WarehouseConnector connector,
    required ProgramProvider provider,
    required ViewSchema strengthView,
    ViewSchema? programMovesView,
    Future<WmSnapshot?> Function()? wmSnapshotOf,
    DateTime Function() now = DateTime.now,
  }) {
    final running = _inFlight;
    if (running != null) {
      // A run is already in flight but may have read the moves BEFORE
      // the change that triggered this call: queue exactly one re-run.
      return _rerun ??= running.then((_) {
        _rerun = null;
        return ensureCurrentWeek(
          repo: repo,
          connector: connector,
          provider: provider,
          strengthView: strengthView,
          programMovesView: programMovesView,
          wmSnapshotOf: wmSnapshotOf,
          now: now,
        );
      });
    }
    final run = _ensure(
      repo: repo,
      connector: connector,
      provider: provider,
      strengthView: strengthView,
      programMovesView: programMovesView,
      wmSnapshotOf: wmSnapshotOf,
      now: now,
    ).whenComplete(() => _inFlight = null);
    return _inFlight = run;
  }

  static Future<void>? _inFlight;
  static Future<void>? _rerun;

  static Future<void> _ensure({
    required EngineLedgerRepository repo,
    required WarehouseConnector connector,
    required ProgramProvider provider,
    required ViewSchema strengthView,
    ViewSchema? programMovesView,
    Future<WmSnapshot?> Function()? wmSnapshotOf,
    required DateTime Function() now,
  }) async {
    try {
      final today = now();
      final docs = await provider.load();
      final program = docs.program;
      if (program == null) return; // no/bad program.yaml: retry next run

      final rows = await connector.list(strengthView);
      final history = [for (final r in rows) ?_strengthRow(r)];
      final references = liftReferencesAsOf(history, today);

      var workingMaxes = const <String, double>{};
      var capRpeByLift = const <String, double>{};
      if (wmSnapshotOf != null) {
        WmSnapshot? snap;
        try {
          snap = await wmSnapshotOf();
        } catch (_) {
          snap = null;
        }
        if (snap == null) return; // TMs unreadable: keep the current plan
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

      // program_moves (moves + skips). A failed read = an unmoved week
      // (WeekStateLoader's degrade-honestly rule).
      var moves = const <ProgramMove>[];
      if (programMovesView != null) {
        try {
          moves = [
            for (final r in await connector.list(programMovesView))
              ?ProgramMove.fromRecord(r),
          ];
        } catch (_) {}
      }

      final stored = decodeDaySignatures(
          await repo.metaGet(metaDaySignaturesKey));
      final signatures = await syncPlannedDays(
        strengthView: strengthView,
        program: program,
        phase: docs.phase,
        moves: moves,
        today: today,
        storedSignatures: stored,
        loggedRows: rows,
        references: references,
        workingMaxes: workingMaxes,
        capRpeByLift: capRpeByLift,
        accessoryHistory: history,
        // THE week start (synced setting > program default > Monday).
        weekStartDay: effectiveWeekStartDay(program),
      );
      await repo.metaSet(metaDaySignaturesKey, jsonEncode(signatures));
    } catch (e) {
      try {
        await repo.metaSet(metaErrorKey, e.toString());
      } catch (_) {
        // Meta write failed too — nothing left to do; stay silent.
      }
    }
  }

  /// Parses the [metaDaySignaturesKey] JSON; anything malformed → empty
  /// (= rewrite the window once).
  static Map<String, String> decodeDaySignatures(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return const {};
      return {
        for (final e in m.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };
    } catch (_) {
      return const {};
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
    // notes carry variant keywords (paused / beltless …) the reference
    // math reads — the Program screen passes them, so must we, or the
    // two price the same day differently.
    return StrengthRow(
      date: date,
      exercise: exercise,
      weight: weight.toDouble(),
      reps: reps.round(),
      rpe: rpe?.toDouble(),
      notes: r['notes']?.toString(),
    );
  }

  static num? _num(Object? v) =>
      v is num ? v : num.tryParse(v?.toString() ?? '');
}
