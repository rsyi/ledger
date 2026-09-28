/// Working-max controller — spec
/// `docs/superpowers/specs/2026-09-21-working-max-controller-spec.md`
/// (airledger repo), extending the coach intent-layers spec §2.5.
///
/// Pure Dart — no Flutter, no IO. Policies / chart / variants are DECLARED
/// in `coach/program.yaml` v5 (`load_policies`, `rpe_chart`, `variants`);
/// this lib carries matching constants for the chart + variants (pinned to
/// the YAML by test) and parses policies straight from the YAML map.
/// e1RM source of truth is the airlayer measure `max_e1rm_capped`
/// (strength_tracker.view.yml): Epley with reps capped at 12 —
/// [program_metrics.epleyE1rm] matches it.
///
/// The TypeScript twin of [evaluate] will live in ledger-mcp; keep the two
/// in lockstep via shared fixture traces.
library;

import 'program_metrics.dart' show StrengthRow, epleyE1rm, mainLiftByExercise;

// ---------------------------------------------------------------------------
// §1.3 RPE chart — fraction of working max by RPE x reps
// ---------------------------------------------------------------------------

/// Chart values as FRACTIONS (spec table is in percent). Reps columns:
/// 1,2,3,4,5,6,8 for RPE 6..10 in 0.5 steps (RPE 7 x 8 = 0.707).
final Map<double, Map<int, double>> rpeChartPct = {
  10: {1: 1.000, 2: .955, 3: .922, 4: .892, 5: .863, 6: .837, 8: .786},
  9.5: {1: .978, 2: .939, 3: .907, 4: .878, 5: .850, 6: .824, 8: .774},
  9: {1: .955, 2: .922, 3: .892, 4: .863, 5: .837, 6: .811, 8: .762},
  8.5: {1: .939, 2: .907, 3: .878, 4: .850, 5: .824, 6: .799, 8: .751},
  8: {1: .922, 2: .892, 3: .863, 4: .837, 5: .811, 6: .786, 8: .739},
  7.5: {1: .907, 2: .878, 3: .850, 4: .824, 5: .799, 6: .774, 8: .723},
  7: {1: .892, 2: .863, 3: .837, 4: .811, 5: .786, 6: .762, 8: .707},
  6.5: {1: .878, 2: .850, 3: .824, 4: .799, 5: .774, 6: .751, 8: .694},
  6: {1: .863, 2: .837, 3: .811, 4: .786, 5: .762, 6: .739, 8: .680},
};

/// Fraction of working max for a [rpe] x [reps] set. Inside the chart the
/// table value is used verbatim; outside it falls back to inverted Epley:
/// `pct = 1 / (1 + (reps + (10 - rpe)) / 30)`.
double rpePct(double rpe, int reps) {
  final v = rpeChartPct[rpe]?[reps];
  if (v != null) return v;
  return 1 / (1 + (reps + (10 - rpe)) / 30);
}

/// Implied max of a set: `weight / chart[rpe][reps]` (spec §1.2).
double impliedMax(double weightLb, int reps, double rpe) =>
    weightLb / rpePct(rpe, reps);

/// Rounds DOWN to the nearest 5 (test resets: wm = weight/0.922 round
/// DOWN 5).
double roundDown5(num x) => (x / 5).floor() * 5.0;

num _roundTo(num x, num step) {
  final r = (x / step).round() * step;
  return r == r.roundToDouble() ? r.round() : r;
}

// ---------------------------------------------------------------------------
// §1.4 variants
// ---------------------------------------------------------------------------

/// Default variant per lift.
const Map<String, String> defaultVariantByLift = {
  'bench': 'paused',
  'squat': 'belted',
  'deadlift': 'belted',
  'press': 'standard',
};

/// Conversion percents per lift (variant strength delta vs the lift's
/// default). Convert an observed weight to default-variant terms by
/// dividing by `1 + pct/100`. A parsed keyword ABSENT from its lift's map
/// has no conversion -> VARIANT_MISMATCH. Mirrors program.yaml v5
/// `variants` (pinned by test).
const Map<String, Map<String, double>> variantConversions = {
  'bench': {'paused': 0, 'pins': 0, 'touch_and_go': 3},
  'squat': {'belted': 0, 'unbelted': -3, 'paused': -3},
  'deadlift': {'belted': 0, 'unbelted': -4, 'straps': 0, 'double_overhand': 0},
  'press': {'standard': 0},
};

