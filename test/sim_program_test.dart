// Tests for lib/services/sim_program.dart (the W3 lift of the sim
// assembly out of tool/sim_forecast.dart): SimProgram construction from
// the intent docs, the t0 state vector off a WeeklySeries, and the ±50%
// drift-guarded refit. Also covers the forecast-tab codec
// (lib/services/forecast_tab.dart) round-trip.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/forecast_tab.dart';
import 'package:airledger/services/sim_core.dart';
import 'package:airledger/services/sim_fit.dart';
import 'package:airledger/services/sim_program.dart';
import 'package:airledger/services/world_model.dart';

const _fixturePath = 'test/fixtures/sim_weekly_series.json';
const _shippedWmPath = '../airledger-fitness/app/world_model.yaml';

const _programYaml = '''
versions:
  - version: 1
    effective_from: "2026-09-21"
    blocks:
      - { n: 0, dates: ["2026-09-21", "2026-12-13"], emphasis: cut,      weight: [163, 154] }
      - { n: 1, dates: ["2026-12-14", "2027-01-03"], emphasis: reverse,  weight: [154, 155] }
      - { n: 2, dates: ["2027-01-04", "2027-02-28"], emphasis: climbing, weight: [154, 157], rate: 0.4 }
      - { n: 7, dates: ["2027-10-11", "2027-12-05"], emphasis: lifting,  weight: [168, 170], rate: 0.2 }
''';

const _phaseYaml = '''
versions:
  - version: 1
    value: cut
    effective_from: "2025-10-06"
    target_weight_lb: 154
    target_rate_lb_per_week: -0.75
''';

Map<Object?, Object?>? _yaml(String raw) {
  final y = loadYaml(raw);
  return y is Map ? Map<Object?, Object?>.from(y) : null;
}

