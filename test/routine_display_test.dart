// Tests for the pure Program-screen formatting helpers
// (lib/services/routine_display.dart): day summary line, bare session
// row format (incl. %-of-TM display rounding), the plain-words week
// status line, the 2-week training-max delta selection, and the TM
// history series for the trend plot.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/routine_display.dart';
import 'package:airledger/services/program_current.dart' show CutWaveWeekSpec;
import 'package:airledger/services/wm_tabs.dart' show WorkingMaxRow;

WorkingMaxRow _wm(
  String lift,
  double value,
  DateTime from, {
  String source = 'rule',
  bool? confirmed,
}) =>
    WorkingMaxRow(
      lift: lift,
      variant: 'belted',
      valueLb: value,
      effectiveFrom: from,
      source: source,
      reason: '',
      confirmed: confirmed,
    );

void main() {
  group('sessionLinesByDay', () {
    final mon = DateTime.utc(2026, 9, 28);

    test('merges consecutive identical sets and skips warm-up rows', () {
      final entries = <Map<String, Object?>>[
        {'date': mon, 'exercise': 'Barbell Squat', 'reps': 5, 'weight': 45,
          'warmup': true},
        {'date': mon, 'exercise': 'Barbell Squat', 'reps': 1, 'weight': 210,
          'warmup': true},
        {'date': mon, 'exercise': 'Barbell Squat', 'reps': 5, 'weight': 260,
          'top': true, 'pct': 0.811},
        {'date': mon, 'exercise': 'Flat Barbell Bench Press', 'reps': 8,
          'weight': 165, 'pct': 0.68},
        {'date': mon, 'exercise': 'Flat Barbell Bench Press', 'reps': 8,
          'weight': 165, 'pct': 0.68},
        {'date': mon, 'exercise': 'Bulgarian Split Squat', 'reps': 8,
          'reps_hi': 12},
      ];
      final byDay = sessionLinesByDay(entries);
      final lines = byDay[mon]!;
      expect(lines, hasLength(3));
      expect(lines[0].exercise, 'Barbell Squat');
      expect(lines[0].sets, 1);
      expect(lines[0].top, isTrue);
      expect(lines[1].sets, 2);
      expect(lines[1].pct, 0.68);
      expect(lines[2].repsHi, 12);
      expect(lines[2].weight, isNull);
    });

    test('same exercise with different weight stays separate', () {
      final entries = <Map<String, Object?>>[
        {'date': mon, 'exercise': 'Barbell Deadlift', 'reps': 3, 'weight': 285,
          'top': true},
        {'date': mon, 'exercise': 'Barbell Deadlift', 'reps': 4, 'weight': 250,
          'pct': 0.75},
      ];
      final lines = sessionLinesByDay(entries)[mon]!;
      expect(lines, hasLength(2));
    });
  });

  group('formatSessionLine', () {
    test('main-lift top set: short name, weight, %-of-TM from planned pct',
        () {
      const l = SessionLine(
          exercise: 'Barbell Squat',
          sets: 1,
          reps: 5,
          weight: 260,
          pct: 0.811,
          top: true);
      expect(formatSessionLine(l, tm: 320), 'Squat 1×5 · 260 lb (81%)');
    });

    test('main-lift volume slot shows the planned pct verbatim', () {
      const l = SessionLine(
          exercise: 'Flat Barbell Bench Press',
          sets: 4,
          reps: 8,
          weight: 165,
          pct: 0.68);
      // 165/240 would be 69% — the DECLARED 68% wins.
      expect(formatSessionLine(l, tm: 240), 'Bench 4×8 · 165 lb (68%)');
    });

    test('pct display rounds half up (0.837 → 84%)', () {
      const l = SessionLine(
          exercise: 'Barbell Squat', sets: 1, reps: 4, weight: 270, pct: 0.837,
          top: true);
      expect(formatSessionLine(l, tm: 320), 'Squat 1×4 · 270 lb (84%)');
    });

    test('main lift without planned pct derives % from weight / TM', () {
      const l = SessionLine(
          exercise: 'Flat Barbell Bench Press', sets: 3, reps: 5, weight: 200);
      // 200/240 = 83.33 → 83%.
      expect(formatSessionLine(l, tm: 240), 'Bench 3×5 · 200 lb (83%)');
      // No TM → no percentage, weight still shown.
      expect(formatSessionLine(l), 'Bench 3×5 · 200 lb');
    });

    test('accessory: full name, rep range, suggested load, no %', () {
      const l = SessionLine(
          exercise: 'Bulgarian Split Squat',
          sets: 3,
          reps: 8,
          repsHi: 12,
          weight: 40);
      expect(formatSessionLine(l, tm: 320), 'Bulgarian Split Squat 3×8-12 · 40 lb');
    });

    test('accessory without history stays blank after the rep range', () {
      const l = SessionLine(exercise: 'Pull Up', sets: 3, reps: 6, repsHi: 10);
      expect(formatSessionLine(l), 'Pull Up 3×6-10');
    });

    test('bodyweight movements read BW, never the logged scale weight '
        '(audit: "Pull Up 3×6-10 · 160.5 lb")', () {
      SessionLine bw(String ex, int sets, int reps, {int? hi, num? w}) =>
          SessionLine(
              exercise: ex, sets: sets, reps: reps, repsHi: hi, weight: w);
      expect(formatSessionLine(bw('Pull Up', 3, 6, hi: 10, w: 160.5)),
          'Pull Up 3×6-10 · BW');
      expect(formatSessionLine(bw('Muscle Up', 6, 1, hi: 2, w: 161)),
          'Muscle Up 6×1-2 · BW');
      expect(formatSessionLine(bw('Muscle Up Green Band', 2, 3, hi: 5, w: 173)),
          'Muscle Up Green Band 2×3-5 · BW');
      expect(
          formatSessionLine(bw('Parallel Bar Triceps Dip', 3, 8, hi: 12, w: 173),
              bodyweight: 161.4),
          'Parallel Bar Triceps Dip 3×8-12 · BW');
      expect(formatSessionLine(bw('Hanging Leg Raise', 3, 8, hi: 15, w: 161)),
          'Hanging Leg Raise 3×8-15 · BW');
      // No planned weight → bare, like any other exercise.
      expect(formatSessionLine(bw('Front Lever', 2, 5)), 'Front Lever 2×5');
    });

    test('bodyweightLoadLabel: BW+N only for explicitly weighted moves', () {
      // Total logged (bodyweight + added) → the excess, rounded to 2.5.
      expect(bodyweightLoadLabel('Weighted Pull Up', 186.4, bodyweight: 161.4),
          'BW+25 lb');
      // Added load logged directly.
      expect(bodyweightLoadLabel('Weighted Pull Up', 25, bodyweight: 161.4),
          'BW+25 lb');
      expect(bodyweightLoadLabel('Weighted Pull Up', 20), 'BW+20 lb');
      // A total with no bodyweight to subtract → never a guess.
      expect(bodyweightLoadLabel('Weighted Pull Up', 185), 'BW');
      // ≈ bodyweight → no added load.
      expect(bodyweightLoadLabel('Weighted Pull Up', 161, bodyweight: 161.4),
          'BW');
      // Unweighted names stay BW even above bodyweight (stale scale).
      expect(bodyweightLoadLabel('Muscle Up Green Band', 173, bodyweight: 161),
          'BW');
      expect(bodyweightLoadLabel('Pull Up', null), 'BW');
      expect(
          formatSessionLine(
              const SessionLine(
                  exercise: 'Weighted Pull Up', sets: 5, reps: 3, weight: 186.4),
              bodyweight: 161.4),
          'Weighted Pull Up 5×3 · BW+25 lb');
    });

    test('fractional loads keep their decimals', () {
      const l = SessionLine(
          exercise: 'Lateral Dumbbell Raise',
          sets: 3,
          reps: 12,
          repsHi: 20,
          weight: 12.5);
      expect(formatSessionLine(l), 'Lateral Dumbbell Raise 3×12-20 · 12.5 lb');
    });
  });

  group('daySummary', () {
    SessionLine line(String ex, {bool top = false}) =>
        SessionLine(exercise: ex, sets: 3, reps: 5, top: top);

    test('cut Monday: heavy + volume mains only, accessories silent', () {
      final s = daySummary(
        lines: [
          line('Barbell Squat', top: true),
          line('Bulgarian Split Squat'),
          line('Flat Barbell Bench Press'),
          line('Lateral Dumbbell Raise'),
        ],
        morning: 'Squat heavy: wave top per strength_wave_cut...',
      );
      expect(s, 'squat heavy · bench volume');
    });

    test('a lift with top AND back-offs reads heavy once', () {
      final s = daySummary(lines: [
        line('Barbell Deadlift', top: true),
        line('Barbell Deadlift'),
        line('Romanian Deadlift'),
      ]);
      expect(s, 'deadlift heavy');
    });

    test('cut Tuesday: 4x4 + hard climb from the prose, no rows', () {
      final s = daySummary(
        lines: const [],
        morning: 'AM: Norwegian 4x4 VO2 (warmup, 4x4 min hard, ~3 min '
            'recovery, cooldown). NO lifting today, ever.',
        afternoon: 'PM: Climb — HARD session (the week\'s quality/limit '
            'climbing; partner day).',
      );
      expect(s, '4x4 · hard climb');
    });

    test('post-cut Friday: deadlift heavy + limit climb', () {
      final s = daySummary(
        lines: [line('Barbell Deadlift', top: true), line('Leg Press')],
        morning: 'Deadlift + lower volume: deadlift top work...',
        afternoon: 'Climb 2 — LIMIT session (hard V5-V7+ projects).',
      );
      expect(s, 'deadlift heavy · limit climb');
    });

    test('cut Friday PM light session reads light climb', () {
      final s = daySummary(
        lines: const [],
        afternoon: 'PM: Climb — LIGHT session (technique/volume, movement '
            'quality; low fatigue).',
      );
      expect(s, 'light climb');
    });

    test('post-cut Tuesday technique session', () {
      final s = daySummary(
        lines: [line('Flat Barbell Bench Press', top: true)],
        afternoon: 'Climb 1 — TECHNIQUE/volume session (~V3-V5, onsight + '
            'movement-quality focus; partner day).',
      );
      expect(s, 'bench heavy · technique climb');
    });

    test('calisthenics days read calisthenics', () {
      expect(
        daySummary(
          lines: [line('Muscle Up'), line('Parallel Bar Triceps Dip')],
          morning: 'Muscle-ups FIRST (skill — quality sets). Then dips...',
        ),
        'calisthenics',
      );
      expect(
        daySummary(
          lines: [line('Pistol Squat')],
          morning: 'Calisthenics skill (~30-45 min): handstand practice...',
        ),
        'calisthenics',
      );
    });

    test('recovery prose without training reads recovery', () {
      final s = daySummary(
        lines: const [],
        afternoon: 'Recovery: no hard training; walking/easy activity '
            'encouraged.',
      );
      expect(s, 'recovery');
    });

    test('accessory-only day with no keywords reads accessories', () {
      expect(daySummary(lines: [line('Seated Cable Row')]), 'accessories');
    });

    test('empty day reads Rest', () {
      expect(daySummary(lines: const []), 'Rest');
      expect(daySummary(lines: const [], morning: '', afternoon: null), 'Rest');
    });
  });

  group('weekStatusLine', () {
    test('cut weeks: week N of 4 + top set reps @ pct', () {
      expect(
        weekStatusLine(
            cut: const CutWaveWeekSpec(
                week: 2, reps: 4, pct: 0.837, deload: false)),
        'Week 2 of 4 · top set 4 reps @ 84%',
      );
      expect(
        weekStatusLine(
            cut: const CutWaveWeekSpec(
                week: 1, reps: 5, pct: 0.811, deload: false)),
        'Week 1 of 4 · top set 5 reps @ 81%',
      );
    });

    test('cut deload week says deload in plain words', () {
      expect(
        weekStatusLine(
            cut: const CutWaveWeekSpec(
                week: 4, reps: 5, pct: 0.70, deload: true)),
        'Week 4 of 4 · deload — top set 5 reps @ ~70%, volume halved',
      );
    });

    test('post-cut weeks: week N of 4 @ RPE 7-8; light/test plain', () {
      expect(weekStatusLine(waveWeek: 1, waveReps: 5),
          'Week 1 of 4 · top set 5 reps @ RPE 7-8');
      expect(weekStatusLine(waveWeek: 4, waveReps: 5, weekType: 'light'),
          'Light week · top set 5 reps at the RPE 6 cap, volume halved');
      expect(weekStatusLine(waveWeek: 4, waveReps: 1, weekType: 'test'),
          'Test week · one single @ RPE 8, volume halved');
    });

    test('no wave in force → null; never says wave', () {
      expect(weekStatusLine(), isNull);
      for (final s in [
        weekStatusLine(
            cut: const CutWaveWeekSpec(
                week: 4, reps: 5, pct: 0.70, deload: true)),
        weekStatusLine(waveWeek: 2, waveReps: 3),
        weekStatusLine(waveWeek: 4, waveReps: 5, weekType: 'light'),
        weekStatusLine(waveWeek: 4, waveReps: 1, weekType: 'test'),
      ]) {
        expect(s!.toLowerCase().contains('wave'), isFalse, reason: s);
      }
    });
  });

  group('backoffLine', () {
    test('collapses the rule to one short line', () {
      expect(
        backoffLine(const {
          'target_rpe': 8,
          'hold_if_rpe_lte': 8,
          'drop_pct': [2.5, 5],
          'purpose': 'prevent RPE drift, not normal fatigue',
        }),
        'hold ≤8 · drop 2.5-5% if over',
      );
    });

    test('scalar drop and missing rule degrade honestly', () {
      expect(backoffLine(const {'hold_if_rpe_lte': 7, 'drop_pct': 5}),
          'hold ≤7 · drop 5% if over');
      expect(backoffLine(null), isNull);
      expect(backoffLine('not a map'), isNull);
      expect(backoffLine(const {'drop_pct': 5}), isNull);
    });
  });

  group('tmSignal', () {
    final rows = [
      _wm('squat', 320, DateTime.utc(2026, 9, 21),
          source: 'seed', confirmed: false),
      _wm('bench', 240, DateTime.utc(2026, 9, 21),
          source: 'seed', confirmed: false),
      _wm('squat', 310, DateTime.utc(2026, 10, 1)),
    ];

    test('picks current vs the value in force two weeks ago', () {
      final s = tmSignal(rows, 'squat', DateTime.utc(2026, 10, 5))!;
      expect(s.current, 310);
      expect(s.previous, 320); // in force Sep 21 (Oct 5 − 14d = Sep 21)
      expect(s.changedOn, DateTime.utc(2026, 10, 1));
    });

    test('unchanged lift keeps previous == current', () {
      final s = tmSignal(rows, 'bench', DateTime.utc(2026, 10, 5))!;
      expect(s.current, 240);
      expect(s.previous, 240);
      expect(s.changedOn, DateTime.utc(2026, 9, 21));
    });

    test('as-of respects effective_from (future rows not in force)', () {
      final s = tmSignal(rows, 'squat', DateTime.utc(2026, 9, 25))!;
      expect(s.current, 320);
      expect(s.previous, isNull); // nothing in force at Sep 11
      expect(s.changedOn, DateTime.utc(2026, 9, 21));
    });

    test('unknown lift → null', () {
      expect(tmSignal(rows, 'press', DateTime.utc(2026, 10, 5)), isNull);
    });

    test('labels: drop, raise, steady — slow-loop rows read auto', () {
      // v13 source labels: `rule` rows (slow-loop recomputes) → auto;
      // `manual` rows (pinned values) → manual; seeds stay bare.
      final drop = tmSignal(rows, 'squat', DateTime.utc(2026, 10, 5))!;
      expect(tmSignalLabel(drop), '310 · was 320 ↓ · Oct 1 · auto');
      expect(tmSignalSuffix(drop), 'was 320 ↓ · Oct 1 · auto');
      final steady = tmSignal(rows, 'bench', DateTime.utc(2026, 10, 5))!;
      expect(tmSignalLabel(steady), '240 · since Sep 21');
      expect(tmSignalSuffix(steady), 'since Sep 21');
      final raise = tmSignal(
          [..._raiseRows()], 'press', DateTime.utc(2026, 10, 5))!;
      expect(tmSignalLabel(raise), '145 · was 140 ↑ · Oct 3 · auto');
    });

    test('manual values are labeled — the pin is visible', () {
      final manual = tmSignal([
        _wm('deadlift', 330, DateTime.utc(2026, 9, 21),
            source: 'seed', confirmed: false),
        _wm('deadlift', 340, DateTime.utc(2026, 10, 2),
            source: 'manual', confirmed: true),
      ], 'deadlift', DateTime.utc(2026, 10, 5))!;
      expect(tmSignalSuffix(manual), 'was 330 ↑ · Oct 2 · manual');
    });
  });

  group('tmHistoryPoints', () {
    test('chronological per-lift series, same-day collapse (last wins)', () {
      final rows = [
        _wm('squat', 320, DateTime.utc(2026, 9, 21),
            source: 'seed', confirmed: false),
        _wm('squat', 320, DateTime.utc(2026, 9, 21),
            source: 'seed', confirmed: true), // in-app confirm duplicate
        _wm('bench', 240, DateTime.utc(2026, 9, 22)),
        _wm('squat', 310, DateTime.utc(2026, 10, 1)),
      ];
      final pts = tmHistoryPoints(rows, 'squat');
      expect(pts, hasLength(2));
      expect(pts.first.day, DateTime.utc(2026, 9, 21));
      expect(pts.first.value, 320);
      expect(pts.last.value, 310);
      expect(tmHistoryPoints(rows, 'deadlift'), isEmpty);
    });
  });
}

List<WorkingMaxRow> _raiseRows() => [
      _wm('press', 140, DateTime.utc(2026, 9, 21),
          source: 'seed', confirmed: false),
      _wm('press', 145, DateTime.utc(2026, 10, 3)),
    ];
