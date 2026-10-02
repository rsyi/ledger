// missed_work.dart — the pure missed-work detector over a Mon–Sun week.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/missed_work.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';

final mon = DateTime(2026, 9, 28);
DateTime d(int i) => DateTime(2026, 9, 28 + i);

PrescribedItem it(
  String name, {
  String scheme = '1x3',
  int sets = 1,
  String period = 'AM',
}) => PrescribedItem(
  name: name,
  scheme: scheme,
  period: period,
  targetSets: sets,
);

/// Base week: Mon squat+bench volume, Tue climb (PM) + Bike 4x4 (AM),
/// Wed bench top, Thu nothing, Fri deadlift, Sat press, Sun rest.
Map<DateTime, List<PrescribedItem>> prescribed() => {
  d(0): [
    it('Squat top set', scheme: '1x5'),
    it('Bench', scheme: '4x8 @68%', sets: 4),
  ],
  d(1): [
    it('Bike', scheme: '4x4', sets: 4),
    it('Hard climb', scheme: '(limit)', period: 'PM'),
  ],
  d(2): [it('Bench top set', scheme: '1x3 @ RPE 8')],
  d(3): [],
  d(4): [it('Deadlift top set', scheme: '1x3')],
  d(5): [it('Press top set', scheme: '1x4')],
  d(6): [],
};

Map<DateTime, List<EffectiveItem>> eff([List<ProgramMove> moves = const []]) =>
    effectiveWeek(prescribed(), activeMoves(moves, mon));

List<({DateTime date, String exercise})> sets(DateTime day, String ex, int n) =>
    [for (var i = 0; i < n; i++) (date: day, exercise: ex)];

/// Everything Mon–Tue done (squat, 4 bench, 4x4, climb).
List<({DateTime date, String exercise})> monTueDone() => [
  ...sets(d(0), 'Squat', 1),
  ...sets(d(0), 'Bench Press', 4),
];

MissedWork run({
  Map<DateTime, List<EffectiveItem>>? week,
  List<({DateTime date, String exercise})>? rows,
  Set<DateTime>? climb,
  Set<DateTime>? cardio,
  required DateTime today,
}) => detectMissedWork(
  week: week ?? eff(),
  strengthRows: rows ?? monTueDone(),
  climbDays: climb ?? {d(1)},
  cardio4x4Days: cardio ?? {d(1)},
  today: today,
);

ProgramMove mv(String item, DateTime from, DateTime to) => ProgramMove(
  id: 'm-$item',
  to: to,
  from: from,
  item: item,
  source: 'manual',
);

