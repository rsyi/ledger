import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/day_achievement.dart';
import 'package:airledger/services/prescribed_exercises.dart';

AchievedSet s(String ex, num? w, int? reps) => AchievedSet.fromRecord(
    ex, {'exercise': ex, 'weight': ?w, 'reps': ?reps});

PrescribedItem item(String name, int sets) =>
    PrescribedItem(name: name, scheme: '', period: 'AM', targetSets: sets);

void main() {
  group('achievedMeta', () {
    test('top-set item reads "top W×R"', () {
      expect(achievedMeta([s('Deadlift', 275, 6)], target: 1, top: true),
          'top 275×6');
      expect(
          achievedMeta([s('Deadlift', 265, 5), s('Deadlift', 275, 6)],
              target: 1, top: true),
          'top 275×6 · 2 sets');
    });

    test('uniform sets collapse to N×R · load', () {
      expect(
          achievedMeta([for (var i = 0; i < 3; i++) s('Bench', 160, 8)],
              target: 3),
          '3×8 · 160 lb');
      expect(
          achievedMeta([for (var i = 0; i < 3; i++) s('Dips', null, 10)],
              target: 3),
          '3×10 · BW');
    });

    test('mixed sets: count + best', () {
      expect(
          achievedMeta(
              [s('Bench', 160, 10), s('Bench', 160, 8), s('Bench', 155, 8)],
              target: 3),
          '3 sets · best 160×10');
    });

    test('short of target: k of N sets', () {
      expect(achievedMeta([s('Bench', 160, 8)], target: 3),
          '1 of 3 sets · best 160×8');
      expect(achievedMeta([s('Skill', null, null)], target: 3), '1 of 3 sets');
    });

    test('nothing recorded → set count; none → null', () {
      expect(achievedMeta([s('Bench', null, null), s('Bench', null, null)],
              target: 2),
          '2 sets');
      expect(achievedMeta(const [], target: 1), isNull);
      expect(achievedMeta([s('Curl', 17.5, 19)], target: 0), '17.5×19');
    });
  });

  group('achieveDay', () {
    test('counts agree with allocateDay; surplus folds; top swap', () {
      final items = [item('Deadlift heavy', 1), item('Deadlift back-offs', 2)];
      final logged = [
        s('Barbell Deadlift', 255, 4),
        s('Barbell Deadlift', 275, 6),
        s('Barbell Deadlift', 255, 4),
        s('Barbell Deadlift', 255, 4),
      ];
      final r = achieveDay(
          items: items, logged: logged, isTop: const [true, false]);
      expect([for (final i in r.items) i.loggedSets], [1, 2]);
      expect([for (final x in r.sets[0]) x.weight], [275]);
      expect(r.sets[1], hasLength(3), reason: 'surplus folds in');
      expect(r.extra, isEmpty);
    });

    test('unmatched sets + their clips → Also logged; warm-up clip → '
        'first item that claimed the lift', () {
      final items = [item('Squat heavy', 1), item('Squat volume', 3)];
      final warm = {'exercise': 'Back Squat', 'weight': 135, 'reps': 5};
      final face = {'exercise': 'Cable Face Pull', 'weight': 17.5, 'reps': 19};
      final logged = [
        s('Back Squat', 275, 3),
        AchievedSet.fromRecord('Cable Face Pull', face),
      ];
      final r = achieveDay(items: items, logged: logged, clips: [
        DayClip(url: 'u1', mediaId: 'w', exercise: 'Back Squat', record: warm),
        DayClip(
            url: 'u2', mediaId: 'f', exercise: 'Cable Face Pull', record: face),
        DayClip(url: 'u3', mediaId: 'x', exercise: 'Hip Thrust', record: {}),
      ]);
      expect([for (final c in r.clips[0]) c.mediaId], ['w']);
      expect(r.clips[1], isEmpty);
      expect([for (final e in r.extra) e.exercise],
          ['Cable Face Pull', 'Hip Thrust']);
      expect([for (final c in r.extra[0].clips) c.mediaId], ['f']);
      expect(r.extra[1].sets, isEmpty, reason: 'clip-only (warm-up) extra');
    });
  });
}
