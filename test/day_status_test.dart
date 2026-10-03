import 'package:airledger/services/day_achievement.dart';
import 'package:airledger/services/day_status.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/whoop_activity.dart';
import 'package:flutter_test/flutter_test.dart';

/// The live Fri 10/2 (cut) day: AM deadlift session + PM light climb,
/// with the climb done in the MORNING (Whoop rock-climbing 10:25) — the
/// 2026-10-02 coach-read bug ("make sure that PM light climbing session
/// actually happens").
final fri = DateTime(2026, 10, 2);
final tue = DateTime(2026, 10, 6);
final wed = DateTime(2026, 9, 30);

PrescribedItem it(String name, String scheme, String period, int sets) =>
    PrescribedItem(
        name: name, scheme: scheme, period: period, targetSets: sets);

List<EffectiveItem> fridayEntries() => [
      EffectiveItem(item: it('Deadlift heavy', 'top set', 'AM', 1), home: fri),
      EffectiveItem(
          item: it('Deadlift back-offs', '2x4-6 @ 75% TM', 'AM', 2),
          home: fri),
      EffectiveItem(
          item: it('RDL or leg curl', '2-3x8-12', 'AM', 2), home: fri),
      EffectiveItem(
          item: it('Bench volume', '3x8-10 @ 65% TM.', 'AM', 3), home: fri),
      EffectiveItem(
          item: it('Climb — LIGHT session',
              '(technique/volume, movement quality; low fatigue).', 'PM', 1),
          home: fri),
    ];

AchievedSet s(String ex, double w, int r) =>
    AchievedSet(exercise: ex, weight: w, reps: r);

final morningClimb = WhoopActivity(
  date: fri,
  start: DateTime(2026, 10, 2, 10, 25),
  sport: 'rock-climbing',
  kind: ActivityKind.climb,
  strain: 8.0,
  durationMin: 25,
);