/// Which keywords are VARIANT-bearing per lift. Keywords outside a
/// lift's set are gear/context notes and are ignored (extraction-rule
/// interpretation, 2026-09-21: "straps, paused" on BENCH means wrist
/// straps — §7.1 expects that reading to drop, not VARIANT_MISMATCH;
/// straps only change anything on deadlift, belts never matter on
/// bench/press). A keyword in scope but with no conversion entry (e.g.
/// paused deadlift, pin squat) is a real variant we can't convert ->
/// VARIANT_MISMATCH.
const Map<String, Set<String>> parsedKeywordsByLift = {
  'bench': {'paused', 'pins', 'touch_and_go'},
  'squat': {'paused', 'pins', 'belted', 'unbelted'},
  'deadlift': {
    'belted',
    'unbelted',
    'straps',
    'double_overhand',
    'paused',
    'pins',
    'touch_and_go',
  },
  'press': {},
};

final Map<String, RegExp> _variantKeywords = {
  'touch_and_go': RegExp(r'touch[\s&-]*(and|n|&)[\s-]*go|\btng\b',
      caseSensitive: false),
  'double_overhand': RegExp(r'double[\s-]?over\s?hand', caseSensitive: false),
  'unbelted': RegExp(r'\bunbelted\b|\bbeltless\b|no belt', caseSensitive: false),
  'belted': RegExp(r'\bbelted\b|\bbelt\b', caseSensitive: false),
  'paused': RegExp(r'\bpaused?\b', caseSensitive: false),
  'pins': RegExp(r'\bpins?\b', caseSensitive: false),
  'straps': RegExp(r'\bstraps?\b', caseSensitive: false),
};

/// Result of parsing a lift's variant out of a row's notes.
class VariantResult {
  /// Parsed variant name (the lift's default when no keyword matched;
  /// multiple keywords join with `+`, e.g. `belted+paused`).
  final String variant;

  /// Divide the observed weight by this to express it in the lift's
  /// default variant (`touch_and_go` bench -> 1.03). 1.0 when default.
  final double factor;

  /// True when a keyword matched but the lift has no conversion for it —
  /// the controller must hold and prompt instead of guessing (§2).
  final bool mismatch;

  const VariantResult(this.variant, this.factor, this.mismatch);
}

/// Parses the §1.4 variant for [lift] out of [notes], optionally
/// overridden by the STRUCTURED equipment flags (sheet columns
/// Paused/Belted, 2026-09-21). Unknown text -> the lift's default.
/// Distinct matched conversions multiply, but default-equivalent
/// keywords contribute 1.0, so "belted, paused" squat is a single -3%
/// (never stacked).
///
/// Structured precedence: a non-null [belted]/[paused] REPLACES whatever
/// the notes said within its own keyword domain (belted ⇒
/// {belted, unbelted}; paused ⇒ {paused} + bench's {touch_and_go}) —
/// notes keep feeding every other keyword (straps, pins, ...). Null =
/// legacy row, notes-only, unchanged behavior:
///   belted: true  -> 'belted';  false -> 'unbelted'
///   paused: true  -> 'paused';  false -> bench: 'touch_and_go'
///                               (not-paused IS touch-and-go on bench);
///                               other lifts: the default, no keyword.
/// Out-of-scope structured values (e.g. belted on bench) are ignored,
/// matching the notes-keyword scoping rule.
VariantResult parseVariant(
  String lift,
  String? notes, {
  bool? paused,
  bool? belted,
}) {
  final def = defaultVariantByLift[lift] ?? 'default';
  final text = notes ?? '';
  final scope = parsedKeywordsByLift[lift] ?? const <String>{};

  final matched = <String>[];
  if (text.trim().isNotEmpty) {
    var scan = text;
    for (final e in _variantKeywords.entries) {
      if (e.value.hasMatch(scan)) {
        // Remove matches even when out of scope so 'unbelted' never
        // double-counts as 'belted' and 'double overhand' doesn't re-match.
        scan = scan.replaceAll(e.value, ' ');
        if (scope.contains(e.key)) matched.add(e.key);
      }
    }
  }

  // Structured overrides — remove the domain's notes keywords, then add
  // the keyword the flag implies (when in scope for this lift).
  if (belted != null) {
    matched.removeWhere((k) => k == 'belted' || k == 'unbelted');
    final kw = belted ? 'belted' : 'unbelted';
    if (scope.contains(kw)) matched.add(kw);
  }
  if (paused != null) {
    matched.removeWhere(
      (k) => k == 'paused' || (lift == 'bench' && k == 'touch_and_go'),
    );
    if (paused) {
      if (scope.contains('paused')) matched.add('paused');
    } else if (lift == 'bench') {
      // Explicit not-paused bench is touch-and-go by definition.
      matched.add('touch_and_go');
    }
  }

  if (matched.isEmpty) return VariantResult(def, 1.0, false);

  final conversions = variantConversions[lift] ?? const {};
  var factor = 1.0;
  for (final kw in matched) {
    final pct = conversions[kw];
    if (pct == null) return VariantResult(matched.join('+'), 1.0, true);
    factor *= 1 + pct / 100;
  }
  return VariantResult(matched.join('+'), factor, false);
}

