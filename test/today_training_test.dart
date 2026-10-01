import 'package:airledger/services/today_training.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('summarizeTraining', () {
    test('groups by exercise in first-seen order with set counts', () {
      final t = summarizeTraining(const [
        TrainingSet(exercise: 'Squat', reps: 5, weight: 225),
        TrainingSet(exercise: 'Squat', reps: 3, weight: 275),
        TrainingSet(exercise: 'Bench', reps: 8, weight: 155),
        TrainingSet(exercise: 'squat', reps: 3, weight: 245), // case-insens
      ]);
      expect(t.exercises.map((e) => e.exercise), ['Squat', 'Bench']);
      expect(t.exercises[0].sets, 3);
      expect(t.exercises[0].topWeight, 275);
      expect(t.exercises[0].topWeightReps, 3);
      expect(t.exercises[1].sets, 1);
      expect(t.totalSets, 4);
      expect(t.isEmpty, isFalse);
    });

    test('bodyweight work: no weight → null topWeight, reps collected', () {
      final t = summarizeTraining(const [
        TrainingSet(exercise: 'Hanging Leg Raise', reps: 12),
        TrainingSet(exercise: 'Hanging Leg Raise', reps: 10),
      ]);
      expect(t.exercises.single.sets, 2);
      expect(t.exercises.single.topWeight, isNull);
      expect(t.exercises.single.reps, [12, 10]);
    });

    test('blank exercise names are skipped; empty input is empty', () {
      expect(summarizeTraining(const []).isEmpty, isTrue);
      final t = summarizeTraining(const [
        TrainingSet(exercise: '  '),
        TrainingSet(exercise: 'Row', reps: 10),
      ]);
      expect(t.exercises.single.exercise, 'Row');
    });
  });
}
