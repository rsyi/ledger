/// Process-wide cache of the user's current bodyweight (lb), refreshed
/// whenever a weight series loads (the Today/Progress tabs). The strength
/// form reads it to prefill the load for bodyweight movements (pull-ups,
/// muscle-ups, dips, front lever, hanging leg raise …) so those sets
/// carry the right weight without manual entry.
library;

class BodyweightCache {
  BodyweightCache._();

  /// Most recent known bodyweight (7-day average when available). Null
  /// until a weight series has loaded this session.
  static double? currentLbs;

  static void update(double? lbs) {
    if (lbs != null && lbs > 0) currentLbs = lbs;
  }
}

const _bodyweightKeywords = [
  'pull up',
  'pull-up',
  'pullup',
  'chin up',
  'chin-up',
  'muscle up',
  'muscle-up',
  'dip',
  'hanging leg raise',
  'front lever',
  'inverted row',
  'handstand',
  'pistol',
  'l sit',
  'l-sit',
  'push up',
  'push-up',
  'ring',
];

/// Heuristic: does this exercise use bodyweight as its load? (Name-based —
/// the schema has no bodyweight flag.)
bool isBodyweightExercise(String exercise) {
  final n = exercise.toLowerCase();
  return _bodyweightKeywords.any(n.contains);
}
