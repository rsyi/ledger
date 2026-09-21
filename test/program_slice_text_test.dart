// Tests for renderProgramSlice — the terse markdown renderer used in the
// coach system prompt. Uses a hand-crafted fixture ProgramSlice so the test
// stays pure (no IO, no YAML loading).
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_slice_text.dart';

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

/// Block-0 cut slice, Mon 2026-09-27 (week 1 of the cut).
ProgramSlice _block0MondaySlice() => ProgramSlice(
      id: 'bulk-2026-27',
      version: 1,
      block: {
        'number': 0,
        'emphasis': 'cut',
        'dates': ['2026-09-21', '2026-12-13'],
        'target_weight': [163, 154],
        'notes':
            'Maintenance week + DEXA Nov 2-8. Top singles at RPE 7 from Nov 16.',
      },
      weekInBlock: 1,
      weekType: 'normal',
      todayTemplate: {
        'weekday': 'mon',
        'morning':
            'Squat heavy: top set of 1-3 at RPE 8.5-9, then 4x3 at 82%; hanging leg raise; muscle-ups.',
        'afternoon': null,
        'block_note':
            'Block 0 (cut): current routine plus a second bench day (light 3x5 at 70%), climbing Tuesday afternoons, no heavy lower on Tuesdays, top singles at RPE 7 from Nov 16.',
      },
      targetsInForce: {
        'near_max_sets': 6,
        'working_sets': 28,
        'working_sets_min_normal': 20,
        'bench_days': 2,
        'press_days': 2,
        'squat_days': 2,
        'deadlift_days': 1,
        'climbing_sessions': 2,
        'bike_4x4': 1,
        'muscle_up_sessions': 1,
        'gain_rate_lb_wk': [-1.0, -0.5],
        'bodyweight_band_lb': [154, 172],
        'hard_cap_lb': 172,
        'protein_g_per_lb': [0.8, 1.0],
      },
      rulesInForce: const [
        'WEIGHT_FAST',
        'WEIGHT_FLAT',
        'WEIGHT_CAP',
        'WEIGHT_DRIFT',
        'PHASE_MISMATCH',
        'NEAR_MAX_LOW',
        'WORKING_LOW',
        'LONG_SETS',
        'BENCH_ONCE',
        'TUESDAY_LOWER',
        'CLIMB_OVER',
        'BIKE_DROP',
        'TOP_SET_HEAVY',
        'PAIN_NOTE',
        'TWO_SIGNALS',
        'BLOCK_END',
      ],
    );

/// Block-3 lifting slice, Thu 2027-03-04 (week 1 normal).
ProgramSlice _block3ThursdaySlice() => ProgramSlice(
      id: 'bulk-2026-27',
      version: 1,
      block: {
        'number': 3,
        'emphasis': 'lifting',
        'dates': ['2027-03-01', '2027-04-25'],
        'target_weight': [157, 160],
      },
      weekInBlock: 1,
      weekType: 'normal',
      todayTemplate: {
        'weekday': 'thu',
        'morning':
            'Deadlift heavy: top set of 1-3, then 3x3 at 82%; press heavy: top set, then 4x3.',
        'afternoon': null,
      },
      targetsInForce: {
        'near_max_sets': 6,
        'working_sets': 28,
        'working_sets_min_normal': 20,
        'bench_days': 2,
        'squat_days': 2,
        'deadlift_days': 1,
        'climbing_sessions': 2,
        'bike_4x4': 1,
        'gain_rate_lb_wk': 0.4,
        'hard_cap_lb': 172,
        'protein_g_per_lb': [0.8, 1.0],
      },
      rulesInForce: const ['NEAR_MAX_LOW', 'WORKING_LOW', 'LONG_SETS'],
    );

// ---------------------------------------------------------------------------
// Phase + strategy fixture maps
// ---------------------------------------------------------------------------

Map<Object?, Object?> _cutPhase() => {
      'version': 1,
      'value': 'cut',
      'effective_from': '2025-10-06',
      'reason': 'Ending the 2025 bulk at 186.5; the extra weight bought nothing',
      'target_weight_lb': 154,
      'target_rate_lb_per_week': -0.75,
    };

