import 'package:airledger/services/recomp_review.dart';
import 'package:airledger/services/week_drivers.dart'
    show MuscleMap, TopSetReading;
import 'package:flutter_test/flutter_test.dart';

// Week under review: Mon 2026-12-14 .. Sun 2026-12-20 (block 1 start).
final DateTime wk = DateTime(2026, 12, 14);
DateTime d(int offset) => wk.add(Duration(days: offset));

RecompTargets targets({double? maintenance, MuscleMap? map}) => RecompTargets(
      proteinGDay: const [160, 175],
      fatGDayMin: 55,
      carbsGDay: const [225, 300],
      maintenanceKcal: maintenance,
      hypBand: const [8, 12],
      muscleGroups: const ['chest', 'back'],
      muscleMap: map,
      climbingWk: 2,
      calisthenicsWk: 1,
      bike4x4Wk: 1,
    );

MuscleMap map() => const MuscleMap(
      exercises: {
        'Flat Barbell Bench Press': {'chest': 1.0, 'triceps': 0.5},
        'Pull Up': {'back': 1.0},
        'Muscle Up': {'back': 0.75},
      },
      climbingSession: {'back': 3.0},
    );

void main() {
  group('daily nutrition adherence', () {
    test('per-day rollup + target gates', () {
      final days = dailyNutrition(
        [
          // Day 0: two meals summing protein 165 (met), fat 60 (met),
          // carbs 250 (met), kcal 2500.
          MealRow(eatenAt: d(0).add(const Duration(hours: 8)),
              calories: 1200, proteinG: 80, carbsG: 120, fatG: 30),
          MealRow(eatenAt: d(0).add(const Duration(hours: 19)),
              calories: 1300, proteinG: 85, carbsG: 130, fatG: 30),
          // Day 1: protein low, fat low, carbs high.
          MealRow(eatenAt: d(1).add(const Duration(hours: 12)),
              calories: 2000, proteinG: 120, carbsG: 350, fatG: 40),
        ],
        targets(maintenance: 2600),
      );
      expect(days, hasLength(2));
      final day0 = days.first;
      expect(day0.proteinMet, isTrue);
      expect(day0.fatMet, isTrue);
      expect(day0.carbsMet, isTrue);
      expect(day0.kcalVsMaintenance, closeTo(-100, 0.01));
      final day1 = days.last;
      expect(day1.proteinMet, isFalse);
      expect(day1.fatMet, isFalse);
      expect(day1.carbsMet, isFalse); // over the range is not "met"
    });

    test('no maintenance -> kcalVsMaintenance null', () {
      final days = dailyNutrition(
        [MealRow(eatenAt: d(0), calories: 2000)],
        targets(),
      );
      expect(days.single.kcalVsMaintenance, isNull);
    });
  });

  group('productive set counting (set_type-aware)', () {
    ReviewSet s(String? type, {double? rpe, String ex = 'Pull Up'}) =>
        ReviewSet(
            date: d(0), exercise: ex, reps: 8, weight: 0,
            rpe: rpe, setType: type);

    test('warmup/skill/rehab excluded; heavy/hypertrophy counted', () {
      expect(countsAsProductive(s('warmup')), isFalse);
      expect(countsAsProductive(s('skill')), isFalse);
      expect(countsAsProductive(s('rehab')), isFalse);
      expect(countsAsProductive(s('heavy')), isTrue);
      expect(countsAsProductive(s('hypertrophy')), isTrue);
    });

    test('untagged legacy rows: effort-inferred (RPE < 6 = warmup)', () {
      expect(countsAsProductive(s(null, rpe: 5)), isFalse);
      expect(countsAsProductive(s(null, rpe: 7)), isTrue);
      expect(countsAsProductive(s(null)), isTrue); // no RPE: counted
    });

    test('per-muscle credits + climbing session overlap', () {
      final counts = productiveSetsByMuscle(
        sets: [
          for (var i = 0; i < 4; i++) s('hypertrophy'), // back 4
          s('warmup'), // excluded
          s('hypertrophy', ex: 'Flat Barbell Bench Press'), // chest 1
          s(null, rpe: 5, ex: 'Flat Barbell Bench Press'), // excluded
        ],
        map: map(),
        climbingSessionCount: 2, // back +6
        groups: const ['chest', 'back'],
      );
      expect(counts['back'], closeTo(10, 0.001));
      expect(counts['chest'], closeTo(1, 0.001));
    });

    test('avg RIR over counted sets with RPE (RIR = 10 - RPE)', () {
      final rir = avgRirOfProductiveSets([
        s('hypertrophy', rpe: 8), // RIR 2
        s('hypertrophy', rpe: 7), // RIR 3
        s('warmup', rpe: 4), // excluded
        s('hypertrophy'), // no RPE: not averaged
      ]);
      expect(rir, closeTo(2.5, 0.001));
    });
  });

  group('climbing deriveds', () {
    test('V5+ first sends + onsight/flash, highest sent', () {
      final c = climbingWeekOf(
        climbs: [
          ClimbRow(date: d(1), grade: 'v5', ascentType: 'Redpoint'),
          ClimbRow(date: d(1), grade: 'v6', ascentType: 'Flash'),
          ClimbRow(date: d(1), grade: 'v5', ascentType: 'Repeat'),
          ClimbRow(date: d(4), grade: 'v4', ascentType: 'Onsight'),
          ClimbRow(date: d(4), grade: '5.12a', ascentType: 'Redpoint'),
        ],
        weekStart: wk,
      );
      expect(c.sessions, 2);
      expect(c.newV5PlusSends, 2); // v5 RP + v6 flash (repeat excluded)
      expect(c.v5PlusOnsightFlash, 1); // the v6 flash
      expect(c.highestSentV, 6);
    });
  });

  group('calisthenics bests', () {
    test('best reps / hold per skill, sessions', () {
      final cal = calisthenicsWeekOf(
        rows: [
          CalisthenicsRow(date: d(2), skill: 'muscle-up',
              variation: 'strict', reps: 2, clean: true),
          CalisthenicsRow(date: d(2), skill: 'muscle-up',
              variation: 'strict', reps: 3, clean: false),
          CalisthenicsRow(date: d(2), skill: 'front lever',
              variation: 'tuck', holdSeconds: 12),
          CalisthenicsRow(date: d(5), skill: 'handstand',
              holdSeconds: 30, clean: true),
        ],
        weekStart: wk,
      );
      expect(cal.sessions, 2);
      expect(cal.bests['muscle-up']!.bestReps, 3);
      expect(cal.bests['muscle-up']!.bestCleanReps, 2);
      expect(cal.bests['front lever']!.bestHoldSeconds, 12);
      expect(cal.bests['handstand']!.bestHoldSeconds, 30);
    });
  });

  group('4x4 workload trend', () {
    test('workload at comparable HR vs prior sessions', () {
      final cw = cardioWeekOf(
        rows: [
          // Prior weeks: workload 8.0 at 175 bpm, then 8.4 at 176.
          Cardio4x4Row(date: d(-14), speed: 8.0, maxHr: 175),
          Cardio4x4Row(date: d(-7), speed: 8.4, maxHr: 176),
          // This week: 8.8 at 174 — comparable HR (within 5 bpm).
          Cardio4x4Row(
              date: d(3), speed: 8.8, maxHr: 174, completedIntervals: 4),
        ],
        weekStart: wk,
      );
      expect(cw.sessions, 1);
      expect(cw.completedAllFour, isTrue);
      expect(cw.workload, closeTo(8.8, 0.001));
      // vs most recent comparable-HR prior session (8.4).
      expect(cw.workloadTrendPct, closeTo(100 * (8.8 - 8.4) / 8.4, 0.01));
    });

    test('incline multiplies into the workload index', () {
      final cw = cardioWeekOf(
        rows: [
          Cardio4x4Row(date: d(3), speed: 6.0, incline: 10, maxHr: 170),
        ],
        weekStart: wk,
      );
      expect(cw.workload, closeTo(60, 0.001)); // speed × incline
    });

    test('no comparable prior HR -> trend null', () {
      final cw = cardioWeekOf(
        rows: [
          Cardio4x4Row(date: d(-7), speed: 8.0, maxHr: 150),
          Cardio4x4Row(date: d(3), speed: 8.8, maxHr: 174),
        ],
        weekStart: wk,
      );
      expect(cw.workloadTrendPct, isNull);
    });
  });

  group('recovery aggregates', () {
    test('averages + pain flags outrank numbers', () {
      final r = recoveryWeekOf(
        rows: [
          RecoveryRow(date: d(0), sleepHours: 7.5, fatigue: 2, soreness: 2),
          RecoveryRow(date: d(1), sleepHours: 6.5, fatigue: 3, soreness: 3,
              pain: 'left elbow twinge'),
          RecoveryRow(date: d(2)), // empty numbers: ignored in averages
        ],
        weekStart: wk,
      );
      expect(r.avgSleepHours, closeTo(7.0, 0.001));
      expect(r.avgFatigue, closeTo(2.5, 0.001));
      expect(r.painDays, hasLength(1));
      expect(r.painDays.single.text, contains('elbow'));
    });

    test('objective recovery_score averaged + surfaced', () {
      final r = recoveryWeekOf(
        rows: [
          RecoveryRow(date: d(0), recoveryScore: 40, sleepHours: 7),
          RecoveryRow(date: d(1), recoveryScore: 60),
        ],
        weekStart: wk,
      );
      expect(r.avgRecoveryScore, closeTo(50.0, 0.001));
      // recovery_score alone counts as reported (no subjectives needed).
      expect(r.daysReported, 2);
    });
  });

  group('mergeRecoveryRows', () {
    test('objective sleep_hours + recovery_score win; subjectives carried',
        () {
      final merged = mergeRecoveryRows(
        objective: [
          RecoveryRow(date: d(0), sleepHours: 7.2, recoveryScore: 65),
        ],
        manual: [
          RecoveryRow(
            date: d(0),
            sleepHours: 6.0, // overridden by objective
            fatigue: 3,
            pain: 'knee',
          ),
        ],
      );
      final row = merged.single;
      expect(row.sleepHours, 7.2); // objective wins
      expect(row.recoveryScore, 65);
      expect(row.fatigue, 3); // manual carried
      expect(row.pain, 'knee');
    });

    test('objective-only day survives; manual-only day survives', () {
      final merged = mergeRecoveryRows(
        objective: [RecoveryRow(date: d(0), recoveryScore: 55)],
        manual: [RecoveryRow(date: d(1), fatigue: 2)],
      );
      expect(merged, hasLength(2));
      expect(merged[0].recoveryScore, 55);
      expect(merged[1].fatigue, 2);
    });
  });

  group('full weekly review + markdown', () {
    WeeklyReview build({double? maintenance}) => buildWeeklyReview(
          weekStart: wk,
          inputs: RecompInputs(
            meals: [
              for (var day = 0; day < 7; day++)
                MealRow(eatenAt: d(day),
                    calories: 2500, proteinG: 170, carbsG: 260, fatG: 60),
            ],
            strengthSets: [
              // Bench: 1 heavy + 3 hypertrophy (chest 4 productive).
              ReviewSet(date: d(1), exercise: 'Flat Barbell Bench Press',
                  reps: 2, weight: 225, rpe: 8, setType: 'heavy'),
              for (var i = 0; i < 3; i++)
                ReviewSet(date: d(1), exercise: 'Flat Barbell Bench Press',
                    reps: 6, weight: 185, rpe: 8, setType: 'hypertrophy'),
              // Back: pull-ups 5 sets untagged at RPE 8 (counted).
              for (var i = 0; i < 5; i++)
                ReviewSet(date: d(5), exercise: 'Pull Up',
                    reps: 8, weight: 0, rpe: 8),
            ],
            readings: [
              TopSetReading(date: d(1), lift: 'bench', kind: 'heavy_top',
                  reps: 2, rpe: 8),
              TopSetReading(date: d(0), lift: 'squat', kind: 'heavy_top',
                  reps: 3, rpe: 8),
            ],
            climbs: [
              ClimbRow(date: d(1), grade: 'v6', ascentType: 'Flash'),
              ClimbRow(date: d(4), grade: 'v5', ascentType: 'Redpoint'),
            ],
            calisthenics: [
              CalisthenicsRow(date: d(0), skill: 'muscle-up',
                  variation: 'strict', reps: 2, clean: true),
            ],
            cardio: [
              Cardio4x4Row(date: d(3), speed: 8.8, maxHr: 174,
                  completedIntervals: 4),
            ],
            recovery: [
              RecoveryRow(date: d(0), sleepHours: 7.5, fatigue: 2,
                  soreness: 2, readiness: 4),
            ],
            body: [
              for (var day = -7; day < 7; day++)
                BodyRow(date: d(day), weightLbs: 156.0 + 0.02 * day,
                    waistIn: day == 6 ? 31.5 : null),
            ],
          ),
          targets: targets(maintenance: maintenance, map: map()),
        );

    test('sections computed', () {
      final r = build(maintenance: 2500);
      expect(r.nutrition!.proteinDaysMet, 7);
      expect(r.nutrition!.daysLogged, 7);
      expect(r.muscleSets['chest'], closeTo(4, 0.001));
      // back: 5 pull-ups + 2 climb sessions × 3.0 = 11.
      expect(r.muscleSets['back'], closeTo(11, 0.001));
      expect(r.heavyExposures['bench'], 1);
      expect(r.heavyExposures['deadlift'], 0);
      expect(r.climbing.newV5PlusSends, 2);
      expect(r.cardio.completedAllFour, isTrue);
      expect(r.body.avg7d, isNotNull);
      expect(r.body.waistIn, 31.5);
      expect(r.decision, hasLength(10));
    });

    test('honest no-data answers', () {
      final r = buildWeeklyReview(
        weekStart: wk,
        inputs: const RecompInputs(),
        targets: targets(map: map()),
      );
      // Q2 calories vs maintenance: no meals + no maintenance -> no data.
      expect(r.decision[1].answer.toLowerCase(), contains('no data'));
      // Q8 recovery: no recovery rows -> no data.
      expect(r.decision[7].answer.toLowerCase(), contains('no data'));
      final md = renderWeeklyReviewMarkdown(r);
      expect(md.toLowerCase(), contains('no data'));
    });

    test('markdown carries the spec sections + 10 questions', () {
      final md = renderWeeklyReviewMarkdown(build(maintenance: 2500));
      for (final section in [
        '## Nutrition', '## Hypertrophy', '## Strength', '## Climbing',
        '## Calisthenics', '## VO2', '## Recovery', '## Body comp',
        '## Coaching decision',
      ]) {
        expect(md, contains(section));
      }
      expect(md, contains('10.'));
      expect(md, contains('RIR')); // the RIR = 10 - RPE convention note
    });

    test('backoff compliance: RPE > 8.5 with a held load flags; missing '
        'RPE is unknown; warmups + non-mains excluded', () {
      ReviewSet set0(int day, String ex, double w, int reps,
              {double? rpe, String? type}) =>
          ReviewSet(date: d(day), exercise: ex, reps: reps, weight: w,
              rpe: rpe, setType: type);
      final c = backoffComplianceOf([
        // Warmup never participates (tagged or effort-inferred).
        set0(0, 'Barbell Squat', 135, 5, rpe: 4),
        // Top 9 RPE → next set HELD the load → flagged.
        set0(0, 'Barbell Squat', 260, 5, rpe: 9),
        set0(0, 'Barbell Squat', 260, 5, rpe: 9),
        // ...then a proper drop → the 260→250 pair is compliant.
        set0(0, 'Barbell Squat', 250, 5, rpe: 8),
        // Missing RPE on the leading set → unknown, not judged.
        set0(2, 'Flat Barbell Bench Press', 175, 6),
        set0(2, 'Flat Barbell Bench Press', 175, 6, rpe: 8),
        // RPE 8 exactly = hold territory, no flag.
        set0(2, 'Flat Barbell Bench Press', 175, 6, rpe: 8),
        // Non-main exercises never checked.
        set0(2, 'Lateral Dumbbell Raise', 20, 15, rpe: 9.5),
        set0(2, 'Lateral Dumbbell Raise', 20, 15, rpe: 9.5),
      ]);
      expect(c.pairs, 4); // 2 squat pairs + 2 bench pairs
      expect(c.unknown, 1);
      expect(c.findings, hasLength(1));
      expect(c.findings.single.exercise, 'Barbell Squat');
      expect(c.findings.single.rpe, 9);
      expect(c.findings.single.nextWeight, 260);
    });

    test('backoff readout renders in the Strength markdown section', () {
      final r = buildWeeklyReview(
        weekStart: wk,
        inputs: RecompInputs(
          strengthSets: [
            ReviewSet(date: d(0), exercise: 'Barbell Squat', reps: 5,
                weight: 260, rpe: 9),
            ReviewSet(date: d(0), exercise: 'Barbell Squat', reps: 5,
                weight: 260, rpe: 8.5),
          ],
        ),
        targets: targets(),
      );
      expect(r.backoff.findings, hasLength(1));
      final md = renderWeeklyReviewMarkdown(r);
      expect(md, contains('Fatigue-match (backoff_rule'));
      expect(md, contains('1 flagged'));
      // No sequences → the honest no-data line.
      final empty = buildWeeklyReview(
          weekStart: wk, inputs: const RecompInputs(), targets: targets());
      expect(renderWeeklyReviewMarkdown(empty),
          contains('no main-lift back-off sequences'));
    });

    test('pain outranks: decision Q8 leads with pain when flagged', () {
      final r = buildWeeklyReview(
        weekStart: wk,
        inputs: RecompInputs(
          recovery: [
            RecoveryRow(date: d(1), sleepHours: 8, fatigue: 1, soreness: 1,
                pain: 'right knee pain'),
          ],
        ),
        targets: targets(),
      );
      expect(r.decision[7].answer.toLowerCase(), contains('pain'));
      expect(r.decision[7].verdict, ReviewVerdict.no);
    });
  });
}