void main() {
  group('buildDayStatus — Friday morning-climb scenario', () {
    DayStatus build({List<WhoopActivity> whoop = const []}) => buildDayStatus(
          date: fri,
          entries: fridayEntries(),
          logged: [
            s('Barbell Deadlift', 275, 6),
            s('Barbell Deadlift', 245, 5),
            s('Barbell Deadlift', 245, 5),
            s('Romanian Deadlift', 185, 10),
            s('Romanian Deadlift', 185, 10),
          ],
          whoop: whoop,
        );

    test('a Whoop morning climb makes the PM climb DONE', () {
      final st = build(whoop: [morningClimb]);
      final climb = st.items.last;
      expect(climb.state, DayItemState.done);
      expect(climb.whoop, same(morningClimb));
      expect(st.climbPending, isFalse);
      expect(st.climbPrescribed, isTrue);
    });

    test('without the Whoop climb the climb is PENDING', () {
      final st = build();
      expect(st.items.last.state, DayItemState.pending);
      expect(st.climbPending, isTrue);
    });

    test('lift states from the shared allocation', () {
      final st = build(whoop: [morningClimb]);
      expect([for (final i in st.items) i.state], [
        DayItemState.done, // deadlift heavy (1 set)
        DayItemState.done, // back-offs (2)
        DayItemState.done, // RDL (2)
        DayItemState.pending, // bench volume (0 of 3)
        DayItemState.done, // climb (Whoop)
      ]);
      expect(st.items.first.achievedText, 'top 275×6');
    });

    test('prompt block: climb DONE with no PM framing; bench PENDING', () {
      final b = build(whoop: [morningClimb]).promptBlock();
      expect(b, contains('PROGRAM STATUS'));
      expect(b, contains('authoritative'));
      expect(
          b,
          contains('- DONE Climb — LIGHT session — Whoop rock-climbing 10:25, '
              'strain 8.0, 25 min (planned PM, done earlier — complete)'));
      expect(b, contains('- DONE Deadlift heavy — top 275×6'));
      expect(b, contains('- PENDING Bench volume — 0 of 3 sets logged'));
      expect(b, isNot(contains('PENDING Climb')));
      expect(b, contains('TRAINING LEFT TODAY: Bench volume'));
      expect(b, isNot(contains('TRAINING LEFT TODAY: Bench volume, Climb')));
    });

    test('nothing pending → the training day is complete', () {
      final st = buildDayStatus(
        date: fri,
        entries: fridayEntries(),
        logged: [
          s('Barbell Deadlift', 275, 6),
          s('Barbell Deadlift', 245, 5),
          s('Barbell Deadlift', 245, 5),
          s('Romanian Deadlift', 185, 10),
          s('Romanian Deadlift', 185, 10),
          for (var i = 0; i < 3; i++) s('Flat Barbell Bench Press', 155, 8),
        ],
        whoop: [morningClimb],
      );
      expect(st.pending, isEmpty);
      expect(st.allDone, isTrue);
      final b = st.promptBlock();
      expect(b, contains("TRAINING LEFT TODAY: none — today's training is "
          'complete'));
      expect(b, isNot(contains('PENDING')));
    });
  });

  group('moves, skips, extras', () {
    test('moved-out ghost → MOVED, skipped → SKIPPED with reason; neither '
        'counts as live or pending', () {
      final entries = [
        EffectiveItem(
            item: it('Seated cable row', '3x10', 'AM', 3),
            home: fri,
            movedTo: tue),
        EffectiveItem(item: it('Dips', '3x8-12', 'AM', 3), home: fri),
        EffectiveItem(
            item: it('Bench heavy', 'top set', 'AM', 1),
            home: wed,
            movedFrom: wed),
      ];
      final skip = ProgramMove(
        id: 'x',
        to: fri,
        from: fri,
        item: 'Dips',
        period: 'AM',
        source: skipSource,
        note: 'travel Wed–Sat',
      );
      final st = buildDayStatus(
        date: fri,
        entries: entries,
        logged: [s('Cable Face Pull', 40, 15)],
        skips: {skipKey(fri, 'Dips'): skip},
      );
      expect(st.items[0].state, DayItemState.movedOut);
      expect(st.items[1].state, DayItemState.skipped);
      expect(st.items[1].skipReason, 'travel Wed–Sat');
      expect(st.live.map((e) => e.item.name), ['Bench heavy']);
      final b = st.promptBlock();
      expect(b, contains('- MOVED Seated cable row → Tue'));
      expect(b, contains('- SKIPPED Dips — travel Wed–Sat'));
      expect(b, contains('- PENDING Bench heavy (moved in from Wed)'));
      expect(b, contains('ALSO LOGGED (outside the program): '
          'Cable Face Pull (1 set)'));
    });

    test('Kaya ascents on the day credit a climb when Whoop saw none', () {
      final st = buildDayStatus(
        date: fri,
        entries: [fridayEntries().last],
        logged: const [],
        kayaDays: [fri],
      );
      expect(st.items.single.state, DayItemState.done);
      expect(st.promptBlock(), contains('- DONE Climb — LIGHT session'));
    });

    test('a logged 4x4 credits the 4x4 item', () {
      final st = buildDayStatus(
        date: tue,
        entries: [
          EffectiveItem(item: it('4x4', 'bike intervals', 'AM', 4), home: tue),
        ],
        logged: const [],
        cardio4x4Days: {tue},
      );
      expect(st.items.single.state, DayItemState.done);
    });

    test('M5: Whoop lifting + pending lifts → may-be-unlogged note', () {
      final st = buildDayStatus(
        date: fri,
        entries: [fridayEntries().first],
        logged: const [],
        whoop: [
          WhoopActivity(
              date: fri, sport: 'weightlifting', kind: ActivityKind.lift),
        ],
      );
      expect(st.promptBlock(), contains('may simply be unlogged'));
    });

    test('rest day', () {
      final st = buildDayStatus(date: fri, entries: const [], logged: const []);
      expect(st.promptBlock(), contains('rest day'));
    });

    test('no set tracking (no strength source) → lifts stay PENDING but '
        'Whoop still credits the climb', () {
      final st = buildDayStatus(
        date: fri,
        entries: fridayEntries(),
        logged: null,
        whoop: [morningClimb],
      );
      expect(st.items.first.state, DayItemState.pending);
      expect(st.items.last.state, DayItemState.done);
    });

    test('Whoop activity on another day never credits', () {
      final st = buildDayStatus(
        date: fri,
        entries: [fridayEntries().last],
        logged: const [],
        whoop: [
          WhoopActivity(
              date: DateTime(2026, 10, 1),
              sport: 'rock-climbing',
              kind: ActivityKind.climb),
        ],
      );
      expect(st.items.single.state, DayItemState.pending);
    });
  });
}
