// Tests for lib/services/sim_core.dart — the pure week stepper (design
// doc airledger/docs/superpowers/specs/2026-09-25-sim-design.md §§2–5):
// S4 damper behavior at the frontier, adaptive cut end (target-or-date,
// the user's lighter-now ⇒ shorter-cut example), maintain filler,
// next-cycle generation shape, lever monotonicity, the Wilks k-anchor,
// and the climbing frequency lever.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/sim_core.dart';
import 'package:airledger/services/sim_fit.dart';
import 'package:airledger/services/wilks.dart' show wilksPointsLb;
import 'package:airledger/services/world_model.dart';

/// The v7 program shape (coach/program.yaml blocks 1–7 + phase.yaml v1
/// cut target/end) — the schedule the sim honors.
SimProgram v7Program() => SimProgram(
      cutTargetLb: 154,
      cutEndDate: DateTime(2026, 12, 13),
      blocks: [
        SimBlock(
            n: 1,
            start: DateTime(2026, 12, 14),
            end: DateTime(2027, 1, 3),
            emphasis: 'reverse'),
        SimBlock(
            n: 2,
            start: DateTime(2027, 1, 4),
            end: DateTime(2027, 2, 28),
            emphasis: 'climbing',
            rate: 0.4),
        SimBlock(
            n: 3,
            start: DateTime(2027, 3, 1),
            end: DateTime(2027, 4, 25),
            emphasis: 'lifting',
            rate: 0.4),
        SimBlock(
            n: 4,
            start: DateTime(2027, 4, 26),
            end: DateTime(2027, 6, 20),
            emphasis: 'climbing',
            rate: 0.4),
        SimBlock(
            n: 5,
            start: DateTime(2027, 6, 21),
            end: DateTime(2027, 8, 15),
            emphasis: 'lifting',
            rate: 0.4),
        SimBlock(
            n: 6,
            start: DateTime(2027, 8, 16),
            end: DateTime(2027, 10, 10),
            emphasis: 'climbing',
            rate: 0.2),
        SimBlock(
            n: 7,
            start: DateTime(2027, 10, 11),
            end: DateTime(2027, 12, 5),
            emphasis: 'lifting',
            rate: 0.2),
      ],
    );

/// The study's 2026-09-21 state vector.
SimInitialState currentState({double bw = 160.6}) => SimInitialState(
      monday: DateTime(2026, 9, 21),
      bw: bw,
      e1rm: const {
        'squat': 311.7,
        'bench': 247.5,
        'deadlift': 351.8,
        'press': 144.0,
      },
      gradeP75: 5.0,
      actualMaxSbdTotalLbs: 275.0 + 225.0 + 315.0,
    );

/// The shipped world_model.yaml coefficients (design §6).
SimCoefficients shippedCoefficients() => const SimCoefficients(
      strength: {
        'squat': LiftResponse(a: -0.280, bBw: 2.295),
        'bench': LiftResponse(a: -0.099, bBw: 0.919),
        'deadlift': LiftResponse(a: 0.775, bBw: 0.795),
        'press': LiftResponse(a: -0.143, bBw: 0.352),
      },
      pooled: null,
      climbC0: 8.56,
      climbCBw: -0.0288,
      climbBf: 0.0032,
    );

/// A program that pins the whole horizon to one rate-0 bulk block —
/// isolates the strength stepper from the phase machinery.
SimProgram flatForever(DateTime t0) => SimProgram(
      cutTargetLb: 500, // bw never above it → no initial cut
      cutEndDate: t0,
      blocks: [
        SimBlock(
            n: 1,
            start: t0,
            end: DateTime(t0.year + 10, 1, 1),
            emphasis: 'lifting',
            rate: 0),
      ],
    );

List<SimSegment> segmentsAfter(SimResult r, DateTime date) => [
      for (final s in r.segments)
        if (!s.start.isBefore(date)) s,
    ];

