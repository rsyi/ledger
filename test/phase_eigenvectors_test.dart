import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/home_synthesis.dart' show StatusWeek;
import 'package:airledger/services/phase_eigenvectors.dart';
import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_metrics.dart' show WeightRow;
import 'package:airledger/services/program_observed.dart';
import 'package:airledger/services/wilks.dart';

WilksWeek _wk(DateTime monday, double wilks) => WilksWeek(
      weekStart: monday,
      wilks: wilks,
      totalLbs: 1000,
      bodyweightLbs: 160,
    );

void main() {
  group('parsePhaseEigenvectors', () {
    const yaml = '''
domains:
  - name: strength
    views: [strength]
phases:
  cut:
    eigenvectors:
      - id: weight_loss
        label: weight
        rate_band: [-1.0, -0.5]
        act_above: 0.2
        act_below: -1.5
      - id: wilks_stability
        from: "2026-09-21"
        floor_pct: 2.5
        act_weeks_below: 3
  bulk:
    eigenvectors:
      - id: gain_rate
        rate_band: [0.2, 0.5]
        act_above: 0.6
      - id: strength_gain
        floor_pct: 1.5
      - id: inputs_delivered
''';

    test('parses phases, bands, thresholds, defaults', () {
      final phases = parsePhaseEigenvectors(yaml)!;
      expect(phases.keys, containsAll(['cut', 'bulk']));
      final cut = phases['cut']!;
      expect(cut, hasLength(2));
      expect(cut[0].id, 'weight_loss');
      expect(cut[0].label, 'weight');
      expect(cut[0].rateBand, [-1.0, -0.5]);
      expect(cut[0].actAbove, 0.2);
      expect(cut[0].actBelow, -1.5);
      expect(cut[1].id, 'wilks_stability');
      expect(cut[1].from, DateTime(2026, 9, 21));
      expect(cut[1].floorPct, 2.5);
      expect(cut[1].actWeeksBelow, 3);
      final bulk = phases['bulk']!;
      expect(bulk.map((e) => e.id),
          ['gain_rate', 'strength_gain', 'inputs_delivered']);
      expect(bulk[1].actWeeksBelow, 3); // default
    });

    test('absent phases section → null (back-compat)', () {
      expect(parsePhaseEigenvectors('domains:\n  - name: x\n    views: [x]'),
          isNull);
      expect(parsePhaseEigenvectors(null), isNull);
      expect(parsePhaseEigenvectors(''), isNull);
      expect(parsePhaseEigenvectors('::: not yaml'), isNull);
    });

    test('bad entries are skipped, not fatal', () {
      final phases = parsePhaseEigenvectors('''
phases:
  cut:
    eigenvectors:
      - label: no id here
      - id: weight_loss
        rate_band: [only-one]
  broken: just a string
''')!;
      expect(phases.keys, ['cut']);
      expect(phases['cut']!.single.id, 'weight_loss');
      expect(phases['cut']!.single.rateBand, isNull); // malformed band
    });
  });

  group('effectivePhaseKey (program.yaml v8 variant selection)', () {
    const keys = ['cut', 'bulk', 'recomp', 'maintain', 'reverse'];

    test('recomposition variant redirects bulk → recomp', () {
      expect(
        effectivePhaseKey('bulk', variant: 'recomposition', available: keys),
        'recomp',
      );
    });

    test('non-bulk phases pass through under the variant', () {
      for (final p in ['cut', 'reverse', 'maintain', 'recomp']) {
        expect(
          effectivePhaseKey(p, variant: 'recomposition', available: keys),
          p,
        );
      }
    });

    test('no variant / unknown variant / no recomp set → unchanged', () {
      expect(
          effectivePhaseKey('bulk', variant: null, available: keys), 'bulk');
      expect(
          effectivePhaseKey('bulk', variant: 'bulk', available: keys), 'bulk');
      expect(
        effectivePhaseKey('bulk',
            variant: 'recomposition', available: const ['cut', 'bulk']),
        'bulk',
      );
    });
  });

  group('rateBandVerdict', () {
    const band = [-1.0, -0.5];

    test('unknown without observed or band', () {
      expect(rateBandVerdict(null, band), EigenVerdict.unknown);
      expect(rateBandVerdict(-0.7, null), EigenVerdict.unknown);
    });

    test('inside the band agrees', () {
      expect(rateBandVerdict(-0.75, band), EigenVerdict.agree);
      expect(rateBandVerdict(-0.5, band), EigenVerdict.agree);
      expect(rateBandVerdict(-1.0, band), EigenVerdict.agree);
    });

    test('outside the band drifts', () {
      expect(rateBandVerdict(-0.3, band), EigenVerdict.drifting);
      expect(rateBandVerdict(-1.2, band), EigenVerdict.drifting);
      expect(rateBandVerdict(0.1, band, actAbove: 0.2), EigenVerdict.drifting);
    });

    test('red edges act', () {
      expect(rateBandVerdict(0.2, band, actAbove: 0.2), EigenVerdict.act);
      expect(rateBandVerdict(0.5, band, actAbove: 0.2), EigenVerdict.act);
      expect(rateBandVerdict(-1.6, band, actBelow: -1.5), EigenVerdict.act);
      // Bulk: losing on a bulk is red.
      expect(rateBandVerdict(-0.3, const [0.2, 0.5], actBelow: -0.2),
          EigenVerdict.act);
    });
  });

  group('wilksStability', () {
    final anchor = DateTime(2026, 9, 21); // a Monday
    List<WilksWeek> weeks(List<double> values, {DateTime? start}) {
      final s = start ?? anchor;
      return [
        for (var i = 0; i < values.length; i++)
          _wk(DateTime(s.year, s.month, s.day + 7 * i), values[i]),
      ];
    }

    test('reference anchors to the weekly value as of from', () {
      // Lead-in weeks before the anchor; anchor week = 327.5.
      final series = [
        _wk(DateTime(2026, 9, 7), 330.0),
        _wk(DateTime(2026, 9, 14), 329.0),
        _wk(DateTime(2026, 9, 21), 327.5),
        _wk(DateTime(2026, 9, 28), 326.0),
      ];
      final s = wilksStability(
          weeks: series, from: anchor, floorPct: 2.5);
      expect(s.reference, 327.5);
      expect(s.floor, closeTo(319.3125, 1e-9));
      expect(s.current, 326.0);
      expect(s.weeksBelowFloor, 0);
      expect(s.verdict, EigenVerdict.agree); // above floor = holding
    });

    test('mid-week anchor uses that week (from need not be a Monday)', () {
      final series = weeks([327.5, 326.0]);
      final s = wilksStability(
          weeks: series, from: DateTime(2026, 9, 24), floorPct: 2.5);
      expect(s.reference, 327.5);
    });

    test('weeks below the floor count consecutively from the end', () {
      // floor = 327.5 * 0.975 = 319.3125
      final s1 = wilksStability(
          weeks: weeks([327.5, 325.0, 318.0]), from: anchor, floorPct: 2.5);
      expect(s1.weeksBelowFloor, 1);
      expect(s1.verdict, EigenVerdict.drifting);

      final s3 = wilksStability(
          weeks: weeks([327.5, 319.0, 318.5, 317.0]),
          from: anchor,
          floorPct: 2.5);
      expect(s3.weeksBelowFloor, 3);
      expect(s3.verdict, EigenVerdict.act);

      // A recovery week resets the streak.
      final reset = wilksStability(
          weeks: weeks([327.5, 318.0, 318.0, 322.0, 318.0]),
          from: anchor,
          floorPct: 2.5);
      expect(reset.weeksBelowFloor, 1);
      expect(reset.verdict, EigenVerdict.drifting);
    });

    test('weeks before the anchor never count toward the streak', () {
      // A deep dip before the phase started, recovered exactly at the
      // anchor: reference = anchor week's value.
      final series = [
        _wk(DateTime(2026, 9, 7), 300.0),
        _wk(DateTime(2026, 9, 14), 300.0),
        _wk(DateTime(2026, 9, 21), 327.5),
      ];
      final s = wilksStability(
          weeks: series, from: anchor, floorPct: 2.5);
      expect(s.weeksBelowFloor, 0);
      expect(s.verdict, EigenVerdict.agree);
    });

    test('requireGain: above floor but below reference is drifting', () {
      final s = wilksStability(
          weeks: weeks([327.5, 325.0]),
          from: anchor,
          floorPct: 1.5,
          requireGain: true);
      expect(s.verdict, EigenVerdict.drifting);
      final up = wilksStability(
          weeks: weeks([327.5, 330.0]),
          from: anchor,
          floorPct: 1.5,
          requireGain: true);
      expect(up.verdict, EigenVerdict.agree);
    });

    test('unknown without data or anchor', () {
      expect(
          wilksStability(weeks: const [], from: anchor, floorPct: 2.5).verdict,
          EigenVerdict.unknown);
      final s = wilksStability(
          weeks: weeks([327.5]), from: null, floorPct: 2.5);
      expect(s.verdict, EigenVerdict.unknown);
      expect(s.current, 327.5); // the number still shows
    });
  });

  group('quotaVerdict', () {
    test('no target in force → unknown (cut has no volume floor)', () {
      expect(quotaVerdict(14, null), EigenVerdict.unknown);
      expect(quotaVerdict(null, 28), EigenVerdict.unknown);
    });

    test('completed week ratios', () {
      expect(quotaVerdict(28, 28), EigenVerdict.agree);
      expect(quotaVerdict(26, 28), EigenVerdict.agree); // >= 90%
      expect(quotaVerdict(15, 28), EigenVerdict.drifting);
      expect(quotaVerdict(10, 28), EigenVerdict.act);
    });

    test('running week pro-rates by elapsed fraction', () {
      // Wednesday (3/7 elapsed): 6 of 28 ≈ half pace → drifting, not act.
      expect(quotaVerdict(6, 28, weekElapsedFraction: 3 / 7),
          EigenVerdict.drifting);
      expect(quotaVerdict(12, 28, weekElapsedFraction: 3 / 7),
          EigenVerdict.agree);
      // Range target uses its upper bound.
      expect(quotaVerdict(4, const [4, 6]), EigenVerdict.drifting);
      expect(quotaVerdict(6, const [4, 6]), EigenVerdict.agree);
    });
  });

  group('worstVerdict', () {
    test('ordering', () {
      expect(worstVerdict([EigenVerdict.agree, EigenVerdict.act]),
          EigenVerdict.act);
      expect(worstVerdict([EigenVerdict.agree, EigenVerdict.drifting]),
          EigenVerdict.drifting);
      expect(worstVerdict([EigenVerdict.agree, EigenVerdict.unknown]),
          EigenVerdict.agree);
      expect(worstVerdict([EigenVerdict.unknown]), EigenVerdict.unknown);
      expect(worstVerdict(const []), EigenVerdict.unknown);
    });
  });

  group('buildPhaseHero', () {
    final phases = parsePhaseEigenvectors('''
phases:
  cut:
    eigenvectors:
      - id: weight_loss
        rate_band: [-1.0, -0.5]
        act_above: 0.2
      - id: wilks_stability
        from: "2026-09-21"
        floor_pct: 2.5
  bulk:
    eigenvectors:
      - id: gain_rate
        rate_band: [0.2, 0.5]
        act_above: 0.6
        act_below: -0.2
      - id: inputs_delivered
''');

    final slice = ProgramSlice(
      id: 'bulk-2026-27',
      version: 6,
      block: {
        'number': 0,
        'emphasis': 'cut',
        'dates': ['2026-09-21', '2026-12-13'],
        'target_weight': [163, 154],
      },
      weekInBlock: 1,
      weekType: 'normal',
      todayTemplate: const {},
      targetsInForce: const {
        'near_max_sets': 4,
        'working_sets': null,
      },
      rulesInForce: const [],
    );

    const stats = ObservedWeightStats(
      bw7dAvg: 162.4,
      bwRateLbWk: -0.4,
      bw3wkChange: -1.2,
      recentRates: [-0.5, -0.3, -0.4],
      lastWeighIn: null,
    );

    final wilksWeeks = [
      _wk(DateTime(2026, 9, 14), 328.0),
      _wk(DateTime(2026, 9, 21), 327.5),
    ];

    test('null phases / undeclared phase → null (legacy dashboard)', () {
      expect(
        buildPhaseHero(
          phases: null,
          phaseValue: 'cut',
          targetRateLbWk: -0.75,
          slice: slice,
          stats: stats,
          weightDaily: const [],
          wilksWeeks: wilksWeeks,
          statusWeek: null,
          targets: slice.targetsInForce,
          today: DateTime(2026, 9, 21),
        ),
        isNull,
      );
      expect(
        buildPhaseHero(
          phases: phases,
          phaseValue: 'maintain', // not declared in this config
          targetRateLbWk: null,
          slice: slice,
          stats: stats,
          weightDaily: const [],
          wilksWeeks: wilksWeeks,
          statusWeek: null,
          targets: slice.targetsInForce,
          today: DateTime(2026, 9, 21),
        ),
        isNull,
      );
    });

    test('cut hero: header, trajectory, verdicts, detail lines', () {
      final hero = buildPhaseHero(
        phases: phases,
        phaseValue: 'cut',
        targetRateLbWk: -0.75,
        slice: slice,
        stats: stats,
        weightDaily: [
          for (var i = 0; i < 10; i++)
            WeightRow(
              date: DateTime(2026, 9, 12 + i),
              weightLbs: 163 - i * 0.1,
            ),
        ],
        wilksWeeks: wilksWeeks,
        statusWeek: null,
        targets: slice.targetsInForce,
        today: DateTime(2026, 9, 23),
      )!;
      expect(hero.phaseTitle, 'Cut');
      expect(hero.blockLine, 'block 0 · wk 1 · day 3 of 84');
      expect(hero.trajectory, '163 → 154 lb by Dec 13');
      expect(hero.rows, hasLength(2));

      final weight = hero.rows[0];
      expect(weight.label, 'weight');
      // observed = -1.2 / 3 = -0.40 → outside [-1.0, -0.5] → drifting.
      expect(weight.verdict, EigenVerdict.drifting);
      expect(weight.detail, '162.4 lb · -0.40 lb/wk · target -0.75');
      expect(weight.spark, isNotEmpty);
      expect(weight.nav, EigenNav.program);

      final wilks = hero.rows[1];
      expect(wilks.label, 'strength');
      expect(wilks.verdict, EigenVerdict.agree);
      expect(wilks.detail, 'Wilks 327.5 · floor 319.3');
      expect(wilks.sparkReference, 327.5);
      expect(wilks.sparkFloor, closeTo(319.3125, 1e-9));
      expect(wilks.nav, EigenNav.strength);
      expect(hero.overall, EigenVerdict.drifting);
    });

    test('breached floor: detail switches to the streak count', () {
      final hero = buildPhaseHero(
        phases: phases,
        phaseValue: 'cut',
        targetRateLbWk: -0.75,
        slice: slice,
        stats: stats,
        weightDaily: const [],
        wilksWeeks: [
          _wk(DateTime(2026, 9, 21), 327.5),
          _wk(DateTime(2026, 9, 28), 318.0), // under floor 319.3125
          _wk(DateTime(2026, 10, 5), 317.0),
        ],
        statusWeek: null,
        targets: slice.targetsInForce,
        today: DateTime(2026, 10, 7),
      )!;
      final wilks = hero.rows[1];
      expect(wilks.verdict, EigenVerdict.drifting);
      expect(wilks.detail, 'Wilks 317.0 · 2 wk below floor');
    });

    test('cut on pace → weight row agrees', () {
      final hero = buildPhaseHero(
        phases: phases,
        phaseValue: 'cut',
        targetRateLbWk: -0.75,
        slice: slice,
        stats: const ObservedWeightStats(
          bw7dAvg: 161.0,
          bwRateLbWk: -0.8,
          bw3wkChange: -2.25,
          recentRates: [-0.8, -0.7, -0.75],
          lastWeighIn: null,
        ),
        weightDaily: const [],
        wilksWeeks: wilksWeeks,
        statusWeek: null,
        targets: slice.targetsInForce,
        today: DateTime(2026, 10, 12),
      )!;
      expect(hero.rows[0].verdict, EigenVerdict.agree);
    });

    test('bulk hero: inputs row reads the status week vs targets', () {
      final hero = buildPhaseHero(
        phases: phases,
        phaseValue: 'bulk',
        targetRateLbWk: 0.4,
        slice: null, // offline docs — hero still renders
        stats: const ObservedWeightStats(
          bw7dAvg: 158.0,
          bwRateLbWk: 0.35,
          bw3wkChange: 1.05,
          recentRates: [0.3, 0.4, 0.35],
          lastWeighIn: null,
        ),
        weightDaily: const [],
        wilksWeeks: const [],
        statusWeek: StatusWeek(
          row: const {'near_max_sets': 6, 'working_sets': 22},
          weekMonday: DateTime.utc(2027, 3, 1),
          isCurrentWeek: false,
        ),
        targets: const {'near_max_sets': 6, 'working_sets': 28},
        today: DateTime(2027, 3, 10),
      )!;
      expect(hero.blockLine, isNull);
      final inputs = hero.rows[1];
      expect(inputs.label, 'inputs');
      // near-max 6/6 agree; working 22/28 ≈ 0.79 drifting → drifting.
      expect(inputs.verdict, EigenVerdict.drifting);
      expect(inputs.detail, 'near-max 6/6 · sets 22/28');
      expect(inputs.nav, EigenNav.status);
      // gain 0.35 in [0.2, 0.5] → agree.
      expect(hero.rows[0].verdict, EigenVerdict.agree);
    });

    test('unknown eigenvector id degrades to an unknown row', () {
      final p = parsePhaseEigenvectors('''
phases:
  cut:
    eigenvectors:
      - id: mystery_metric
''');
      final hero = buildPhaseHero(
        phases: p,
        phaseValue: 'cut',
        targetRateLbWk: null,
        slice: null,
        stats: stats,
        weightDaily: const [],
        wilksWeeks: const [],
        statusWeek: null,
        targets: const {},
        today: DateTime(2026, 9, 23),
      )!;
      expect(hero.rows.single.verdict, EigenVerdict.unknown);
      expect(hero.rows.single.detail, 'unknown eigenvector');
    });
  });
}
