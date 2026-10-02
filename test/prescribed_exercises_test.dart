import 'package:airledger/services/prescribed_exercises.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const thu =
      'Muscle-ups 3-5x1-2 (quality); handstand hold; front lever up-downs 2x5; '
      'hanging leg raise 3x8-15; dips 3x8-12; EZ-bar curls 2x8-15.';

  group('parsePrescribedProse', () {
    test('extracts each exercise incl. front lever + hanging leg raise', () {
      final items = parsePrescribedProse(thu, null);
      final names = items.map((e) => e.name.toLowerCase()).toList();
      expect(names, contains('muscle-ups'));
      expect(names.any((n) => n.contains('front lever')), isTrue);
      expect(names.any((n) => n.contains('hanging leg raise')), isTrue);
      expect(names.any((n) => n.contains('dips')), isTrue);
      expect(names.every((n) => n.isNotEmpty), isTrue);
    });

    test('splits "then"-chained exercises (real v14 Thursday prose)', () {
      const real =
          'Muscle-ups FIRST (skill — quality sets, stop on quality loss). '
          'Then handstand practice ~10 min (wall or free, quality holds); '
          'front-lever up-downs 2x5 (straight-arm, short of failure); '
          'hanging leg raise 3x8-15. Then dips 3x8-12; optional row; '
          'EZ curls 3x8-12; optional triceps 2x10-15.';
      final names =
          parsePrescribedProse(real, null).map((e) => e.name.toLowerCase());
      expect(names.any((n) => n.contains('muscle')), isTrue);
      expect(names.any((n) => n.contains('handstand')), isTrue);
      expect(names.any((n) => n.contains('front-lever')), isTrue);
      expect(names.any((n) => n.contains('hanging leg raise')), isTrue);
      expect(names.any((n) => n.contains('dips')), isTrue);
      expect(names.any((n) => n.contains('ez curls')), isTrue);
      // "optional row/triceps" are skipped.
      expect(names.any((n) => n.contains('optional')), isFalse);
    });

    test('skips non-exercise clauses', () {
      final items = parsePrescribedProse(
          'Bench top set, then back-offs 3x5-8; No squat or deadlift today; '
          'mind total weekly pulling volume',
          null);
      final names = items.map((e) => e.name.toLowerCase()).join('|');
      expect(names, contains('bench'));
      expect(names, isNot(contains('no squat')));
      expect(names, isNot(contains('mind')));
    });

    test('strips the "wave" jargon from names', () {
      final items = parsePrescribedProse(
          'Squat heavy: wave top per strength_wave_cut (wk1 5@81%)', null);
      expect(items.first.name.toLowerCase(), isNot(contains('wave')));
    });
  });

  group('set count is first-class', () {
    test('parseTargetSets reads the set count', () {
      expect(parseTargetSets('2x5 (straight-arm)'), 2);
      expect(parseTargetSets('3-5x1-2 (quality)'), 3);
      expect(parseTargetSets('6 sets unassisted'), 6);
      expect(parseTargetSets('top set at RPE 8'), 1); // no count → 1
    });

    test('completes only when the full set target is logged', () {
      final items = parsePrescribedProse(
          'Front lever up-downs 2x5; Hanging leg raise 3x8-15', null);
      final fl = items.firstWhere((e) => e.name.contains('Front'));
      expect(fl.targetSets, 2);

      // One logged set → partial, NOT done.
      var marked = markPrescribedDone(items, ['Front Lever']);
      var flMarked = marked.firstWhere((e) => e.name.contains('Front'));
      expect(flMarked.loggedSets, 1);
      expect(flMarked.done, isFalse);

      // Both sets logged → done.
      marked = markPrescribedDone(items, ['Front Lever', 'Front Lever']);
      flMarked = marked.firstWhere((e) => e.name.contains('Front'));
      expect(flMarked.loggedSets, 2);
      expect(flMarked.done, isTrue);
    });

    test('matches with aliases (MU → muscle)', () {
      final items =
          parsePrescribedProse('Muscle-ups 1x1 (skill)', null);
      final marked = markPrescribedDone(items, ['Muscle-up']);
      expect(marked.single.done, isTrue);
    });
  });

  test('PM climb prose: period prefix stripped, no split inside parens', () {
    final items = parsePrescribedProse(null,
        'PM: Climb — LIGHT session (technique/volume, movement quality; low fatigue).');
    expect(items, hasLength(1));
    expect(items.single.name, 'Climb — LIGHT session');
    expect(items.single.period, 'PM');
    expect(items.single.scheme, contains('low fatigue'));
  });

  test('Tue PM climb survives a skip word inside its parentheses', () {
    final items = parsePrescribedProse(null,
        "PM: Climb — HARD session (the week's quality/limit climbing; partner day). The Tue AM-4x4 + PM-climb double session is the week's biggest recovery bite — keep both honest, no junk volume.");
    expect(items.where((i) => i.name.startsWith('Climb')), hasLength(1));
  });
}
