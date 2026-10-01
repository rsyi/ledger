/// Pure summariser for "what I've actually trained today" — groups the
/// day's logged strength sets per exercise so the Today tab can show the
/// session (Squat 5 sets, top 275×3; Bench 4 sets …) instead of a bare
/// "24 sets logged" count.
///
/// Zero Flutter/IO imports; testable in pure Dart.
library;

/// One logged set (one strength row).
class TrainingSet {
  final String exercise;
  final int? reps;
  final double? weight;
  const TrainingSet({required this.exercise, this.reps, this.weight});
}

/// A per-exercise rollup of the day's sets, in first-logged order.
class LoggedExercise {
  final String exercise;
  final int sets;

  /// Reps per set, in log order (nulls dropped).
  final List<int> reps;

  /// Heaviest logged weight across the exercise's sets, and the reps on
  /// that set — null when no weight was recorded (bodyweight/skill work).
  final double? topWeight;
  final int? topWeightReps;

  const LoggedExercise({
    required this.exercise,
    required this.sets,
    required this.reps,
    this.topWeight,
    this.topWeightReps,
  });
}

/// The day's training, grouped by exercise.
class TrainingToday {
  final List<LoggedExercise> exercises;
  const TrainingToday(this.exercises);

  bool get isEmpty => exercises.isEmpty;
  int get totalSets => exercises.fold(0, (a, e) => a + e.sets);
}

/// Groups [sets] by exercise (case-insensitive, first-seen display
/// casing), preserving the order each exercise first appears.
TrainingToday summarizeTraining(List<TrainingSet> sets) {
  final order = <String>[]; // lowercase keys in first-seen order
  final display = <String, String>{};
  final count = <String, int>{};
  final reps = <String, List<int>>{};
  final topW = <String, double>{};
  final topWReps = <String, int?>{};

  for (final s in sets) {
    final name = s.exercise.trim();
    if (name.isEmpty) continue;
    final key = name.toLowerCase();
    if (!display.containsKey(key)) {
      order.add(key);
      display[key] = name;
      count[key] = 0;
      reps[key] = [];
    }
    count[key] = count[key]! + 1;
    if (s.reps != null) reps[key]!.add(s.reps!);
    final w = s.weight;
    if (w != null && (topW[key] == null || w > topW[key]!)) {
      topW[key] = w;
      topWReps[key] = s.reps;
    }
  }

  return TrainingToday([
    for (final key in order)
      LoggedExercise(
        exercise: display[key]!,
        sets: count[key]!,
        reps: reps[key]!,
        topWeight: topW[key],
        topWeightReps: topWReps[key],
      ),
  ]);
}

/// Formats one logged exercise for display: "Squat — 3 sets · top 275×3"
/// (weighted) or "Hanging Leg Raise — 2 sets · 12, 10" (bodyweight).
String trainingLineFor(LoggedExercise e) {
  final setWord = e.sets == 1 ? 'set' : 'sets';
  final buf = StringBuffer('${e.exercise} — ${e.sets} $setWord');
  if (e.topWeight != null) {
    final w = e.topWeight!;
    final wStr = w == w.roundToDouble() ? w.round().toString() : w.toString();
    buf.write(' · top $wStr');
    if (e.topWeightReps != null) buf.write('×${e.topWeightReps}');
  } else if (e.reps.isNotEmpty) {
    buf.write(' · ${e.reps.join(', ')}');
  }
  return buf.toString();
}