void main() {
  test('Wed bench top unlogged → missed on Thu', () {
    final mw = run(today: d(3));
    expect(mw.missed, hasLength(1));
    final m = mw.missed.single;
    expect(m.item.name, 'Bench top set');
    expect(m.day, d(2));
    expect(m.home, d(2));
    expect(m.kind, 'lift');
    expect(m.setsShort, 1);
    expect(mw.isEmpty, isFalse);
  });

  test('Wed bench logged Thu instead (no move) → not missed', () {
    final mw = run(
      today: d(4),
      rows: [...monTueDone(), ...sets(d(3), 'Bench Press', 1)],
    );
    expect(mw.isEmpty, isTrue);
    expect(mw.missed, isEmpty);
  });

  test('moved Wed→Fri, today Thu → not due yet', () {
    final mw = run(today: d(3), week: eff([mv('Bench top set', d(2), d(4))]));
    expect(mw.isEmpty, isTrue);
  });

  test('moved Wed→Tue and not logged → missed with day=Tue, home=Wed', () {
    final mw = run(today: d(2), week: eff([mv('Bench top set', d(2), d(1))]));
    expect(mw.missed, hasLength(1));
    expect(mw.missed.single.day, d(1));
    expect(mw.missed.single.home, d(2));
  });

  test('ghost entries are ignored (moved-out item not double-counted)', () {
    // Moved Wed→Fri; today Sat; logged on Fri → nothing missed (the Wed
    // ghost would otherwise show as unlogged).
    final mw = run(
      today: d(5),
      week: eff([mv('Bench top set', d(2), d(4))]),
      rows: [
        ...monTueDone(),
        ...sets(d(4), 'Bench Press', 1),
        ...sets(d(4), 'Deadlift', 1),
      ],
    );
    expect(mw.isEmpty, isTrue);
  });

  test('partial sets → setsShort is the shortfall', () {
    final mw = run(
      today: d(1),
      rows: [...sets(d(0), 'Squat', 1), ...sets(d(0), 'Bench Press', 3)],
    );
    expect(mw.missed.single.item.name, 'Bench');
    expect(mw.missed.single.setsShort, 1);
  });

  test('target 3 with 2 logged → setsShort 1', () {
    final week = effectiveWeek({
      d(0): [it('Pull-ups', scheme: '3x6', sets: 3)],
    }, const {});
    final mw = detectMissedWork(
      week: week,
      strengthRows: sets(d(0), 'Pull-up', 2),
      climbDays: const {},
      cardio4x4Days: const {},
      today: d(1),
    );
    expect(mw.missed.single.setsShort, 1);
    expect(mw.toPromptLines(), contains('2/3 sets'));
  });

  test('two bench items, 4 sets logged Mon → Wed top missed (day order)', () {
    final mw = run(today: d(3));
    expect(mw.missed.map((m) => m.item.name), ['Bench top set']);
    expect(mw.missed.single.day, d(2));
  });

  test('today\'s logged sets serve today\'s item before earlier misses', () {
    // Today Wed, 1 bench set logged Wed: it's Wed's top set, not a
    // makeup for Monday's short volume.
    final mw = run(
      today: d(2),
      rows: [
        ...sets(d(0), 'Squat', 1),
        ...sets(d(0), 'Bench Press', 3),
        ...sets(d(2), 'Bench Press', 1),
      ],
    );
    expect(mw.missed.single.item.name, 'Bench');
    expect(mw.missed.single.setsShort, 1);
    // A surplus today DOES clear it.
    final mw2 = run(
      today: d(2),
      rows: [
        ...sets(d(0), 'Squat', 1),
        ...sets(d(0), 'Bench Press', 3),
        ...sets(d(2), 'Bench Press', 2),
      ],
    );
    expect(mw2.isEmpty, isTrue);
  });

  test('rows outside the week are ignored', () {
    final mw = run(
      today: d(3),
      rows: [
        ...monTueDone(),
        ...sets(DateTime(2026, 9, 27), 'Bench Press', 1), // prior Sunday
      ],
    );
    expect(mw.missed.single.item.name, 'Bench top set');
  });

  test('climb Tue due, Whoop climb Wed → not missed', () {
    final mw = run(
      today: d(3),
      climb: {d(2)},
      rows: [...monTueDone(), ...sets(d(2), 'Bench', 1)],
    );
    expect(mw.isEmpty, isTrue);
  });

  test('climb Tue not climbed → missed, kind climb, setsShort 1', () {
    final mw = run(
      today: d(3),
      climb: {},
      rows: [...monTueDone(), ...sets(d(2), 'Bench', 1)],
    );
    final m = mw.missed.single;
    expect(m.kind, 'climb');
    expect(m.setsShort, 1);
    expect(m.day, d(1));
    expect(mw.toPromptLines(), contains('session not logged'));
  });

  test('climbing today serves today\'s climb, not an earlier miss', () {
    final week = effectiveWeek({
      d(1): [it('Hard climb', period: 'PM')],
      d(2): [it('Light climb', period: 'PM')],
    }, const {});
    final mw = detectMissedWork(
      week: week,
      strengthRows: const [],
      climbDays: {d(2)},
      cardio4x4Days: const {},
      today: d(2),
    );
    expect(mw.missed.single.item.name, 'Hard climb');
  });

  test('4x4 not done → missed as cardio (sets are a session, not 4)', () {
    final mw = run(today: d(2), cardio: {}, rows: monTueDone());
    final m = mw.missed.single;
    expect(m.kind, 'cardio');
    expect(m.item.name, 'Bike');
    expect(m.setsShort, 1);
  });

  test('4x4 done another day of the week → not missed', () {
    final mw = run(
      today: d(3),
      cardio: {d(0)},
      rows: [...monTueDone(), ...sets(d(2), 'Bench', 1)],
    );
    expect(mw.isEmpty, isTrue);
  });

  test('real prose: Optional run never yields an item, Bike 4x4 is cardio', () {
    final items = parsePrescribedProse(
      'Bike 4x4; 10 min hip and thoracic mobility. Easy day.',
      'Optional easy run',
    );
    final week = effectiveWeek({d(0): items}, const {});
    final mw = detectMissedWork(
      week: week,
      strengthRows: const [],
      climbDays: const {},
      cardio4x4Days: const {},
      today: d(1),
    );
    expect(mw.missed.map((m) => (m.item.name, m.kind)), [('Bike', 'cardio')]);
  });

  test('today = Monday → nothing missed', () {
    final mw = run(today: d(0), rows: const [], climb: {}, cardio: {});
    expect(mw.isEmpty, isTrue);
    expect(mw.remainingDays, [for (var i = 0; i < 7; i++) d(i)]);
  });

  test('remainingDays = today..Sunday', () {
    final mw = run(today: d(4));
    expect(mw.remainingDays, [d(4), d(5), d(6)]);
  });

  test('today carries a time of day → treated as its calendar day', () {
    final mw = run(today: DateTime(2026, 10, 1, 21, 30));
    expect(mw.missed.single.item.name, 'Bench top set');
    expect(mw.remainingDays.first, d(3));
  });

  test('rest week / empty program → empty', () {
    final empty = effectiveWeek({
      for (var i = 0; i < 7; i++) d(i): <PrescribedItem>[],
    }, const {});
    final mw = detectMissedWork(
      week: empty,
      strengthRows: const [],
      climbDays: const {},
      cardio4x4Days: const {},
      today: d(5),
    );
    expect(mw.isEmpty, isTrue);
    expect(mw.toPromptLines(), '');
    final none = detectMissedWork(
      week: const {},
      strengthRows: const [],
      climbDays: const {},
      cardio4x4Days: const {},
      today: d(5),
    );
    expect(none.isEmpty, isTrue);
  });

  test('missed sorted by day then program order', () {
    final mw = run(today: d(6), rows: const [], climb: {}, cardio: {});
    expect(mw.missed.map((m) => m.item.name).toList(), [
      'Squat top set',
      'Bench',
      'Bike',
      'Hard climb',
      'Bench top set',
      'Deadlift top set',
      'Press top set',
    ]);
  });

  test('toPromptLines format', () {
    final mw = run(today: d(3), climb: {});
    expect(
      mw.toPromptLines(),
      '- Hard climb — due Tue 9/29, session not logged\n'
      '- Bench top set (1x3 @ RPE 8) — due Wed 9/30, 0/1 sets',
    );
  });

  test('toPromptLines shortens long schemes and omits empty ones', () {
    final week = effectiveWeek({
      d(0): [
        it(
          'Romanian deadlift',
          scheme: '2x8-12 (hinge pattern, keep it smooth and controlled)',
          sets: 2,
        ),
        it('Dips', scheme: '', sets: 1),
      ],
    }, const {});
    final mw = detectMissedWork(
      week: week,
      strengthRows: const [],
      climbDays: const {},
      cardio4x4Days: const {},
      today: d(1),
    );
    expect(
      mw.toPromptLines(),
      '- Romanian deadlift (2x8-12) — due Mon 9/28, 0/2 sets\n'
      '- Dips — due Mon 9/28, 0/1 sets',
    );
  });

  test('climb item whose prose mentions 4x4 is a CLIMB (name decides)', () {
    // Live Tue: "Climb — HARD session" scheme cites "Tue AM-4x4 + PM-climb".
    final week = effectiveWeek({
      d(1): [
        it('Norwegian', scheme: '4x4 VO2 (warmup, 4x4 min hard)', sets: 4),
        it('Climb — HARD session',
            scheme: '(partner day). The Tue AM-4x4 + PM-climb double',
            sets: 4, period: 'PM'),
      ],
    }, const {});
    final m = run(week: week, climb: {d(1)}, cardio: {}, today: d(2));
    expect([for (final x in m.missed) '${x.item.name}|${x.kind}'],
        ['Norwegian|cardio']);
  });

  group('cross-day spare sets need a STRONG match (I3)', () {
    MissedWork one(String item, int target, DateTime loggedDay, String ex,
            int n) =>
        detectMissedWork(
          week: effectiveWeek({
            d(0): [it(item, scheme: '${target}x10', sets: target)],
          }, const {}),
          strengthRows: sets(loggedDay, ex, n),
          climbDays: const {},
          cardio4x4Days: const {},
          today: d(4),
        );

    test('Thu triceps dip does not cover Mon triceps extension', () {
      final mw = one('Triceps extension', 2, d(3),
          'Parallel Bar Triceps Dip', 3);
      expect(mw.missed.single.item.name, 'Triceps extension');
      expect(mw.missed.single.setsShort, 2);
    });

    test('hanging leg raise does not cover lateral raise', () {
      final mw = one('Lateral raise', 3, d(3), 'Hanging Leg Raise', 3);
      expect(mw.missed.single.setsShort, 3);
    });

    test('pull up does not cover face pull', () {
      final mw = one('Face pulls', 2, d(3), 'Pull Up', 3);
      expect(mw.missed.single.setsShort, 2);
    });

    test('Bulgarian split squat does not cover squat; bench press does '
        'not cover press', () {
      expect(one('Squat', 3, d(3), 'Bulgarian Split Squat', 3).isEmpty,
          isFalse);
      expect(one('Press top set', 1, d(3), 'Bench Press', 1).isEmpty,
          isFalse);
    });

    test('"Bench Press" logged Thu covers Wed "Bench heavy"', () {
      final mw = detectMissedWork(
        week: effectiveWeek({
          d(2): [it('Bench heavy', scheme: '1x3')],
        }, const {}),
        strengthRows: sets(d(3), 'Bench Press', 1),
        climbDays: const {},
        cardio4x4Days: const {},
        today: d(4),
      );
      expect(mw.isEmpty, isTrue);
    });

    test('plural prescriptions still strong-match singular logs', () {
      final mw = one('Pull-ups', 2, d(3), 'Pull-up', 2);
      expect(mw.isEmpty, isTrue);
    });
  });

  group('allocateDay — one exclusive per-day allocation (I4)', () {
    test('Fri moved-in "Bench heavy" + own "Bench volume", 3 bench sets → '
        'own item (program order) complete, moved-in short', () {
      final week = effectiveWeek({
        d(2): [it('Bench heavy', scheme: '1x3')],
        d(4): [it('Bench volume', scheme: '3x8-10', sets: 3)],
      }, activeMoves([mv('Bench heavy', d(2), d(4))], mon));
      final fri = [for (final e in week[d(4)]!) if (!e.isGhost) e.item];
      expect(fri.map((i) => i.name), ['Bench volume', 'Bench heavy']);
      final out = allocateDay(fri, List.filled(3, 'Bench Press'));
      expect(out[0].loggedSets, 3);
      expect(out[0].done, isTrue);
      expect(out[1].loggedSets, 0);
      expect(out[1].done, isFalse);
      // The detector agrees (today Sat): only the moved-in item is short.
      final mw = detectMissedWork(
        week: week,
        strengthRows: sets(d(4), 'Bench Press', 3),
        climbDays: const {},
        cardio4x4Days: const {},
        today: d(5),
      );
      expect(mw.missed.map((m) => m.item.name), ['Bench heavy']);
    });

    test('strong matches claim first: face-pull sets go to face pulls, '
        'not to pull-ups listed earlier', () {
      final out = allocateDay([
        it('Pull-ups', scheme: '2x6', sets: 2),
        it('Face pulls', scheme: '2x15', sets: 2),
      ], ['Face Pull', 'Face Pull', 'Pull Up', 'Pull Up']);
      expect([for (final i in out) i.loggedSets], [2, 2]);
    });

    test('session items are left untouched', () {
      final out = allocateDay([
        it('Hard climb', period: 'PM'),
      ], ['Climbing']);
      expect(out.single.loggedSets, 0);
    });
  });

  group('expiryLabel (nightly)', () {
    final sat = DateTime(2026, 10, 3);
    final sun = DateTime(2026, 10, 4);
    test('Saturday-night run planning Sunday → expires end of Sunday, '
        'not tonight', () {
      expect(expiryLabel(sun, sat), 'expires end of Sun 10/4');
    });
    test('Sunday-morning run planning Sunday → tonight', () {
      expect(expiryLabel(sun, sun), 'expires end of Sun 10/4 (tonight)');
    });
    test('non-Sunday targets → null', () {
      expect(expiryLabel(sat, DateTime(2026, 10, 2)), isNull);
      expect(expiryLabel(DateTime(2026, 10, 5), sun), isNull);
    });
  });

  group('Fri 10/2 regression: RDL sets credit "RDL or leg curl"', () {
    final items = parsePrescribedProse(
        'Deadlift heavy: wave top per strength_wave_cut, then deadlift '
        'back-offs 2x4-6 @ 75% TM; RDL or leg curl 2-3x8-12; bench volume '
        '3x8-10 @ 65% TM.',
        null);
    // Working sets as logged (log order — RDL before the deadlifts).
    const logged = [
      'Cable Face Pull', 'Cable Face Pull', 'Flat Barbell Bench Press',
      'Cable Face Pull', 'Flat Barbell Bench Press',
      'Flat Barbell Bench Press', 'Romanian Deadlift', 'Romanian Deadlift',
      'Barbell Deadlift', 'Barbell Deadlift', 'Barbell Deadlift',
    ];
    test('allocation', () {
      final out = {
        for (final i in allocateDay(items, logged)) i.name: i.loggedSets,
      };
      expect(out['Deadlift heavy'], 1);
      expect(out['Deadlift back-offs'], 2);
      expect(out['RDL or leg curl'], 2);
      expect(out['Bench volume'], 3);
    });
    test('"or" alternatives strong-match either side', () {
      expect(loggedCoversPrescribed('Romanian Deadlift', 'RDL or leg curl'),
          isTrue);
      expect(loggedCoversPrescribed('Lying Leg Curl', 'RDL or leg curl'),
          isTrue);
      expect(loggedCoversPrescribed('Barbell Deadlift', 'RDL or leg curl'),
          isFalse);
    });
    test('"back-offs" is a qualifier, not an exercise word', () {
      expect(loggedCoversPrescribed('Barbell Deadlift', 'Deadlift back-offs'),
          isTrue);
    });
  });
}
