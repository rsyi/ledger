import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/projection_replay.dart';
import 'package:airledger/services/projection_snapshot.dart';
import 'package:airledger/services/projection_tracking.dart';
import 'package:airledger/services/recomp_review.dart' show MealRow;
import 'package:airledger/services/sim2_harness.dart';
import 'package:airledger/services/sim2_model.dart';
import 'package:airledger/services/wm_tabs.dart' show WorkingMaxRow;

final _blocks = [
  Sim2Block(0, DateTime.utc(2026, 9, 21), DateTime.utc(2026, 12, 13), 'cut',
      -0.75),
  Sim2Block(1, DateTime.utc(2026, 12, 14), DateTime.utc(2027, 1, 3),
      'reverse', 0.15),
];

List<WeightRow> _weighIns() => [
      // Before the anchor: ~162 flat. After: a crash to 150 that the
      // replay must NOT see.
      for (var i = 0; i < 40; i++)
        WeightRow(
            date: DateTime(2026, 8, 13).add(Duration(days: i)),
            weightLbs: 162),
      for (var i = 1; i < 12; i++)
        WeightRow(
            date: DateTime(2026, 9, 21).add(Duration(days: i)),
            weightLbs: 150),
    ];

List<StrengthRow> _strength() => [
      StrengthRow(date: DateTime(2026, 9, 14), exercise: 'Barbell Squat',
          weight: 300, reps: 1, rpe: 8),
      StrengthRow(date: DateTime(2026, 9, 15), exercise:
          'Flat Barbell Bench Press', weight: 220, reps: 1, rpe: 8),
      StrengthRow(date: DateTime(2026, 9, 16), exercise: 'Barbell Deadlift',
          weight: 310, reps: 1, rpe: 8),
      // After the anchor — a huge squat the replay must ignore.
      StrengthRow(date: DateTime(2026, 9, 28), exercise: 'Barbell Squat',
          weight: 400, reps: 1, rpe: 8),
    ];

List<MealRow> _meals() => [
      for (var i = 0; i < 40; i++)
        MealRow(
          eatenAt: DateTime(2026, 8, 13, 12).add(Duration(days: i)),
          calories: 2000,
          proteinG: 160,
          carbsG: 200,
          fatG: 60,
        ),
    ];

ProjectionSnapshot _snap({DateTime? madeAt, double aScale = 1}) =>
    snapshotAtBlockStart(
      blocks: _blocks,
      blockN: 0,
      madeAt: madeAt ?? DateTime.utc(2026, 10, 2, 6),
      programVersion: '16',
      weighIns: _weighIns(),
      bodyFat: [BodyFatReading(DateTime(2026, 9, 20), 12.2)],
      strength: _strength(),
      meals: _meals(),
      workingMax: [
        WorkingMaxRow(
          lift: 'squat',
          variant: 'high_bar',
          valueLb: 320,
          effectiveFrom: DateTime(2026, 9, 1),
          source: 'seed',
          reason: '',
          readingId: '',
        ),
        WorkingMaxRow(
          lift: 'squat',
          variant: 'high_bar',
          valueLb: 345,
          effectiveFrom: DateTime(2026, 9, 29),
          source: 'rule',
          reason: '',
          readingId: '',
        ),
      ],
      aScale: aScale,
      mcPaths: 10,
    )!;

void main() {
  test('anchors use only data on/before the block start', () {
    final s = _snap();
    final a = s.inputs['anchors'] as Map;
    expect(a['bodyweight'], 162.0); // the post-anchor 150s are invisible
    expect(a['body_fat'], 12.2);
    expect((a['e1rm'] as Map)['squat'], 330.0); // not the Sep 28 400
    expect(s.metrics[ProjectionMetric.bodyweight]!.first.projected, 162);
    expect(s.metrics[ProjectionMetric.e1rmSquat]!.first.projected, 330);
    expect(s.inputs['data_through'], '2026-09-21');
    expect(s.inputs['training_maxes'], {'squat': 320.0});
  });

  test('nutrition estimated as of the anchor (flat bw at 2000 kcal)', () {
    final s = _snap();
    final n = s.inputs['nutrition'] as Map;
    expect(n['can_project'], isTrue);
    expect(n['intake_14d_kcal'], 2000);
    // Flat trend → maintenance ≈ intake → r ≈ 0, not the declared −0.75.
    expect(s.inputs['r_source'], 'nutrition');
    expect((s.inputs['r_lb_wk'] as num).abs(), lessThan(0.05));
  });

  test('replay (made days later) ignores tonight\'s recalibration scales',
      () {
    final late = _snap(aScale: 1.4);
    expect(late.inputs['replay'], isTrue);
    expect(late.inputs['a_scale'], 1.0);
    expect((late.inputs['params'] as Map)['a'], Sim2Params.fitted().a);
    final onTime = _snap(madeAt: DateTime.utc(2026, 9, 21, 23), aScale: 1.4);
    expect(onTime.inputs['replay'], isFalse);
    expect(onTime.inputs['a_scale'], 1.4);
    expect((onTime.inputs['params'] as Map)['a'],
        closeTo(Sim2Params.fitted().a * 1.4, 1e-9));
  });

  test('unknown block → null', () {
    expect(
      snapshotAtBlockStart(
        blocks: _blocks,
        blockN: 5,
        madeAt: DateTime.utc(2026, 10, 2),
        programVersion: '16',
      ),
      isNull,
    );
  });
}
