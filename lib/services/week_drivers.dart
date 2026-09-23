/// Weekly driver checklist — the THIS WEEK strip's brain (2026-09-22).
///
/// Design principle (CLAUDE.md): output metrics >> input metrics. The
/// strip no longer tallies activity (sets logged, totals); it renders
/// the per-phase DRIVER CHECKLIST — the few causal, eigenvector inputs
/// that actually produce the phase's outcome, each tied to the outcome
/// it drives. Declared in app/dashboards.yaml under the existing
/// `phases:` section as `weekly_drivers:`; absent → [parseWeeklyDrivers]
/// returns null and the old quota strip renders unchanged (back-compat
/// by construction, same contract as the `phases:` hero itself).
///
/// Driver vocabulary (id selects the computation):
///   top_single_per_lift  each listed lift gets its heavy single this
///                        week (a §2.5 near-max set) — four per-lift
///                        ticks, not a count.
///   bench_frequency      distinct bench days vs `target`.
///   lift_frequency       per-lift distinct days vs `per_lift_targets`
///                        (the muscle-group 2x/wk eigenvector
///                        specialized to the program's big lifts).
///   near_max_exposure    near-max SETS this week vs `target`.
///   protein_floor        daily-avg protein (g) over this week's
///                        logged days / bodyweight ≥ `floor_g_per_lb`.
///   climbing_cap         climb session days vs `cap` — a CAP, not a
///                        target: over is violated, under is fine. When
///                        the kaya snapshot's latest ascent predates
///                        the accounting week the count is unknowable
///                        (import-driven snapshot) → pending with
///                        [DriverEval.staleAsOf] for the "as of" tag.
///   bike_4x4             distinct 4x4 session days vs `target`.
///
/// Pure Dart, no Flutter, no IO — the strip UI stays layout-only.
library;

import 'package:yaml/yaml.dart';

import 'program_metrics.dart' show GradedSet, weekStartOf;

// ---------------------------------------------------------------------------
// Config (dashboards.yaml phases.<phase>.weekly_drivers)
// ---------------------------------------------------------------------------

/// One declared driver. Only the fields its `id` needs are read.
class WeekDriverConfig {
  final String id;

  /// Strip label. Absent → per-id default.
  final String? label;

  /// top_single_per_lift: which lifts tick. Empty → the four mains.
  final List<String> lifts;

  /// lift_frequency: lift → weekly day target.
  final Map<String, int> perLiftTargets;

  /// Count targets (bench_frequency / near_max_exposure / bike_4x4).
  final double? target;

  /// climbing_cap's allowance.
  final double? cap;

  /// protein_floor's g-per-lb-of-bodyweight floor.
  final double? floorGPerLb;

  /// The outcome this driver produces ("Wilks preserved") — every
  /// driver must name one (the principle's ship gate).
  final String? outcome;

  /// One-line causal story for the detail sheet.
  final String? why;

  const WeekDriverConfig({
    required this.id,
    this.label,
    this.lifts = const [],
    this.perLiftTargets = const {},
    this.target,
    this.cap,
    this.floorGPerLb,
    this.outcome,
    this.why,
  });
}