// ---------------------------------------------------------------------------
// §1.2 readings
// ---------------------------------------------------------------------------

/// One top-set reading (spec §1.2): the day's heaviest RPE-logged set of a
/// main lift.
class Reading {
  final DateTime date;

  /// squat | bench | deadlift | press.
  final String lift;

  /// Parsed variant (shown in app for correction).
  final String variant;

  /// Weight CONVERTED to the lift's default variant (raw / factor).
  final double weightLb;

  /// The weight as logged.
  final double rawWeightLb;
  final int reps;
  final double rpe;

  /// heavy_top | saturday_single | test | light_week | capped.
  final String kind;

  /// rpe >= 9.5 or notes match /grind|slow|stall|miss/.
  final bool grinder;

  /// reps < prescribed (false when nothing was prescribed).
  final bool missed;

  /// Variant keyword with no conversion -> controller holds + prompts.
  final bool variantMismatch;

  const Reading({
    required this.date,
    required this.lift,
    required this.variant,
    required this.weightLb,
    required this.rawWeightLb,
    required this.reps,
    required this.rpe,
    required this.kind,
    required this.grinder,
    required this.missed,
    required this.variantMismatch,
  });

  /// weight / chart[rpe][reps], on the CONVERTED weight.
  double get impliedMax => weightLb / rpePct(rpe, reps);
}

final RegExp _grinderNotes =
    RegExp(r'grind|slow|stall|miss', caseSensitive: false);

/// Reading kind from week type + day + controller state (spec §1.2 "from
/// week type + day template"):
///   light week -> light_week; test week -> test; an active top-set cap
///   (post-drop / pain) -> capped; Saturday bench/squat when the policy
///   prescribes Saturday singles -> saturday_single; else heavy_top.
String classifyKind({
  required String lift,
  required DateTime date,
  String? weekType,
  bool capActive = false,
  bool saturdaySingle = false,
}) {
  if (weekType == 'light') return 'light_week';
  if (weekType == 'test') return 'test';
  if (capActive) return 'capped';
  if (saturdaySingle &&
      date.weekday == DateTime.saturday &&
      (lift == 'bench' || lift == 'squat')) {
    return 'saturday_single';
  }
  return 'heavy_top';
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Extracts §1.2 readings from strength rows: per (day, main lift), the
/// heaviest row WITH an RPE (ties: more reps wins — higher e1rm). Rows
/// without RPE (warm-ups) and non-main lifts never produce readings.
/// [kindOf] supplies the kind (see [classifyKind]); [prescribedReps]
/// drives `missed` when the day had a prescription.
List<Reading> extractReadings(
  List<StrengthRow> rows, {
  required String Function(DateTime date, String lift) kindOf,
  int? Function(DateTime date, String lift)? prescribedReps,
}) {
  final best = <String, StrengthRow>{};
  final order = <String>[];
  for (final r in rows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || r.rpe == null) continue;
    final key = '${_day(r.date).toIso8601String()}|$lift';
    final cur = best[key];
    if (cur == null) {
      best[key] = r;
      order.add(key);
    } else if (r.weight > cur.weight ||
        (r.weight == cur.weight &&
            epleyE1rm(r.weight, r.reps) > epleyE1rm(cur.weight, cur.reps))) {
      best[key] = r;
    }
  }
  final readings = <Reading>[
    for (final key in order)
      _toReading(best[key]!, kindOf, prescribedReps),
  ]..sort((a, b) => a.date.compareTo(b.date));
  return readings;
}

Reading _toReading(
  StrengthRow r,
  String Function(DateTime, String) kindOf,
  int? Function(DateTime, String)? prescribedReps,
) {
  final lift = mainLiftByExercise[r.exercise]!;
  final day = _day(r.date);
  // Structured equipment flags win over notes keywords when present
  // (post-hardening rows); legacy rows fall back to notes-only parsing.
  final variant =
      parseVariant(lift, r.notes, paused: r.paused, belted: r.belted);
  final prescribed = prescribedReps?.call(day, lift);
  return Reading(
    date: day,
    lift: lift,
    variant: variant.variant,
    weightLb: r.weight / variant.factor,
    rawWeightLb: r.weight,
    reps: r.reps,
    rpe: r.rpe!,
    kind: kindOf(day, lift),
    grinder: r.rpe! >= 9.5 ||
        (r.notes != null && _grinderNotes.hasMatch(r.notes!)),
    missed: prescribed != null && r.reps < prescribed,
    variantMismatch: variant.mismatch,
  );
}

