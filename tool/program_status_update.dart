// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:airledger/services/forecast_tab.dart';
import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_metrics.dart';
import 'package:airledger/services/recomp_review.dart';
import 'package:airledger/services/week_drivers.dart'
    show TopSetReading, parseExerciseMuscleMap;
import 'package:airledger/services/sim_fit.dart'
    show buildWeeklySeries, climbsFromTab;
import 'package:airledger/services/sim_program.dart' show simInitialFromSeries;
import 'package:airledger/services/sim2_harness.dart';
import 'package:airledger/services/sim2_model.dart' show Sim2Params;
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/services/working_max.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:yaml/yaml.dart';

/// Nightly program-status compute + write for the coach outcome layer.
///
/// Reads FULL strength + weight + 4x4 + kaya_ascents + daily_notes history
/// from the workbook, runs gradeSets → weeklyRollup → evaluateFlags (with
/// programCurrent for weeks >= the program effective date), and writes:
///   • program_status tab — one row per ISO week, 2024-01-01 forward.
///   • coach_flags tab   — one row per flag fired in the last 8 ISO weeks,
///                         acknowledged values preserved by (id, fired_on).
///   • working_max + readings tabs — APPEND-ONLY (never rewritten): new
///     §1.2 readings since the last run are evaluated chronologically
///     through the WM-1 controller (lib/services/working_max.dart via
///     runWmChain) and appended together with any working-max changes.
///     When the working_max tab is empty/missing, the §5 seed rows land
///     first (source=seed, confirmed=false — the app's "Working maxes"
///     card confirms them; the deadlift seed carries its pain_cap marker).
///     program_status rows gain `working_max_&lt;lift&gt;` (end of week) +
///     wm_decisions columns.
///
/// Modes:
///   dart run tool/program_status_update.dart           # full update (writes tabs)
///   dart run tool/program_status_update.dart --brief   # print top-3 rows + open
///                                                        flags as markdown, no write
///   dart run tool/program_status_update.dart --dry-run # compute but no write
///   dart run tool/program_status_update.dart --weekly-brief
///     # print THIS Mon-Sun week's recomp weekly review markdown
///     # (recomp_review.dart), no writes — coach_nightly.sh injects it
///     # into the Sunday briefing prompt.
///   --weekly  # force the weekly_review tab write on a non-Sunday
///
/// Weekly review (recomp tracking spec 2026-09-27): full runs on
/// SUNDAYS (or --weekly) also rewrite the `weekly_review` tab — one row
/// per Mon-Sun week (last 8, newest first) with the generated markdown.
/// The MCP get_weekly_review tool and the coach read that tab.
///
/// Wire into coach_nightly.sh BEFORE the briefing prompt is assembled.

// ---------------------------------------------------------------------------
// Config / API (backtest pattern)
// ---------------------------------------------------------------------------

final home = Platform.environment['HOME']!;
final configPath = '$home/.config/airledger/config.yaml';
final coachDir = '$home/repos/airledger-fitness/coach';

