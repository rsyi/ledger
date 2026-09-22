/// Pure synthesis helpers for the home-screen progress dashboard.
///
/// No Flutter, no IO — everything here turns already-fetched data
/// (WmStore snapshots, program_status rows read through the read-only
/// SheetsRepository path, ProgramSlice targets) into the small display
/// facts the dashboard cards render: direction arrows, week-progress
/// fractions, condensed verdict chips. Kept pure so the dashboard UI
/// stays thin and this logic stays unit-testable.
library;

import 'program_current.dart';
import 'program_metrics.dart'
    show GradedSet, StrengthRow, epleyE1rm, gradeSets, mainLiftByExercise,
        weekStartOf;
import 'wm_tabs.dart';

// ---------------------------------------------------------------------------
// Strength: working-max trends
// ---------------------------------------------------------------------------

enum TrendDirection { up, down, flat, unknown }

/// Display order for the four working maxes.
const List<String> synthesisLifts = ['squat', 'bench', 'deadlift', 'press'];

/// Direction of [current] vs [past]. [threshold] (lb) absorbs noise —
/// the smallest working-max step is 5 lb, so anything within ±2.5 lb is
/// flat. Unknown when either side is missing (e.g. the controller has
/// less than four weeks of history).
TrendDirection trendDirection(
  double? current,
  double? past, {
  double threshold = 2.5,
}) {
  if (current == null || past == null) return TrendDirection.unknown;
  final diff = current - past;
  if (diff > threshold) return TrendDirection.up;
  if (diff < -threshold) return TrendDirection.down;
  return TrendDirection.flat;
}

/// One lift's dashboard line: current working max, 4-week direction, and
/// whether a pain cap is active.
class LiftTrend {
  final String lift;
  final double? valueLb;

  /// When the current working max took effect (the row's
  /// effective_from) — feeds the card's age tag. Null with [valueLb].
  final DateTime? asOf;
  final TrendDirection direction;
  final bool painCap;

  const LiftTrend({
    required this.lift,
    required this.valueLb,
    this.asOf,
    required this.direction,
    required this.painCap,
  });
}

/// Trends for all four lifts from a working-max tab snapshot. A null
/// snapshot (offline, tabs not seeded) yields four unknown placeholders
/// so the card can still render its skeleton.
List<LiftTrend> liftTrends(
  WmSnapshot? snap,
  DateTime today, {
  int windowDays = 28,
}) {
  final rows = snap?.workingMax ?? const <WorkingMaxRow>[];
  final past = DateTime(today.year, today.month, today.day - windowDays);
  return [
    for (final lift in synthesisLifts)
      LiftTrend(
        lift: lift,
        valueLb: currentWorkingMax(rows, lift)?.valueLb,
        asOf: currentWorkingMax(rows, lift)?.effectiveFrom,
        direction: trendDirection(
          currentWorkingMax(rows, lift)?.valueLb,
          workingMaxAsOf(rows, lift, past),
        ),
        painCap: painCapActive(rows, lift),
      ),
  ];
}

