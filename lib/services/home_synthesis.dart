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
  final TrendDirection direction;
  final bool painCap;

  const LiftTrend({
    required this.lift,
    required this.valueLb,
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
StatusWeek? latestStatusWeek(
  List<Map<String, Object?>> rows,
  DateTime today,
) {
  final currentMonday = _mondayOf(today);
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

DateTime _mondayOf(DateTime d) {
  final day = DateTime.utc(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
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
  DateTime today,
) {
  final currentMonday = _mondayOf(today);
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
  final afternoon =
      slice.todayTemplate['afternoon']?.toString().trim() ?? '';
  final line = morning.isNotEmpty
      ? morning
      : afternoon.isNotEmpty
          ? 'PM: $afternoon'
          : '';
  if (line.isEmpty) return null;
  return line.length <= maxLen ? line : '${line.substring(0, maxLen)}…';
}
