// SATURDAY REGRESSION PIN (2026-09-28) + full cut-week structure.
//
// Root cause of "Saturday shows as rest": the Program screen displays a
// Monday-anchored week (buildWeekPlan → Mon–Sun) but the planner core
// snapped its 7-day window back to the program's Sat-start ACCOUNTING
// week (`week_start: saturday` → Sat–Fri), so the DISPLAYED Saturday
// (the following one) fell outside the generated window, got zero
// session lines, and daySummary fell through to 'Rest'. The screen now
// calls buildWeekPlannedEntries with `snapToWeekStart: false`.
//
// This suite pins, against the LIVE airledger-fitness program.yaml:
//   1. the display window (Mon–Sun, snapToWeekStart: false) covers all
//      seven days — Saturday included — for a cut week;
//   2. ALL SEVEN days of the approved cut week, movements verbatim:
//      Mon  squat heavy + bench volume + BSS + accessories
//      Tue  4x4 + hard climb (no barbell rows)
//      Wed  bench heavy + squat volume + press volume + pull-ups
//      Thu  calisthenics (muscle-ups main + handstand/front-lever skill
//           + hanging leg raise) + dips + EZ-bar preacher curls
//      Fri  deadlift heavy + bench volume + light climb
//      Sat  press heavy + OHP back-offs + seated cable row + pull-ups +
//           laterals + face pulls + external rotations
//      Sun  rest — optional easy zone-2 run (prose only, v15 2026-10-01;
//           never planned, never a missed session).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/routine_display.dart';
import 'package:airledger/services/week_planner.dart';

const _fitnessRepo = '../airledger-fitness/coach';

