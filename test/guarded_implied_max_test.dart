// Guarded implied-max TM rule (program.yaml v12 `tm_rule`) — unit tests
// against inline policies (no live-YAML dependency; the shared fixtures
// in airledger-fitness/coach/fixtures/wm_evaluate_cases.yaml pin the
// same behavior against the live program for both twins).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/working_max.dart';

const _tm = TmRule(); // defaults: +5 cap, round 5, 0.78 guard, clean < 9

LoadPolicy _policy({
  bool frozen = false,
  bool readingsIgnored = false,
  double? capRpe = 8.5,
  double? capAfterDrop = 8.5,
}) =>
    LoadPolicy(
      name: 'test_policy',
      targetRpeLow: 7.5,
      targetRpeHigh: 8,
      raiseIfRpeLte: null,
      raiseRequiresConsecutive: 1,
      holdBand: null,
      dropIfRpeGte: null,
      stepLb: const {'bench': 5, 'press': 5, 'squat': 5, 'deadlift': 5},
      frozen: frozen,
      capRpe: capRpe,
      capAfterDropRpe: capAfterDrop,
      consecutiveDropsAction: 'no_top_sets_next_week',
      readingsThatRaise: const [],
      readingsThatLower: const [],
      resetOnTest: true,
      readingsIgnored: readingsIgnored,
      saturdaySingle: false,
      applies: const {},
    );

Reading _reading({
  String lift = 'squat',
  double weight = 195,
  int reps = 5,
  double rpe = 8,
  String kind = 'heavy_top',
  bool grinder = false,
  bool missed = false,
}) =>
    Reading(
      date: DateTime.utc(2026, 10, 5),
      lift: lift,
      variant: 'belted',
      weightLb: weight,
      rawWeightLb: weight,
      reps: reps,
      rpe: rpe,
      kind: kind,
      grinder: grinder || rpe >= 9.5,
      missed: missed,
      variantMismatch: false,
    );

WmDecision _eval({
  required double wm,
  Reading? reading,
  LoadPolicy? policy,
  List<WmDecision> priors = const [],
  bool painCap = false,
}) =>
    evaluate(
      lift: 'squat',
      policy: policy ?? _policy(),
      workingMax: wm,
      date: DateTime.utc(2026, 10, 5),
      reading: reading,
      priorDecisions: priors,
      painCapActive: painCap,
      tmRule: _tm,
    );