/// Parses `phases:` → phase value → its `weekly_drivers:` list. Null
/// when nothing declares weekly_drivers (or the yaml is missing or
/// malformed) — the caller keeps the old quota strip. Entries without
/// an id are skipped, never fatal.
Map<String, List<WeekDriverConfig>>? parseWeeklyDrivers(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  Object? doc;
  try {
    doc = loadYaml(raw);
  } catch (_) {
    return null;
  }
  if (doc is! Map) return null;
  final phases = doc['phases'];
  if (phases is! Map) return null;
  final out = <String, List<WeekDriverConfig>>{};
  for (final entry in phases.entries) {
    final name = entry.key?.toString().trim() ?? '';
    final body = entry.value;
    if (name.isEmpty || body is! Map) continue;
    final drivers = body['weekly_drivers'];
    if (drivers is! List) continue;
    final parsed = <WeekDriverConfig>[];
    for (final d in drivers) {
      if (d is! Map) continue;
      final id = d['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final lifts = d['lifts'];
      final perLift = d['per_lift_targets'];
      parsed.add(
        WeekDriverConfig(
          id: id,
          label: d['label']?.toString(),
          lifts: lifts is List
              ? [for (final l in lifts) l.toString()]
              : const [],
          perLiftTargets: perLift is Map
              ? {
                  for (final e in perLift.entries)
                    if (e.value is num)
                      e.key.toString(): (e.value as num).toInt(),
                }
              : const {},
          target: (d['target'] as num?)?.toDouble(),
          cap: (d['cap'] as num?)?.toDouble(),
          floorGPerLb: (d['floor_g_per_lb'] as num?)?.toDouble(),
          outcome: d['outcome']?.toString(),
          why: d['why']?.toString(),
        ),
      );
    }
    if (parsed.isNotEmpty) out[name] = parsed;
  }
  return out.isEmpty ? null : out;
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

/// met      the driver's condition holds (a cap counts as met while
///          at/under it — under a cap is fine, not "incomplete").
/// pending  not there yet, week still open (never punitive mid-week);
///          also "cannot know" (stale climb snapshot, no meal data).
/// violated a cap exceeded, or a floor breached — the amber/red states.
enum DriverStatus { met, pending, violated }

/// One per-lift tick (top_single_per_lift / lift_frequency).
class DriverTick {
  final String lift;
  final int count;
  final int target;

  const DriverTick({
    required this.lift,
    required this.count,
    required this.target,
  });

  bool get done => count >= target;
}

/// One evaluated driver, preformatted for the strip.
class DriverEval {
  final WeekDriverConfig config;
  final DriverStatus status;

  /// "3/4", "1.05 g/lb", "2/≤2".
  final String value;

  /// Per-lift ticks (empty for scalar drivers).
  final List<DriverTick> ticks;

  /// climbing_cap honesty: the snapshot's latest ascent date when it
  /// predates the accounting week (count unknowable until re-import).
  final DateTime? staleAsOf;

  const DriverEval({
    required this.config,
    required this.status,
    required this.value,
    this.ticks = const [],
    this.staleAsOf,
  });

  /// Strip label fallback chain: declared label → per-id default.
  String get label =>
      config.label ??
      const {
        'top_single_per_lift': 'singles',
        'bench_frequency': 'bench',
        'lift_frequency': 'lifts',
        'near_max_exposure': 'near-max',
        'protein_floor': 'protein',
        'climbing_cap': 'climb',
        'bike_4x4': '4x4',
      }[config.id] ??
      config.id;
}

/// Already-fetched observations the evaluators read. All dates may be
/// full timestamps — evaluation normalizes to calendar days.
class WeekDriverInputs {
  /// §2.5 graded sets over FULL history (so references match the
  /// nightly tab); evaluation filters to the accounting week.
  final List<GradedSet> graded;

  /// kaya_ascents ascent dates (full snapshot — staleness needs the
  /// overall latest).
  final List<DateTime> climbingDates;

  /// 4x4 cardio row dates (caller applies the nightly job's type
  /// filter); interval rows collapse to distinct session days here.
  final List<DateTime> cardioDates;

  /// Calendar day → total protein grams (meals rows summed per day).
  final Map<DateTime, double> proteinByDay;

  /// Current bodyweight (lb) pricing the protein floor — 7-day avg.
  final double? bodyweightLb;

  const WeekDriverInputs({
    this.graded = const [],
    this.climbingDates = const [],
    this.cardioDates = const [],
    this.proteinByDay = const {},
    this.bodyweightLb,
  });
}

const List<String> _defaultLifts = ['squat', 'bench', 'deadlift', 'press'];

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

/// Evaluates [configs] against the CURRENT accounting week (the week
/// of [today] keyed by [weekStartDay] — program v7: saturday). Future
/// rows (planned) never count. Unknown ids are skipped so a newer
/// config never breaks an older app.
List<DriverEval> evaluateWeekDrivers({
  required List<WeekDriverConfig> configs,
  required WeekDriverInputs inputs,
  required DateTime today,
  int weekStartDay = DateTime.monday,
}) {
  final weekStart = weekStartOf(_day(today), weekStartDay);
  bool inWeek(DateTime d) =>
      _daysBetween(d, today) >= 0 &&
      weekStartOf(_day(d), weekStartDay) == weekStart;

  /// Distinct this-week days with a graded set of [lift].
  Set<DateTime> liftDays(String lift) => {
    for (final s in inputs.graded)
      if (s.lift == lift && inWeek(s.date)) _day(s.date),
  };

  String frac(num done, num target) =>
      '${done.round()}/${target.round()}';

  final out = <DriverEval>[];
  for (final c in configs) {
    switch (c.id) {
      case 'top_single_per_lift':
        final lifts = c.lifts.isEmpty ? _defaultLifts : c.lifts;
        final ticks = <DriverTick>[
          for (final lift in lifts)
            DriverTick(
              lift: lift,
              count: inputs.graded.any(
                (s) => s.lift == lift && s.nearMax && inWeek(s.date),
              )
                  ? 1
                  : 0,
              target: 1,
            ),
        ];
        final done = ticks.where((t) => t.done).length;
        out.add(
          DriverEval(
            config: c,
            status: done >= lifts.length
                ? DriverStatus.met
                : DriverStatus.pending,
            value: frac(done, lifts.length),
            ticks: ticks,
          ),
        );

      case 'lift_frequency':
        final ticks = <DriverTick>[
          for (final e in c.perLiftTargets.entries)
            DriverTick(
              lift: e.key,
              count: liftDays(e.key).length,
              target: e.value,
            ),
        ];
        final done = ticks.where((t) => t.done).length;
        out.add(
          DriverEval(
            config: c,
            status: ticks.isNotEmpty && done == ticks.length
                ? DriverStatus.met
                : DriverStatus.pending,
            value: frac(done, ticks.length),
            ticks: ticks,
          ),
        );

      case 'bench_frequency':
        final days = liftDays('bench').length;
        final t = c.target ?? 2;
        out.add(
          DriverEval(
            config: c,
            status: days >= t ? DriverStatus.met : DriverStatus.pending,
            value: frac(days, t),
          ),
        );

      case 'near_max_exposure':
        final sets = inputs.graded
            .where((s) => s.nearMax && inWeek(s.date))
            .length;
        final t = c.target ?? 6;
        out.add(
          DriverEval(
            config: c,
            status: sets >= t ? DriverStatus.met : DriverStatus.pending,
            value: frac(sets, t),
          ),
        );

      case 'protein_floor':
        double sum = 0;
        var days = 0;
        inputs.proteinByDay.forEach((d, grams) {
          if (!inWeek(d)) return;
          sum += grams;
          days++;
        });
        final bw = inputs.bodyweightLb;
        final gPerLb = days == 0 || bw == null || bw <= 0
            ? null
            : (sum / days) / bw;
        final floor = c.floorGPerLb;
        out.add(
          DriverEval(
            config: c,
            status: gPerLb == null || floor == null
                ? DriverStatus.pending
                : gPerLb >= floor
                    ? DriverStatus.met
                    : DriverStatus.violated,
            value: gPerLb == null
                ? '— g/lb'
                : '${gPerLb.toStringAsFixed(2)} g/lb',
          ),
        );

      case 'climbing_cap':
        final sessions = <DateTime>{
          for (final d in inputs.climbingDates)
            if (inWeek(d)) _day(d),
        }.length;
        final cap = c.cap ?? 2;
        // Snapshot honesty: the tab only updates on re-import — when
        // its newest ascent predates this accounting week, "0 climbs"
        // is unknowable, not observed.
        DateTime? latest;
        for (final d in inputs.climbingDates) {
          final day = _day(d);
          if (latest == null || day.isAfter(latest)) latest = day;
        }
        final stale = latest != null && latest.isBefore(weekStart);
        out.add(
          DriverEval(
            config: c,
            status: sessions > cap
                ? DriverStatus.violated
                : stale || latest == null
                    ? DriverStatus.pending
                    : DriverStatus.met,
            value: '${sessions.round()}/≤${cap.round()}',
            staleAsOf: stale ? latest : null,
          ),
        );

      case 'bike_4x4':
        final sessions = <DateTime>{
          for (final d in inputs.cardioDates)
            if (inWeek(d)) _day(d),
        }.length;
        final t = c.target ?? 1;
        out.add(
          DriverEval(
            config: c,
            status: sessions >= t ? DriverStatus.met : DriverStatus.pending,
            value: frac(sessions, t),
          ),
        );

      default:
        // Unknown id — newer config, older app. Skip, never error.
        break;
    }
  }
  return out;
}
