// Unit tests for lib/services/sim_fit.dart — the shared fitting layer
// extracted from tool/sim_calibrate.dart (W2, design doc
// airledger/docs/superpowers/specs/2026-09-25-sim-design.md §7).
// The walk-forward acceptance gate lives in sim_gate_test.dart.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/sim_fit.dart';

/// A synthetic series: [weeks] entries, bw from [bwOf], squat e1RM from
/// [e1rmOf] (null = untrained week); every other channel quiet.
WeeklySeries synthetic(
  int weeks, {
  required double? Function(int i) bwOf,
  double? Function(int i)? e1rmOf,
  double? Function(int i)? gradeOf,
  int Function(int i)? climbSessionsOf,
}) {
  final mondays = [
    for (var i = 0; i < weeks; i++) DateTime(2024, 1, 1 + 7 * i),
  ];
  return WeeklySeries(
    mondays: mondays,
    bwRaw: [for (var i = 0; i < weeks; i++) bwOf(i)],
    e1rmRaw: {
      for (final l in simLifts)
        l: [
          for (var i = 0; i < weeks; i++)
            l == 'squat' ? (e1rmOf?.call(i)) : null,
        ],
    },
    bestActualRaw: {
      for (final l in simLifts) l: List<double?>.filled(weeks, null),
    },
    nearMax: {for (final l in simLifts) l: List<int>.filled(weeks, 0)},
    climbSessions: [
      for (var i = 0; i < weeks; i++) climbSessionsOf?.call(i) ?? 0,
    ],
    gradeP75Raw: [for (var i = 0; i < weeks; i++) gradeOf?.call(i)],
    wilks: List<double?>.filled(weeks, null),
    wilksTotalLbs: List<double?>.filled(weeks, null),
  );
}

