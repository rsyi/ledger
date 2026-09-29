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
///   top_single_per_lift  each listed lift gets its top-set READING
///                        this week (working-max controller extraction
///                        — the ground truth of "top stimulus
///                        happened": heavy_top / saturday_single /
///                        capped / test all tick, light_week never
///                        does; ANY reps — the user's codified rule,
///                        2026-09-25: "a heavy single every two weeks,
///                        a lighter stimulus on alternate weeks").
///                        Squat/deadlift ticks carry the alternation
///                        parity tag (heavy/light expected this week,
///                        from planned_alternation's anchor Monday),
///                        and `heavy_single_max_days` adds the
///                        every-two-weeks heavy-exposure recency line
///                        (a ≤2-rep reading at RPE ≥ 7.5; amber past
///                        the config, red a week later). When no
///                        readings source is plumbed the tick falls
///                        back to the legacy §2.5 near-max criterion.
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
///   dual_exposure        v9 (post-cut-recomp-spec): each listed lift
///                        needs BOTH a heavy exposure (a top-set
///                        reading, same rule as top_single_per_lift)
///                        and a hypertrophy exposure (≥ `hyp_sets_min`
///                        logged sets with reps inside `hyp_reps`)
///                        this week — two half-ticks per lift.
///   hypertrophy_volume   v9: per-muscle-group weekly productive sets
///                        vs the `band` (8-12), overlap-counted from
///                        strength rows + climbing sessions +
///                        calisthenics via the program's declared
///                        exercise_muscle_map. Under the band mid-week
///                        is pending; OVER the top is violated (the
///                        excess-pulling caution).
///
/// Pure Dart, no Flutter, no IO — the strip UI stays layout-only.
library;

import 'package:yaml/yaml.dart';

import 'program_metrics.dart'
    show GradedSet, anchorMondayOf, mainLiftByExercise, weekStartOf;

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

  /// protein_floor v9: ABSOLUTE daily floor in grams (post-cut recomp:
  /// 160). Wins over [floorGPerLb] when declared.
  final double? floorG;

  /// protein_floor v9: the absolute target band ([160, 175]) — display
  /// context; the floor is the gate.
  final List<double>? bandG;

  /// hypertrophy_volume: the per-muscle weekly set band ([8, 12]).
  final List<double>? band;

  /// hypertrophy_volume: the muscle groups the band is evaluated
  /// against (v9 hypertrophy_targets.muscle_groups).
  final List<String> muscleGroups;

  /// dual_exposure: minimum hypertrophy sets per lift per week (def 3).
  final int? hypSetsMin;

  /// dual_exposure: the rep range that counts as hypertrophy work
  /// (def [3, 8]).
  final List<int>? hypReps;

  /// top_single_per_lift: the every-two-weeks heavy rule (2026-09-25).
  /// A HEAVY exposure (reading with reps ≤ 2 at RPE ≥ 7.5) must exist
  /// within this many trailing days for squat/deadlift; the eval's
  /// [DriverEval.heavyRecency] line goes amber past it and red a week
  /// later. Null → no recency tracking.
  final int? heavySingleMaxDays;

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
    this.floorG,
    this.bandG,
    this.band,
    this.muscleGroups = const [],
    this.hypSetsMin,
    this.hypReps,
    this.heavySingleMaxDays,
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
      List<double>? numPair(Object? v) =>
          v is List && v.length == 2 && v.every((e) => e is num)
              ? [(v[0] as num).toDouble(), (v[1] as num).toDouble()]
              : null;
      final groups = d['muscle_groups'];
      final hypReps = numPair(d['hyp_reps']);
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
          floorG: (d['floor_g'] as num?)?.toDouble(),
          bandG: numPair(d['band_g']),
          band: numPair(d['band']),
          muscleGroups: groups is List
              ? [for (final g in groups) g.toString()]
              : const [],
          hypSetsMin: (d['hyp_sets_min'] as num?)?.toInt(),
          hypReps: hypReps == null
              ? null
              : [hypReps[0].toInt(), hypReps[1].toInt()],
          heavySingleMaxDays: (d['heavy_single_max_days'] as num?)?.toInt(),
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

  /// This week's alternation expectation for the lift — 'heavy' /
  /// 'light' (squat/deadlift under planned_alternation), null for
  /// non-alternating lifts or when no anchor is declared. Display
  /// only: a light-week top set still ticks.
  final String? parity;

  const DriverTick({
    required this.lift,
    required this.count,
    required this.target,
    this.parity,
  });

  bool get done => count >= target;
}

/// One top-set reading the singles driver evaluates — a thin projection
/// of the working-max controller's readings (tab rows + the app's live
/// extraction for not-yet-evaluated days). Kept local so this lib stays
/// dependency-free.
class TopSetReading {
  final DateTime date;

