/// projection_replay.dart — assembles a block's FROZEN projection from
/// raw history using ONLY the data available on the block's start day
/// (the forecast_calibration replay pattern: re-run the model from a
/// past anchor, anchored to the actuals then). The nightly writer
/// (tool/program_status_update.dart) calls this at a block's first
/// nightly run; the same path backfilled block 0 (cut, 2026-09-21).
///
/// What "available then" means here:
///   * every history input (weigh-ins, body fat, strength, climbs,
///     meals) is filtered to rows dated ON OR BEFORE the block's start
///     day — the anchors and the nutrition estimate never see later
///     data;
///   * training maxes = the working_max rows effective on that day;
///   * the recalibration state (forecast_meta scales + maintenance
///     offset) is NOT historized, so a REPLAYED snapshot (made more than
///     a day after the block started) runs the un-recalibrated FITTED
///     params and no maintenance offset — tonight's scales were learned
///     from data after the anchor. A snapshot made on the block's first
///     nightly run uses the scales in force that night.
///   * the program calendar and the model are today's (recorded as
///     program_version / model_version in inputs_json).
///
/// Pure Dart (no Flutter, no IO).
library;

import 'nutrition_model.dart'
    show
        buildNutritionForecast,
        nutritionDays,
        nutritionWindowAvg;
import 'program_metrics.dart' show StrengthRow, WeightRow;
import 'projection_snapshot.dart';
import 'projection_tracking.dart';
import 'recomp_review.dart' show MealRow;
import 'sim2_harness.dart';
import 'sim2_model.dart';
import 'sim_fit.dart' show ClimbAscent;
import 'wm_tabs.dart' show WorkingMaxRow, workingMaxAsOf;

/// A snapshot made more than this many days after the block's start is
/// a replay (see the library note).
const int projectionReplayAfterDays = 1;

DateTime _d(DateTime d) => DateTime.utc(d.year, d.month, d.day);

bool _onOrBefore(DateTime x, DateTime day) => !_d(x).isAfter(_d(day));

/// Minimum logged nutrition days before a snapshot trusts the
/// logged-intake rate over the declared block rate.
const int projectionMinLoggedDays = 14;

/// The trailing window those logged days are counted in — the 14-day
/// INTAKE window the logged-intake rate's numerator is averaged over
/// (r = (14d avg intake − maintenance)/3500×7). So the rule reads
/// "every day of the intake window logged": block 0's thin-data r came
/// from 6 of 14 (18 of the 28-day maintenance window — counting there
/// would have kept the thin rate). Strict by design; a missed export
/// day falls back to the declared rate for that freeze.
const int projectionLoggedDaysWindowDays = 14;

/// Rate-source wire values (inputs_json `rate_source`).
const String projectionRateDeclared = 'declared';
const String projectionRateLoggedIntake = 'logged_intake';

/// THE RULE: 'logged_intake' only when the nutrition model can project
/// AND [loggedDays] ≥ [projectionMinLoggedDays]; else 'declared'.
String projectionRateSource({
  required int loggedDays,
  required bool canProject,
}) => canProject && loggedDays >= projectionMinLoggedDays
    ? projectionRateLoggedIntake
    : projectionRateDeclared;

/// Logged days (≥ 800 kcal) in the trailing
/// [projectionLoggedDaysWindowDays] ending on [anchor] (inclusive).
int projectionLoggedDaysAt(List<MealRow> meals, DateTime anchor) =>
    nutritionWindowAvg(
      nutritionDays(meals),
      today: anchor,
      windowDays: projectionLoggedDaysWindowDays,
    )?.loggedDays ??
    0;

