/// Pure formatting for the Program (routine) screen — 2026-09-28
/// restructure per user feedback ("too unstructured … don't want
/// freeform text"). No prose paragraphs, no jargon: each day renders
/// ONE summary line plus a bare list of exercise rows with load and
/// %-of-training-max; the header states the week in plain words
/// ("Week 2 of 4 · top set 4 reps @ 84%" — never "wave").
///
/// Zero Flutter imports; every helper here is unit-tested in
/// test/routine_display_test.dart.
library;

import 'package:intl/intl.dart';

import 'bodyweight_cache.dart' show isBodyweightExercise;
import 'program_current.dart' show CutWaveWeekSpec;
import 'program_metrics.dart' show mainLiftByExercise;
import 'wm_tabs.dart' show WorkingMaxRow;

/// One display row: [sets] identical planned sets of an exercise.
/// [repsHi] is the top of a rep range (accessory double progression);
/// [pct] is the DECLARED fraction of the training max the planner
/// priced the row at (cut-wave tops + %TM volume slots).
class SessionLine {
  final String exercise;
  final int sets;
  final num reps;
  final num? repsHi;
  final num? weight;
  final num? pct;
  final bool top;

  const SessionLine({
    required this.exercise,
    required this.sets,
    required this.reps,
    this.repsHi,
    this.weight,
    this.pct,
    this.top = false,
  });
}

/// Groups the planner's one-row-per-set output into per-day display
/// lines: warm-up rows are dropped (the routine list is working sets
/// only), consecutive identical (exercise, reps, repsHi, weight, pct,
/// top) rows merge into one `N×reps` line.
Map<DateTime, List<SessionLine>> sessionLinesByDay(
  List<Map<String, Object?>> entries,
) {
  final out = <DateTime, List<SessionLine>>{};
  for (final e in entries) {
    if (e['warmup'] == true) continue;
    final date = e['date'] as DateTime;
    final exercise = e['exercise'] as String;
    final reps = e['reps'] as num;
    final repsHi = e['reps_hi'] as num?;
    final weight = e['weight'] as num?;
    final pct = e['pct'] as num?;
    final top = e['top'] == true;
    final lines = out[date] ??= [];
    final last = lines.isEmpty ? null : lines.last;
    if (last != null &&
        last.exercise == exercise &&
        last.reps == reps &&
        last.repsHi == repsHi &&
        last.weight == weight &&
        last.pct == pct &&
        last.top == top) {
      lines[lines.length - 1] = SessionLine(
        exercise: exercise,
        sets: last.sets + 1,
        reps: reps,
        repsHi: repsHi,
        weight: weight,
        pct: pct,
        top: top,
      );
    } else {
      lines.add(SessionLine(
        exercise: exercise,
        sets: 1,
        reps: reps,
        repsHi: repsHi,
        weight: weight,
        pct: pct,
        top: top,
      ));
    }
  }
  return out;
}

/// Short display name: main lifts collapse to Squat / Bench / Deadlift
/// / Press; everything else keeps its logged exercise name.
String exerciseDisplayName(String exercise) {
  final lift = mainLiftByExercise[exercise];
  if (lift == null) return exercise;
  return lift[0].toUpperCase() + lift.substring(1);
}