/// Formats a pound value without a trailing `.0` (240, not 240.0).
String fmtLb(num v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

// ---------------------------------------------------------------------------
// Strength: estimated-1RM numbers (dashboard STRENGTH card, spec §0)
// ---------------------------------------------------------------------------

/// Maps a ledger strength record into a [StrengthRow] for e1RM math.
/// Null when the row lacks a parseable date/exercise/weight/reps
/// (isometric holds, planned rows without weights — they never qualify
/// anyway). Mirror of WeekPlanner's private mapper.
StrengthRow? strengthRowFromRecord(Map<String, Object?> r) {
  final rawDate = r['date'];
  final date = rawDate is DateTime
      ? rawDate
      : DateTime.tryParse(rawDate?.toString() ?? '');
  final exercise = r['exercise']?.toString();
  final weight = asNum(r['weight']);
  final reps = asNum(r['reps']);
  if (date == null || exercise == null || exercise.isEmpty) return null;
  if (weight == null || reps == null) return null;
  return StrengthRow(
    date: date,
    exercise: exercise,
    weight: weight,
    reps: reps.round(),
    rpe: asNum(r['rpe']),
  );
}

/// All-time best estimated 1RM per lift ('squat'|'bench'|'deadlift'|
/// 'press') over the FULL strength history. Epley with reps capped at
/// 12 — the airlayer `max_e1rm_capped` measure's expression (the e1RM
/// source of truth per the working-max spec header), deliberately NOT
/// the 42-day reference's reps<=8 qualifier: an all-time best may be a
/// rep PR. Lifts with no history are absent from the map.
Map<String, double> allTimeBestE1rms(List<StrengthRow> rows) {
  final out = <String, double>{};
  for (final r in rows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || r.weight <= 0 || r.reps <= 0) continue;
    final e = epleyE1rm(r.weight, r.reps);
    if ((out[lift] ?? 0) < e) out[lift] = e;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Strength: recency (STRENGTH card redesign 2026-09-22)
// ---------------------------------------------------------------------------

int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

/// Compact age tag for "when was this number set": "3d", "2w", "5mo",
/// "2y". Days under two weeks stay in days; then weeks to ~10 weeks;
/// then months to ~2 years; then years. Never negative (future dates
/// clamp to "0d" — they shouldn't happen, but a tag must never crash).
String fmtAge(DateTime date, DateTime today) {
  final d = _daysBetween(date, today) < 0 ? 0 : _daysBetween(date, today);
  if (d < 14) return '${d}d';
  if (d < 70) return '${(d / 7).round()}w';
  if (d < 720) return '${(d / 30.44).round()}mo';
  return '${(d / 365.25).round()}y';
}

/// Recent e1RM — the STRENGTH card's display metric (2026-09-22): the
/// lift's best capped e1RM over the trailing [windowDays] (14) days of
/// REAL work. Excluded from "real work", per the documented rule:
///   • sets whose ACCOUNTING week ([weekStartDay]) is week_type
///     `light` per [weekTypeOf] — deload work never sets the number;
///   • sets with effort < 0.75 against the §2.5 42-day reference
///     (warm-ups / technique days), including ungraded sets that
///     predate any reference (no effort → not comparable → excluded).
/// When the window holds nothing, it WIDENS: the window slides back to
/// end at the newest qualifying set (still [windowDays] long) and the
/// age tag tells the story. Null only when the lift has no qualifying
/// history at all.
///
/// DISPLAY-ONLY: the §2.5 42-day reference is unchanged internally —
/// the controller, planner weight fill, and backtest still hang off it.
({double value, DateTime date})? recentBestE1rm(
  List<GradedSet> graded,
  String lift,
  DateTime today, {
  String? Function(DateTime weekStartDate)? weekTypeOf,
  int weekStartDay = DateTime.monday,
  int windowDays = 14,
}) {
  final q = <GradedSet>[
    for (final s in graded)
      if (s.lift == lift &&
          _daysBetween(s.date, today) >= 0 &&
          s.effort != null &&
          s.effort! >= 0.75 &&
          weekTypeOf?.call(weekStartOf(s.date, weekStartDay)) != 'light')
        s,
  ];
  if (q.isEmpty) return null;
  var end = today;
  final newest = q.map((s) => s.date).reduce((a, b) => a.isAfter(b) ? a : b);
  if (_daysBetween(newest, today) >= windowDays) end = newest; // widen
  GradedSet? best;
  for (final s in q) {
    final ago = _daysBetween(s.date, end);
    if (ago < 0 || ago >= windowDays) continue;
    if (best == null ||
        s.e1rm > best.e1rm ||
        (s.e1rm == best.e1rm && s.date.isAfter(best.date))) {
      best = s;
    }
  }
  return best == null ? null : (value: best.e1rm, date: best.date);
}

/// All-time best e1RM per lift WITH the date it was set — same
/// qualification as [allTimeBestE1rms] (Epley capped at 12, full
/// history); ties keep the more recent date (the age tag should say
/// "you matched this 3d ago", not point at 2024).
Map<String, ({double value, DateTime date})> allTimeBestE1rmsWithDates(
  List<StrengthRow> rows,
) {
  final out = <String, ({double value, DateTime date})>{};
  for (final r in rows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || r.weight <= 0 || r.reps <= 0) continue;
    final e = epleyE1rm(r.weight, r.reps);
    final cur = out[lift];
    if (cur == null ||
        e > cur.value ||
        (e == cur.value && r.date.isAfter(cur.date))) {
      out[lift] = (value: e, date: DateTime(r.date.year, r.date.month, r.date.day));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Execution: LIVE current-week counts (2026-09-22 — the THIS WEEK strip
// computes the running week from local rows at render; the nightly
// program_status tab keeps owning last week + history)
// ---------------------------------------------------------------------------

/// The four quotas the THIS WEEK strip shows, computed live.
class LiveWeekCounts {
  /// Start of the accounting week the counts cover.
  final DateTime weekStart;
  final int workingSets;
  final int nearMaxSets;
  final int benchDays;
  final int climbingSessions;

  const LiveWeekCounts({
    required this.weekStart,
    required this.workingSets,
    required this.nearMaxSets,
    required this.benchDays,
    required this.climbingSessions,
  });
}

/// Live current-week rollup over local rows — the same §2.5 semantics
/// the nightly job writes (gradeSets over FULL history so the 42-day
/// references match, then this week's counts), so the strip and the
/// tab agree the morning after. [weekStartDay] keys the week
/// (program.yaml week_start — saturday makes a Saturday session count
/// toward the new week immediately).
LiveWeekCounts liveWeekCounts({
  required List<StrengthRow> strengthRows,
  List<DateTime> climbingDates = const [],
  required DateTime today,
  int weekStartDay = DateTime.monday,
}) {
  final start = weekStartOf(today, weekStartDay);
  var working = 0;
  var nearMax = 0;
  final benchDates = <DateTime>{};
  for (final s in gradeSets(strengthRows)) {
    if (_daysBetween(s.date, today) < 0) continue; // future/planned rows
    if (weekStartOf(s.date, weekStartDay) != start) continue;
    if (s.working) working++;
    if (s.nearMax) nearMax++;
    if (s.lift == 'bench') benchDates.add(s.date);
  }
  final climbDays = <DateTime>{
    for (final c in climbingDates)
      if (_daysBetween(c, today) >= 0 &&
          weekStartOf(c, weekStartDay) == start)
        DateTime(c.year, c.month, c.day),
  };
  return LiveWeekCounts(
    weekStart: start,
    workingSets: working,
    nearMaxSets: nearMax,
    benchDays: benchDates.length,
    climbingSessions: climbDays.length,
  );
}

// ---------------------------------------------------------------------------
// Tolerant cell parsing (program_status rows arrive as DateTime/num from
// the sheet codec, but degrade to strings on hand-edited tabs)
// ---------------------------------------------------------------------------

DateTime? asDay(Object? v) {
  if (v is DateTime) return DateTime.utc(v.year, v.month, v.day);
  final s = v?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  final d = DateTime.tryParse(s);
  return d == null ? null : DateTime.utc(d.year, d.month, d.day);
}

double? asNum(Object? v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

// ---------------------------------------------------------------------------
// Execution: this week's program_status row
// ---------------------------------------------------------------------------

/// The status row the dashboard reads, plus whether it is the week
/// containing today (vs the newest completed week — the nightly job may
/// not have written the current week yet).
class StatusWeek {
  final Map<String, Object?> row;
  final DateTime weekMonday;
  final bool isCurrentWeek;

  const StatusWeek({
    required this.row,
    required this.weekMonday,
    required this.isCurrentWeek,
  });
}

/// Picks the newest program_status row whose `week_monday` is at or
/// before today's week. Rows may be in any order; future weeks are
/// ignored. Null when nothing usable exists.
///
/// [weekStartDay] must match the nightly job's rollup keying (program
/// week_start — v7: saturday) or `isCurrentWeek` misfires on the days
/// the two calendars disagree about.
StatusWeek? latestStatusWeek(
  List<Map<String, Object?>> rows,
  DateTime today, {
  int weekStartDay = DateTime.monday,
}) {
  final currentMonday = _weekStartUtc(today, weekStartDay);
  DateTime? best;
  Map<String, Object?>? bestRow;
  for (final r in rows) {
    final m = asDay(r['week_monday']);
    if (m == null || m.isAfter(currentMonday)) continue;
    if (best == null || m.isAfter(best)) {
      best = m;
      bestRow = r;
    }
  }
  if (best == null || bestRow == null) return null;
  return StatusWeek(
    row: bestRow,
    weekMonday: best,
    isCurrentWeek: best == currentMonday,
  );
}

/// UTC-day accounting week start (status rows parse to UTC days).
DateTime _weekStartUtc(DateTime d, int weekStartDay) {
  final day = DateTime.utc(d.year, d.month, d.day);
  return day.subtract(Duration(days: (day.weekday - weekStartDay) % 7));
}

/// Number of flag ids in a program_status `flags` cell (comma-separated).
int flagCount(Object? flagsCell) {
  final s = flagsCell?.toString() ?? '';
  return s.split(',').where((p) => p.trim().isNotEmpty).length;
}

// ---------------------------------------------------------------------------
// Targets (ProgramSlice.targetsInForce values: num | [lo, hi] | null)
// ---------------------------------------------------------------------------

/// A single comparable number for a target: nums pass through, ranges
/// use the upper bound, anything else is null.
double? targetNumber(Object? target) {
  if (target is List) {
    return target.isEmpty ? null : asNum(target.last);
  }
  return asNum(target);
}

/// Human text for a target: `28`, `2–3`, or an em-dash when absent.
String targetText(Object? target) {
  if (target is List && target.length == 2) {
    return '${_fmtTarget(target[0])}–${_fmtTarget(target[1])}';
  }
  final n = targetNumber(target);
  return n == null ? '—' : fmtLb(n);
}

String _fmtTarget(Object? v) {
  final n = asNum(v);
  return n == null ? v.toString() : fmtLb(n);
}

/// Fraction of a weekly target achieved, clamped to 0..1. Null when
/// either side is missing or the target is zero (no bar to draw).
double? weekFraction(num? done, Object? target) {
  final t = targetNumber(target);
  if (done == null || t == null || t <= 0) return null;
  return (done / t).clamp(0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Body: verdict condensation
// ---------------------------------------------------------------------------

/// Condenses a [PhaseVerdict] label to chip length: everything before the
/// " — " explanation ("gaining — PHASE_MISMATCH would fire" → "gaining");
/// short labels pass through. The chip's color carries the severity.
String verdictChipText(String label) {
  final i = label.indexOf(' — ');
  return i < 0 ? label : label.substring(0, i);
}

// ---------------------------------------------------------------------------
// Engine: last measured 4x4 + today's template
// ---------------------------------------------------------------------------

/// The newest week at or before today's with a measured 4x4 max HR.
({DateTime weekMonday, double maxHr})? lastBike4x4(
  List<Map<String, Object?>> rows,
  DateTime today, {
  int weekStartDay = DateTime.monday,
}) {
  final currentMonday = _weekStartUtc(today, weekStartDay);
  DateTime? best;
  double? bestHr;
  for (final r in rows) {
    final m = asDay(r['week_monday']);
    final hr = asNum(r['bike_4x4_max_hr']);
    if (m == null || hr == null || m.isAfter(currentMonday)) continue;
    if (best == null || m.isAfter(best)) {
      best = m;
      bestHr = hr;
    }
  }
  return best == null ? null : (weekMonday: best, maxHr: bestHr!);
}

/// One-line summary of today's template: the morning session, else the
/// afternoon prefixed "PM: ", truncated to [maxLen] characters. Null when
/// the day is a rest day or no slice resolved.
String? templateOneLiner(ProgramSlice? slice, {int maxLen = 84}) {
  if (slice == null) return null;
  final morning = slice.todayTemplate['morning']?.toString().trim() ?? '';
  final afternoon = slice.todayTemplate['afternoon']?.toString().trim() ?? '';
  final line = morning.isNotEmpty
      ? morning
      : afternoon.isNotEmpty
      ? 'PM: $afternoon'
      : '';
  if (line.isEmpty) return null;
  return line.length <= maxLen ? line : '${line.substring(0, maxLen)}…';
}