// ---------------------------------------------------------------------------
// §1.5 load policy
// ---------------------------------------------------------------------------

/// One load policy from program.yaml v5 `load_policies` (spec §1.5/§3).
class LoadPolicy {
  final String name;
  final double targetRpeLow;
  final double targetRpeHigh;

  /// Null = no raises (cut_late / reverse / climbing / light / test).
  final double? raiseIfRpeLte;

  /// cut_early's twice-in-a-row rule = 2; single-session raises = 1.
  final int raiseRequiresConsecutive;
  final List<double>? holdBand;
  final double? dropIfRpeGte;
  final Map<String, num> stepLb;
  final bool frozen;
  final double? capRpe;
  final double? capAfterDropRpe;
  final String? consecutiveDropsAction;
  final List<String> readingsThatRaise;
  final List<String> readingsThatLower;
  final bool resetOnTest;

  /// Light week: readings recorded + ignored (not even drops).
  final bool readingsIgnored;

  /// Whether the phase prescribes the Saturday RPE-8.5 single.
  final bool saturdaySingle;

  /// Applicability ({block}/{blocks}/{dates}/{week_type}) — see
  /// [policyForDate].
  final Map<Object?, Object?> applies;

  const LoadPolicy({
    required this.name,
    required this.targetRpeLow,
    required this.targetRpeHigh,
    required this.raiseIfRpeLte,
    required this.raiseRequiresConsecutive,
    required this.holdBand,
    required this.dropIfRpeGte,
    required this.stepLb,
    required this.frozen,
    required this.capRpe,
    required this.capAfterDropRpe,
    required this.consecutiveDropsAction,
    required this.readingsThatRaise,
    required this.readingsThatLower,
    required this.resetOnTest,
    required this.readingsIgnored,
    required this.saturdaySingle,
    required this.applies,
  });

  factory LoadPolicy.fromMap(Map m) {
    double? numOf(Object? v) => v is num ? v.toDouble() : null;
    final target = m['target_rpe'];
    final targetLow = target is List
        ? numOf(target.first)!
        : numOf(target) ?? 8;
    final targetHigh = target is List
        ? numOf(target.last)!
        : numOf(target) ?? 8;
    return LoadPolicy(
      name: m['name'].toString(),
      targetRpeLow: targetLow,
      targetRpeHigh: targetHigh,
      raiseIfRpeLte: numOf(m['raise_if_rpe_lte']),
      raiseRequiresConsecutive:
          (m['raise_requires_consecutive'] as num?)?.toInt() ?? 1,
      holdBand: m['hold_band'] is List
          ? [for (final v in m['hold_band'] as List) (v as num).toDouble()]
          : null,
      dropIfRpeGte: numOf(m['drop_if_rpe_gte']),
      stepLb: m['step_lb'] is Map
          ? {
              for (final e in (m['step_lb'] as Map).entries)
                e.key.toString(): e.value as num,
            }
          : const {'bench': 5, 'press': 5, 'squat': 5, 'deadlift': 5},
      frozen: m['frozen'] == true,
      capRpe: numOf(m['cap_rpe']),
      capAfterDropRpe: numOf(m['cap_after_drop_rpe']),
      consecutiveDropsAction: m['consecutive_drops_action']?.toString(),
      readingsThatRaise: [
        for (final v in (m['readings_that_raise'] as List? ?? const []))
          v.toString(),
      ],
      readingsThatLower: [
        for (final v in (m['readings_that_lower'] as List? ?? const []))
          v.toString(),
      ],
      resetOnTest: m['reset_on']?.toString() == 'test',
      readingsIgnored: m['readings_ignored'] == true,
      saturdaySingle: m['saturday_single'] == true,
      applies: m['applies'] is Map
          ? Map<Object?, Object?>.from(m['applies'] as Map)
          : const {},
    );
  }
}

/// Parses `load_policies` from a program VERSION map (the result of
/// `currentVersion(programYaml)`).
List<LoadPolicy> loadPolicies(Map<Object?, Object?> version) {
  final raw = version['load_policies'];
  if (raw is! List) return const [];
  return [
    for (final p in raw)
      if (p is Map) LoadPolicy.fromMap(p),
  ];
}

DateTime _parseDay(Object? s) {
  final d = DateTime.parse(s.toString());
  return DateTime.utc(d.year, d.month, d.day);
}