/// `Squat 1×5 · 260 lb (81%)` — the bare session row.
///
/// Percentage precedence: the planner's DECLARED pct wins (the program
/// says "@ 68% TM" — display 68 even when rounding lands the weight at
/// 69% of the TM); otherwise weight/[tm] when both are known. Rounded
/// to a whole percent. Accessories (no TM) never get one; a missing
/// load leaves the row bare after the rep range (never guessed).
///
/// Bodyweight movements (`isBodyweightExercise`) read `· BW` instead of
/// a load — the strength log stores the lifter's bodyweight as their
/// weight, so the planner's "suggestion" (`Pull Up 3×6-10 · 160.5 lb`)
/// was just last session's scale reading, not a prescription. A row
/// with no planned weight stays bare, as for any exercise. See
/// [bodyweightLoadLabel] for the `BW+N` case ([bodyweight] = current
/// bodyweight in lb, when known).
String formatSessionLine(SessionLine l, {double? tm, double? bodyweight}) {
  final reps = l.repsHi != null && l.repsHi != l.reps
      ? '${_n(l.reps)}-${_n(l.repsHi!)}'
      : _n(l.reps);
  final b = StringBuffer('${exerciseDisplayName(l.exercise)} ${l.sets}×$reps');
  if (l.weight != null && isBodyweightExercise(l.exercise)) {
    b.write(' · ${bodyweightLoadLabel(l.exercise, l.weight, bodyweight: bodyweight)}');
    return b.toString();
  }
  if (l.weight != null) b.write(' · ${_n(l.weight!)} lb');
  final pct = _displayPct(l, tm);
  if (pct != null) b.write(' ($pct%)');
  return b.toString();
}

/// Load label for a bodyweight movement: `BW`, or `BW+N` when the
/// exercise is explicitly WEIGHTED ("Weighted Pull Up") and the planned
/// weight carries an added load:
///   * weight above the known [bodyweight] → the excess (log convention:
///     weight = bodyweight + added, e.g. a dip at 171.4 on a 161.4 day);
///   * weight under half of bodyweight (or under 100 lb when bodyweight
///     is unknown) → it already IS the added load.
/// Anything else — unweighted movements (band-assisted muscle-ups, dips,
/// leg raises), no weight, a total with no bodyweight to subtract — is
/// plain `BW`: never a guessed number. N rounds to 2.5 lb.
String bodyweightLoadLabel(String exercise, num? weight, {double? bodyweight}) {
  if (weight == null || weight <= 0) return 'BW';
  if (!exercise.toLowerCase().contains('weighted')) return 'BW';
  double? added;
  if (bodyweight != null && bodyweight > 0) {
    if (weight > bodyweight) {
      added = weight - bodyweight;
    } else if (weight < bodyweight / 2) {
      added = weight.toDouble();
    }
  } else if (weight < 100) {
    added = weight.toDouble();
  }
  if (added == null) return 'BW';
  final rounded = (added / 2.5).round() * 2.5;
  return rounded <= 0 ? 'BW' : 'BW+${_n(rounded)} lb';
}

int? _displayPct(SessionLine l, double? tm) {
  if (l.pct != null) return (l.pct! * 100).round();
  if (l.weight == null || tm == null || tm <= 0) return null;
  if (mainLiftByExercise[l.exercise] == null) return null;
  return (l.weight! / tm * 100).round();
}

/// The day's ONE summary line: main lifts as `<lift> heavy` (has a top
/// set) / `<lift> volume`, in order of appearance, then the day's
/// non-barbell work derived from the template prose (4x4, climb with
/// its flavor, calisthenics, recovery). Accessories never earn a token
/// on lifting days; a day of only accessories reads `accessories`; an
/// empty day reads `Rest`.
String daySummary({
  required List<SessionLine> lines,
  String? morning,
  String? afternoon,
}) {
  final tokens = <String>[];
  final mains = <String, bool>{}; // lift → has a top set (insertion order)
  for (final l in lines) {
    final lift = mainLiftByExercise[l.exercise];
    if (lift == null) continue;
    mains[lift] = (mains[lift] ?? false) || l.top;
  }
  mains.forEach(
      (lift, heavy) => tokens.add('$lift ${heavy ? 'heavy' : 'volume'}'));

  final prose = '${morning ?? ''} ${afternoon ?? ''}'.toLowerCase();
  if (prose.contains('4x4')) tokens.add('4x4');
  if (prose.contains('climb')) {
    final flavor = prose.contains('limit session')
        ? 'limit '
        : prose.contains('light session')
            ? 'light '
            : prose.contains('hard session')
                ? 'hard '
                : prose.contains('technique')
                    ? 'technique '
                    : '';
    tokens.add('${flavor}climb');
  }
  if (prose.contains('calisthenics') ||
      (mains.isEmpty &&
          (prose.contains('muscle-up') || prose.contains('handstand')))) {
    tokens.add('calisthenics');
  }
  if (tokens.isEmpty && lines.isNotEmpty) tokens.add('accessories');
  if (tokens.isEmpty &&
      (prose.contains('recovery') || prose.contains('rest'))) {
    tokens.add('recovery');
  }
  return tokens.isEmpty ? 'Rest' : tokens.join(' · ');
}

