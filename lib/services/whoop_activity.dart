/// Whoop workouts as the app's ACTIVITY signal (2026-10-01, spec
/// docs/superpowers/specs/2026-10-01-whoop-activity-layer-design.md).
///
/// Pure: turns `whoop_workouts` rows into typed [WhoopActivity] values and
/// answers the questions consumers ask — what kind of session, was it an
/// easy zone-2 run, was it logged anywhere else, does it complete a
/// prescribed climb. Whoop says a session HAPPENED (+ strain); Kaya adds
/// climbing grades when an export lands; manual logs carry set detail.
library;

import 'prescribed_exercises.dart';

enum ActivityKind { climb, run, lift, walk, other }

class WhoopActivity {
  /// Local calendar day (midnight).
  final DateTime date;

  /// Local wall-clock start, when known.
  final DateTime? start;
  final String sport;
  final ActivityKind kind;
  final double? strain;
  final double? avgHr;
  final double? maxHr;
  final double? durationMin;

  const WhoopActivity({
    required this.date,
    required this.sport,
    required this.kind,
    this.start,
    this.strain,
    this.avgHr,
    this.maxHr,
    this.durationMin,
  });
}

/// Sport label → kind. Normalized (lowercase, spaces/underscores → '-').
/// MIRRORED by ledger-mcp src/tools.ts `kindOf` — edit both.
///
/// I3 (2026-10-01): a bare "climb" substring is too broad — it matched
/// "stair climber" / "stairmaster"-style cardio machines. Climb requires
/// 'rock-climb' or 'bouldering' or an exact 'climbing', and is explicitly
/// vetoed by 'stair' or 'machine' in the sport label.
ActivityKind activityKindOf(String sport) {
  final s = sport.trim().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');
  final climbMatch =
      s.contains('rock-climb') || s.contains('bouldering') || s == 'climbing';
  if (climbMatch && !s.contains('stair') && !s.contains('machine')) {
    return ActivityKind.climb;
  }
  if (s == 'run' || s.contains('running')) return ActivityKind.run;
  if (s == 'weightlifting' ||
      s.contains('powerlifting') ||
      s.contains('strength')) {
    return ActivityKind.lift;
  }
  if (s == 'walking') return ActivityKind.walk;
  return ActivityKind.other;
}

DateTime? _dt(Object? v) {
  if (v is DateTime) return v;
  if (v == null) return null;
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v == null) return null;
  return double.tryParse(v.toString());
}

/// `whoop_workouts` rows → activities, oldest first. Rows without a date
/// or sport are skipped (never throws).
List<WhoopActivity> whoopActivitiesFromRecords(
    Iterable<Map<String, Object?>> rows) {
  final out = <WhoopActivity>[];
  for (final r in rows) {
    final d = _dt(r['date']);
    final sport = r['sport']?.toString().trim() ?? '';
    if (d == null || sport.isEmpty) continue;
    out.add(WhoopActivity(
      date: DateTime(d.year, d.month, d.day),
      start: _dt(r['start_time']),
      sport: sport,
      kind: activityKindOf(sport),
      strain: _num(r['strain']),
      avgHr: _num(r['avg_hr']),
      maxHr: _num(r['max_hr']),
      durationMin: _num(r['duration_min']),
    ));
  }
  out.sort((a, b) => (a.start ?? a.date).compareTo(b.start ?? b.date));
  return out;
}

/// An easy run: kind run, ≥ [minMinutes], average HR ≤ [maxAvgPct] of
/// the user's max HR. Missing HR or duration → false (never guessed).
bool isZone2Run(
  WhoopActivity a, {
  required double maxHr,
  double minMinutes = 20,
  double maxAvgPct = 0.75,
}) =>
    a.kind == ActivityKind.run &&
    a.durationMin != null &&
    a.durationMin! >= minMinutes &&
    a.avgHr != null &&
    a.avgHr! <= maxHr * maxAvgPct;

/// True when nothing else in the app records this session: a climb with
/// no Kaya ascents that day, a lift with no logged strength sets that day,
/// and every other kind (never logged in-app).
bool isUnlogged(
  WhoopActivity a, {
  required Set<DateTime> strengthDays,
  required Set<DateTime> climbDays,
}) =>
    switch (a.kind) {
      ActivityKind.climb => !climbDays.contains(a.date),
      ActivityKind.lift => !strengthDays.contains(a.date),
      _ => true,
    };

/// Distinct local days with a Whoop climb.
Set<DateTime> whoopClimbDays(Iterable<WhoopActivity> acts) => {
      for (final a in acts)
        if (a.kind == ActivityKind.climb) a.date,
    };

/// A prescribed climbing item. The prose parser puts "PM: Climb — …" as
/// name "PM" + scheme "Climb — …", so match on both.
bool isClimbItem(PrescribedItem i) =>
    RegExp(r'climb', caseSensitive: false).hasMatch('${i.name} ${i.scheme}');

/// Ticks not-yet-done climb items when [dayActivities] (the card's day)
/// include a Whoop climb; the note carries the strain of the hardest one.
List<PrescribedItem> creditClimbItems(
    List<PrescribedItem> items, List<WhoopActivity> dayActivities) {
  final climbs =
      dayActivities.where((a) => a.kind == ActivityKind.climb).toList();
  if (climbs.isEmpty) return items;
  final strains = [for (final c in climbs) ?c.strain];
  final note = strains.isEmpty
      ? 'via Whoop'
      : 'strain ${strains.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)}';
  return [
    for (final i in items)
      isClimbItem(i) && !i.done ? i.withCredit(note) : i,
  ];
}
