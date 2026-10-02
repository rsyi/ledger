/// Program item relocations within a Mon–Sun week — the pure resolver
/// over the synced `program_moves` view (one row per move; manual from
/// the program day card or an accepted coach proposal).
///
/// A move relocates ONE prescribed item instance, keyed by
/// `from_date + item` (case-insensitive), to `date`. The latest row per
/// key wins; deleting the row (Undo) puts the item back. Moves whose
/// from or to day falls outside the week are ignored.
///
/// Pure: no Flutter/IO imports.
library;

import 'prescribed_exercises.dart';
import 'program_week.dart' show dayOnly, mondayOf;

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _norm(String s) => s.toLowerCase().trim();

String _str(Object? v) {
  if (v == null) return '';
  final s = v.toString().trim();
  return s == 'null' ? '' : s;
}

DateTime? _dateTime(Object? v) {
  if (v is DateTime) return v;
  final s = _str(v);
  return s.isEmpty ? null : DateTime.tryParse(s);
}

DateTime? _day(Object? v) {
  final d = _dateTime(v);
  return d == null ? null : dayOnly(d);
}

/// One `program_moves` row.
class ProgramMove {
  final String id;
  final DateTime to; // local midnight — the day the item now lives on
  final DateTime from; // local midnight — the day the program prescribed it
  final String item; // display name
  final String period; // 'AM' | 'PM' | ''
  final String source; // 'manual' | 'coach'
  final DateTime? createdAt;
  final String note;

  const ProgramMove({
    required this.id,
    required this.to,
    required this.from,
    required this.item,
    this.period = '',
    this.source = '',
    this.createdAt,
    this.note = '',
  });

  /// `yyyy-mm-dd(from)|item lowercased+trimmed`.
  String get key => '${_ymd(from)}|${_norm(item)}';

  /// Tolerant parse of a ledger/Sheets record (dates as DateTime or
  /// strings — "2026-10-02", "2026-10-02 08:00:00", ISO). Null when id,
  /// date, from_date or item is missing/unparseable.
  static ProgramMove? fromRecord(Map<String, Object?> r) {
    final id = _str(r['id']);
    final item = _str(r['item']);
    final to = _day(r['date']);
    final from = _day(r['from_date']);
    if (id.isEmpty || item.isEmpty || to == null || from == null) return null;
    return ProgramMove(
      id: id,
      to: to,
      from: from,
      item: item,
      period: _str(r['period']),
      source: _str(r['source']),
      createdAt: _dateTime(r['created_at']),
      note: _str(r['note']),
    );
  }

  /// Record for `repo.create` — date dims as midnight DateTimes (the
  /// engine codec stores them as plain dates), like the form writes them.
  Map<String, Object?> toRecord() => <String, Object?>{
        'id': id,
        'date': to,
        'from_date': from,
        'item': item,
        'period': period,
        'source': source,
        'created_at': createdAt,
        'note': note,
      };
}

/// Latest move per key (by createdAt, then list order — a row without a
/// createdAt sorts as oldest), restricted to moves whose from AND to fall
/// in [monday]'s week. A latest row with to == from is "back home": it
/// yields no active move for that key.
Map<String, ProgramMove> activeMoves(
    Iterable<ProgramMove> all, DateTime monday) {
  final mon = mondayOf(monday);
  final inWeek = [
    for (final m in all)
      if (mondayOf(m.from) == mon && mondayOf(m.to) == mon) m,
  ];
  // Stable order: createdAt ascending (null first), ties keep list order.
  final indexed = [for (var i = 0; i < inWeek.length; i++) (i, inWeek[i])];
  indexed.sort((a, b) {
    final ca = a.$2.createdAt, cb = b.$2.createdAt;
    if (ca != null && cb != null) {
      final c = ca.compareTo(cb);
      if (c != 0) return c;
    } else if (ca == null && cb != null) {
      return -1;
    } else if (ca != null && cb == null) {
      return 1;
    }
    return a.$1.compareTo(b.$1);
  });
  final latest = <String, ProgramMove>{};
  for (final (_, m) in indexed) {
    latest[m.key] = m;
  }
  latest.removeWhere((_, m) => m.to == m.from);
  return latest;
}

/// A prescribed item placed in the effective (post-moves) week.
class EffectiveItem {
  final PrescribedItem item;

  /// The day the program prescribed it.
  final DateTime home;

  /// Non-null on the ORIGIN day's ghost entry (the item now lives there).
  final DateTime? movedTo;

  /// Non-null on the TARGET day's entry (the item came from there).
  final DateTime? movedFrom;

  final ProgramMove? move;

  const EffectiveItem({
    required this.item,
    required this.home,
    this.movedTo,
    this.movedFrom,
    this.move,
  });

  bool get isGhost => movedTo != null;
}

/// The week after moves: each day = its own items (moved-out ones become
/// ghosts, in place) + moved-in items appended (tagged movedFrom), in
/// origin-day then item order. A move matches the FIRST same-named item
/// on its from day (case-insensitive, trimmed); a move naming no item on
/// that day is ignored. A target day absent from [prescribed] is added.
Map<DateTime, List<EffectiveItem>> effectiveWeek(
  Map<DateTime, List<PrescribedItem>> prescribed,
  Map<String, ProgramMove> moves,
) {
  final byKey = <String, ProgramMove>{
    for (final m in moves.values) m.key: m,
  };
  final days = prescribed.keys.map(dayOnly).toList()..sort();
  final out = <DateTime, List<EffectiveItem>>{
    for (final d in days) d: <EffectiveItem>[],
  };
  final incoming = <(DateTime, EffectiveItem)>[];
  for (final day in days) {
    final items = prescribed.entries
        .firstWhere((e) => dayOnly(e.key) == day)
        .value;
    final used = <String>{};
    for (final it in items) {
      final key = '${_ymd(day)}|${_norm(it.name)}';
      final m = used.contains(key) ? null : byKey[key];
      if (m == null) {
        out[day]!.add(EffectiveItem(item: it, home: day));
        continue;
      }
      used.add(key);
      out[day]!
          .add(EffectiveItem(item: it, home: day, movedTo: m.to, move: m));
      incoming.add((
        m.to,
        EffectiveItem(item: it, home: day, movedFrom: day, move: m),
      ));
    }
  }
  for (final (to, e) in incoming) {
    out.putIfAbsent(to, () => <EffectiveItem>[]).add(e);
  }
  return out;
}
