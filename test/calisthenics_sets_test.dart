import 'package:airledger/services/missed_work.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/working_sets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calisthenics rows expand to one logged set per set', () {
    final out = calisthenicsLoggedSets([
      {'date': '2026-10-01', 'skill': 'handstand', 'variation': 'wall', 'sets': null},
      {'date': DateTime(2026, 10, 1), 'skill': 'muscle-up', 'variation': '', 'sets': 3},
      {'date': '2026-10-01', 'skill': '', 'sets': 2}, // no skill → skipped
    ]);
    expect(out.map((e) => e.exercise).toList(),
        ['handstand wall', 'muscle-up', 'muscle-up', 'muscle-up']);
    expect(out.first.date, DateTime(2026, 10, 1));
  });

  test('a logged handstand set completes "Handstand practice"', () {
    final items = parsePrescribedProse(
        'Then handstand practice ~10 min (wall or free, quality holds)', null);
    final out = allocateDay(items, [
      for (final s in calisthenicsLoggedSets([
        {'date': '2026-10-01', 'skill': 'handstand', 'sets': 1},
      ]))
        s.exercise,
    ]);
    expect(out.single.done, isTrue);
  });

  test('handstand logged Fri covers Thu "Handstand practice" (cross-day)', () {
    expect(loggedCoversPrescribed('handstand', 'Handstand practice'), isTrue);
  });
}
