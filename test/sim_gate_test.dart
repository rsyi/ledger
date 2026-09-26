// W2 ACCEPTANCE GATE (design doc
// airledger/docs/superpowers/specs/2026-09-25-sim-design.md §7):
// reproduce the calibration study's S4/C2 walk-forward MAE table to
// within ±0.1 from the frozen weekly-series fixture — pure Dart, no
// network. The fixture (test/fixtures/sim_weekly_series.json) was
// generated once from the live workbook via
// `dart run tool/sim_calibrate.dart --fixture ...` on 2026-09-25, the
// same run that produced the committed study markdown (verified
// byte-identical against docs/superpowers/specs/2026-09-25-sim-calibration-study.md).
//
// Also gated here: the refit path (fitFromSeries) must reproduce the
// world_model.yaml shipped coefficients from the same fixture, and the
// design's directional "must beat flat" rows must hold.
@Tags(['sim_gate'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/sim_fit.dart';

const _fixturePath = 'test/fixtures/sim_weekly_series.json';

/// The design-doc §7 gate table: window → output → (flat MAE, sim MAE,
/// beatFlat?). Sim column = S4 for strength/Wilks, C2 for the grade.
const _gate = <String, Map<String, (double, double, bool)>>{
  '2024 bulk (Apr–Jul 2024)': {
    'squat e1RM (lb)': (22.2, 16.1, true),
    'bench e1RM (lb)': (10.9, 14.7, false),
    'deadlift e1RM (lb)': (21.0, 23.4, false),
    'press e1RM (lb)': (7.7, 7.5, true),
    'Wilks (derived, S4)': (22.7, 20.1, true),
  },
  '2025 bulk (Nov 2024 – Oct 2025)': {
    'squat e1RM (lb)': (24.2, 28.1, false),
    'bench e1RM (lb)': (14.9, 15.9, false),
    'deadlift e1RM (lb)': (26.7, 41.3, false),
    'press e1RM (lb)': (8.8, 9.6, false),
    'Wilks (derived, S4)': (27.4, 38.1, false),
  },
  'current cut (since 2025-10-06)': {
    'squat e1RM (lb)': (37.9, 27.7, true),
    'bench e1RM (lb)': (13.0, 11.8, true),
    'deadlift e1RM (lb)': (118.1, 93.7, true),
    'press e1RM (lb)': (47.3, 54.6, false),
    'Wilks (derived, S4)': (49.6, 45.9, true),
    'climb grade p75 (V)': (0.71, 0.62, true),
  },
};

void main() {
  final file = File(_fixturePath);
  final series = WeeklySeries.fromJson(
    jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
  );

  test('fixture is the study\'s frozen input (804 weeks through 2026-09-21)',
      () {
    expect(series.length, 804);
    expect(series.mondays.first, DateTime(2011, 5, 2));
    expect(series.mondays.last, DateTime(2026, 9, 21));
    // Study state vector (latest week).
    final last = series.length - 1;
    expect(series.bw[last], closeTo(160.6, 0.05));
    expect(series.e1rm['squat']![last], closeTo(311.7, 0.05));
    expect(series.e1rm['bench']![last], closeTo(247.5, 0.05));
    expect(series.e1rm['deadlift']![last], closeTo(351.8, 0.051));
    expect(series.e1rm['press']![last], closeTo(144.0, 0.05));
    expect(series.wilks[last], closeTo(321.2, 0.05));
    expect(series.gradeP75[last], closeTo(5.0, 1e-9));
  });

  test('walk-forward S4/C2 MAE table reproduces the study within ±0.1', () {
    final wf = walkForward(series);
    final failures = <String>[];
    _gate.forEach((window, outputs) {
      outputs.forEach((output, expected) {
        final (flatMae, simMae, mustBeatFlat) = expected;
        final row = wf.row(window, output);
        if (row == null) {
          failures.add('$window / $output: row missing');
          return;
        }
        final simKey = output.startsWith('climb') ? 'C2' : 'S4';
        final sim = row.models[simKey];
        if ((row.flat - flatMae).abs() > 0.1 + 1e-9) {
          failures.add('$window / $output: flat '
              '${row.flat.toStringAsFixed(2)} vs $flatMae');
        }
        if (sim == null || (sim - simMae).abs() > 0.1 + 1e-9) {
          failures.add('$window / $output: $simKey '
              '${sim?.toStringAsFixed(2)} vs $simMae');
        }
        if (mustBeatFlat && (sim == null || sim >= row.flat)) {
          failures.add('$window / $output: $simKey must beat flat '
              '($sim vs ${row.flat})');
        }
      });
    });
    expect(failures, isEmpty,
        reason: 'gate deviations >0.1 MAE:\n${failures.join('\n')}');
  });

  test('directional acceptance: aggregates beat flat where required', () {
    final wf = walkForward(series);
    // Wilks beats flat on the 2024 bulk and the current cut.
    for (final w in ['2024 bulk (Apr–Jul 2024)',
        'current cut (since 2025-10-06)']) {
      final row = wf.row(w, 'Wilks (derived, S4)')!;
      expect(row.models['S4']!, lessThan(row.flat), reason: w);
    }
    // Grade beats flat on the only window with climbing data.
    final grade =
        wf.row('current cut (since 2025-10-06)', 'climb grade p75 (V)')!;
    expect(grade.models['C2']!, lessThan(grade.flat));
  });

  test('refit from the fixture reproduces world_model.yaml coefficients',
      () {
    final c = fitFromSeries(series);
    // Shipped values are the study fits rounded (3–4 dp) — the refit
    // must land within rounding distance.
    expect(c.strength['squat']!.a, closeTo(-0.280, 0.0006));
    expect(c.strength['squat']!.bBw, closeTo(2.295, 0.0006));
    expect(c.strength['bench']!.a, closeTo(-0.099, 0.0006));
    expect(c.strength['bench']!.bBw, closeTo(0.919, 0.0006));
    expect(c.strength['deadlift']!.a, closeTo(0.775, 0.0006));
    expect(c.strength['deadlift']!.bBw, closeTo(0.795, 0.0006));
    expect(c.strength['press']!.a, closeTo(-0.143, 0.0006));
    expect(c.strength['press']!.bBw, closeTo(0.352, 0.0006));
    expect(c.climbC0!, closeTo(8.56, 0.005));
    expect(c.climbCBw!, closeTo(-0.0288, 0.00006));
    expect(c.climbBf!, closeTo(0.0032, 0.00006));
  });
}
