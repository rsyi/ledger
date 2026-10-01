/// Pure "how should I approach this set" recommendation, from the last
/// comparable session's logged sets. Surfaced when the user taps a
/// prescribed exercise in the program view.
///
/// Deliberately simple + RPE-driven (double-progression spirit): if last
/// time was easy, nudge up; if it was a grind, hold; otherwise repeat and
/// try for one more rep. Bodyweight work (no load) nudges reps/sets.
///
/// Zero Flutter/IO imports; testable in pure Dart.
library;

/// One logged set from a prior session.
class PriorSet {
  final int? reps;
  final double? weight;
  final double? rpe;
  const PriorSet({this.reps, this.weight, this.rpe});
}

class SetRecommendation {
  /// Null when there's no comparable history.
  final String? lastSessionSummary; // "3×10 @ 95 lb · RPE 8"
  final String advice; // the one-line recommendation
  const SetRecommendation({this.lastSessionSummary, required this.advice});
}

String _wStr(double w) =>
    w == w.roundToDouble() ? w.round().toString() : w.toStringAsFixed(1);

/// Builds a recommendation from the most recent comparable session's
/// [sets] (all from one day). Empty → "first time" advice.
SetRecommendation recommendSet(List<PriorSet> sets) {
  if (sets.isEmpty) {
    return const SetRecommendation(
      advice: 'No prior log for this movement — start conservative and '
          'leave 1–2 reps in reserve.',
    );
  }

  final weights = [for (final s in sets) if (s.weight != null) s.weight!];
  final reps = [for (final s in sets) if (s.reps != null) s.reps!];
  final rpes = [for (final s in sets) if (s.rpe != null) s.rpe!];
  final topWeight = weights.isEmpty
      ? null
      : weights.reduce((a, b) => a > b ? a : b);
  final maxRpe = rpes.isEmpty ? null : rpes.reduce((a, b) => a > b ? a : b);

  // Summary line.
  final parts = <String>['${sets.length} ${sets.length == 1 ? "set" : "sets"}'];
  if (reps.isNotEmpty) {
    final lo = reps.reduce((a, b) => a < b ? a : b);
    final hi = reps.reduce((a, b) => a > b ? a : b);
    parts.add(lo == hi ? '$lo reps' : '$lo–$hi reps');
  }
  if (topWeight != null) parts.add('top ${_wStr(topWeight)} lb');
  if (maxRpe != null) parts.add('RPE ${_wStr(maxRpe)}');
  final summary = parts.join(' · ');

  // Advice.
  final String advice;
  if (maxRpe == null) {
    advice = topWeight == null
        ? 'Last time: $summary. Add a rep or a set this week.'
        : 'Last time: $summary. Log RPE this week so progression can tune '
            'the load.';
  } else if (maxRpe <= 8) {
    advice = topWeight == null
        ? 'Last time felt easy (RPE ${_wStr(maxRpe)}). Add reps or a set.'
        : 'Last time felt easy (RPE ${_wStr(maxRpe)}). Add ~5 lb or a rep.';
  } else if (maxRpe >= 9.5) {
    advice =
        'Last time was a grind (RPE ${_wStr(maxRpe)}). Hold the load and '
        'keep the reps clean — no need to add yet.';
  } else {
    advice =
        'Last time was on target (RPE ${_wStr(maxRpe)}). Repeat and try for '
        'one more rep at the same load.';
  }

  return SetRecommendation(lastSessionSummary: summary, advice: advice);
}