void main() {
  const rules = SimRules();

  group('S4 saturation damper', () {
    test('exactly 0.5x at the all-time frontier, every week (asymptote)',
        () {
      expect(dampedVelocity(vRaw: 1, e1rm: 100, peak: 100), closeTo(0.5, 1e-12));
      // In-sim: the peak updates with the sim, so the damper STAYS 0.5
      // at the frontier instead of fading to zero.
      final t0 = DateTime(2026, 9, 21);
      final r = simulate(
        initial: SimInitialState(
            monday: t0, bw: 160, e1rm: const {'squat': 100}, peak: const {
          'squat': 100
        }),
        coefficients: const SimCoefficients(
          strength: {'squat': LiftResponse(a: 1, bBw: 0)},
          pooled: null,
          climbC0: null,
          climbCBw: null,
          climbBf: null,
        ),
        rules: rules,
        program: flatForever(t0),
        levers: const SimLevers(horizonYears: 1),
      );
      for (var t = 1; t < 20; t++) {
        expect(
          r.weeks[t].e1rm['squat']! - r.weeks[t - 1].e1rm['squat']!,
          closeTo(0.5, 1e-9),
          reason: 'week $t gain should be the 0.5x frontier asymptote',
        );
        expect(r.weeks[t].peak['squat'], r.weeks[t].e1rm['squat']);
      }
    });

    test('full velocity below 95% of peak, fading above', () {
      expect(dampedVelocity(vRaw: 1, e1rm: 90, peak: 100), closeTo(1, 1e-12));
      expect(dampedVelocity(vRaw: 1, e1rm: 95, peak: 100), closeTo(1, 1e-12));
      expect(dampedVelocity(vRaw: 1, e1rm: 100, peak: 100), closeTo(0.5, 1e-12));
      expect(dampedVelocity(vRaw: 1, e1rm: 105, peak: 100), closeTo(0, 1e-12));
      expect(dampedVelocity(vRaw: 2, e1rm: 97.5, peak: 100),
          closeTo(1.5, 1e-9));
    });

    test('losses pass through undamped (cuts hit full strength cost)', () {
      expect(dampedVelocity(vRaw: -1, e1rm: 100, peak: 100), -1.0);
      expect(dampedVelocity(vRaw: -1, e1rm: 120, peak: 100), -1.0);
    });
  });

  group('adaptive cut end (target-or-date)', () {
    int cutWeeks(double bw0) {
      final r = simulate(
        initial: currentState(bw: bw0),
        coefficients: shippedCoefficients(),
        rules: rules,
        program: v7Program(),
      );
      final cut = r.segments.first;
      expect(cut.phase, 'cut');
      return cut.weeks;
    }

    test('lighter now ⇒ shorter cut (the user\'s example)', () {
      // 160.6 → 9 weeks at -0.75; 157 → 4 weeks.
      expect(cutWeeks(160.6), 9);
      expect(cutWeeks(157), 4);
      expect(cutWeeks(157), lessThan(cutWeeks(160.6)));
    });

    test('early cut end inserts maintain filler until block 1', () {
      final r = simulate(
        initial: currentState(),
        coefficients: shippedCoefficients(),
        rules: rules,
        program: v7Program(),
      );
      final segs = r.segments;
      expect(segs[0].phase, 'cut');
      expect(segs[1].phase, 'maintain');
      // Cut 9 wks (through 2026-11-16) + filler → block 1 starts
      // 2026-12-14 sharp.
      expect(segs[2].phase, 'reverse');
      expect(segs[2].start, DateTime(2026, 12, 14));
      expect(segs[2].weeks, 3);
      expect(segs[3].phase, 'bulk');
      expect(segs[3].start, DateTime(2027, 1, 4));
      // Maintain filler holds bw flat.
      expect(segs[1].first.bw, closeTo(segs[1].last.bw, 1e-9));
    });

    test('cut runs to the declared date when the target is out of reach',
        () {
      final r = simulate(
        initial: currentState(),
        coefficients: shippedCoefficients(),
        rules: rules,
        levers: const SimLevers(cutRateLbWk: -0.5),
        program: v7Program(),
      );
      final cut = r.segments.first;
      // 160.6 at -0.5 never reaches 154 before 2026-12-13: every Monday
      // strictly before the end date cuts (12 weeks), no maintain gap.
      expect(cut.weeks, 12);
      expect(r.segments[1].phase, 'reverse');
      expect(r.segments[1].start, DateTime(2026, 12, 14));
    });
  });

  group('next-cycle auto-generation (design §4 rule 4)', () {
    test('hold → cut → reverse → bulk shape after the program ends', () {
      final r = simulate(
        initial: currentState(),
        coefficients: shippedCoefficients(),
        rules: rules,
        program: v7Program(),
        levers: const SimLevers(horizonYears: 3),
      );
      // The program's last block ends 2027-12-05.
      final after = segmentsAfter(r, DateTime(2027, 12, 6));
      expect(after.first.phase, 'maintain');
      expect(after.first.weeks, 8);
      expect(after[1].phase, 'cut');
      // The generated cut obeys rule 1: it runs while bw > 154 and the
      // week after its last week lands at or under the target.
      expect(after[1].last.bw, greaterThan(154));
      expect(after[1].last.bw + after[1].last.rateLbWk,
          lessThanOrEqualTo(154 + 1e-9));
      expect(after[2].phase, 'reverse');
      expect(after[2].weeks, 3);
      expect(after[3].phase, 'bulk');
      // Bulk climbs back toward the band top at the default 0.4.
      expect(after[3].first.rateLbWk, closeTo(0.4, 1e-9));
      // The cycle repeats (another hold appears before the horizon).
      expect(
        after.skip(4).map((s) => s.phase),
        contains('maintain'),
      );
    });

    test('horizon lever bounds the trajectory', () {
      for (final years in [1, 2, 3]) {
        final r = simulate(
          initial: currentState(),
          coefficients: shippedCoefficients(),
          rules: rules,
          program: v7Program(),
          levers: SimLevers(horizonYears: years),
        );
        expect(r.weeks.length, years * 52);
      }
    });
  });

  group('lever monotonicity', () {
    test('faster bulk ⇒ more weight AND more strength at program end', () {
      SimWeek atProgramEnd(double bulkRate) {
        final r = simulate(
          initial: currentState(),
          coefficients: shippedCoefficients(),
          rules: rules,
          program: v7Program(),
          levers: SimLevers(bulkRateLbWk: bulkRate),
        );
        return r.weeks
            .lastWhere((w) => !w.monday.isAfter(DateTime(2027, 12, 5)));
      }

      final slow = atProgramEnd(0.3);
      final fast = atProgramEnd(0.5);
      expect(fast.bw, greaterThan(slow.bw));
      for (final l in simLifts) {
        expect(fast.e1rm[l]!, greaterThan(slow.e1rm[l]!),
            reason: '$l should gain more on the faster bulk');
      }
      // NOTE (found in test): Wilks is deliberately NOT asserted
      // monotone — the heavier bodyweight lowers the coefficient
      // faster than the damped strength gains add points, so a slower
      // bulk can end the program with the better Wilks. The design
      // only promises more strength and more weight.
    });

    test('bulk lever scales declared block rates around the 0.4 default',
        () {
      final r = simulate(
        initial: currentState(),
        coefficients: shippedCoefficients(),
        rules: rules,
        program: v7Program(),
        levers: const SimLevers(bulkRateLbWk: 0.6),
      );
      // Block 2 (declared 0.4) → 0.6; block 7 (declared 0.2) → 0.3.
      final block2 = r.weeks
          .firstWhere((w) => w.monday == DateTime(2027, 1, 4));
      final block7 = r.weeks
          .firstWhere((w) => w.monday == DateTime(2027, 10, 11));
      expect(block2.rateLbWk, closeTo(0.6, 1e-9));
      expect(block7.rateLbWk, closeTo(0.3, 1e-9));
    });
  });

  group('derived outputs', () {
    test('Wilks k-anchor: week 0 equals the actual-max Wilks', () {
      final r = simulate(
        initial: currentState(),
        coefficients: shippedCoefficients(),
        rules: rules,
        program: v7Program(),
      );
      expect(
        r.weeks.first.wilks,
        closeTo(wilksPointsLb(815, 160.6), 1e-9),
      );
      // Reference value from the study: 321.2.
      expect(r.weeks.first.wilks, closeTo(321.2, 0.1));
    });

    test('climbing follows C2 with the frequency lever capped at 26 wk',
        () {
      SimResult run(int freq) => simulate(
            initial: currentState(),
            coefficients: shippedCoefficients(),
            rules: rules,
            program: v7Program(),
            levers: SimLevers(climbFrequency: freq),
          );
      final f2 = run(2);
      final f3 = run(3);
      // Same bw script → C2 term identical; frequency adds b_f·min(t,26).
      expect(f2.weeks.first.gradeP75,
          closeTo(8.56 - 0.0288 * 160.6, 1e-9));
      expect(f3.weeks[10].gradeP75! - f2.weeks[10].gradeP75!,
          closeTo(0.0032 * 10, 1e-9));
      expect(f3.weeks[52].gradeP75! - f2.weeks[52].gradeP75!,
          closeTo(0.0032 * 26, 1e-9),
          reason: 'frequency benefit is honestly bounded at ~6 months');
      // Cutting to 154 raises the C2 grade forecast.
      final cutEnd = f2.segments.first.last;
      expect(cutEnd.gradeP75!, greaterThan(f2.weeks.first.gradeP75!));
    });

    test('parsed world_model.yaml drives the same sim as the literals',
        () {
      // The shipped file's toCoefficients + sim rules are what W3 will
      // feed simulate(); pin that path end-to-end.
      final wm = parseWorldModel('''
version: 1
drivers:
  - { target: e1rm_squat, driver: bw, form: linear_rate, coefficient: 2.295, intercept: -0.280 }
  - { target: e1rm_bench, driver: bw, form: linear_rate, coefficient: 0.919, intercept: -0.099 }
  - { target: e1rm_deadlift, driver: bw, form: linear_rate, coefficient: 0.795, intercept: 0.775 }
  - { target: e1rm_press, driver: bw, form: linear_rate, coefficient: 0.352, intercept: -0.143 }
  - { target: grade_p75, driver: bw, form: linear, coefficient: -0.0288, intercept: 8.56 }
  - { target: grade_p75, driver: climb_frequency, form: linear_rate, coefficient: 0.0032 }
''')!;
      final a = simulate(
        initial: currentState(),
        coefficients: wm.toCoefficients(),
        rules: wm.sim,
        program: v7Program(),
      );
      final b = simulate(
        initial: currentState(),
        coefficients: shippedCoefficients(),
        rules: rules,
        program: v7Program(),
      );
      expect(a.weeks.length, b.weeks.length);
      expect(a.weeks.last.bw, b.weeks.last.bw);
      expect(a.weeks.last.e1rm, b.weeks.last.e1rm);
      expect(a.weeks.last.gradeP75, b.weeks.last.gradeP75);
      expect(a.weeks.last.wilks, b.weeks.last.wilks);
    });
  });
}