void main() {
  group('math helpers', () {
    test('carryForward fills nulls with the last value, leading nulls stay',
        () {
      expect(
        carryForward([null, 1.0, null, null, 2.0, null]),
        [null, 1.0, 1.0, 1.0, 2.0, 2.0],
      );
    });

    test('percentile interpolates (p75 of 1..5 = 4)', () {
      expect(percentile([1, 2, 3, 4, 5], 0.75), 4.0);
      expect(percentile([1, 2], 0.75), closeTo(1.75, 1e-9));
    });

    test('ols recovers exact linear coefficients', () {
      // y = 3 + 2x, no noise.
      final xs = [0.0, 1.0, 2.0, 3.0, 4.0];
      final beta = ols(
        [for (final x in xs) [1.0, x]],
        [for (final x in xs) 3 + 2 * x],
      )!;
      expect(beta[0], closeTo(3, 1e-9));
      expect(beta[1], closeTo(2, 1e-9));
      final f = fitStats(
        [for (final x in xs) [1.0, x]],
        [for (final x in xs) 3 + 2 * x],
        beta,
      );
      expect(f.r2, closeTo(1, 1e-9));
      expect(f.mae, closeTo(0, 1e-9));
    });

    test('ols returns null on a singular design matrix', () {
      // Second column identical to the first → singular.
      expect(
        ols([
          [1.0, 1.0],
          [1.0, 1.0],
          [1.0, 1.0],
        ], [
          1.0,
          2.0,
          3.0,
        ]),
        isNull,
      );
    });
  });

  group('phase detection', () {
    test('gain / loss / flat runs from a synthetic bw trajectory', () {
      // 20 flat weeks at 170, 20 gaining +0.5/wk, 20 losing -0.8/wk.
      final s = synthetic(60, bwOf: (i) {
        if (i < 20) return 170;
        if (i < 40) return 170 + 0.5 * (i - 19);
        return 180 - 0.8 * (i - 39);
      });
      final runs = detectPhaseRuns(s);
      expect(runs.first.label, 'flat');
      expect(runs.map((r) => r.label), contains('gain'));
      expect(runs.last.label, 'loss');
      // Runs tile the series contiguously.
      expect(runs.first.start, 0);
      expect(runs.last.end, 59);
      for (var i = 1; i < runs.length; i++) {
        expect(runs[i].start, runs[i - 1].end + 1);
      }
    });

    test('short runs (< 4 wk) are merged away', () {
      final s = synthetic(30, bwOf: (i) => 170 + (i == 15 ? 3.0 : 0.0));
      for (final r in detectPhaseRuns(s)) {
        expect(r.end - r.start + 1, greaterThanOrEqualTo(4));
      }
    });
  });

  group('block observations', () {
    test('strength blocks need 2 trained weeks + fresh endpoint', () {
      // 12 gaining weeks; squat trained every week → 2 full blocks
      // (i=0..4, 4..8; block 8..12 needs index 12 which doesn't exist).
      final s = synthetic(
        13,
        bwOf: (i) => 170 + 0.5 * i,
        e1rmOf: (i) => 200 + 2.0 * i,
      );
      final obs = blockObservations(s, detectPhaseRuns(s));
      expect(obs.strength, isNotEmpty);
      for (final o in obs.strength) {
        expect(o.lift, 'squat');
        expect(o.velocity, closeTo(2.0, 1e-9));
        expect(o.bwRate, closeTo(0.5, 1e-9));
      }
    });

    test('untrained lift yields no blocks', () {
      final s = synthetic(13, bwOf: (i) => 170 + 0.5 * i); // no e1rm at all
      final obs = blockObservations(s, detectPhaseRuns(s));
      expect(obs.strength, isEmpty);
    });

    test('level observations pair non-carried p75 with bw', () {
      final s = synthetic(
        10,
        bwOf: (i) => 170,
        gradeOf: (i) => i.isEven ? 5.0 : null,
      );
      final obs = blockObservations(s, detectPhaseRuns(s));
      expect(obs.level.length, 5);
      expect(obs.level.first.p75, 5.0);
      expect(obs.level.first.bwLb, 170.0);
    });
  });

  group('WeeklySeries JSON codec', () {
    test('round-trips losslessly', () {
      final s = synthetic(
        8,
        bwOf: (i) => i < 2 ? null : 170.0 + i,
        e1rmOf: (i) => i.isEven ? 200.0 + i : null,
        gradeOf: (i) => i == 5 ? 5.5 : null,
        climbSessionsOf: (i) => i % 3,
      );
      final back = WeeklySeries.fromJson(
        // Force a real encode/decode boundary shape (string keys, lists).
        (s.toJson()),
      );
      expect(back.mondays, s.mondays);
      expect(back.bwRaw, s.bwRaw);
      expect(back.e1rmRaw, s.e1rmRaw);
      expect(back.bestActualRaw, s.bestActualRaw);
      expect(back.nearMax, s.nearMax);
      expect(back.climbSessions, s.climbSessions);
      expect(back.gradeP75Raw, s.gradeP75Raw);
      expect(back.wilks, s.wilks);
      expect(back.wilksTotalLbs, s.wilksTotalLbs);
    });
  });

  group('fitFromSeries (refit-on-demand)', () {
    test('recovers a clean linear bw-rate response', () {
      // Alternate 8-week gain (+0.5) and loss (-0.5) stretches; squat
      // velocity exactly 1 + 2·rate every week.
      var e = 200.0;
      final rates = <double>[];
      for (var i = 0; i < 64; i++) {
        rates.add(i % 16 < 8 ? 0.5 : -0.5);
      }
      var bw = 170.0;
      final bws = <double>[];
      final es = <double>[];
      for (var i = 0; i < 64; i++) {
        bws.add(bw);
        es.add(e);
        bw += rates[i];
        e += 1 + 2 * rates[i];
      }
      final s = synthetic(64, bwOf: (i) => bws[i], e1rmOf: (i) => es[i]);
      final c = fitFromSeries(s);
      final squat = c.strength['squat'];
      expect(squat, isNotNull);
      // Block velocities are exact; detection boundaries only trim obs.
      expect(squat!.bBw, closeTo(2.0, 0.2));
      expect(squat.a, closeTo(1.0, 0.15));
      // Pooled fallback serves lifts with no history.
      expect(c.strengthFor('bench'), isNotNull);
      expect(c.strengthFor('bench')!.bBw, squat.bBw);
    });
  });
}