/// Selects the policy in force for [date]: week type first (light/test
/// weeks override the block policy), then block number, then the policy's
/// date window (the block-0 cut_early/cut_late split at Nov 16).
LoadPolicy? policyForDate(
  List<LoadPolicy> policies, {
  required DateTime date,
  int? block,
  String? weekType,
}) {
  for (final p in policies) {
    if (weekType != null && p.applies['week_type'] == weekType) return p;
  }
  if (weekType == 'light' || weekType == 'test') return null;
  final day = DateTime.utc(date.year, date.month, date.day);
  for (final p in policies) {
    if (p.applies.containsKey('week_type')) continue;
    final single = p.applies['block'];
    final many = p.applies['blocks'];
    final blocks = <int>[
      if (single is num) single.toInt(),
      if (many is List) ...[for (final b in many) (b as num).toInt()],
    ];
    if (block == null || !blocks.contains(block)) continue;
    final dates = p.applies['dates'];
    if (dates is List && dates.length >= 2) {
      final start = _parseDay(dates[0]);
      final end = _parseDay(dates[1]);
      if (day.isBefore(start) || day.isAfter(end)) continue;
    }
    return p;
  }
  return null;
}

// ---------------------------------------------------------------------------
// §2 controller
// ---------------------------------------------------------------------------

/// One controller evaluation (append-only history; also the state carrier
/// for the twice-in-a-row raise rule, consecutive drops, and pain-cap
/// clean-session counting — pass prior decisions back in).
class WmDecision {
  final DateTime date;
  final String lift;

  /// raise | hold | drop | freeze | reset | manual.
  final String action;
  final double wmBefore;
  final double wmAfter;

  /// rule | test | manual | pain_cap.
  final String source;
  final String reason;

  /// RPE cap for the NEXT top set (after a drop, or 7 under a pain cap).
  final double? capNextTopSetRpe;

  /// Two drops in a row -> consecutive_drops_action.
  final bool noTopSetsNextWeek;

  /// This evaluation's reading qualified toward a raise streak (only
  /// meaningful on holds; a raise consumes the streak).
  final bool raiseEligible;

  /// NO_READING / VARIANT_MISMATCH / TWO_SIGNALS / PAIN_CAP /
  /// PAIN_CAP_CLEAN / PAIN_CAP_LIFTED.
  final List<String> flags;
  final Reading? reading;

  const WmDecision({
    required this.date,
    required this.lift,
    required this.action,
    required this.wmBefore,
    required this.wmAfter,
    required this.source,
    required this.reason,
    this.capNextTopSetRpe,
    this.noTopSetsNextWeek = false,
    this.raiseEligible = false,
    this.flags = const [],
    this.reading,
  });
}

/// Lifts a pain note freezes (spec §2): back -> squat + deadlift;
/// elbow / finger -> press + bench. Empty when the note names neither.
List<String> painCapLiftsForNote(String note) {
  final t = note.toLowerCase();
  final out = <String>[];
  if (t.contains('back')) out.addAll(['squat', 'deadlift']);
  if (t.contains('elbow') || t.contains('finger')) {
    out.addAll(['press', 'bench']);
  }
  return out;
}