  /// squat | bench | deadlift | press.
  final String lift;

  /// heavy_top | saturday_single | test | light_week | capped.
  final String kind;
  final int reps;
  final double rpe;

  const TopSetReading({
    required this.date,
    required this.lift,
    required this.kind,
    required this.reps,
    required this.rpe,
  });
}

/// Freshness band of a lift's newest HEAVY exposure vs the config's
/// `heavy_single_max_days`: fresh ≤ max, overdue (amber) past it —
/// including "no qualifying reading yet" (unknown, not violated) —
/// stale (red) a week past that.
enum HeavySingleBand { fresh, overdue, stale }

/// The every-two-weeks heavy rule, per alternating lift: days since the
/// newest reading with reps ≤ 2 at RPE ≥ 7.5 (null = none recorded).
class HeavySingleRecency {
  final String lift;
  final int? daysAgo;
  final HeavySingleBand band;

  const HeavySingleRecency({
    required this.lift,
    required this.daysAgo,
    required this.band,
  });
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

  /// top_single_per_lift's every-two-weeks heavy rule — one entry per
  /// alternating lift (squat/deadlift) when `heavy_single_max_days` is
  /// configured and a readings source is plumbed; the strip renders it
  /// as the secondary line under the singles pills.
  final List<HeavySingleRecency> heavyRecency;

  const DriverEval({
    required this.config,
    required this.status,
    required this.value,
    this.ticks = const [],
    this.staleAsOf,
    this.heavyRecency = const [],
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
        'dual_exposure': 'lifts',
        // Clarity pass 2026-09-29 (user: '"hyp sets" is very
        // confusing'): plain words, no abbreviation.
        'hypertrophy_volume': 'muscle sets',
      }[config.id] ??
      config.id;
}

/// One logged strength SET (one row) — the raw material the v9
/// hypertrophy/dual-exposure counters read. Deliberately thinner than
/// GradedSet: counting needs the exercise NAME (the muscle map is
/// name-keyed and covers accessories/calisthenics the §2.5 grader
/// ignores) and the reps.
class LoggedSet {
  final DateTime date;
  final String exercise;
  final int reps;

  const LoggedSet({
    required this.date,
    required this.exercise,
    required this.reps,
  });
}

/// The v9 exercise → muscle-group credit map (program.yaml
/// `exercise_muscle_map`): per-SET fractional credits per group, plus
/// the per-SESSION climbing credits. Parsed by [parseExerciseMuscleMap].
class MuscleMap {
  /// Exact logged exercise name → {group: credit}. Lookup is exact
  /// first, then longest declared PREFIX ("Muscle Up Purple Band"
  /// counts under "Muscle Up").
  final Map<String, Map<String, double>> exercises;

  /// One climbing session's credits ({back: 3, forearms: 3, ...}).
  final Map<String, double> climbingSession;

  const MuscleMap({
    required this.exercises,
    this.climbingSession = const {},
  });

  /// Credits for a logged [exercise] name, or null when unmapped.
  Map<String, double>? creditsFor(String exercise) {
    final exact = exercises[exercise];
    if (exact != null) return exact;
    String? bestKey;
    for (final key in exercises.keys) {
      if (exercise.startsWith(key) &&
          (bestKey == null || key.length > bestKey.length)) {
        bestKey = key;
      }
    }
    return bestKey == null ? null : exercises[bestKey];
  }
}

/// Parses a program VERSION map's `exercise_muscle_map` (v9). Null when
/// absent/malformed — the hypertrophy driver then reports pending.
MuscleMap? parseExerciseMuscleMap(Map<Object?, Object?>? version) {
  final raw = version?['exercise_muscle_map'];
  if (raw is! Map) return null;
  Map<String, double> credits(Object? m) => m is Map
      ? {
          for (final e in m.entries)
            if (e.value is num) e.key.toString(): (e.value as num).toDouble(),
        }
      : const {};
  final exercises = raw['exercises'];
  if (exercises is! Map) return null;
  return MuscleMap(
    exercises: {
      for (final e in exercises.entries)
        e.key.toString(): credits(e.value),
    },
    climbingSession: credits(raw['climbing_session']),
  );
}

/// Already-fetched observations the evaluators read. All dates may be
/// full timestamps — evaluation normalizes to calendar days.
class WeekDriverInputs {
  /// §2.5 graded sets over FULL history (so references match the
  /// nightly tab); evaluation filters to the accounting week.
  final List<GradedSet> graded;

  /// Working-max controller readings (tab + live extraction), the
  /// singles driver's source of truth since 2026-09-25. NULL (as
  /// opposed to empty) = no readings source plumbed → the tick falls
  /// back to the legacy §2.5 near-max criterion on [graded].
  final List<TopSetReading>? readings;