Map<Object?, Object?> _strategyV1() => {
      'version': 1,
      'effective_from': '2026-09-21',
      'text':
          'Block 0, cut, week 1 of 12. Deadlift held back after back twinge. Nothing else pushed; arrive at 154 with lifts intact.',
    };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('renderProgramSlice — structure', () {
    test('output starts with ## PROGRAM SLICE header', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, startsWith('## PROGRAM SLICE'));
    });

    test('contains block number, emphasis, and week info', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, contains('block=0/cut'));
      expect(out, contains('week 1'));
      expect(out, contains('normal'));
    });

    test('contains block date range', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, contains('2026-09-21'));
      expect(out, contains('2026-12-13'));
    });

    test('contains target weight', () {
      final out = renderProgramSlice(_block0MondaySlice());
      // target_weight [163, 154] → "163→154lb"
      expect(out, contains('163→154lb'));
    });

    test('contains today weekday', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, contains('Today (mon)'));
    });

    test('contains morning template text', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, contains('Squat heavy'));
    });

    test('block-0 note appears', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, contains('second bench day'));
    });

    test('targets section present with key fields', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, contains('near_max_sets=6'));
      expect(out, contains('working_sets=28'));
      expect(out, contains('bench_days=2'));
    });

    test('gain_rate_lb_wk list rendered as range', () {
      final out = renderProgramSlice(_block0MondaySlice());
      // [-1.0, -0.5] → "gain_rate_lb_wk=-1.0--0.5"
      expect(out, contains('gain_rate_lb_wk='));
      expect(out, contains('-1.0'));
      expect(out, contains('-0.5'));
    });

    test('scalar gain rate rendered as scalar', () {
      final out = renderProgramSlice(_block3ThursdaySlice());
      expect(out, contains('gain_rate_lb_wk=0.4'));
    });

    test('rules section present', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, contains('NEAR_MAX_LOW'));
      expect(out, contains('LONG_SETS'));
    });
  });

  group('renderProgramSlice — phase injection', () {
    test('phase line absent when phase is null', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, isNot(contains('Phase:')));
    });

    test('phase line present when phase provided', () {
      final out =
          renderProgramSlice(_block0MondaySlice(), phase: _cutPhase());
      expect(out, contains('Phase:'));
      expect(out, contains('phase=cut'));
      expect(out, contains('from=2025-10-06'));
      expect(out, contains('target=154lb'));
    });

    test('phase reason appears in phase line', () {
      final out =
          renderProgramSlice(_block0MondaySlice(), phase: _cutPhase());
      expect(out, contains('Ending the 2025 bulk'));
    });
  });

  group('renderProgramSlice — strategy injection', () {
    test('strategy absent when null', () {
      final out = renderProgramSlice(_block0MondaySlice());
      expect(out, isNot(contains('Strategy:')));
    });

    test('strategy text appears verbatim when provided', () {
      final out = renderProgramSlice(_block0MondaySlice(),
          strategy: _strategyV1());
      expect(out, contains('Strategy:'));
      expect(out, contains('Block 0, cut, week 1 of 12'));
    });
  });

  group('renderProgramSlice — edge cases', () {
    test('off day renders Off when no AM or PM', () {
      final offDaySlice = ProgramSlice(
        id: 'bulk-2026-27',
        version: 1,
        block: {
          'number': 0,
          'emphasis': 'cut',
          'dates': ['2026-09-21', '2026-12-13'],
          'target_weight': [163, 154],
        },
        weekInBlock: 1,
        weekType: 'normal',
        todayTemplate: {
          'weekday': 'sun',
          'morning': null,
          'afternoon': null,
        },
        targetsInForce: const {},
        rulesInForce: const [],
      );
      final out = renderProgramSlice(offDaySlice);
      expect(out, contains('Off'));
    });

    test('empty rules section omitted', () {
      final noRulesSlice = ProgramSlice(
        id: 'bulk-2026-27',
        version: 1,
        block: {
          'number': 0,
          'emphasis': 'cut',
          'dates': ['2026-09-21', '2026-12-13'],
          'target_weight': [163, 154],
        },
        weekInBlock: 1,
        weekType: 'normal',
        todayTemplate: {
          'weekday': 'mon',
          'morning': null,
          'afternoon': null,
        },
        targetsInForce: const {},
        rulesInForce: const [],
      );
      final out = renderProgramSlice(noRulesSlice);
      expect(out, isNot(contains('Rules:')));
    });

    test('output is roughly 600-900 chars for a typical full slice', () {
      final out = renderProgramSlice(
        _block0MondaySlice(),
        phase: _cutPhase(),
        strategy: _strategyV1(),
      );
      // This is a soft guideline, not a hard limit, but we check we're in range.
      expect(out.length, greaterThan(400),
          reason: 'slice should have substantive content');
      expect(out.length, lessThan(1500),
          reason: 'slice should remain terse');
    });
  });
}