/// Evaluates one lift against its policy (spec §2). Called after every
/// reading-creating log and nightly.
///
/// Overrides run FIRST, in spec order: PAIN_CAP, TWO_SIGNALS,
/// VARIANT_MISMATCH, MANUAL. Then: no reading (two readingless weeks ->
/// NO_READING flag), test reset, light week (recorded + ignored), the
/// drop rule (grinder / missed / rpe >= drop threshold — runs even when
/// the policy is frozen), frozen -> hold, and finally the raise rule
/// (kind in readings_that_raise, rpe <= raise threshold; cut_early needs
/// TWO qualifying readings in a row — the streak lives on
/// [WmDecision.raiseEligible] of the last prior decision and is consumed
/// by a raise or broken by anything else).
WmDecision evaluate({
  required String lift,
  required LoadPolicy policy,
  required double workingMax,
  required DateTime date,
  Reading? reading,
  List<WmDecision> priorDecisions = const [],
  bool painCapActive = false,
  bool twoSignalsThisWeek = false,
  double? manualValue,
  String? manualReason,
  int weeksWithoutReading = 0,
}) {
  final wm = workingMax;
  final prior = priorDecisions.isEmpty ? null : priorDecisions.last;
  WmDecision decision({
    required String action,
    required double wmAfter,
    String source = 'rule',
    required String reason,
    double? capNextTopSetRpe,
    bool noTopSetsNextWeek = false,
    bool raiseEligible = false,
    List<String> flags = const [],
  }) =>
      WmDecision(
        date: date,
        lift: lift,
        action: action,
        wmBefore: wm,
        wmAfter: wmAfter,
        source: source,
        reason: reason,
        capNextTopSetRpe: capNextTopSetRpe,
        noTopSetsNextWeek: noTopSetsNextWeek,
        raiseEligible: raiseEligible,
        flags: flags,
        reading: reading,
      );

  // --- Overrides, checked first (spec §2 order) ---
  if (painCapActive) {
    final clean = reading != null &&
        (reading.kind == 'heavy_top' || reading.kind == 'capped') &&
        !reading.grinder &&
        !reading.missed &&
        (policy.dropIfRpeGte == null || reading.rpe < policy.dropIfRpeGte!);
    final priorClean = prior?.flags.contains('PAIN_CAP_CLEAN') ?? false;
    final lifted = clean && priorClean;
    return decision(
      action: 'freeze',
      wmAfter: wm,
      source: 'pain_cap',
      capNextTopSetRpe: 7,
      flags: [
        'PAIN_CAP',
        if (clean) 'PAIN_CAP_CLEAN',
        if (lifted) 'PAIN_CAP_LIFTED',
      ],
      reason: lifted
          ? 'pain cap: second consecutive clean heavy session — cap lifts '
              'after today'
          : clean
              ? 'pain cap: frozen at RPE cap 7 (1 of 2 clean heavy sessions)'
              : 'pain cap: frozen at RPE cap 7 until two consecutive clean '
                  'heavy sessions',
    );
  }
  if (twoSignalsThisWeek) {
    return decision(
      action: 'freeze',
      wmAfter: wm,
      flags: const ['TWO_SIGNALS'],
      reason: 'TWO_SIGNALS fired this week — all lifts frozen this week',
    );
  }
  if (reading != null && reading.variantMismatch) {
    return decision(
      action: 'hold',
      wmAfter: wm,
      flags: const ['VARIANT_MISMATCH'],
      reason: 'variant "${reading.variant}" has no conversion for $lift — '
          'holding; confirm the variant in the app',
    );
  }
  if (manualValue != null) {
    return decision(
      action: 'manual',
      wmAfter: manualValue,
      source: 'manual',
      reason: manualReason ?? 'manual set_working_max',
    );
  }

  // --- No reading ---
  if (reading == null) {
    final flag = weeksWithoutReading >= 2;
    return decision(
      action: 'hold',
      wmAfter: wm,
      flags: flag ? const ['NO_READING'] : const [],
      reason: flag
          ? 'no reading for $weeksWithoutReading consecutive weeks'
          : 'no new reading — hold',
    );
  }

  // --- Test reset ---
  if (reading.kind == 'test' && policy.resetOnTest) {
    final next = roundDown5(reading.weightLb / 0.922);
    return decision(
      action: 'reset',
      wmAfter: next,
      source: 'test',
      reason: 'test single ${reading.weightLb.toStringAsFixed(0)} / 0.922 '
          '→ $next (round down 5)',
    );
  }

  // --- Light week: recorded + ignored ---
  if (reading.kind == 'light_week' || policy.readingsIgnored) {
    return decision(
      action: 'hold',
      wmAfter: wm,
      reason: 'light week — reading recorded and ignored',
    );
  }

  final step = (policy.stepLb[lift] ?? 5).toDouble();

  // --- Drop rule (runs even when frozen) ---
  final dropSignal = reading.grinder ||
      reading.missed ||
      (policy.dropIfRpeGte != null && reading.rpe >= policy.dropIfRpeGte!);
  if (policy.readingsThatLower.contains(reading.kind) && dropSignal) {
    final consecutive = prior?.action == 'drop';
    final why = reading.grinder
        ? 'grinder'
        : reading.missed
            ? 'missed prescribed reps'
            : 'rpe ${reading.rpe} >= ${policy.dropIfRpeGte}';
    return decision(
      action: 'drop',
      wmAfter: wm - step,
      capNextTopSetRpe: policy.capAfterDropRpe,
      noTopSetsNextWeek:
          consecutive && policy.consecutiveDropsAction == 'no_top_sets_next_week',
      reason: '$why → ${wm - step}; next top set capped at RPE '
          '${policy.capAfterDropRpe}'
          '${consecutive ? '; second drop in a row → '
              '${policy.consecutiveDropsAction}' : ''}',
    );
  }

  // --- Frozen: only the drop rule above runs ---
  if (policy.frozen) {
    return decision(
      action: 'hold',
      wmAfter: wm,
      reason: '${policy.name} is frozen — hold',
    );
  }

  // --- Raise rule ---
  final qualifies = policy.raiseIfRpeLte != null &&
      policy.readingsThatRaise.contains(reading.kind) &&
      reading.rpe <= policy.raiseIfRpeLte!;
  if (qualifies) {
    final streakMet = policy.raiseRequiresConsecutive <= 1 ||
        (prior?.raiseEligible ?? false);
    if (streakMet) {
      return decision(
        action: 'raise',
        wmAfter: wm + step,
        reason: 'rpe ${reading.rpe} <= ${policy.raiseIfRpeLte}'
            '${policy.raiseRequiresConsecutive > 1 ? ' twice in a row' : ''}'
            ' → ${wm + step}',
      );
    }
    return decision(
      action: 'hold',
      wmAfter: wm,
      raiseEligible: true,
      reason: 'rpe ${reading.rpe} <= ${policy.raiseIfRpeLte} (1 of '
          '${policy.raiseRequiresConsecutive} in a row) — hold',
    );
  }

  return decision(
    action: 'hold',
    wmAfter: wm,
    reason: 'rpe ${reading.rpe} in/near hold band — hold',
  );
}