  /// planned_alternation's anchor Monday (program.yaml) — even whole
  /// weeks since it = A week (squat heavy + deadlift light), odd = B.
  /// Null → no parity tags.
  final DateTime? alternationAnchorMonday;

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

  /// ALL logged strength rows (one per set, any exercise) — the v9
  /// hypertrophy/dual-exposure counters' source. Includes calisthenics
  /// rows (they live in the strength view).
  final List<LoggedSet> strengthSets;

  /// The program's declared exercise → muscle-group credit map (v9).
  /// Null → hypertrophy_volume reports pending.
  final MuscleMap? muscleMap;

  const WeekDriverInputs({
    this.graded = const [],
    this.readings,
    this.alternationAnchorMonday,
    this.climbingDates = const [],
    this.cardioDates = const [],
    this.proteinByDay = const {},
    this.bodyweightLb,
    this.strengthSets = const [],
    this.muscleMap,
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
        final readings = inputs.readings;

        // Weekly tick (codified 2026-09-25): a top-set READING exists
        // for the lift this accounting week — the controller's own
        // extraction is the ground truth of "top stimulus happened".
        // Any reps, any kind except light_week (a capped or Saturday
        // single is still top stimulus; a deload single is not). The
        // user's rule: heavy every two weeks, a lighter stimulus is
        // fine on alternate weeks — so §2.5 near-max grading no longer
        // gates the tick. Legacy fallback when no readings source.
        bool ticked(String lift) => readings != null
            ? readings.any(
                (r) =>
                    r.lift == lift &&
                    r.kind != 'light_week' &&
                    inWeek(r.date),
              )
            : inputs.graded.any(
                (s) => s.lift == lift && s.nearMax && inWeek(s.date),
              );

        // Parity tag: this week's side of the squat/deadlift heavy ↔
        // light alternation. Program STRUCTURE is Monday-anchored, so
        // the accounting week's parity is its contained Monday's whole
        // weeks since the anchor — even (incl. 0) = A = squat heavy +
        // deadlift light (planned_alternation note), matching the week
        // planner's a/b resolution.
        String? parityOf(String lift) {
          final anchor = inputs.alternationAnchorMonday;
          if (anchor == null) return null;
          if (lift != 'squat' && lift != 'deadlift') return null;
          final monday = anchorMondayOf(weekStart);
          final weeks = DateTime.utc(monday.year, monday.month, monday.day)
                  .difference(
                    DateTime.utc(anchor.year, anchor.month, anchor.day),
                  )
                  .inDays ~/
              7;
          final aWeek = weeks.isEven;
          return (lift == 'squat') == aWeek ? 'heavy' : 'light';
        }

        final ticks = <DriverTick>[
          for (final lift in lifts)
            DriverTick(
              lift: lift,
              count: ticked(lift) ? 1 : 0,
              target: 1,
              parity: parityOf(lift),
            ),
        ];

        // The every-two-weeks heavy rule, tracked per alternating lift:
        // days since the newest HEAVY exposure (reps ≤ 2 at RPE ≥ 7.5,
        // weights already variant-converted upstream). Amber past
        // `heavy_single_max_days`, red a week later; "never recorded"
        // is unknown → amber, not violated.
        final heavy = <HeavySingleRecency>[];
        final maxDays = c.heavySingleMaxDays;
        if (maxDays != null && readings != null) {
          for (final lift in const ['squat', 'deadlift']) {
            if (!lifts.contains(lift)) continue;
            DateTime? last;
            for (final r in readings) {
              if (r.lift != lift ||
                  r.kind == 'light_week' ||
                  r.reps > 2 ||
                  r.rpe < 7.5) {
                continue;
              }
              final day = _day(r.date);
              if (_daysBetween(day, today) < 0) continue; // future
              if (last == null || day.isAfter(last)) last = day;
            }
            final days = last == null ? null : _daysBetween(last, today);
            heavy.add(
              HeavySingleRecency(
                lift: lift,
                daysAgo: days,
                band: days == null
                    ? HeavySingleBand.overdue
                    : days <= maxDays
                        ? HeavySingleBand.fresh
                        : days <= maxDays + 7
                            ? HeavySingleBand.overdue
                            : HeavySingleBand.stale,
              ),
            );
          }
        }

        final done = ticks.where((t) => t.done).length;
        out.add(
          DriverEval(
            config: c,
            status: done >= lifts.length
                ? DriverStatus.met
                : DriverStatus.pending,
            value: frac(done, lifts.length),
            ticks: ticks,
            heavyRecency: heavy,
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
        final avg = days == 0 ? null : sum / days;
        // v9: an ABSOLUTE floor_g (post-cut recomp 160-175 g/day) wins
        // over the per-lb floor when declared — no bodyweight needed.
        if (c.floorG != null) {
          out.add(
            DriverEval(
              config: c,
              status: avg == null
                  ? DriverStatus.pending
                  : avg >= c.floorG!
                      ? DriverStatus.met
                      : DriverStatus.violated,
              value: avg == null ? '— g' : '${avg.round()} g',
            ),
          );
          break;
        }
        final bw = inputs.bodyweightLb;
        final gPerLb =
            avg == null || bw == null || bw <= 0 ? null : avg / bw;
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

      // v9 (post-cut-recomp-spec): each main lift needs BOTH a heavy
      // exposure (a top-set reading — same ground truth as
      // top_single_per_lift) and a hypertrophy exposure (≥ hyp_sets_min
      // sets in the hyp_reps range) every week. Two half-ticks per
      // lift; a heavy triple double-counts into the hypertrophy half by
      // design (reps 3 sits in both bands).
      case 'dual_exposure':
        final lifts = c.lifts.isEmpty ? _defaultLifts : c.lifts;
        final hypMin = c.hypSetsMin ?? 3;
        final repsLo = c.hypReps == null ? 3 : c.hypReps![0];
        final repsHi = c.hypReps == null ? 8 : c.hypReps![1];
        final readings = inputs.readings ?? const <TopSetReading>[];
        bool heavy(String lift) => readings.any(
              (r) =>
                  r.lift == lift &&
                  r.kind != 'light_week' &&
                  inWeek(r.date),
            );
        int hypSets(String lift) => inputs.strengthSets
            .where(
              (s) =>
                  mainLiftByExercise[s.exercise] == lift &&
                  s.reps >= repsLo &&
                  s.reps <= repsHi &&
                  inWeek(s.date),
            )
            .length;
        final ticks = <DriverTick>[
          for (final lift in lifts)
            DriverTick(
              lift: lift,
              count: (heavy(lift) ? 1 : 0) +
                  (hypSets(lift) >= hypMin ? 1 : 0),
              target: 2,
            ),
        ];
        final done = ticks.fold<int>(0, (n, t) => n + t.count);
        out.add(
          DriverEval(
            config: c,
            status: ticks.every((t) => t.done)
                ? DriverStatus.met
                : DriverStatus.pending,
            value: frac(done, lifts.length * 2),
            ticks: ticks,
          ),
        );

      // v9: weekly productive sets per muscle group vs the 8-12 band,
      // overlap-counted from strength rows (incl. calisthenics) +
      // climbing sessions via the program's exercise_muscle_map. Under
      // the band mid-week = pending (never punitive); OVER the top =
      // violated (the excess-pulling caution). No map plumbed →
      // pending with no ticks (a newer config on an older program
      // can't count honestly).
      case 'hypertrophy_volume':
        final map = inputs.muscleMap;
        final band = c.band ?? const [8.0, 12.0];
        final lo = band[0] <= band[1] ? band[0] : band[1];
        final hi = band[0] <= band[1] ? band[1] : band[0];
        if (map == null) {
          out.add(
            DriverEval(
              config: c,
              status: DriverStatus.pending,
              value: '— sets',
            ),
          );
          break;
        }
        final groups = c.muscleGroups.isNotEmpty
            ? c.muscleGroups
            : {
                for (final m in map.exercises.values) ...m.keys,
              }.toList();
        final counts = {for (final g in groups) g: 0.0};
        for (final s in inputs.strengthSets) {
          if (!inWeek(s.date)) continue;
          final credits = map.creditsFor(s.exercise);
          if (credits == null) continue;
          for (final e in credits.entries) {
            if (counts.containsKey(e.key)) {
              counts[e.key] = counts[e.key]! + e.value;
            }
          }
        }
        final climbSessions = <DateTime>{
          for (final d in inputs.climbingDates)
            if (inWeek(d)) _day(d),
        }.length;
        for (final e in map.climbingSession.entries) {
          if (counts.containsKey(e.key)) {
            counts[e.key] = counts[e.key]! + climbSessions * e.value;
          }
        }
        final ticks = <DriverTick>[
          for (final g in groups)
            DriverTick(
              lift: g,
              count: counts[g]!.round(),
              target: lo.round(),
            ),
        ];
        final over = counts.values.any((v) => v.round() > hi);
        final inBand = ticks.where((t) => t.done).length;
        out.add(
          DriverEval(
            config: c,
            status: over
                ? DriverStatus.violated
                : inBand == groups.length
                    ? DriverStatus.met
                    : DriverStatus.pending,
            value: frac(inBand, groups.length),
            ticks: ticks,
          ),
        );

      default:
        // Unknown id — newer config, older app. Skip, never error.
        break;
    }
  }
  return out;
}