void main() {
  group('guarded implied-max', () {
    test('top set at the prescription RPE holds (implied == TM)', () {
      // 240 TM, 195×5@8 → implied 195/0.811 = 240.4 → 240 → hold.
      final d = _eval(wm: 240, reading: _reading(weight: 195, reps: 5));
      expect(d.action, 'hold');
      expect(d.wmAfter, 240);
    });

    test('easy top raises, capped at +5/session', () {
      // 195×5@7 → implied 195/0.786 = 248.1 → 250 > 240 → +5 cap → 245.
      final d = _eval(wm: 240, reading: _reading(rpe: 7));
      expect(d.action, 'raise');
      expect(d.wmAfter, 245);
      expect(d.reason, contains('capped'));
    });

    test('a +5 implied raise lands uncapped', () {
      // wm 245, 230×1@8 → 230/0.922 = 249.5 → 250 = wm+5 → raise 250.
      final d = _eval(wm: 245, reading: _reading(weight: 230, reps: 1));
      expect(d.action, 'raise');
      expect(d.wmAfter, 250);
    });

    test('hard top drops in full to the implied max', () {
      // 195×5@9 → 195/0.837 = 233.0 → 235 < 240 → drop to 235, cap 8.5.
      final d = _eval(wm: 240, reading: _reading(rpe: 9));
      expect(d.action, 'drop');
      expect(d.wmAfter, 235);
      expect(d.capNextTopSetRpe, 8.5);
    });

    test('grinder drops at least −5, in full when implied is lower', () {
      // 185×5@9.5 (grinder) → implied 185/0.85 = 217.6 → 220 → full drop.
      final d = _eval(wm: 240, reading: _reading(weight: 185, rpe: 9.5));
      expect(d.action, 'drop');
      expect(d.wmAfter, 220);
    });

    test('grinder with a HIGH implied max still drops −5', () {
      // Ground a PR single: 250×1@9.5 → implied 255.6, but a grinder
      // never raises — min(255, 240−5) = 235.
      final d =
          _eval(wm: 240, reading: _reading(weight: 250, reps: 1, rpe: 9.5));
      expect(d.action, 'drop');
      expect(d.wmAfter, 235);
    });

    test('missed prescribed reps drops even when implied is high', () {
      final d = _eval(
          wm: 240,
          reading: _reading(weight: 225, reps: 3, rpe: 8, missed: true));
      expect(d.action, 'drop');
      expect(d.wmAfter, 235);
      expect(d.reason, contains('missed'));
    });

    test('sub-top reading (%TM volume slot) is recorded, never moves TM',
        () {
      // Wed squat volume 3x8@65%: 160×8@7 → implied 226 (< TM) but
      // 160 < 0.78×240 = 187.2 → the guard holds instead of cratering.
      final d = _eval(wm: 240, reading: _reading(weight: 160, reps: 8, rpe: 7));
      expect(d.action, 'hold');
      expect(d.wmAfter, 240);
      expect(d.reason, contains('sub-top'));
    });

    test('sub-top easy set cannot raise either', () {
      // 175×8@6 → implied 175/0.68 = 257 > TM, but sub-top → hold.
      final d = _eval(wm: 240, reading: _reading(weight: 175, reps: 8, rpe: 6));
      expect(d.action, 'hold');
    });

    test('test single is just a reading: implied /0.922, raise capped', () {
      // Old rule: reset to roundDown5(240/0.922) = 260. New: one rule,
      // raise capped at +5 → 255 (converges over later sessions).
      final d = _eval(
          wm: 250,
          reading: _reading(weight: 240, reps: 1, rpe: 8, kind: 'test'));
      expect(d.action, 'raise');
      expect(d.wmAfter, 255);
      expect(d.source, 'rule');
    });

    test('light-week reading recorded + ignored', () {
      final d = _eval(
          wm: 240,
          reading: _reading(weight: 230, reps: 1, rpe: 6, kind: 'light_week'));
      expect(d.action, 'hold');
      expect(d.wmAfter, 240);
    });

    test('deload reading (cut wave week 4) recorded + ignored', () {
      // 70%×5 deload top would imply ~0.86×TM — must never drop.
      final d = _eval(
          wm: 240,
          reading: _reading(weight: 170, reps: 5, rpe: 7, kind: 'deload'));
      expect(d.action, 'hold');
      expect(d.wmAfter, 240);
      expect(d.reason, contains('deload'));
    });

    test('frozen policy holds regardless of implied', () {
      final d = _eval(
        wm: 240,
        reading: _reading(rpe: 7),
        policy: _policy(frozen: true),
      );
      expect(d.action, 'hold');
      expect(d.wmAfter, 240);
    });

    test('second consecutive drop → no top sets next week', () {
      final prior = _eval(wm: 245, reading: _reading(weight: 199, rpe: 9));
      expect(prior.action, 'drop');
      final d = _eval(
          wm: prior.wmAfter,
          reading: _reading(weight: 195, rpe: 9),
          priors: [prior]);
      expect(d.action, 'drop');
      expect(d.noTopSetsNextWeek, isTrue);
    });

    test('pain cap freezes; clean session uses tm_rule clean_rpe_lt', () {
      final d = _eval(
        wm: 240,
        reading: _reading(rpe: 8.5, kind: 'capped'),
        painCap: true,
      );
      expect(d.action, 'freeze');
      expect(d.flags, ['PAIN_CAP', 'PAIN_CAP_CLEAN']);
      final dirty = _eval(
        wm: 240,
        reading: _reading(rpe: 9, kind: 'capped'),
        painCap: true,
      );
      expect(dirty.flags, ['PAIN_CAP']);
    });

    test('variant mismatch still holds + flags before the rule runs', () {
      final r = Reading(
        date: DateTime.utc(2026, 10, 5),
        lift: 'deadlift',
        variant: 'paused',
        weightLb: 300,
        rawWeightLb: 300,
        reps: 1,
        rpe: 8,
        kind: 'heavy_top',
        grinder: false,
        missed: false,
        variantMismatch: true,
      );
      final d = evaluate(
        lift: 'deadlift',
        policy: _policy(),
        workingMax: 330,
        date: r.date,
        reading: r,
        tmRule: _tm,
      );
      expect(d.action, 'hold');
      expect(d.flags, ['VARIANT_MISMATCH']);
    });
  });

  group('classifyKind deload', () {
    test('weekType deload → kind deload', () {
      expect(
        classifyKind(
            lift: 'squat', date: DateTime.utc(2026, 12, 21), weekType: 'deload'),
        'deload',
      );
    });
  });

  group('tmRuleOf', () {
    test('parses guarded_implied_max with declared knobs', () {
      final r = tmRuleOf({
        'tm_rule': {
          'mode': 'guarded_implied_max',
          'raise_cap_lb': 5,
          'rounding_lb': 5,
          'min_top_fraction': 0.78,
          'min_drop_lb_on_grinder': 5,
          'clean_rpe_lt': 9,
        },
      });
      expect(r, isNotNull);
      expect(r!.raiseCapLb, 5);
      expect(r.minTopFraction, 0.78);
    });

    test('absent / other mode → null (legacy band rules)', () {
      expect(tmRuleOf({}), isNull);
      expect(tmRuleOf({'tm_rule': {'mode': 'bands'}}), isNull);
      expect(tmRuleOf(null), isNull);
    });
  });
}