// ---------------------------------------------------------------------------
// Replay (acceptance §7.1 + tool/wm_replay.dart)
// ---------------------------------------------------------------------------

/// Replays one lift's strength rows through the controller from [seedWm]:
/// extracts the day-top readings, threads prior decisions, and applies the
/// post-drop cap to the NEXT reading's kind (`capped`). [policyFor] picks
/// the policy per reading date; [weekTypeOf] (when given) marks light/test
/// weeks for kind classification.
List<WmDecision> replayLift({
  required String lift,
  required double seedWm,
  required List<StrengthRow> rows,
  required LoadPolicy Function(DateTime date) policyFor,
  String? Function(DateTime date)? weekTypeOf,
  int? Function(DateTime date, String lift)? prescribedReps,
}) {
  final liftRows = [
    for (final r in rows)
      if (mainLiftByExercise[r.exercise] == lift) r,
  ];
  // Extract with a placeholder kind, then reclassify while replaying (the
  // capped kind depends on the previous decision).
  final base = extractReadings(
    liftRows,
    kindOf: (_, _) => 'heavy_top',
    prescribedReps: prescribedReps,
  );

  final decisions = <WmDecision>[];
  var wm = seedWm;
  var capActive = false;
  for (final r in base) {
    final policy = policyFor(r.date);
    final kind = classifyKind(
      lift: lift,
      date: r.date,
      weekType: weekTypeOf?.call(r.date),
      capActive: capActive,
      saturdaySingle: policy.saturdaySingle,
    );
    final reading = Reading(
      date: r.date,
      lift: r.lift,
      variant: r.variant,
      weightLb: r.weightLb,
      rawWeightLb: r.rawWeightLb,
      reps: r.reps,
      rpe: r.rpe,
      kind: kind,
      grinder: r.grinder,
      missed: r.missed,
      variantMismatch: r.variantMismatch,
    );
    final d = evaluate(
      lift: lift,
      policy: policy,
      workingMax: wm,
      date: r.date,
      reading: reading,
      priorDecisions: decisions,
    );
    decisions.add(d);
    wm = d.wmAfter;
    // A drop caps the NEXT top set only.
    capActive = d.action == 'drop' && d.capNextTopSetRpe != null;
  }
  return decisions;
}

// ---------------------------------------------------------------------------
// §4 prescription
// ---------------------------------------------------------------------------

/// Advisory prescription for the next heavy session (spec §4).
class Prescription {
  final String lift;
  final String policyName;
  final String variant;
  final double workingMax;

  /// Warm-up ramp toward the top single (program v4/v5 warmup_protocol).
  final List<({num weight, num reps})> warmups;

  /// Top-set options: reps (1/2/3) -> weight at the policy target RPE.
  final Map<int, num> topSetOptions;
  final int backOffSets;
  final int backOffReps;

  /// 4x3 at 82% (mid of the 81–83% band), rounded.
  final num backOffWeight;

  /// Saturday single at RPE 8.5 — null where the policy omits it
  /// (cut_late / reverse / climbing_block / light / test).
  final num? saturdaySingle;

  /// Last readings with their decisions (most recent last, max three).
  final List<WmDecision> lastDecisions;

  const Prescription({
    required this.lift,
    required this.policyName,
    required this.variant,
    required this.workingMax,
    required this.warmups,
    required this.topSetOptions,
    required this.backOffSets,
    required this.backOffReps,
    required this.backOffWeight,
    required this.saturdaySingle,
    required this.lastDecisions,
  });
}

