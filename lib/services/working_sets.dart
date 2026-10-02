/// Warm-up exclusion for crediting prescribed program items — ONE rule
/// shared by the program day card, the day synthesis, the missed-work
/// detector (via [WeekStateLoader]) and tool/missed_work.dart, so a
/// ramp of light sets never makes a 4-set item look done.
///
/// Rule:
///   * `set_type == 'warmup'` → warm-up. Any other tag (heavy /
///     hypertrophy / skill / rehab) → working.
///   * untagged → warm-up iff it's a RAMP set: rpe is null or < 6 AND
///     its weight is below 75% of that day's top weight for the same
///     exercise OR below that day's lightest RPE-rated (>= 6) set of it.
///     The second gate catches the live pattern (bench 175 @ 8, 175 @ 7
///     + unrated 155/135/95 — 155 is 89% of the top): an unrated set
///     lighter than every rated working set is a ramp. Unrated sets at
///     or above the lightest rated set (un-RPE'd back-offs) still work.
///   * bodyweight / no-weight rows (pull-ups, dips) are never warm-ups
///     by weight.
///
/// Deliberately NOT recomp_review's `countsAsProductive` (untagged
/// rpe < 6 = warm-up, weight-blind; skill/rehab excluded): that rule
/// counts hypertrophy-productive sets, this one decides whether a set
/// did prescribed work — a skill set does a skill item, and an
/// untagged heavy single at RPE 5 is still the top set.
///
/// Pure: no Flutter/IO imports.
library;

/// Fraction of the day's top weight below which an easy untagged set is
/// a ramp/warm-up set.
const warmupTopFraction = 0.75;

/// Whether one logged set is a warm-up (see the library doc).
bool isWarmupSet({
  String? setType,
  double? weight,
  double? rpe,
  double? dayTopWeight,
  double? dayMinRatedWeight,
}) {
  final tag = setType?.trim().toLowerCase() ?? '';
  if (tag.isNotEmpty && tag != 'null') return tag == 'warmup';
  if (weight == null || weight <= 0) return false;
  if (rpe != null && rpe >= 6) return false;
  if (dayTopWeight != null &&
      dayTopWeight > 0 &&
      weight < warmupTopFraction * dayTopWeight) {
    return true;
  }
  return dayMinRatedWeight != null && weight < dayMinRatedWeight;
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v == null) return null;
  return double.tryParse(v.toString().trim());
}

String _dayKey(Object? v) {
  DateTime? d;
  if (v is DateTime) {
    d = v;
  } else if (v != null) {
    final s = v.toString().trim();
    d = DateTime.tryParse(s.length >= 10 ? s.substring(0, 10) : s);
  }
  return d == null ? '' : '${d.year}-${d.month}-${d.day}';
}

/// [rows] (strength records: `date`, `exercise`, `weight`, `rpe`,
/// `set_type`; DateTime/num or Sheets strings) minus warm-ups, in input
/// order. "Day top" / "lightest rated" = over rows of the same exercise
/// (case-insensitive) on the same calendar day.
List<Map<String, Object?>> workingSetRecords(
  Iterable<Map<String, Object?>> rows,
) {
  final list = rows.toList();
  String key(Map<String, Object?> r) =>
      '${_dayKey(r['date'])}|'
      '${(r['exercise'] ?? '').toString().trim().toLowerCase()}';
  final top = <String, double>{};
  final minRated = <String, double>{};
  for (final r in list) {
    final w = _num(r['weight']);
    if (w == null || w <= 0) continue;
    final k = key(r);
    if (w > (top[k] ?? double.negativeInfinity)) top[k] = w;
    final rpe = _num(r['rpe']);
    final warm = r['set_type']?.toString().trim().toLowerCase() == 'warmup';
    if (!warm &&
        rpe != null &&
        rpe >= 6 &&
        w < (minRated[k] ?? double.infinity)) {
      minRated[k] = w;
    }
  }
  return [
    for (final r in list)
      if (!isWarmupSet(
        setType: r['set_type']?.toString(),
        weight: _num(r['weight']),
        rpe: _num(r['rpe']),
        dayTopWeight: top[key(r)],
        dayMinRatedWeight: minRated[key(r)],
      ))
        r,
  ];
}

/// Calisthenics log rows (skill / variation / sets) as logged sets for
/// program crediting — one entry per set (blank sets = 1), named
/// "skill variation" so "handstand" credits "Handstand practice".
/// Rows without a date or skill are skipped.
List<({DateTime date, String exercise})> calisthenicsLoggedSets(
    Iterable<Map<String, Object?>> rows) {
  final out = <({DateTime date, String exercise})>[];
  for (final r in rows) {
    final raw = r['date'];
    final d = raw is DateTime ? raw : DateTime.tryParse(raw?.toString() ?? '');
    final skill = r['skill']?.toString().trim() ?? '';
    if (d == null || skill.isEmpty) continue;
    final variation = r['variation']?.toString().trim() ?? '';
    final name = variation.isEmpty ? skill : '$skill $variation';
    final setsRaw = r['sets'];
    final sets = setsRaw is num
        ? setsRaw.round()
        : (num.tryParse(setsRaw?.toString() ?? '')?.round() ?? 1);
    for (var i = 0; i < (sets < 1 ? 1 : sets); i++) {
      out.add((date: DateTime(d.year, d.month, d.day), exercise: name));
    }
  }
  return out;
}
