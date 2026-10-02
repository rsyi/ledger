import 'package:airledger/services/accessory_progression.dart';
import 'package:airledger/services/set_recommendation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('recommendSet', () {
    test('no history → conservative start', () {
      final r = recommendSet(const []);
      expect(r.lastSessionSummary, isNull);
      expect(r.advice.toLowerCase(), contains('no prior'));
    });

    test('easy last session (RPE ≤ 8) → nudge up', () {
      final r = recommendSet(const [
        PriorSet(reps: 10, weight: 95, rpe: 7.5),
        PriorSet(reps: 10, weight: 95, rpe: 8),
      ]);
      expect(r.lastSessionSummary, contains('95'));
      expect(r.advice.toLowerCase(), contains('add'));
    });

    test('grind last session (RPE ≥ 9.5) → hold', () {
      final r = recommendSet(const [PriorSet(reps: 3, weight: 250, rpe: 9.5)]);
      expect(r.advice.toLowerCase(), contains('hold'));
    });

    test('on-target (RPE 9) → repeat, one more rep', () {
      final r = recommendSet(const [PriorSet(reps: 8, weight: 135, rpe: 9)]);
      expect(r.advice.toLowerCase(), contains('one more rep'));
    });

    test('bodyweight (no load) summarises reps/sets', () {
      final r = recommendSet(const [
        PriorSet(reps: 12),
        PriorSet(reps: 10),
      ]);
      expect(r.lastSessionSummary, contains('2 sets'));
      expect(r.lastSessionSummary, contains('10–12 reps'));
    });
  });

  group('recommendForPrescription', () {
    final last = LastSession(
      day: DateTime(2026, 9, 25),
      sets: const [PriorSet(reps: 1, weight: 315, rpe: 7.5)],
    );

    test('main-lift top set: the program load, never "+5 lb"', () {
      final r = recommendForPrescription(
        lines: const ['1×5 · 275 lb (81%)'],
        mainLift: true,
        top: true,
        weighted: true,
        last: last,
      );
      expect(r.advice, contains('1×5 · 275 lb'));
      expect(r.advice, isNot(contains('5 lb or')));
      expect(r.advice.toLowerCase(), isNot(contains('add ~5')));
      expect(r.advice.toLowerCase(), contains("don't add load"));
      expect(r.lastSessionSummary, contains('315'));
    });

    test('main-lift back-offs carry the back-off rule', () {
      final r = recommendForPrescription(
        lines: const ['2×4 · 255 lb (75%)'],
        mainLift: true,
        top: false,
        weighted: true,
        backoff: 'hold ≤8 · drop 2.5-5% if over',
      );
      expect(r.advice, contains('2×4 · 255 lb'));
      expect(r.advice, contains('hold ≤8 · drop 2.5-5% if over'));
      expect(r.lastSessionSummary, isNull);
    });

    test('accessory: the double-progression suggestion is the advice', () {
      final r = recommendForPrescription(
        lines: const ['3×8-12 · 45 lb'],
        mainLift: false,
        top: false,
        weighted: true,
        accessory: AccessorySuggestion(
          action: 'overload',
          weightLb: 45,
          lastWeightLb: 40,
          lastDate: DateTime(2026, 9, 26),
          reason: 'all sets at 12+ reps at <= 2 RIR → +5 lb',
        ),
      );
      expect(r.advice, startsWith('Add load'));
      expect(r.advice, contains('3×8-12 · 45 lb'));
      expect(r.advice, contains('up from 40 lb'));
    });

    test('unweighted accessory: reps first', () {
      final r = recommendForPrescription(
        lines: const ['3×6-10'],
        mainLift: false,
        top: false,
        weighted: false,
      );
      expect(r.advice, contains('3×6-10'));
      expect(r.advice.toLowerCase(), contains('add reps'));
    });

    test('no-TM top set: honest, no invented load', () {
      final r = recommendForPrescription(
        lines: const ['1×5'],
        mainLift: true,
        top: true,
        weighted: false,
      );
      expect(r.advice, contains('RPE 7-8'));
    });
  });

  group('lastComparableSession', () {
    Map<String, Object?> row(String day, String ex, num w, int reps,
            {num? rpe, String? type, String? notes}) =>
        {
          'date': day,
          'exercise': ex,
          'weight': w,
          'reps': reps,
          'rpe': ?rpe,
          'set_type': ?type,
          'notes': ?notes,
        };
    final rows = [
      // 9/25: ramp + single + back-offs (the "315x1" session).
      row('2026-09-25', 'Barbell Deadlift', 135, 5),
      row('2026-09-25', 'Barbell Deadlift', 225, 3),
      row('2026-09-25', 'Barbell Deadlift', 315, 1, rpe: 7.5),
      row('2026-09-25', 'Barbell Deadlift', 275, 3, rpe: 7),
      row('2026-09-25', 'Barbell Deadlift', 275, 3),
      // An RDL day later than the last deadlift day.
      row('2026-09-28', 'Romanian Deadlift', 135, 10, rpe: 6),
      // The shown day itself never counts.
      row('2026-10-02', 'Barbell Deadlift', 275, 6, rpe: 7.5),
    ];
    final before = DateTime(2026, 10, 2);

    test('fallback matcher prefers the strong match (no RDL)', () {
      final m = historyMatcher('Deadlift heavy', [
        for (final r in rows) r['exercise'].toString(),
      ]);
      expect(m('Barbell Deadlift'), isTrue);
      expect(m('Romanian Deadlift'), isFalse);
    });

    test('top role = the day\'s heaviest working set; warm-ups never', () {
      final s = lastComparableSession(rows,
          matches: (e) => e == 'Barbell Deadlift',
          before: before,
          role: SetRole.top)!;
      expect(s.day, DateTime(2026, 9, 25));
      expect(s.sets.single.weight, 315);
    });

    test('backoff role drops the top single; all role keeps working sets',
        () {
      final b = lastComparableSession(rows,
          matches: (e) => e == 'Barbell Deadlift',
          before: before,
          role: SetRole.backoff)!;
      expect([for (final x in b.sets) x.weight], [275, 275]);
      final a = lastComparableSession(rows,
          matches: (e) => e == 'Barbell Deadlift', before: before)!;
      expect([for (final x in a.sets) x.weight], [315, 275, 275]);
    });

    test('backoff role keeps everything when there is no distinct top', () {
      final b = lastComparableSession([
        row('2026-09-28', 'Flat Barbell Bench Press', 175, 6, rpe: 7),
        row('2026-09-28', 'Flat Barbell Bench Press', 175, 6, rpe: 8),
      ], matches: (_) => true, before: before, role: SetRole.backoff)!;
      expect(b.sets, hasLength(2));
    });

    test('null without history', () {
      expect(
          lastComparableSession(rows,
              matches: (e) => e == 'Front Squat', before: before),
          isNull);
    });
  });
}