/// Warm-up ramp steps for [lift] toward [topWeight], from a program
/// `warmup_protocol` map (v4 semantics, shared with the week planner —
/// fixed `weight_lb` steps pass through; `pct_top` steps are rounded to
/// `rounding_lb` and dropped unless strictly above `min_above_lb` when
/// declared). Null/malformed protocol -> no rows.
List<({num weight, num reps})> warmupRamp(
  Object? warmupProtocol,
  String? lift,
  num topWeight,
) {
  if (warmupProtocol is! Map) return const [];
  final rounding = warmupProtocol['rounding_lb'] is num
      ? warmupProtocol['rounding_lb'] as num
      : 5;
  final steps =
      (lift != null ? warmupProtocol[lift] : null) ?? warmupProtocol['default'];
  if (steps is! List) return const [];
  final out = <({num weight, num reps})>[];
  for (final step in steps) {
    if (step is! Map) continue;
    final reps = step['reps'];
    if (reps is! num) continue;
    num? w;
    if (step['weight_lb'] is num) {
      w = step['weight_lb'] as num;
    } else if (step['pct_top'] is num) {
      w = _roundTo((step['pct_top'] as num) * topWeight, rounding);
      final minAbove = step['min_above_lb'];
      if (minAbove is num && w <= minAbove) continue; // deadlift 135 rule
    } else {
      continue;
    }
    out.add((weight: w, reps: reps));
  }
  return out;
}

/// Builds the §4 prescription: top-set options for 1/2/3 reps from the
/// chart at the policy's target RPE (upper end of the range, undercut by
/// [activeCapRpe] when a cap is in force), back-offs 4x3 at 82%, the
/// Saturday 8.5 single where the policy allows, and the warm-up ramp
/// toward the top single. Rounds to 5 lb (2.5 for bench/press with
/// [microplates]).
///
/// Strength wave (program.yaml v10): when [topReps] is given, the week
/// prescribes exactly ONE top-set rep count (the wave's 5/3/1) —
/// topSetOptions carries only that entry, priced off the same chart at
/// the same policy target, and the warm-up ramps toward it.
///
/// Cut wave (program.yaml v11 `strength_wave_cut`): [topPct] prices the
/// single [topReps] option DIRECTLY at working max × min(topPct,
/// chart[target][reps]) — the declared wave pcts for weeks 1-3 equal
/// chart[8][reps] (0.811/0.837/0.863, cut_early's upper target), the
/// deload's 0.70 undercuts it, and any active RPE cap (pain cap /
/// post-drop / cut_late's 7) still wins via the min. Ignored without
/// [topReps].
Prescription buildPrescription({
  required String lift,
  required LoadPolicy policy,
  required double workingMax,
  Object? warmupProtocol,
  double? activeCapRpe,
  bool microplates = false,
  int? topReps,
  double? topPct,
  List<WmDecision> recentDecisions = const [],
}) {
  final rounding =
      microplates && (lift == 'bench' || lift == 'press') ? 2.5 : 5;
  var target = policy.targetRpeHigh;
  if (activeCapRpe != null && activeCapRpe < target) target = activeCapRpe;
  if (policy.capRpe != null && policy.capRpe! < target) {
    target = policy.capRpe!;
  }

  double fracFor(int reps) {
    final chart = rpePct(target, reps);
    if (topPct == null || topReps == null) return chart;
    return topPct < chart ? topPct : chart;
  }

  final repOptions = topReps != null ? [topReps] : const [1, 2, 3];
  final topSetOptions = <int, num>{
    for (final reps in repOptions)
      reps: _roundTo(workingMax * fracFor(reps), rounding),
  };
  final backOffWeight = _roundTo(workingMax * 0.82, rounding);
  final saturdaySingle = policy.saturdaySingle
      ? _roundTo(workingMax * rpePct(8.5, 1), rounding)
      : null;
  final warmups = warmupRamp(
      warmupProtocol, lift, topSetOptions[topReps ?? 1]!);
  final last = recentDecisions.length <= 3
      ? recentDecisions
      : recentDecisions.sublist(recentDecisions.length - 3);
  return Prescription(
    lift: lift,
    policyName: policy.name,
    variant: defaultVariantByLift[lift] ?? 'default',
    workingMax: workingMax,
    warmups: warmups,
    topSetOptions: topSetOptions,
    backOffSets: 4,
    backOffReps: 3,
    backOffWeight: backOffWeight,
    saturdaySingle: saturdaySingle,
    lastDecisions: last,
  );
}
