/// Pure "how should I approach this set" recommendation, from the last
/// comparable session's logged sets. Surfaced when the user taps a
/// prescribed exercise in the program view.
///
/// Deliberately simple + RPE-driven (double-progression spirit): if last
/// time was easy, nudge up; if it was a grind, hold; otherwise repeat and
/// try for one more rep. Bodyweight work (no load) nudges reps/sets.
///
/// 2026-10-02: when the program PRICES the item (the Plan tab's numbers,
/// program_item_pricing.dart) the prescription leads and
/// [recommendForPrescription] is consistent with it — last session is
/// context only, never "+5 lb over the program". [recommendSet] is the
/// fallback for unpriced items. [lastComparableSession] picks the last
/// session's WORKING sets (warm-ups excluded) of the same lift, in the
/// item's role (top set vs back-offs).
///
/// Zero Flutter/IO imports; testable in pure Dart.
library;

import 'accessory_progression.dart' show AccessorySuggestion;
import 'prescribed_exercises.dart'
    show loggedAddsVariant, loggedCoversPrescribed, loggedMatchesPrescribed;
import 'working_sets.dart' show workingSetRecords;

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

/// "3 sets · 8–10 reps · top 95 lb · RPE 8" — null when [sets] is empty.
String? summarizeSets(List<PriorSet> sets) {
  if (sets.isEmpty) return null;
  final weights = [for (final s in sets) if (s.weight != null) s.weight!];
  final reps = [for (final s in sets) if (s.reps != null) s.reps!];
  final rpes = [for (final s in sets) if (s.rpe != null) s.rpe!];
  final parts = <String>['${sets.length} ${sets.length == 1 ? "set" : "sets"}'];
  if (reps.isNotEmpty) {
    final lo = reps.reduce((a, b) => a < b ? a : b);
    final hi = reps.reduce((a, b) => a > b ? a : b);
    parts.add(lo == hi ? '$lo reps' : '$lo–$hi reps');
  }
  if (weights.isNotEmpty) {
    parts.add('top ${_wStr(weights.reduce((a, b) => a > b ? a : b))} lb');
  }
  if (rpes.isNotEmpty) {
    parts.add('RPE ${_wStr(rpes.reduce((a, b) => a > b ? a : b))}');
  }
  return parts.join(' · ');
}

/// Which sets of the last session are comparable to the item.
enum SetRole {
  /// The day's single heaviest working set (a top-set item).
  top,

  /// The working sets minus the top set (a back-off / volume item).
  backoff,

  /// Every working set.
  all,
}

/// One prior session: its day, comparable sets and last note.
class LastSession {
  final DateTime day;
  final List<PriorSet> sets;
  final String? note;
  const LastSession({required this.day, required this.sets, this.note});
}

