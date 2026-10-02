/// Best-set-of-the-day selection for the timeline's logged rows — the
/// same "day top" the history panel tints, applied per group (exercise)
/// within one day.
library;

/// Indices of the best-scoring row in each group. Rows with a null group
/// or null score are ignored; a group needs ≥2 scored rows to have a
/// "best" (a lone set is trivially the max — tinting it is noise). Ties
/// keep every tied row, matching the history panel.
Set<int> bestIndicesPerGroup(List<String?> groups, List<double?> scores) {
  assert(groups.length == scores.length);
  final max = <String, double>{};
  final count = <String, int>{};
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i];
    final s = scores[i];
    if (g == null || s == null) continue;
    count[g] = (count[g] ?? 0) + 1;
    final cur = max[g];
    if (cur == null || s > cur) max[g] = s;
  }
  return {
    for (var i = 0; i < groups.length; i++)
      if (groups[i] != null &&
          scores[i] != null &&
          count[groups[i]]! >= 2 &&
          (scores[i]! - max[groups[i]]!).abs() < 1e-6)
        i,
  };
}