/// Builds block [blockN]'s snapshot anchored at its start day. Null
/// when the block isn't in [blocks]. [baselineVersion] / [supersedes] /
/// [rebaselineReason] mark a USER re-baseline (projection_snapshot.dart
/// [maxBaselineVersionForBlock]); a system freeze passes the block's
/// current max baseline_version.
ProjectionSnapshot? snapshotAtBlockStart({
  required List<Sim2Block> blocks,
  required int blockN,
  required DateTime madeAt,
  required String programVersion,
  List<WeightRow> weighIns = const [],
  List<BodyFatReading> bodyFat = const [],
  List<StrengthRow> strength = const [],
  List<ClimbAscent> climbs = const [],
  List<MealRow> meals = const [],
  List<WorkingMaxRow> workingMax = const [],
  double aScale = 1,
  double bScale = 1,
  double maintenanceOffsetKcal = 0,
  int mcPaths = 200,
  int baselineVersion = 1,
  DateTime? supersedes,
  String? rebaselineReason,
}) {
  final i = blocks.indexWhere((b) => b.n == blockN);
  if (i < 0) return null;
  final block = blocks[i];
  final anchor = _d(block.start);
  final replay =
      _d(madeAt).difference(anchor).inDays > projectionReplayAfterDays;

  final w = [
    for (final r in weighIns)
      if (_onOrBefore(r.date, anchor)) r,
  ];
  final bf = [
    for (final r in bodyFat)
      if (_onOrBefore(r.date, anchor)) r,
  ];
  final s = [
    for (final r in strength)
      if (_onOrBefore(r.date, anchor)) r,
  ];
  final c = [
    for (final r in climbs)
      if (_onOrBefore(r.date, anchor)) r,
  ];
  final m = [
    for (final r in meals)
      if (_onOrBefore(r.eatenAt, anchor)) r,
  ];

  final e1rm = e1rmActualsAt(s, anchor);
  final anchors = ProjectionAnchors(
    bodyweight: bodyweightActualAt(w, anchor),
    bodyFat: bodyFatActualAt(bf, anchor),
    climbingGrade: climbingActualAt(c, anchor),
    e1rm: e1rm,
  );

  final useA = replay ? 1.0 : aScale;
  final useB = replay ? 1.0 : bScale;
  final useOffset = replay ? 0.0 : maintenanceOffsetKcal;
  final params = Sim2Params.fitted()
    ..a *= useA
    ..b *= useB;

  final nutrition = buildNutritionForecast(
    meals: m,
    weighIns: w,
    today: anchor,
  ).withMaintenanceOffset(useOffset);
  final bwForP = anchors.bodyweight ?? sim2SeedBw;
  final loggedDays = projectionLoggedDaysAt(m, anchor);
  final rateSource = projectionRateSource(
    loggedDays: loggedDays,
    canProject: nutrition.canProject,
  );
  final useLogged = rateSource == projectionRateLoggedIntake;
  // Protein follows the same gate: thin logging drives neither dial
  // (null → the block's baseline protein).
  final r = useLogged ? nutrition.rProjectedLbWk : null;
  final p = useLogged ? nutrition.proteinGPerLb(bwForP) : null;

  double? r0(double? v) => v?.roundToDouble();
  final tms = <String, double>{
    for (final lift in ProjectionMetric.lifts)
      if (workingMaxAsOf(workingMax, lift, anchor) != null)
        lift: workingMaxAsOf(workingMax, lift, anchor)!,
  };

  return buildProjectionSnapshot(
    params: params,
    blocks: blocks,
    blockN: blockN,
    anchors: anchors,
    madeAt: madeAt,
    programVersion: programVersion,
    rLbWk: r,
    proteinGPerLb: p,
    mcPaths: mcPaths,
    extraInputs: {
      'made_at': madeAt.toIso8601String(),
      'replay': replay,
      'data_through': _ymd(anchor),
      'training_maxes': tms,
      'nutrition': {
        'intake_14d_kcal': r0(nutrition.avg14?.kcal),
        'protein_14d_g': r0(nutrition.avg14?.proteinG),
        'carbs_14d_g': r0(nutrition.avg14?.carbsG),
        'logged_days_14d': nutrition.avg14?.loggedDays,
        'maintenance_kcal': r0(nutrition.maintenance?.kcal),
        'maintenance_band_kcal': r0(nutrition.maintenance?.bandKcal),
        'maintenance_method': nutrition.maintenance?.method,
        'maintenance_paired_days': nutrition.maintenance?.pairedDays,
        'maintenance_offset_kcal': useOffset.round(),
        'can_project': nutrition.canProject,
      },
      'a_scale': useA,
      'b_scale': useB,
      'rate_source': rateSource,
      'rate_logged_days': loggedDays,
      'rate_logged_days_window': projectionLoggedDaysWindowDays,
      'rate_min_logged_days': projectionMinLoggedDays,
      'rate_logged_intake_lb_wk': nutrition.canProject
          ? double.parse(nutrition.rProjectedLbWk!.toStringAsFixed(2))
          : null,
      'baseline_version': baselineVersion,
      'supersedes': ?supersedes?.toIso8601String(),
      'rebaseline_reason': ?rebaselineReason,
    },
  );
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
