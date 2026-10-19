/// Strength form "previous record" hint (2026-10-19, user request): the
/// best WORKING set (warm-ups excluded via working_sets.dart's shared
/// rule) by [rpeAdjustedE1rm] for the same exercise AND the same
/// paused/belted state the form currently has toggled, plus the most
/// recent comparable session's top set.
///
/// Flag filter: a null form flag = no filter; true/false match rows with
/// that EXPLICIT value only — a blank row flag is "not recorded", never
/// coerced to false (the switch-widget contract).
///
/// Built once per form from the already-loaded strength list; every
/// (exercise, flags, before) query is memoized, so toggling a switch or
/// retyping an exercise never rescans the table.
///
/// Pure: no Flutter/IO imports.
library;

import 'program_metrics.dart' show rpeAdjustedE1rm;
import 'working_sets.dart' show warmupIndices;

/// One logged working set as the hint shows it.
class RecordSet {
  final String? id;
  final DateTime date;
  final double weight;
  final int reps;
  final double? rpe;
  final double e1rm;

  const RecordSet({
    this.id,
    required this.date,
    required this.weight,
    required this.reps,
    this.rpe,
    required this.e1rm,
  });

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// "275×5 @ 8.5" (RPE omitted when unrated).
  String get label =>
      '${_n(weight)}×$reps${rpe == null ? '' : ' @ ${_n(rpe!)}'}';
}

/// [best] = the record; [last] = top set of the most recent session
/// strictly before the query's `before` day (any session when null).
typedef PreviousRecord = ({RecordSet? best, RecordSet? last});

class _Entry {
  final RecordSet set;
  final bool? paused;
  final bool? belted;
  const _Entry(this.set, this.paused, this.belted);
}

class PreviousRecordIndex {
  final Map<String, List<_Entry>> _byExercise = {};
  final Map<String, PreviousRecord> _memo = {};

  PreviousRecordIndex(
    Iterable<Map<String, Object?>> rows, {
    String dateField = 'date',
  }) {
    final list = [
      for (final r in rows)
        // The shared warm-up rule keys on `date`.
        if (dateField == 'date') r else {...r, 'date': r[dateField]},
    ];
    final warm = warmupIndices(list);
    for (var i = 0; i < list.length; i++) {
      if (warm.contains(i)) continue;
      final r = list[i];
      final ex = _exKey(r['exercise']);
      final date = _date(r['date']);
      final w = _num(r['weight']);
      final reps = _num(r['reps'])?.round();
      if (ex.isEmpty || date == null || w == null || w <= 0) continue;
      if (reps == null || reps <= 0) continue;
      final rpe = _num(r['rpe']);
      (_byExercise[ex] ??= []).add(_Entry(
        RecordSet(
          id: r['id']?.toString(),
          date: date,
          weight: w,
          reps: reps,
          rpe: rpe,
          e1rm: rpeAdjustedE1rm(w, reps, rpe),
        ),
        _bool(r['paused']),
        _bool(r['belted']),
      ));
    }
  }

  PreviousRecord lookup(
    String exercise, {
    bool? paused,
    bool? belted,
    DateTime? before,
  }) {
    final ex = _exKey(exercise);
    final day = before == null
        ? null
        : DateTime(before.year, before.month, before.day);
    final key = '$ex|$paused|$belted|$day';
    return _memo[key] ??= _compute(ex, paused, belted, day);
  }

  PreviousRecord _compute(
      String ex, bool? paused, bool? belted, DateTime? before) {
    RecordSet? best;
    DateTime? lastDay;
    RecordSet? last;
    for (final e in _byExercise[ex] ?? const <_Entry>[]) {
      if (paused != null && e.paused != paused) continue;
      if (belted != null && e.belted != belted) continue;
      final s = e.set;
      if (best == null ||
          s.e1rm > best.e1rm ||
          (s.e1rm == best.e1rm && s.date.isAfter(best.date))) {
        best = s;
      }
      if (before != null && !s.date.isBefore(before)) continue;
      if (lastDay == null || s.date.isAfter(lastDay)) {
        lastDay = s.date;
        last = s;
      } else if (s.date == lastDay && s.e1rm > last!.e1rm) {
        last = s;
      }
    }
    return (best: best, last: last);
  }

  static String _exKey(Object? v) =>
      (v ?? '').toString().trim().toLowerCase();

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v == null) return null;
    return double.tryParse(v.toString().trim());
  }

  static bool? _bool(Object? v) {
    if (v is bool) return v;
    if (v == null) return null;
    return switch (v.toString().trim().toLowerCase()) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => null,
    };
  }

  static DateTime? _date(Object? v) {
    DateTime? d;
    if (v is DateTime) {
      d = v;
    } else if (v != null) {
      final s = v.toString().trim();
      d = DateTime.tryParse(s.length >= 10 ? s.substring(0, 10) : s);
    }
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }
}