Future<void> main(List<String> args) async {
  final brief = args.contains('--brief');
  final weeklyBrief = args.contains('--weekly-brief');
  final forceWeekly = args.contains('--weekly');
  final dryRun = args.contains('--dry-run') || args.contains('--dry');

  final config = readConfig();
  final api = await sheetsApi(config.keyPath);

  Future<List<List<Object?>>> tab(String name) async {
    try {
      final resp = await api.spreadsheets.values.get(
        config.spreadsheetId,
        "'$name'",
      );
      return resp.values ?? [];
    } on gsheets.DetailedApiRequestError catch (e) {
      if (e.status == 400) return [];
      rethrow;
    }
  }

  if (!brief && !weeklyBrief) print('reading tabs ...');

  final strengthTab = await tab('strength');
  final weightTab = await tab('weight');
  final cardioTab = await tab('4x4');
  final climbTab = await tab('kaya_ascents');
  final notesTab = await tab('daily_notes');
  // Recomp weekly review sources (tracking spec 2026-09-27). Both may
  // be missing/empty (calisthenics tab appears on the app's first sync
  // after the schema lands) — tab() returns [] and the review says
  // "no data" honestly.
  final mealsTab = await tab('meals');
  final calisthenicsTab = await tab('calisthenics');

  // -------------------------------------------------------------------------
  // Map sheet rows → metrics inputs
  // -------------------------------------------------------------------------
  final anomalies = <String, int>{};
  void anomaly(String kind) => anomalies[kind] = (anomalies[kind] ?? 0) + 1;

  final sHead = headerIndex(strengthTab);
  final strengthRows = <StrengthRow>[];
  for (final r in strengthTab.skip(1)) {
    if (r.isEmpty) { anomaly('strength: empty row'); continue; }
    final date = parseSheetDate(cell(r, sHead['Date']));
    if (date == null) { anomaly('strength: missing Date'); continue; }
    final exercise = cell(r, sHead['Exercise']);
    if (exercise.isEmpty) { anomaly('strength: empty Exercise'); continue; }
    final weight = double.tryParse(cell(r, sHead['Weight']));
    final reps = double.tryParse(cell(r, sHead['Reps']));
    if (mainLiftByExercise.containsKey(exercise) &&
        (weight == null || reps == null)) {
      anomaly('strength: main lift missing weight/reps');
      continue;
    }
    final rpeText = cell(r, sHead['RPE']);
    final rpe = rpeText.isEmpty ? null : double.tryParse(rpeText);
    final notes = cell(r, sHead['Notes']);
    strengthRows.add(StrengthRow(
      date: date,
      exercise: exercise,
      weight: weight ?? 0,
      reps: (reps ?? 0).round(),
      rpe: rpe,
      // Notes feed the working-max chain (variant + grinder parsing).
      notes: notes.isEmpty ? null : notes,
      // Structured equipment flags (2026-09-21 hardening) — the variant
      // parser prefers these over notes keywords when present.
      paused: boolCell(cell(r, sHead['Paused'])),
      belted: boolCell(cell(r, sHead['Belted'])),
    ));
  }

  final wHead = headerIndex(weightTab);
  final weightRows = <WeightRow>[];
  for (final r in weightTab.skip(1)) {
    final date = parseSheetDate(cell(r, wHead['date']));
    final lbs = double.tryParse(cell(r, wHead['weight_lbs']));
    if (date == null || lbs == null) {
      anomaly('weight: missing date or weight_lbs');
      continue;
    }
    weightRows.add(WeightRow(date: date, weightLbs: lbs));
  }

  final cHead = headerIndex(cardioTab);
  final fourByFours = <FourByFourRow>[];
  for (final r in cardioTab.skip(1)) {
    final date = parseSheetDate(cell(r, cHead['Date']));
    if (date == null) { anomaly('4x4: missing Date'); continue; }
    final type = cell(r, cHead['Type']).toLowerCase();
    if (type.isNotEmpty &&
        !const {'treadmill', 'bike', 'stairmaster'}.contains(type)) {
      anomaly('4x4: non-4x4 row excluded (type=$type)');
      continue;
    }
    final speed = double.tryParse(cell(r, cHead['Treadmill Speed'])) ??
        double.tryParse(cell(r, cHead['Stairmaster Speed']));
    fourByFours.add(FourByFourRow(
      date: date,
      maxHr: double.tryParse(cell(r, cHead['Max Heart Rate'])),
      workRateOrSpeed: speed,
    ));
  }

  final kHead = headerIndex(climbTab);
  final climbingDates = <DateTime>[];
  for (final r in climbTab.skip(1)) {
    final date = parseSheetDate(cell(r, kHead['date']));
    if (date == null) { anomaly('kaya_ascents: missing date'); continue; }
    climbingDates.add(date);
  }

  // daily_notes: read `cause` column if present (PAIN_NOTE) + the note
  // text (the working-max chain scans it for pain-capped lifts/regions).
  final nHead = headerIndex(notesTab);
  final noteRows = <DailyNoteRow>[];
  for (final r in notesTab.skip(1)) {
    final date = parseSheetDate(cell(r, nHead['date']));
    if (date == null) continue;
    final cause = nHead.containsKey('cause')
        ? (cell(r, nHead['cause']).isEmpty ? null : cell(r, nHead['cause']))
        : null;
    final text = cell(r, nHead['note']);
    noteRows.add(DailyNoteRow(
        date: date, cause: cause, note: text.isEmpty ? null : text));
  }

  if (!brief && !weeklyBrief) {
    print('  ${strengthRows.length} strength rows, ${weightRows.length} '
        'weigh-ins, ${fourByFours.length} 4x4 rows, '
        '${climbingDates.length} climb ascents, ${noteRows.length} notes');
    for (final e in anomalies.entries) {
      print('  anomaly: ${e.value}x ${e.key}');
    }
  }

  // -------------------------------------------------------------------------
  // Load program.yaml + phase.yaml for resolvers
  // -------------------------------------------------------------------------
  Map<Object?, Object?>? programYaml;
  Map<Object?, Object?>? phaseYaml;

  final programFile = File('$coachDir/program.yaml');
  if (programFile.existsSync()) {
    final parsed = loadYaml(programFile.readAsStringSync());
    if (parsed is Map) programYaml = Map<Object?, Object?>.from(parsed);
  }

  final phaseFile = File('$coachDir/phase.yaml');
  if (phaseFile.existsSync()) {
    final parsed = loadYaml(phaseFile.readAsStringSync());
    if (parsed is Map) phaseYaml = Map<Object?, Object?>.from(parsed);
  }

  // Program effective date: first block start of the current program version.
  DateTime? programEffectiveDate;
  if (programYaml != null) {
    final ver = currentVersion(programYaml);
    if (ver != null) {
      final blocks = ver['blocks'];
      if (blocks is List && blocks.isNotEmpty && blocks.first is Map) {
        final dates = (blocks.first as Map)['dates'];
        if (dates is List && dates.isNotEmpty) {
          final d = DateTime.tryParse(dates.first.toString());
          if (d != null) programEffectiveDate = DateTime.utc(d.year, d.month, d.day);
        }
      }
    }
  }

  // Accounting-week start (program.yaml v7 `week_start` — saturday since
  // the 2026-09-22 amendment). Keys the rollup + flag weeks; program
  // STRUCTURE (week_type, targets) stays Monday-anchored and accounting
  // weeks resolve onto it via anchorMondayOf (the contained Monday).
  final wsDay = weekStartDayOf(
      programYaml == null ? null : currentVersion(programYaml));

  String? Function(DateTime) weekTypeResolver = (m) => null;
  Map<String, Object?>? Function(DateTime) targetsResolver = (m) => null;
  if (programYaml != null && programEffectiveDate != null) {
    final py = programYaml; // non-null: inside `programYaml != null` guard
    final effDate = programEffectiveDate;
    weekTypeResolver = (DateTime weekStartDate) {
      // effDate is captured from programEffectiveDate which is non-null here.
      final anchor = anchorMondayOf(weekStartDate);
      if (anchor.isBefore(effDate)) return null;
      final slice = programCurrent(py, phaseYaml, anchor);
      return slice?.weekType;
    };
    // Phase-aware flag thresholds: hand evaluateFlags the week's
    // targets_in_force (block-0 cut targets via v6 targets_block_0).
    // Pre-program weeks stay null → legacy backtest thresholds.
    targetsResolver = (DateTime weekStartDate) {
      final anchor = anchorMondayOf(weekStartDate);
      if (anchor.isBefore(effDate)) return null;
      return programCurrent(py, phaseYaml, anchor)?.targetsInForce;
    };
  }

  String? Function(DateTime) phaseResolver = (m) => null;
  if (phaseYaml != null) {
    phaseResolver = (DateTime monday) {
      final ver = currentVersion(phaseYaml!);
      return ver?['value']?.toString();
    };
  }

  // -------------------------------------------------------------------------
  // Recomp weekly review inputs (tracking spec 2026-09-27). Assembled
  // once from the tabs above; Mon-Sun weeks — recomp_review.dart's
  // header documents why this is NOT the Saturday accounting week.
  // -------------------------------------------------------------------------
  DateTime? parseSheetDateTime(String s) =>
      s.isEmpty ? null : (DateTime.tryParse(s) ?? parseSheetDate(s));

  final mHead = headerIndex(mealsTab);
  final mealRows = <MealRow>[];
  for (final r in mealsTab.skip(1)) {
    final dt = parseSheetDateTime(cell(r, mHead['eaten_at']));
    if (dt == null) continue;
    mealRows.add(MealRow(
      eatenAt: dt,
      calories: double.tryParse(cell(r, mHead['calories'])),
      proteinG: double.tryParse(cell(r, mHead['protein_g'])),
      carbsG: double.tryParse(cell(r, mHead['carbs_g'])),
      fatG: double.tryParse(cell(r, mHead['fat_g'])),
    ));
  }

  final reviewSets = <ReviewSet>[];
  for (final r in strengthTab.skip(1)) {
    final date = parseSheetDate(cell(r, sHead['Date']));
    final exercise = cell(r, sHead['Exercise']);
    if (date == null || exercise.isEmpty) continue;
    final st = cell(r, sHead['Set Type']);
    reviewSets.add(ReviewSet(
      date: date,
      exercise: exercise,
      reps: double.tryParse(cell(r, sHead['Reps']))?.round() ?? 0,
      weight: double.tryParse(cell(r, sHead['Weight'])) ?? 0,
      rpe: double.tryParse(cell(r, sHead['RPE'])),
      setType: st.isEmpty ? null : st,
    ));
  }

  final caHead = headerIndex(calisthenicsTab);
  final caliRows = <CalisthenicsRow>[];
  for (final r in calisthenicsTab.skip(1)) {
    final date = parseSheetDate(cell(r, caHead['date']));
    final skill = cell(r, caHead['skill']);
    if (date == null || skill.isEmpty) continue;
    caliRows.add(CalisthenicsRow(
      date: date,
      skill: skill,
      variation: cell(r, caHead['variation']).isEmpty
          ? null
          : cell(r, caHead['variation']),
      sets: double.tryParse(cell(r, caHead['sets']))?.round(),
      reps: double.tryParse(cell(r, caHead['reps']))?.round(),
      holdSeconds: double.tryParse(cell(r, caHead['hold_seconds'])),
      clean: boolCell(cell(r, caHead['clean'])),
      rpe: double.tryParse(cell(r, caHead['rpe'])),
    ));
  }

  final reviewClimbs = <ClimbRow>[];
  for (final r in climbTab.skip(1)) {
    final date = parseSheetDate(cell(r, kHead['date']));
    if (date == null) continue;
    reviewClimbs.add(ClimbRow(
      date: date,
      grade: cell(r, kHead['grade']),
      ascentType: cell(r, kHead['ascent_type']),
    ));
  }

  final review4x4s = <Cardio4x4Row>[];
  for (final r in cardioTab.skip(1)) {
    final date = parseSheetDate(cell(r, cHead['Date']));
    if (date == null) continue;
    final type = cell(r, cHead['Type']).toLowerCase();
    if (type.isNotEmpty &&
        !const {'treadmill', 'bike', 'stairmaster'}.contains(type)) {
      continue; // same 4x4 filter as the rollup above
    }
    review4x4s.add(Cardio4x4Row(
      date: date,
      speed: double.tryParse(cell(r, cHead['Treadmill Speed'])) ??
          double.tryParse(cell(r, cHead['Stairmaster Speed'])),
      incline: double.tryParse(cell(r, cHead['Treadmill Incline'])),
      maxHr: double.tryParse(cell(r, cHead['Max Heart Rate'])),
      completedIntervals:
          double.tryParse(cell(r, cHead['Completed Intervals'])),
    ));
  }

  final recoveryRows = <RecoveryRow>[];
  for (final r in notesTab.skip(1)) {
    final date = parseSheetDate(cell(r, nHead['date']));
    if (date == null) continue;
    final pain = cell(r, nHead['pain']);
    recoveryRows.add(RecoveryRow(
      date: date,
      sleepHours: double.tryParse(cell(r, nHead['sleep_hours'])),
      sleepQuality: double.tryParse(cell(r, nHead['sleep_quality'])),
      fatigue: double.tryParse(cell(r, nHead['fatigue'])),
      soreness: double.tryParse(cell(r, nHead['soreness'])),
      readiness: double.tryParse(cell(r, nHead['readiness'])),
      pain: pain.isEmpty ? null : pain,
      note: cell(r, nHead['note']).isEmpty ? null : cell(r, nHead['note']),
    ));
  }

  final bodyRows = <BodyRow>[];
  for (final r in weightTab.skip(1)) {
    final date = parseSheetDate(cell(r, wHead['date']));
    if (date == null) continue;
    bodyRows.add(BodyRow(
      date: date,
      weightLbs: double.tryParse(cell(r, wHead['weight_lbs'])),
      waistIn: double.tryParse(cell(r, wHead['waist_in'])),
    ));
  }

  final pyForReview = programYaml;
  WeeklyReview reviewFor(DateTime monday, List<ReadingRow> readingRows) {
    final version = pyForReview == null ? null : currentVersion(pyForReview);
    // Targets-in-force for the week (block-0 cut weeks null the
    // absolute nutrition keys → honest "no target in force" answers).
    final slice = pyForReview == null
        ? null
        : programCurrent(pyForReview, phaseYaml, monday);
    final targets = recompTargetsFromProgram(
      version,
      parseExerciseMuscleMap(version),
      targetsInForce: slice?.targetsInForce,
    );
    return buildWeeklyReview(
      weekStart: monday,
      inputs: RecompInputs(
        meals: mealRows,
        strengthSets: reviewSets,
        readings: [
          for (final r in readingRows)
            TopSetReading(
              date: r.date,
              lift: r.lift,
              kind: r.kind,
              reps: r.reps,
              rpe: r.rpe,
            ),
        ],
        climbs: reviewClimbs,
        calisthenics: caliRows,
        cardio: review4x4s,
        recovery: recoveryRows,
        body: bodyRows,
      ),
      targets: targets,
    );
  }

  // --weekly-brief: print THIS Mon-Sun week's review markdown, no writes
  // (coach_nightly.sh injects it into the Sunday briefing prompt).
  // --week=YYYY-MM-DD reviews the week containing that date instead
  // (sampling / backfills).
  if (weeklyBrief) {
    var monday = mondayOf(DateTime.now());
    for (final a in args) {
      if (a.startsWith('--week=')) {
        final d = DateTime.tryParse(a.substring('--week='.length));
        if (d != null) monday = mondayOf(d);
      }
    }
    final readingValues = await tab(readingsTabName);
    final rdHead = headerIndex(readingValues);
    final readings = <ReadingRow>[
      for (final r in readingValues.skip(1)) ?ReadingRow.fromCells(rdHead, r),
    ];
    print(renderWeeklyReviewMarkdown(reviewFor(monday, readings)));
    return;
  }

  // -------------------------------------------------------------------------
  // Compute
  // -------------------------------------------------------------------------
  if (!brief) print('computing metrics ...');
  final graded = gradeSets(strengthRows);
  final weeks = weeklyRollup(
    graded,
    weights: weightRows,
    fourByFours: fourByFours,
    climbingDates: climbingDates,
    notes: noteRows,
    weekTypeOf: weekTypeResolver,
    weekStartDay: wsDay,
  );
  final flagsByWeek =
      evaluateFlags(weeks, phaseOf: phaseResolver, targetsOf: targetsResolver);

  // Only keep weeks from 2024-01-01 forward.
  final cutoff = DateTime.utc(2024, 1, 1);
  final filteredWeeks = [for (final w in weeks) if (!w.weekStart.isBefore(cutoff)) w];

  if (!brief) {
    print('  ${weeks.length} total ISO weeks, '
        '${filteredWeeks.length} from 2024-01-01 forward');
  }

  // -------------------------------------------------------------------------
  // --brief mode: print top-3 rows + open flags as markdown, then exit
  // -------------------------------------------------------------------------
  if (brief) {
    _printBrief(filteredWeeks, flagsByWeek, wsDay);
    return;
  }

  // -------------------------------------------------------------------------
  // Working-max controller (WM-2): read tabs, seed if empty, evaluate new
  // readings through the WM-1 chain. APPEND-ONLY — computed here, written
  // (appended) after the dry-run gate below.
  // -------------------------------------------------------------------------
  final wmValues = await tab(wmTabName);
  final readingValues = await tab(readingsTabName);
  final wmHead = headerIndex(wmValues);
  final rdHead = headerIndex(readingValues);
  final existingWm = <WorkingMaxRow>[
    for (final r in wmValues.skip(1)) ?WorkingMaxRow.fromCells(wmHead, r),
  ];
  final existingReadings = <ReadingRow>[
    for (final r in readingValues.skip(1)) ?ReadingRow.fromCells(rdHead, r),
  ];

  // §5 seeds when the tab is empty/missing (pending until confirmed in
  // the app's "Working maxes" card; deadlift carries its pain_cap marker).
  final seeds =
      existingWm.isEmpty ? seedWorkingMaxRows() : const <WorkingMaxRow>[];

  final wmVersion = programYaml == null ? null : currentVersion(programYaml);
  final wmPolicies =
      wmVersion == null ? const <LoadPolicy>[] : loadPolicies(wmVersion);
  final py = programYaml;
  LoadPolicy? policyAt(DateTime d) {
    if (py == null || wmPolicies.isEmpty) return null;
    final slice = programCurrent(py, phaseYaml, d);
    if (slice == null) return null;
    return policyForDate(
      wmPolicies,
      date: d,
      block: slice.block['number'] as int?,
      weekType: slice.weekType,
    );
  }

  // Week type for the WM chain's kind classification. v12: block-0
  // cut-wave DELOAD weeks (wave week 4) report 'deload' so their
  // readings are recorded + ignored (they would otherwise imply ~0.86×
  // TM and drop it under the guarded implied-max rule).
  String? weekTypeAt(DateTime d) {
    if (py == null) return null;
    final slice = programCurrent(py, phaseYaml, d);
    if (slice == null) return null;
    if (slice.weekType == 'normal') {
      final cut = strengthWaveCutFor(
        wmVersion,
        blockN: slice.block['number'] as int?,
        day: d,
      );
      if (cut?.deload == true) return 'deload';
    }
    return slice.weekType;
  }

  // v12 guarded implied-max TM rule (null pre-v12 → legacy bands).
  final tmRule = tmRuleOf(wmVersion);

  // TWO_SIGNALS → controller freeze: DELIBERATELY NOT WIRED (2026-09-21).
  // The flag rules are phase-aware now (targets_block_0 via targetsOf:
  // WORKING_LOW is off in block 0, NEAR_MAX_LOW right-sized to 4), so
  // the original blocker — bulk-calibrated flags firing every cut week
  // and freezing all four lifts — is gone. Wiring it (fire → freeze the
  // FOLLOWING week, since a week's own rollup is partial mid-week) is
  // still a deliberate follow-up, not a side effect of this change.
  final twoSignalsWeeks = <DateTime>{};
  final painNotes = [
    for (final n in noteRows)
      if ((n.cause ?? '').toLowerCase().contains('pain'))
        (date: n.date, text: '${n.cause} ${n.note ?? ''}'),
  ];

  final today = DateTime.now();
  final chain = runWmChain(
    snapshot: (
      workingMax: [...existingWm, ...seeds],
      readings: existingReadings,
    ),
    strengthRows: strengthRows,
    policyFor: policyAt,
    weekTypeOf: weekTypeAt,
    today: today,
    twoSignalsWeeks: twoSignalsWeeks,
    painNotes: painNotes,
    tmRule: tmRule,
  );
  final allWmRows = [...existingWm, ...seeds, ...chain.newWorkingMaxRows];
  final allReadings = [...existingReadings, ...chain.newReadings];

  print('working_max: ${existingWm.length} existing rows'
      '${seeds.isNotEmpty ? ' — EMPTY, seeding §5 (${seeds.length} rows, '
          'pending in-app confirmation)' : ''}');
  print('readings: ${existingReadings.length} existing, '
      '${chain.newReadings.length} new; '
      '${chain.newWorkingMaxRows.length} working-max change rows');
  for (final r in chain.newReadings) {
    print('  ${r.id}: ${r.weightLb}x${r.reps}@${r.rpe} [${r.variant}/'
        '${r.kind}] → ${r.decision} (wm ${r.wmAfter})');
  }
  for (final e in chain.flagsByLift.entries) {
    print('  flags ${e.key}: ${e.value.toSet().join(',')}');
  }
  // v13 slow-loop nightly recomputes (working_max rows not tied to a
  // new reading — rule-change reconciles, outvoted manual pins).
  for (final w in chain.newWorkingMaxRows) {
    if (w.readingId.isEmpty && w.source == 'rule') {
      print('  slow-loop ${w.lift} → ${w.valueLb} (${w.reason})');
    }
  }

  // -------------------------------------------------------------------------
  // Read existing coach_flags tab to preserve acknowledged values
  // -------------------------------------------------------------------------
  final existingFlags = await tab('coach_flags');
  final ackByKey = <String, String>{};
  if (existingFlags.length > 1) {
    final fHead = headerIndex(existingFlags);
    final idCol = fHead['id'];
    final firedCol = fHead['fired_on'];
    final ackCol = fHead['acknowledged'];
    for (final r in existingFlags.skip(1)) {
      if (idCol == null || firedCol == null || ackCol == null) break;
      final id = cell(r, idCol);
      final fired = cell(r, firedCol);
      final ack = cell(r, ackCol);
      if (id.isNotEmpty && fired.isNotEmpty && ack.isNotEmpty) {
        ackByKey['$id|$fired'] = ack;
      }
    }
  }
  print('  preserved ${ackByKey.length} acknowledged flag values');

  // -------------------------------------------------------------------------
  // Build program_status rows (newest first)
  // -------------------------------------------------------------------------
  const psHeaders = [
    'week_monday', 'week_type', 'sessions', 'sets_total', 'working_sets',
    'hard_sets', 'near_max_sets', 'long_failure_sets', 'avg_reps_working',
    'bench_days', 'squat_days', 'deadlift_days', 'press_days',
    'best_e1rm_squat', 'best_e1rm_bench', 'best_e1rm_deadlift',
    'best_e1rm_press',
    'climbing_sessions', 'bike_4x4_count', 'bike_4x4_max_hr',
    'bw_7d_avg', 'bw_rate_lb_wk', 'bw_3wk_change',
    'flags', 'deviations',
    // WM-2: working max in force at week end + the week's controller
    // decisions (current week also carries NO_READING flags).
    'working_max_squat', 'working_max_bench', 'working_max_deadlift',
    'working_max_press', 'wm_decisions',
  ];

  // Current-week extras for wm_decisions (NO_READING has no reading row).
  final currentWeekStart =
      filteredWeeks.isEmpty ? null : filteredWeeks.last.weekStart;
  final noReadingNotes = [
    for (final e in chain.flagsByLift.entries)
      if (e.value.contains('NO_READING')) '${e.key}:NO_READING',
  ].join('; ');

  final psRows = <List<Object?>>[];
  for (final w in filteredWeeks.reversed) {
    final flagHits = flagsByWeek[w.weekStart] ?? [];
    final flagIds = flagHits.map((f) => f.id).join(',');
    final weekSunday = w.weekStart.add(const Duration(days: 6));
    var wmDecisions = wmDecisionsForWeek(allReadings, w.weekStart);
    if (w.weekStart == currentWeekStart && noReadingNotes.isNotEmpty) {
      wmDecisions =
          wmDecisions.isEmpty ? noReadingNotes : '$wmDecisions; $noReadingNotes';
    }
    psRows.add([
      ymd(w.weekStart),
      w.weekType ?? '',
      w.sessions,
      w.setsTotal,
      w.workingSets,
      w.hardSets,
      w.nearMaxSets,
      w.longFailureSets,
      _r1(w.avgRepsWorking),
      w.benchDays,
      w.perLift['squat']?.days ?? 0,
      w.perLift['deadlift']?.days ?? 0,
      w.perLift['press']?.days ?? 0,
      _r1(w.perLift['squat']?.bestE1rmFromSetsLe5),
      _r1(w.perLift['bench']?.bestE1rmFromSetsLe5),
      _r1(w.perLift['deadlift']?.bestE1rmFromSetsLe5),
      _r1(w.perLift['press']?.bestE1rmFromSetsLe5),
      w.climbingSessions,
      w.bike4x4Count,
      _r1(w.bike4x4MaxHr),
      _r1(w.bw7dAvg),
      _r1(w.bwRateLbWk),
      _r1(w.bw3wkChange),
      flagIds,
      '', // deviations — empty until phase C
      workingMaxAsOf(allWmRows, 'squat', weekSunday) ?? '',
      workingMaxAsOf(allWmRows, 'bench', weekSunday) ?? '',
      workingMaxAsOf(allWmRows, 'deadlift', weekSunday) ?? '',
      workingMaxAsOf(allWmRows, 'press', weekSunday) ?? '',
      wmDecisions,
    ]);
  }

  // -------------------------------------------------------------------------
  // Build coach_flags rows (open flags: last 8 ISO weeks, newest first)
  // -------------------------------------------------------------------------
  const cfHeaders = ['id', 'fired_on', 'evidence', 'action', 'acknowledged'];

  final now = DateTime.now();
  final eightWeeksAgo =
      weekStartOf(DateTime(now.year, now.month, now.day - 56), wsDay);
  final cfRows = <List<Object?>>[];
  for (final w in filteredWeeks.reversed) {
    if (w.weekStart.isBefore(eightWeeksAgo)) continue;
    final flagHits = flagsByWeek[w.weekStart] ?? [];
    for (final f in flagHits) {
      final firedStr = ymd(f.firedOn);
      final key = '${f.id}|$firedStr';
      cfRows.add([
        f.id,
        firedStr,
        jsonEncode(f.evidence),
        f.action,
        ackByKey[key] ?? '',
      ]);
    }
  }

  // -------------------------------------------------------------------------
  // Program-sim forecast — sim2 v2.1 baseline (2026-09-26 spec §8/§9.3):
  // baseline dials on the program.yaml block calendar from the current
  // Monday, capacity seeded from the Sep-2026 RPE readings [log], with
  // the observed bw + app Epley index refreshed from workbook history
  // when present. Tab SHAPE is unchanged from v1 (the MCP forecast
  // block keeps parsing): per-lift columns now carry TRUE expressed
  // strength, `phase` = block emphasis, `grade_p75` = sim2 continuous C.
  // Missing config degrades to "skipped" — never blocks the status write.
  // -------------------------------------------------------------------------
  List<List<Object?>>? forecastRows;
  try {
    final s2Blocks = sim2BlocksFromProgramDocs(programYaml);
    if (s2Blocks == null) {
      print('forecast: skipped (program docs missing)');
    } else {
      double? observedBw;
      double? observedIndexTotal;
      final series = buildWeeklySeries(
        strengthRows: strengthRows,
        weightRows: weightRows,
        climbs: climbsFromTab(climbTab),
      );
      final initial = simInitialFromSeries(series);
      if (initial != null) {
        observedBw = initial.bw;
        final e = initial.e1rm;
        if (e.containsKey('squat') &&
            e.containsKey('bench') &&
            e.containsKey('deadlift')) {
          observedIndexTotal = e['squat']! + e['bench']! + e['deadlift']!;
        }
      }
      final run = sim2Run(
        params: Sim2Params.fitted(),
        blocks: s2Blocks,
        start: sim2StartMonday(DateTime.now()),
        observedBw: observedBw,
        observedIndexTotal: observedIndexTotal,
      );
      forecastRows = sim2ForecastTabRows(run);
      print('forecast: sim2 baseline — horizon expressed '
          '${run.last.sTrue.toStringAsFixed(0)} '
          '(index ${run.last.sIdx.toStringAsFixed(0)}) at '
          '${ymd(run.weeks.last.monday)}, C ${run.last.c.toStringAsFixed(1)}, '
          'over-budget ${run.overBudgetWeeks} wks');
    }
  } catch (e) {
    print('forecast: skipped ($e)');
  }

  // -------------------------------------------------------------------------
  // Weekly review rows (Sundays or --weekly): last 8 Mon-Sun weeks,
  // newest first, generated against the full history + ALL readings
  // (tab + this run's new ones).
  // -------------------------------------------------------------------------
  final isSunday = DateTime.now().weekday == DateTime.sunday;
  List<List<Object?>>? weeklyReviewRows;
  if (isSunday || forceWeekly) {
    final thisMonday = mondayOf(DateTime.now());
    weeklyReviewRows = [
      for (var w = 0; w < 8; w++)
        () {
          final monday = thisMonday.subtract(Duration(days: 7 * w));
          final review = reviewFor(monday, allReadings);
          return <Object?>[
            ymd(review.weekStart),
            ymd(review.weekEnd),
            DateTime.now().toIso8601String(),
            renderWeeklyReviewMarkdown(review),
          ];
        }(),
    ];
  }

  if (dryRun) {
    print('--dry-run: skipping writes');
    print('program_status: ${psRows.length} rows');
    print('coach_flags: ${cfRows.length} rows');
    if (weeklyReviewRows != null) {
      print('weekly_review: would write ${weeklyReviewRows.length} rows');
    }
    print('working_max: would append '
        '${seeds.length + chain.newWorkingMaxRows.length} rows');
    print('readings: would append ${chain.newReadings.length} rows');
    if (forecastRows != null) {
      print('forecast: would write ${forecastRows.length} weekly rows');
    }
    _printCurrentWeekRow(filteredWeeks, flagsByWeek, psHeaders);
    return;
  }

  // -------------------------------------------------------------------------
  // APPEND-ONLY write working_max + readings (history is never rewritten)
  // -------------------------------------------------------------------------
  final wmAppends = [
    for (final r in [...seeds, ...chain.newWorkingMaxRows]) r.toSheetRow(),
  ];
  if (wmAppends.isNotEmpty) {
    await _appendRows(
      api: api,
      spreadsheetId: config.spreadsheetId,
      tabName: wmTabName,
      headers: wmTabHeaders,
      existingRowCount: wmValues.length,
      rows: wmAppends,
    );
    print('appended ${wmAppends.length} working_max rows');
  }
  final readingAppends = [
    for (final r in chain.newReadings) r.toSheetRow(),
  ];
  if (readingAppends.isNotEmpty) {
    await _appendRows(
      api: api,
      spreadsheetId: config.spreadsheetId,
      tabName: readingsTabName,
      headers: readingsTabHeaders,
      existingRowCount: readingValues.length,
      rows: readingAppends,
    );
    print('appended ${readingAppends.length} readings rows');
  }

  // -------------------------------------------------------------------------
  // REPLACE-ALL write program_status
  // -------------------------------------------------------------------------
  await _replaceTab(
    api: api,
    spreadsheetId: config.spreadsheetId,
    tabName: 'program_status',
    headers: psHeaders,
    rows: psRows,
  );
  print('wrote program_status: ${psRows.length} data rows');

  // -------------------------------------------------------------------------
  // REPLACE-ALL write coach_flags
  // -------------------------------------------------------------------------
  await _replaceTab(
    api: api,
    spreadsheetId: config.spreadsheetId,
    tabName: 'coach_flags',
    headers: cfHeaders,
    rows: cfRows,
  );
  print('wrote coach_flags: ${cfRows.length} flag rows');

  // -------------------------------------------------------------------------
  // REPLACE-ALL write weekly_review (Sundays / --weekly only)
  // -------------------------------------------------------------------------
  if (weeklyReviewRows != null) {
    await _replaceTab(
      api: api,
      spreadsheetId: config.spreadsheetId,
      tabName: 'weekly_review',
      headers: const ['week_start', 'week_end', 'generated_at', 'markdown'],
      rows: weeklyReviewRows,
    );
    print('wrote weekly_review: ${weeklyReviewRows.length} weekly rows');
  }

  // -------------------------------------------------------------------------
  // REPLACE-ALL write forecast (weekly sim rows; nothing else appended)
  // -------------------------------------------------------------------------
  if (forecastRows != null) {
    await _replaceTab(
      api: api,
      spreadsheetId: config.spreadsheetId,
      tabName: forecastTabName,
      headers: forecastTabHeaders,
      rows: forecastRows,
    );
    print('wrote forecast: ${forecastRows.length} weekly rows');
  }

  // -------------------------------------------------------------------------
  // Report
  // -------------------------------------------------------------------------
  _printCurrentWeekRow(filteredWeeks, flagsByWeek, psHeaders);
}

// ---------------------------------------------------------------------------
// Brief output (for coach_nightly.sh prompt injection)
// ---------------------------------------------------------------------------

void _printBrief(
  List<WeeklyMetrics> filteredWeeks,
  Map<DateTime, List<FlagHit>> flagsByWeek,
  int wsDay,
) {
  print('## Program status (recent weeks)\n');
  print('| week_monday | week_type | sessions | working_sets | near_max_sets | bw_7d_avg | bw_rate_lb_wk | flags |');
  print('|---|---|---|---|---|---|---|---|');

  var count = 0;
  for (final w in filteredWeeks.reversed) {
    if (count >= 3) break;
    count++;
    final flagHits = flagsByWeek[w.weekStart] ?? [];
    final flagIds = flagHits.map((f) => f.id).join(', ');
    print('| ${ymd(w.weekStart)} | ${w.weekType ?? '-'} '
        '| ${w.sessions} | ${w.workingSets} | ${w.nearMaxSets} '
        '| ${_r1(w.bw7dAvg)} | ${_r1(w.bwRateLbWk)} | $flagIds |');
  }

  // Open flags from last 8 weeks
  final now = DateTime.now();
  final eightWeeksAgo =
      weekStartOf(DateTime(now.year, now.month, now.day - 56), wsDay);
  final openFlags = <FlagHit>[];
  for (final w in filteredWeeks.reversed) {
    if (w.weekStart.isBefore(eightWeeksAgo)) break;
    openFlags.addAll(flagsByWeek[w.weekStart] ?? []);
  }

  if (openFlags.isEmpty) {
    print('\n## Open flags\n\nNone.');
  } else {
    print('\n## Open flags (last 8 weeks)\n');
    for (final f in openFlags) {
      print('- **${f.id}** (${ymd(f.firedOn)}): ${f.action}');
    }
  }
}

// ---------------------------------------------------------------------------
// Report current week row to stdout
// ---------------------------------------------------------------------------

void _printCurrentWeekRow(
  List<WeeklyMetrics> filteredWeeks,
  Map<DateTime, List<FlagHit>> flagsByWeek,
  List<String> psHeaders,
) {
  if (filteredWeeks.isEmpty) return;
  final w = filteredWeeks.last;
  final flagHits = flagsByWeek[w.weekStart] ?? [];
  final flagIds = flagHits.map((f) => f.id).join(',');
  print('\nCurrent week: ${ymd(w.weekStart)}');
  print('  week_type=${w.weekType ?? "(none)"} sessions=${w.sessions} '
      'sets_total=${w.setsTotal} working=${w.workingSets} '
      'hard=${w.hardSets} near_max=${w.nearMaxSets} '
      'long_failure=${w.longFailureSets}');
  print('  bench_d=${w.benchDays} squat_d=${w.perLift['squat']?.days ?? 0} '
      'dl_d=${w.perLift['deadlift']?.days ?? 0} '
      'press_d=${w.perLift['press']?.days ?? 0}');
  print('  bw_7d=${_r1(w.bw7dAvg)} rate=${_r1(w.bwRateLbWk)} '
      '3wk=${_r1(w.bw3wkChange)}');
  print('  bike_4x4=${w.bike4x4Count} max_hr=${_r1(w.bike4x4MaxHr)}');
  print('  climb=${w.climbingSessions}');
  print('  flags=${flagIds.isEmpty ? "(none)" : flagIds}');

  if (flagHits.isNotEmpty) {
    print('\nOpen flags this week:');
    for (final f in flagHits) {
      print('  ${f.id}: ${f.action}');
      print('    evidence: ${jsonEncode(f.evidence)}');
    }
  }
}

// ---------------------------------------------------------------------------
// APPEND-ONLY tab write (working_max / readings). Creates the tab +
// header row when missing, then writes new rows at an EXPLICIT range
// below the existing data (never values.append at A1 — that eats the
// header row when A1 is empty; never clear/rewrite).
// ---------------------------------------------------------------------------

Future<void> _appendRows({
  required gsheets.SheetsApi api,
  required String spreadsheetId,
  required String tabName,
  required List<String> headers,
  required int existingRowCount, // header + data rows read this run
  required List<List<Object?>> rows,
}) async {
  final meta = await api.spreadsheets.get(spreadsheetId);
  final exists =
      (meta.sheets ?? []).any((s) => s.properties?.title == tabName);
  if (!exists) {
    print('creating tab "$tabName" ...');
    await api.spreadsheets.batchUpdate(
      gsheets.BatchUpdateSpreadsheetRequest(requests: [
        gsheets.Request(
          addSheet: gsheets.AddSheetRequest(
            properties: gsheets.SheetProperties(title: tabName),
          ),
        ),
      ]),
      spreadsheetId,
    );
  }
  var startRow = existingRowCount + 1; // 1-based first free row
  if (existingRowCount == 0) {
    await api.spreadsheets.values.update(
      gsheets.ValueRange(values: [headers]),
      spreadsheetId,
      "'$tabName'!A1",
      valueInputOption: 'RAW',
    );
    startRow = 2;
  }
  await api.spreadsheets.values.update(
    gsheets.ValueRange(values: rows),
    spreadsheetId,
    "'$tabName'!A$startRow",
    valueInputOption: 'RAW',
  );
}

// ---------------------------------------------------------------------------
// REPLACE-ALL tab write (kaya_import pattern)
// ---------------------------------------------------------------------------

Future<void> _replaceTab({
  required gsheets.SheetsApi api,
  required String spreadsheetId,
  required String tabName,
  required List<String> headers,
  required List<List<Object?>> rows,
}) async {
  // Ensure tab exists.
  final meta = await api.spreadsheets.get(spreadsheetId);
  final exists = (meta.sheets ?? [])
      .any((s) => s.properties?.title == tabName);
  if (!exists) {
    print('creating tab "$tabName" ...');
    await api.spreadsheets.batchUpdate(
      gsheets.BatchUpdateSpreadsheetRequest(requests: [
        gsheets.Request(
          addSheet: gsheets.AddSheetRequest(
            properties: gsheets.SheetProperties(title: tabName),
          ),
        ),
      ]),
      spreadsheetId,
    );
  }

  // Clear then write.
  await api.spreadsheets.values
      .clear(gsheets.ClearValuesRequest(), spreadsheetId, "'$tabName'");
  await api.spreadsheets.values.update(
    gsheets.ValueRange(values: [headers, ...rows]),
    spreadsheetId,
    "'$tabName'!A1",
    valueInputOption: 'RAW',
  );
}

// ---------------------------------------------------------------------------
// Helpers (shared with coach_backtest pattern)
// ---------------------------------------------------------------------------

({String spreadsheetId, String keyPath}) readConfig() {
  final lines = File(configPath).readAsLinesSync();
  String? pick(String key) {
    for (final l in lines) {
      if (l.startsWith('$key:')) return l.substring(key.length + 1).trim();
    }
    return null;
  }

  final spreadsheetId = pick('spreadsheet_id');
  if (spreadsheetId == null || spreadsheetId.isEmpty) {
    print('no spreadsheet_id in $configPath');
    exit(1);
  }
  final keyPath = pick('service_account_key_path') ??
      '$home/.config/airledger/service-account.json';
  return (spreadsheetId: spreadsheetId, keyPath: keyPath);
}

Future<gsheets.SheetsApi> sheetsApi(String keyPath) async {
  final keyJson = await File(keyPath).readAsString();
  final credentials = ServiceAccountCredentials.fromJson(keyJson);
  final client = await clientViaServiceAccount(
    credentials,
    [gsheets.SheetsApi.spreadsheetsScope],
  );
  return gsheets.SheetsApi(client);
}

Map<String, int> headerIndex(List<List<Object?>> tab) => tab.isEmpty
    ? {}
    : {for (var i = 0; i < tab.first.length; i++) tab.first[i].toString(): i};

String cell(List<Object?> row, int? i) =>
    i == null || i < 0 || i >= row.length
        ? ''
        : (row[i]?.toString() ?? '').trim();

/// Tri-state boolean cell: blank/missing = null (not recorded).
bool? boolCell(String s) =>
    s.isEmpty ? null : s.toLowerCase() == 'true';

DateTime? parseSheetDate(String s) {
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final us = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(s);
  if (us != null) {
    return DateTime(
      int.parse(us.group(3)!),
      int.parse(us.group(1)!),
      int.parse(us.group(2)!),
    );
  }
  return null;
}

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Round float to 1dp; return empty string when null.
Object _r1(double? v) => v == null ? '' : double.parse(v.toStringAsFixed(1));