/// Exercise matcher for an UNPRICED item's history: the logged names that
/// strongly cover [itemName] when any exist in [loggedNames], else loose
/// matches that add no variant qualifier — so "Deadlift heavy" reads
/// Barbell Deadlift, never Romanian Deadlift.
bool Function(String) historyMatcher(
    String itemName, Iterable<String> loggedNames) {
  final strong = {
    for (final n in loggedNames)
      if (loggedCoversPrescribed(n, itemName)) n,
  };
  if (strong.isNotEmpty) return strong.contains;
  return (n) =>
      loggedMatchesPrescribed(n, itemName) && !loggedAddsVariant(n, itemName);
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

DateTime? _day(Object? v) {
  DateTime? d;
  if (v is DateTime) {
    d = v;
  } else if (v is String && v.isNotEmpty) {
    d = DateTime.tryParse(v.length >= 10 ? v.substring(0, 10) : v);
  }
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

/// The latest session strictly before [before] with a WORKING set
/// (warm-ups excluded — working_sets.dart) of an exercise [matches]
/// accepts, reduced to [role]'s sets. Null without such a session.
LastSession? lastComparableSession(
  List<Map<String, Object?>> records, {
  required bool Function(String exercise) matches,
  required DateTime before,
  SetRole role = SetRole.all,
}) {
  final cut = DateTime(before.year, before.month, before.day);
  final mine = [
    for (final r in records)
      if (matches((r['exercise'] ?? '').toString().trim()))
        if (_day(r['date']) case final d? when d.isBefore(cut)) r,
  ];
  final working = workingSetRecords(mine);
  DateTime? last;
  for (final r in working) {
    final d = _day(r['date'])!;
    if (last == null || d.isAfter(last)) last = d;
  }
  if (last == null) return null;
  final day = [
    for (final r in working)
      if (_day(r['date']) == last) r,
  ];
  PriorSet prior(Map<String, Object?> r) => PriorSet(
        reps: _num(r['reps'])?.round(),
        weight: _num(r['weight']),
        rpe: _num(r['rpe']),
      );
  String? note;
  for (final r in day) {
    final n = r['notes']?.toString().trim();
    if (n != null && n.isNotEmpty) note = n;
  }
  var sets = [for (final r in day) prior(r)];
  double? top;
  for (final s in sets) {
    if (s.weight != null && (top == null || s.weight! > top)) top = s.weight;
  }
  if (role == SetRole.top && top != null) {
    sets = [sets.firstWhere((s) => s.weight == top)];
  } else if (role == SetRole.backoff && top != null) {
    final tagged = [
      for (var i = 0; i < day.length; i++)
        if (day[i]['set_type']?.toString().trim().toLowerCase() == 'heavy') i,
    ];
    final List<PriorSet> rest;
    if (tagged.isNotEmpty) {
      rest = [
        for (var i = 0; i < sets.length; i++)
          if (!tagged.contains(i)) sets[i],
      ];
    } else if (sets.where((s) => s.weight == top).length == 1) {
      rest = [for (final s in sets) if (s.weight != top) s];
    } else {
      rest = sets;
    }
    if (rest.isNotEmpty) sets = rest;
  }
  return LastSession(day: last, sets: sets, note: note);
}

/// Advice CONSISTENT with a priced prescription ([lines] = the card's
/// formatted lines, e.g. `1×5 · 275 lb (81%)`). Main-lift loads are the
/// program's (training max × wave/%TM) — the day never adds load over
/// them; accessories follow the double-progression [accessory]
/// suggestion. [last] is shown as context only.
SetRecommendation recommendForPrescription({
  required List<String> lines,
  required bool mainLift,
  required bool top,
  required bool weighted,
  LastSession? last,
  AccessorySuggestion? accessory,
  String? backoff,
}) {
  final rx = lines.join(' + ');
  final String advice;
  if (mainLift && top) {
    advice = weighted
        ? 'Do the program\'s top set: $rx. Work up to it and stop there — '
            "don't add load on the day. Log the RPE: the training max "
            're-estimates itself from logged top sets.'
        : 'Top set $rx — no training max yet, so no load is prescribed. '
            'Pick a weight you\'d rate RPE 7-8 and log the RPE.';
  } else if (mainLift) {
    advice = 'Program: $rx.'
        '${backoff == null ? '' : ' Back-offs: $backoff.'}'
        ' Log RPE on each set so drift shows.';
  } else if (accessory != null) {
    final from = _wStr(accessory.lastWeightLb.toDouble());
    advice = switch (accessory.action) {
      'overload' => 'Add load: $rx (up from $from lb — ${accessory.reason}).',
      'backoff' => 'Back off: $rx (down from $from lb — ${accessory.reason}).',
      _ => 'Hold the load: $rx — ${accessory.reason}.',
    };
  } else {
    advice = 'Program: $rx. Add reps toward the top of the range before '
        'adding load or difficulty; leave 1–2 reps in reserve.';
  }
  return SetRecommendation(
    lastSessionSummary: last == null ? null : summarizeSets(last.sets),
    advice: advice,
  );
}

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