void main() {
  final program = loadYaml(
    File('$_fitnessRepo/program.yaml').readAsStringSync(),
  ) as Map<Object?, Object?>;
  final version = currentVersion(program)!;

  const maxes = {
    'squat': 320.0,
    'bench': 240.0,
    'deadlift': 330.0,
    'press': 140.0,
  };

  // Cut wave week 1: Mon 2026-09-28 .. Sun 2026-10-04.
  final monday = DateTime.utc(2026, 9, 28);
  final entries = buildWeekPlannedEntries(
    program,
    monday,
    workingMaxes: maxes,
    snapToWeekStart: false,
  );

  /// The day's working-set rows as (exercise, sets, reps) tuples in
  /// order (warm-ups dropped, per-set rows merged) — the same grouping
  /// the routine screen renders.
  List<(String, int, num)> dayRows(int offset) {
    final date = monday.add(Duration(days: offset));
    final lines = sessionLinesByDay(entries)[date] ?? const [];
    return [for (final l in lines) (l.exercise, l.sets, l.reps)];
  }

  test('display window covers all seven Mon–Sun days (Saturday included)',
      () {
    final dates = {for (final e in entries) e['date'] as DateTime};
    // Lifting days: Mon, Wed, Thu, Fri, Sat. Tue (4x4+climb) and Sun
    // (rest) plan no strength rows.
    expect(
      dates,
      {
        for (final i in [0, 2, 3, 4, 5]) monday.add(Duration(days: i)),
      },
    );
    expect(dates.contains(DateTime.utc(2026, 10, 3)), isTrue,
        reason: 'Saturday Oct 3 must be planned — the regression '
            'dropped it from the displayed week');
  });

  test('Mon: squat heavy + BSS + bench volume + laterals + triceps', () {
    expect(dayRows(0), [
      ('Barbell Squat', 1, 5), // wave week-1 top
      ('Bulgarian Split Squat', 3, 8),
      ('Flat Barbell Bench Press', 4, 8), // @ 68% TM
      ('Lateral Dumbbell Raise', 3, 12),
      ('Triceps Extension', 2, 10),
    ]);
  });

  test('Tue: 4x4 + hard climb, no lifting', () {
    expect(dayRows(1), isEmpty);
    final slice = programCurrent(program, null, monday.add(const Duration(days: 1)))!;
    final morning = slice.todayTemplate['morning'].toString();
    final afternoon = slice.todayTemplate['afternoon'].toString();
    expect(morning.toLowerCase(), contains('4x4'));
    expect(afternoon.toLowerCase(), contains('hard'));
    expect(afternoon.toLowerCase(), contains('climb'));
  });

  test('Wed: bench heavy + back-offs + squat/press volume + pull-ups', () {
    expect(dayRows(2), [
      ('Flat Barbell Bench Press', 1, 5), // wave top
      ('Flat Barbell Bench Press', 3, 6), // 72% back-offs
      ('Barbell Squat', 3, 8), // 65%
      ('Overhead Press', 3, 8), // 62%
      ('Pull Up', 3, 6),
    ]);
  });

  test('Thu: muscle-ups main + skill (handstand/front-lever) + HLR + '
      'dips + EZ-bar preacher curls', () {
    expect(dayRows(3), [
      ('Muscle Up', 6, 1), // 6 unassisted singles/doubles (progression)
      ('Muscle Up Green Band', 2, 3), // + banded volume
      ('Handstand Hold', 3, 1), // v14 skill work
      ('Front Lever', 2, 5), // v14 up-downs
      ('Hanging Leg Raise', 3, 8), // v14 restored core work
      ('Parallel Bar Triceps Dip', 3, 8),
      ('EZ-Bar Preacher Curl', 3, 8),
    ]);
  });

  test('Fri: deadlift heavy + back-offs + RDL + bench volume + light climb',
      () {
    expect(dayRows(4), [
      ('Barbell Deadlift', 1, 5), // wave top
      ('Barbell Deadlift', 2, 4), // 75% back-offs
      ('Romanian Deadlift', 2, 8),
      ('Flat Barbell Bench Press', 3, 8), // 65%
    ]);
    final slice = programCurrent(program, null, monday.add(const Duration(days: 4)))!;
    final afternoon = slice.todayTemplate['afternoon'].toString().toLowerCase();
    expect(afternoon, contains('light'));
    expect(afternoon, contains('climb'));
  });

  test(
      'Sat: OHP heavy + back-offs + seated cable row + pull-ups + laterals '
      '+ face pulls + external rotations — movements preserved verbatim',
      () {
    expect(dayRows(5), [
      ('Overhead Press', 1, 5), // wave top
      ('Overhead Press', 3, 6), // 72% back-offs (3x6-8)
      ('Seated Cable Row', 3, 8), // 3x8-12
      ('Pull Up', 3, 6), // 3x6-10
      ('Lateral Dumbbell Raise', 3, 12), // 3x12-20
      ('Cable Face Pull', 2, 12), // 2-3x12-20
      ('Cable External Rotation', 2, 12), // 2-3x12-20
    ]);
  });

  test('Sat renders as a training day, not Rest', () {
    final date = monday.add(const Duration(days: 5));
    final lines = sessionLinesByDay(entries)[date] ?? const [];
    final slice = programCurrent(program, null, date)!;
    final summary = daySummary(
      lines: lines,
      morning: slice.todayTemplate['morning']?.toString(),
      afternoon: slice.todayTemplate['afternoon']?.toString(),
    );
    expect(summary, isNot('Rest'));
    expect(summary, contains('press heavy'));
  });

  test(
      'Sun: rest — no planned rows (optional zone-2 run is prose only, '
      'v15)', () {
    // v15 (2026-10-01): cut Sunday gained an OPTIONAL easy zone-2 run —
    // prose only, never planned (no `planned` rows) and never a missed
    // session.
    expect(dayRows(6), isEmpty);
    final slice = programCurrent(program, null, monday.add(const Duration(days: 6)))!;
    expect(
      slice.todayTemplate['morning'],
      'Optional: easy zone-2 run, 30-45 min (nice to have; Whoop detects '
      'it — no logging needed).',
    );
    expect(slice.todayTemplate['afternoon'], isNull);
  });

  test('accounting-window call (PlanStore path) still snaps to Saturday',
      () {
    // The default (snapToWeekStart: true) window for the same Monday is
    // the Sat-start accounting week: Sat Sep 26 – Fri Oct 2.
    expect(weekStartDayOf(version), DateTime.saturday);
    final snapped = buildWeekPlannedEntries(program, monday,
        workingMaxes: maxes);
    final dates = {for (final e in snapped) e['date'] as DateTime};
    expect(dates.contains(DateTime.utc(2026, 9, 26)), isTrue,
        reason: 'Sat Sep 26 opens the accounting window');
    expect(dates.contains(DateTime.utc(2026, 10, 3)), isFalse,
        reason: 'Sat Oct 3 belongs to the NEXT accounting week');
  });
}
