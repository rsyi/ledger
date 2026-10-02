import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/projection_snapshot.dart';
import 'package:airledger/services/projection_tracking.dart';

DateTime d(int m, int day) => DateTime(2026, m, day);

List<ProjectionPoint> line(double v0, double perWeek, {double band = 1}) => [
  for (var k = 0; k < 13; k++)
    ProjectionPoint(
      DateTime.utc(2026, 9, 21).add(Duration(days: 7 * k)),
      v0 + perWeek * k,
      v0 + perWeek * k - band,
      v0 + perWeek * k + band,
    ),
];

void main() {
  group('actuals', () {
    test('bodyweight: mean of per-day means over the trailing 7 days', () {
      final rows = [
        WeightRow(date: d(9, 24), weightLbs: 160),
        WeightRow(date: d(9, 24), weightLbs: 162), // same day → 161
        WeightRow(date: d(9, 30), weightLbs: 159),
        WeightRow(date: d(9, 23), weightLbs: 170), // outside the window
        WeightRow(date: d(10, 1), weightLbs: 999), // after the day
      ];
      expect(bodyweightActualAt(rows, d(9, 30)), closeTo(160, 1e-9));
      expect(bodyweightActualAt(rows, d(9, 10)), isNull);
    });

    test('body fat: trailing week mean, else latest within 28 days', () {
      final r = [
        BodyFatReading(d(9, 1), 13.0),
        BodyFatReading(d(9, 20), 12.0),
        BodyFatReading(d(9, 28), 11.6),
        BodyFatReading(d(9, 29), 11.8),
      ];
      expect(bodyFatActualAt(r, d(9, 30)), closeTo(11.7, 1e-9));
      expect(bodyFatActualAt(r, d(9, 27)), closeTo(12.0, 1e-9)); // fallback
      expect(bodyFatActualAt(r, d(10, 30)), isNull); // > 27 days stale
    });

    test('e1rm: best RPE-adjusted set of the latest week the lift trained', () {
      final rows = [
        StrengthRow(
          date: d(9, 8),
          exercise: 'Barbell Squat',
          weight: 400,
          reps: 1,
          rpe: 10,
        ),
        StrengthRow(
          date: d(9, 21),
          exercise: 'Barbell Squat',
          weight: 300,
          reps: 1,
          rpe: 8,
        ), // 300 × (1 + 3/30) = 330
        StrengthRow(
          date: d(9, 23),
          exercise: 'Barbell Squat',
          weight: 225,
          reps: 5,
        ), // 225 × (1 + 5/30) = 262.5 (same week, lower)
        StrengthRow(
          date: d(9, 22),
          exercise: 'Flat Barbell Bench Press',
          weight: 200,
          reps: 1,
          rpe: 8,
        ),
        StrengthRow(
          date: d(9, 30),
          exercise: 'Barbell Squat',
          weight: 100,
          reps: 1,
        ), // after the day
        StrengthRow(
          date: d(9, 22),
          exercise: 'Dumbbell Curl',
          weight: 40,
          reps: 10,
        ),
      ];
      final e = e1rmActualsAt(rows, d(9, 27));
      expect(e['squat'], closeTo(330, 1e-9));
      expect(e['bench'], closeTo(220, 1e-9));
      expect(e.containsKey('deadlift'), isFalse);
      final a = projectionActualsAt(day: d(9, 27), strength: rows);
      expect(a[ProjectionMetric.strengthTotal], isNull); // no deadlift
      expect(a[ProjectionMetric.e1rmSquat], closeTo(330, 1e-9));
      expect(a[ProjectionMetric.vo2max], isNull);
    });

    test('e1rm: rolling 7 days keeps last Saturday\'s top over this '
        'Wednesday\'s volume sets; carries back when untrained', () {
      final rows = [
        StrengthRow(
          date: d(9, 26),
          exercise: 'Overhead Press',
          weight: 120,
          reps: 5,
          rpe: 8.5,
        ), // 146
        StrengthRow(
          date: d(9, 30),
          exercise: 'Overhead Press',
          weight: 90,
          reps: 10,
          rpe: 7,
        ), // 126 (volume)
        StrengthRow(
          date: d(9, 1),
          exercise: 'Barbell Deadlift',
          weight: 300,
          reps: 3,
          rpe: 8,
        ), // 300 × (1 + 5/30) = 350
        StrengthRow(
          date: d(8, 28),
          exercise: 'Barbell Deadlift',
          weight: 310,
          reps: 1,
          rpe: 8,
        ), // 341 (inside the carried window)
        StrengthRow(
          date: d(8, 20),
          exercise: 'Barbell Deadlift',
          weight: 400,
          reps: 1,
          rpe: 8,
        ), // outside it
      ];
      final e = e1rmActualsAt(rows, d(10, 1));
      expect(e['press'], closeTo(146, 1e-9));
      expect(e['deadlift'], closeTo(350, 1e-9));
      expect(e1rmActualsAt(rows, d(10, 3))['press'], closeTo(126, 1e-9));
    });

    test('climbing: 4-week p75 with ≥ 5 grades, steps back when thin', () {
      final climbs = [
        for (final g in [3, 4, 5, 5, 6]) (date: d(9, 2), vGrade: g),
        (date: d(9, 29), vGrade: 7),
        (date: d(9, 29), vGrade: null),
      ];
      // Week of Sep 28: window Sep 7..Oct 4 has 1 numeric → thin; step
      // back to the week of Sep 21 (window Aug 31..Sep 27) → 5 grades.
      expect(climbingActualAt(climbs, d(9, 30)), closeTo(5, 1e-9));
      // Week of Sep 1: window Aug 11..Sep 7 → the five + p75 = 5.
      expect(climbingActualAt(climbs, d(9, 3)), closeTo(5, 1e-9));
      expect(climbingActualAt(const [], d(9, 3)), isNull);
    });
  });

  group('projectionAt', () {
    test('interpolates between weeks, clamps past the end', () {
      final pts = line(160, -0.7);
      final mid = projectionAt(pts, d(9, 24))!; // 3/7 of week 0→1
      expect(mid.projected, closeTo(160 - 0.3, 1e-9));
      expect(mid.lo, closeTo(160 - 0.3 - 1, 1e-9));
      expect(projectionAt(pts, d(9, 21))!.projected, 160);
      expect(
        projectionAt(pts, DateTime(2027, 3, 1))!.projected,
        closeTo(160 - 0.7 * 12, 1e-9),
      );
      expect(projectionAt(pts, d(9, 1)), isNull);
      expect(projectionAt(const [], d(9, 25)), isNull);
    });
  });

  group('status + direction semantics', () {
    test('cut bodyweight: below the band = ahead, above = behind', () {
      final pts = line(160, -0.7);
      MetricTracking t(double a) => trackMetric(
        metric: ProjectionMetric.bodyweight,
        points: pts,
        day: d(9, 28),
        actual: a,
        emphasis: 'cut',
      );
      expect(t(159.3).status, TrackingStatus.onTrack);
      expect(t(157.9).status, TrackingStatus.ahead);
      expect(t(157.9).line, '1.4 lb ahead of projection');
      expect(t(160.8).status, TrackingStatus.behind);
      expect(t(160.8).line, '1.5 lb behind projection');
      expect(t(159.0).line, '−0.3 lb vs projection (within range)');
      expect(t(159.3).line, 'on projection (within range)');
    });

    test('strength: above = ahead, below = behind (also in a cut)', () {
      final pts = line(900, -2, band: 27);
      MetricTracking t(double a) => trackMetric(
        metric: ProjectionMetric.strengthTotal,
        points: pts,
        day: d(9, 28),
        actual: a,
        emphasis: 'cut',
      );
      expect(t(886).status, TrackingStatus.onTrack);
      expect(t(886).line, '−12 lb vs projection (within range)');
      expect(t(860).status, TrackingStatus.behind);
      expect(t(860).line, '38 lb behind projection');
      expect(t(940).status, TrackingStatus.ahead);
    });

    test('body fat is always down-good', () {
      final pts = line(12, -0.1, band: 1);
      final t = trackMetric(
        metric: ProjectionMetric.bodyFat,
        points: pts,
        day: d(9, 21),
        actual: 10.5,
        emphasis: 'lifting',
      );
      expect(t.status, TrackingStatus.ahead);
      expect(t.line, '1.5 pts ahead of projection');
    });

    test('hold bodyweight (flat block): outside either way = behind', () {
      final pts = line(158, 0.05);
      expect(
        goodDirectionFor(
          ProjectionMetric.bodyweight,
          emphasis: 'lifting',
          points: pts,
        ),
        GoodDirection.hold,
      );
      final hi = trackMetric(
        metric: ProjectionMetric.bodyweight,
        points: pts,
        day: d(9, 21),
        actual: 160,
        emphasis: 'lifting',
      );
      expect(hi.status, TrackingStatus.behind);
      expect(hi.line, '2.0 lb above projection');
      // A gaining block (≥ 2 lb over the block) is up-good.
      expect(
        goodDirectionFor(
          ProjectionMetric.bodyweight,
          emphasis: 'reverse',
          points: line(154, 0.3),
        ),
        GoodDirection.up,
      );
    });

    test('no actual / before the block → no_data', () {
      final pts = line(160, -0.7);
      final t = trackMetric(
        metric: ProjectionMetric.vo2max,
        points: pts,
        day: d(9, 28),
        actual: null,
      );
      expect(t.status, TrackingStatus.noData);
      expect(t.status.wire, 'no_data');
      expect(t.line, 'no data yet');
      expect(
        trackMetric(
          metric: ProjectionMetric.bodyweight,
          points: pts,
          day: d(9, 1),
          actual: 160,
        ).status,
        TrackingStatus.noData,
      );
    });
  });

  group('snapshot-level', () {
    ProjectionSnapshot snap() => ProjectionSnapshot(
      block: 0,
      madeAt: DateTime.utc(2026, 10, 2),
      programVersion: '16',
      inputs: const {'block_emphasis': 'cut'},
      metrics: {
        ProjectionMetric.bodyweight: line(163, -0.75),
        ProjectionMetric.strengthTotal: line(900, -2.25, band: 27),
      },
    );

    test('trackSnapshot tracks every metric with the block emphasis', () {
      final t = trackSnapshot(snap(), {
        ProjectionMetric.bodyweight: 157.9,
        ProjectionMetric.strengthTotal: 890,
      }, d(10, 5));
      expect(t.keys, [
        ProjectionMetric.bodyweight,
        ProjectionMetric.strengthTotal,
      ]);
      // projected Oct 5 = 163 − 1.5 = 161.5 → 3.6 below → ahead.
      expect(t[ProjectionMetric.bodyweight]!.status, TrackingStatus.ahead);
      expect(t[ProjectionMetric.strengthTotal]!.status, TrackingStatus.onTrack);
    });

    test('blockResultLine: start → end vs projected, strength % change', () {
      final line = blockResultLine(snap(), {
        ProjectionMetric.bodyweight: 155.8,
        ProjectionMetric.strengthTotal: 886.5,
      }, DateTime(2026, 12, 14));
      expect(
        line,
        'Cut: 163 → 155.8 vs projected 154; strength −1.5% vs projected −3%',
      );
      expect(blockResultLine(snap(), const {}, DateTime(2026, 12, 14)), isNull);
    });
  });
}