/// Plain-words week status for the header — never says "wave".
///
///   cut weeks    `Week 2 of 4 · top set 4 reps @ 84%`
///   cut deload   `Week 4 of 4 · deload — top set 5 reps @ ~70%, volume
///                halved`
///   post-cut     `Week 1 of 4 · top set 5 reps @ RPE 7-8`
///   light/test   `Light week · …` / `Test week · one single @ RPE 8, …`
///
/// Null when no cycle is in force (pre-program weeks).
String? weekStatusLine({
  CutWaveWeekSpec? cut,
  int? waveWeek,
  int? waveReps,
  String? weekType,
}) {
  if (cut != null) {
    final pct = (cut.pct * 100).round();
    if (cut.deload) {
      return 'Week ${cut.week} of 4 · deload — top set ${cut.reps} reps '
          '@ ~$pct%, volume halved';
    }
    return 'Week ${cut.week} of 4 · top set ${cut.reps} reps @ $pct%';
  }
  if (waveReps == null) return null;
  return switch (weekType) {
    'light' =>
      'Light week · top set $waveReps reps at the RPE 6 cap, volume halved',
    'test' => 'Test week · one single @ RPE 8, volume halved',
    _ => waveWeek != null
        ? 'Week $waveWeek of 4 · top set $waveReps reps @ RPE 7-8'
        : 'Top set $waveReps reps @ RPE 7-8',
  };
}

/// The backoff rule collapsed to one plain-words line:
/// `keep RPE ≤ 8; if higher, drop 2.5–5%`. Null when the rule is absent
/// or missing either half — no filler text.
String? backoffLine(Object? rule) {
  if (rule is! Map) return null;
  final hold = rule['hold_if_rpe_lte'];
  final drop = rule['drop_pct'];
  if (hold is! num || drop == null) return null;
  final String dropStr;
  if (drop is List) {
    dropStr = drop.whereType<num>().map(_n).join('–');
  } else if (drop is num) {
    dropStr = _n(drop);
  } else {
    return null;
  }
  if (dropStr.isEmpty) return null;
  return 'keep RPE ≤ ${_n(hold)}; if higher, drop $dropStr%';
}

// ---------------------------------------------------------------------------
// Training-max signal + history
// ---------------------------------------------------------------------------

/// A lift's current training max with its 2-week-back comparison.
class TmSignal {
  /// Value in force at as-of.
  final double current;

  /// Value in force [lookback] before as-of; null when the tab has no
  /// row that old. Equal to [current] when nothing moved.
  final double? previous;

  /// effective_from of the row that set [current] — the date of the
  /// driving reading (or seed/manual edit).
  final DateTime changedOn;

  /// Source of the driving row (seed | rule | manual | test |
  /// pain_cap). v13: `rule` rows are the slow loop's recomputes —
  /// labeled "auto"; `manual` values pin until outvoted — labeled
  /// "manual".
  final String source;

  const TmSignal({
    required this.current,
    required this.previous,
    required this.changedOn,
    this.source = '',
  });
}

/// Last row in force at [day] for [lift]; tab order is chronological
/// (append-only), ties broken by position.
WorkingMaxRow? _inForceAt(
    List<WorkingMaxRow> rows, String lift, DateTime day) {
  WorkingMaxRow? last;
  for (final r in rows) {
    if (r.lift == lift && !r.effectiveFrom.isAfter(day)) last = r;
  }
  return last;
}

