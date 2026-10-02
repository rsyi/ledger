import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/day_best.dart';

void main() {
  test('picks the max per group', () {
    expect(
      bestIndicesPerGroup(
        ['squat', 'squat', 'bench', 'bench', 'squat'],
        [300, 320, 200, 190, 310],
      ),
      {1, 2},
    );
  });

  test('lone scored set in a group is not highlighted', () {
    expect(bestIndicesPerGroup(['curl', 'squat', 'squat'], [80, 1, 2]), {2});
  });

  test('null group / null score ignored; ties keep all', () {
    expect(
      bestIndicesPerGroup(['a', 'a', 'a', null], [null, 5, 5, 9]),
      {1, 2},
    );
  });
}
