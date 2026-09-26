// Tests for lib/services/world_model.dart — the declared causal-graph
// config (design doc airledger/docs/superpowers/specs/2026-09-25-sim-design.md
// §6). The shipped file in airledger-fitness is parsed directly (the
// wm_fixture_test.dart pattern), pinning the app ↔ schema contract.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/world_model.dart';

const _shippedPath = '../airledger-fitness/app/world_model.yaml';

void main() {
  group('back-compat null contract', () {
    test('null / empty / garbage / driverless yaml → null', () {
      expect(parseWorldModel(null), isNull);
      expect(parseWorldModel(''), isNull);
      expect(parseWorldModel('   \n'), isNull);
      expect(parseWorldModel('::: not yaml {{{'), isNull);
      expect(parseWorldModel('just a scalar'), isNull);
      expect(parseWorldModel('version: 1\nnodes: []\n'), isNull);
      expect(parseWorldModel('drivers: [{target: x}]'), isNull,
          reason: 'driver without driver+coefficient is skipped → empty');
    });

    test('malformed entries are skipped, not fatal', () {
      final wm = parseWorldModel('''
version: 1
nodes:
  - not_a_map
  - { measure: x }               # no id → skipped
  - { id: bw, kind: input }
drivers:
  - { target: e1rm_squat, driver: bw, coefficient: 2.0 }
  - { target: broken }           # skipped
''');
      expect(wm, isNotNull);
      expect(wm!.nodes.length, 1);
      expect(wm.drivers.length, 1);
      expect(wm.drivers.single.form, 'linear'); // default
      expect(wm.drivers.single.intercept, 0); // default
      // Absent sim: → design defaults.
      expect(wm.sim.saturation.fullBelowPctOfPeak, 0.95);
      expect(wm.sim.saturation.zeroAtPctOfPeak, 1.05);
      expect(wm.sim.phaseRules.reverseRateLbWk, 0.15);
      expect(wm.sim.phaseRules.nextCycle.holdWeeks, 8);
      expect(wm.sim.wilksAnchor, 'actual_max_ratio');
    });
  });

  group('shipped world_model.yaml (airledger-fitness)', () {
    final file = File(_shippedPath);
    final wm = parseWorldModel(file.readAsStringSync());

    test('parses', () {
      expect(wm, isNotNull);
      expect(wm!.version, 1);
    });

    test('declares the 7 nodes of the design §6 graph', () {
      final ids = [for (final n in wm!.nodes) n.id];
      expect(ids, [
        'bw',
        'e1rm_squat',
        'e1rm_bench',
        'e1rm_deadlift',
        'e1rm_press',
        'grade_p75',
        'wilks',
      ]);
      expect(wm.nodes.first.kind, 'input');
      expect(wm.nodes.last.kind, 'derived');
      expect(
        wm.nodes[1].filter,
        {'lift': 'squat'},
      );
      expect(wm.nodes[1].measure, 'strength_tracker.max_e1rm_capped');
    });

    test('carries the study coefficients (S4 per-lift + C2 + b_f)', () {
      final wmv = wm!;
      WorldModelDriver bwDriver(String target) => wmv
          .driversOf(target)
          .firstWhere((d) => d.driver == 'bw');
      expect(bwDriver('e1rm_squat').coefficient, 2.295);
      expect(bwDriver('e1rm_squat').intercept, -0.280);
      expect(bwDriver('e1rm_squat').form, 'linear_rate');
      expect(bwDriver('e1rm_bench').coefficient, 0.919);
      expect(bwDriver('e1rm_deadlift').intercept, 0.775);
      expect(bwDriver('e1rm_press').coefficient, 0.352);
      expect(bwDriver('grade_p75').coefficient, -0.0288);
      expect(bwDriver('grade_p75').intercept, 8.56);
      expect(bwDriver('grade_p75').form, 'linear');
      final freq = wmv
          .driversOf('grade_p75')
          .firstWhere((d) => d.driver == 'climb_frequency');
      expect(freq.coefficient, 0.0032);
      // fit: audit trail survives parsing.
      expect(bwDriver('e1rm_squat').fit['n'], 88);
      expect(bwDriver('e1rm_squat').fit['method'], 'ols_4wk_blocks');
    });

    test('sim rules match the design doc', () {
      final sim = wm!.sim;
      expect(sim.saturation.fullBelowPctOfPeak, 0.95);
      expect(sim.saturation.zeroAtPctOfPeak, 1.05);
      expect(sim.phaseRules.cutEndsAt, 'target_or_date');
      expect(sim.phaseRules.earlyCutFiller, 'maintain');
      expect(sim.phaseRules.reverseRateLbWk, 0.15);
      expect(sim.phaseRules.nextCycle.holdWeeks, 8);
      expect(sim.phaseRules.nextCycle.bandTopLb, 170);
      expect(sim.phaseRules.nextCycle.cutTargetLb, 154);
      expect(sim.phaseRules.nextCycle.reverseWeeks, 3);
      expect(sim.levers.bulkRateLbWk.min, 0.1);
      expect(sim.levers.bulkRateLbWk.max, 0.6);
      expect(sim.levers.cutRateLbWk.min, -1.6);
      expect(sim.levers.cutRateLbWk.max, -0.5);
      expect(sim.levers.climbFrequency, [2, 3]);
      expect(sim.levers.horizonYr.max, 3);
      expect(sim.wilksAnchor, 'actual_max_ratio');
    });

    test('toCoefficients maps drivers onto the sim shape', () {
      final c = wm!.toCoefficients();
      expect(c.strength.keys.toSet(),
          {'squat', 'bench', 'deadlift', 'press'});
      expect(c.strength['squat']!.a, -0.280);
      expect(c.strength['squat']!.bBw, 2.295);
      expect(c.strength['deadlift']!.a, 0.775);
      expect(c.climbC0, 8.56);
      expect(c.climbCBw, -0.0288);
      expect(c.climbBf, 0.0032);
      expect(c.pooled, isNull);
      expect(c.strengthFor('squat')!.bBw, 2.295);
    });
  });
}