/// The lift's current TM vs the value in force [lookbackDays] ago.
/// Null when no row is in force at [asOf].
TmSignal? tmSignal(
  List<WorkingMaxRow> rows,
  String lift,
  DateTime asOf, {
  int lookbackDays = 14,
}) {
  final day = DateTime.utc(asOf.year, asOf.month, asOf.day);
  final current = _inForceAt(rows, lift, day);
  if (current == null) return null;
  final before =
      _inForceAt(rows, lift, day.subtract(Duration(days: lookbackDays)));
  return TmSignal(
    current: current.valueLb,
    previous: before?.valueLb,
    changedOn: current.effectiveFrom,
    source: current.source,
  );
}

/// Inline label after the lift name: `310 · was 320 ↓ · Oct 1` when it
/// moved inside the window, `310 · since Sep 21` when steady.
String tmSignalLabel(TmSignal s) => '${_n(s.current)} · ${tmSignalSuffix(s)}';

/// The label's tail (the value is rendered separately at value scale):
/// `was 320 ↓ · Oct 1 · auto` / `since Sep 21` / `260 · manual`.
///
/// Source labels (v13 two-loop TM): slow-loop recomputes (`rule` rows)
/// read `auto`; user-pinned values (`manual` rows) read `manual`;
/// seeds/others stay bare.
String tmSignalSuffix(TmSignal s) {
  final when = DateFormat('MMM d').format(s.changedOn);
  final tag = switch (s.source) {
    'manual' => ' · manual',
    'rule' => ' · auto',
    _ => '',
  };
  if (s.previous == null || s.previous == s.current) {
    return 'since $when$tag';
  }
  final arrow = s.current > s.previous! ? '↑' : '↓';
  return 'was ${_n(s.previous!)} $arrow · $when$tag';
}

/// The lift's full TM history for the trend plot: (day, value) in tab
/// (chronological) order, same-day rows collapsed to the last (the
/// in-app seed confirm appends a duplicate value row).
List<({DateTime day, double value})> tmHistoryPoints(
  List<WorkingMaxRow> rows,
  String lift,
) {
  final points = <({DateTime day, double value})>[];
  for (final r in rows) {
    if (r.lift != lift) continue;
    final day = DateTime.utc(
        r.effectiveFrom.year, r.effectiveFrom.month, r.effectiveFrom.day);
    if (points.isNotEmpty && points.last.day == day) {
      points[points.length - 1] = (day: day, value: r.valueLb);
    } else {
      points.add((day: day, value: r.valueLb));
    }
  }
  return points;
}

String _n(num v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

/// Public number formatter: `105.0` → `105`, `161.5` → `161.5`.
String formatNum(num v) => _n(v);

/// Meta line for [sets] identical sets (the Log timeline's planned rows,
/// same shape as [formatSessionLine] minus the name): `3×6 · 105 lb`,
/// `3×8 · BW` for bodyweight movements (a bodyweight load is not a
/// prescription), bare `3×8` when no load is known.
String setsRepsLoad({
  required int sets,
  num? reps,
  num? weight,
  bool bodyweight = false,
}) {
  final b = StringBuffer(reps == null ? '$sets sets' : '$sets×${_n(reps)}');
  if (bodyweight) {
    b.write(' · BW');
  } else if (weight != null) {
    b.write(' · ${_n(weight)} lb');
  }
  return b.toString();
}

/// One set's chip label: `105×6`, `BW×8`, `8 reps` (no load).
String setChipLabel({num? reps, num? weight, bool bodyweight = false}) {
  final r = reps == null ? null : _n(reps);
  if (bodyweight) return r == null ? 'BW' : 'BW×$r';
  if (weight != null) return r == null ? '${_n(weight)} lb' : '${_n(weight)}×$r';
  return r == null ? 'Log' : '$r reps';
}
