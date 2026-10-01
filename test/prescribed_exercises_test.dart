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

  group('markPrescribedDone', () {
    test('matches logged sets to prescribed items (with aliases)', () {
      final done = markPrescribedDone(
        parsePrescribedProse(thu, null),
        ['Muscle-up', 'Front Lever', 'Hanging Leg Raise'],
      );
      PrescribedItem byName(String frag) =>
          done.firstWhere((e) => e.name.toLowerCase().contains(frag));
      expect(byName('muscle').done, isTrue); // MU alias → muscle
      expect(byName('front lever').done, isTrue);
      expect(byName('hanging leg raise').done, isTrue);
      expect(byName('dips').done, isFalse); // not logged
    });
  });
}