void main() {
  final series = WeeklySeries.fromJson(
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, Object?>,
  );
  final shippedWm = parseWorldModel(
    File(_shippedWmPath).readAsStringSync(),
  )!;

  group('simProgramFromDocs', () {
    test('block 0 becomes the cut; blocks 1+ keep dates/emphasis/rate', () {
      final p = simProgramFromDocs(
        program: _yaml(_programYaml),
        phase: _yaml(_phaseYaml),
      )!;
      expect(p.cutTargetLb, 154);
      expect(p.cutEndDate, DateTime(2026, 12, 13));
      expect(p.blocks.map((b) => b.n), [1, 2, 7]);
      expect(p.blocks[0].emphasis, 'reverse');
      expect(p.blocks[0].rate, isNull);
      expect(p.blocks[1].start, DateTime(2027, 1, 4));
      expect(p.blocks[1].rate, 0.4);
      expect(p.blocks[2].end, DateTime(2027, 12, 5));
      expect(p.blocks[2].rate, 0.2);
    });

    test('missing phase doc falls back to the rules cut target', () {
      final p = simProgramFromDocs(
        program: _yaml(_programYaml),
        phase: null,
      )!;
      expect(p.cutTargetLb, 154); // NextCycleRule default
    });

    test('null / malformed / block-less program → null', () {
      expect(simProgramFromDocs(program: null, phase: null), isNull);
      expect(
        simProgramFromDocs(program: _yaml('versions: []'), phase: null),
        isNull,
      );
      expect(
        simProgramFromDocs(
          program: _yaml('versions:\n  - version: 1\n    blocks: nope'),
          phase: null,
        ),
        isNull,
      );
    });

    test('no block 0 → cut must end before the first block', () {
      const noCut = '''
versions:
  - version: 1
    blocks:
      - { n: 1, dates: ["2026-12-14", "2027-01-03"], emphasis: reverse }
''';
      final p = simProgramFromDocs(program: _yaml(noCut), phase: null)!;
      expect(p.cutEndDate, DateTime(2026, 12, 14));
    });
  });

  group('simInitialFromSeries', () {
    test('reproduces the study t0 state vector from the frozen fixture', () {
      final s = simInitialFromSeries(series)!;
      expect(s.monday, DateTime(2026, 9, 21));
      expect(s.bw, closeTo(160.6, 0.05));
      expect(s.e1rm['squat'], closeTo(311.7, 0.05));
      expect(s.e1rm['bench'], closeTo(247.5, 0.05));
      expect(s.e1rm['deadlift'], closeTo(351.8, 0.051));
      expect(s.e1rm['press'], closeTo(144.0, 0.05));
      expect(s.gradeP75, closeTo(5.0, 1e-9));
      // Peaks are all-time raw maxima — at least the current values.
      for (final l in simLifts) {
        expect(s.peak[l]!, greaterThanOrEqualTo(s.e1rm[l]!));
      }
      // All three SBD lifts have actual maxes in history → k-anchor set.
      expect(s.actualMaxSbdTotalLbs, isNotNull);
    });

    test('empty series → null', () {
      final empty = WeeklySeries(
        mondays: const [],
        bwRaw: const [],
        e1rmRaw: {for (final l in simLifts) l: const []},
        bestActualRaw: {for (final l in simLifts) l: const []},
        nearMax: {for (final l in simLifts) l: const []},
        climbSessions: const [],
        gradeP75Raw: const [],
        wilks: const [],
        wilksTotalLbs: const [],
      );
      expect(simInitialFromSeries(empty), isNull);
    });
  });

  group('guardedRefit', () {
    test('shipped model + its own source fixture → no drift, refit values',
        () {
      final g = guardedRefit(model: shippedWm, series: series);
      expect(g.drifted, isEmpty);
      // Refit values pass through (they match the shipped file to
      // rounding — sim_gate_test pins that).
      expect(g.coefficients.strength['squat']!.bBw, closeTo(2.295, 0.001));
      expect(g.coefficients.climbCBw, closeTo(-0.0288, 0.0001));
    });

    test('declared value >50% away from the refit → declared wins + tag',
        () {
      const driftedYaml = '''
version: 1
drivers:
  - target: e1rm_squat
    driver: bw
    form: linear_rate
    coefficient: 100.0
    intercept: -0.280
''';
      final wm = parseWorldModel(driftedYaml)!;
      final g = guardedRefit(model: wm, series: series);
      expect(g.drifted, contains('squat.b_bw'));
      // The DECLARED value is used, not the (refit ≈ 2.3) one.
      expect(g.coefficients.strength['squat']!.bBw, 100.0);
      // The intercept refit (≈ -0.280) is within 50% → refit passes.
      expect(g.drifted, isNot(contains('squat.a')));
    });
  });

  group('forecast tab codec', () {
    test('encode → parse round-trips the trajectory (grade anchored)', () {
      final result = simulate(
        initial: simInitialFromSeries(series)!,
        coefficients: shippedWm.toCoefficients(),
        rules: shippedWm.sim,
        program: simProgramFromDocs(
          program: _yaml(_programYaml),
          phase: _yaml(_phaseYaml),
        )!,
        levers: const SimLevers(horizonYears: 1),
      );
      final offset = gradeAnchorOffset(
        observedP75: 5.0,
        modelP75: result.weeks.first.gradeP75,
      );
      expect(offset, greaterThan(0)); // observed 5.0 above the raw model
      final table = forecastTabTable(result, gradeOffset: offset);
      expect(table.first, forecastTabHeaders);
      expect(table.length, 53); // header + 52 weeks

      final rows = parseForecastTab(table);
      expect(rows.length, 52);
      expect(rows.first.monday, DateTime(2026, 9, 21));
      expect(rows.first.phase, 'cut');
      expect(rows.first.bw, closeTo(160.6, 0.05));
      // Anchored: the first forecast grade IS the observed p75 (1dp).
      expect(rows.first.gradeP75, closeTo(5.0, 0.05));
      expect(rows.first.e1rm['deadlift'], closeTo(351.8, 0.051));
      // Wilks stays in its plausible band all year.
      for (final r in rows) {
        expect(r.wilks, inInclusiveRange(300, 340));
      }
    });

    test('parseForecastTab: empty / header-only / junk rows are safe', () {
      expect(parseForecastTab(const []), isEmpty);
      expect(parseForecastTab([forecastTabHeaders]), isEmpty);
      expect(
        parseForecastTab([
          forecastTabHeaders,
          ['not-a-date', 'cut', 'x', '', '', '', '', 'y', ''],
        ]),
        isEmpty,
      );
    });
  });
}
