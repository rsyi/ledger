/// Program item relocations within a week — the pure resolver
/// over the synced `program_moves` view (one row per move; manual from
/// the program day card or an accepted coach proposal).
///
/// SKIPS (2026-10-02): the same view also carries `source: skip` rows —
/// an item intentionally skipped on a day (date == from_date == that
/// day, note = the user's reason). They are NOT moves: [activeMoves]
/// ignores them entirely (a skip never cancels or creates a move);
/// [activeSkips] resolves them; Undo skip deletes the row(s).
///
/// A move relocates ONE prescribed item instance, keyed by
/// `from_date + item` (case-insensitive), to `date`. The latest row per
/// key wins; deleting the row (Undo) puts the item back.
///
/// WEEKS (2026-10-03): every week here is the CONFIGURED week
/// ([weekStartDay], week_start.dart's resolver — Saturday for the user),
/// never a hard-coded Mon–Sun. A move is VALID ([isAllowedMove]) when
///   * from and to fall in the same week (later or earlier), or
///   * it PULLS work forward: to is earlier than from by at most
///     [pullForwardMaxDays] days, even across the week boundary (an item
///     of next week done in this one).
/// A later move must stay in from's week, so missed work still expires
/// at week end. Invalid rows are ignored (never an error).
///
/// Pure: no Flutter/IO imports.
library;

import 'prescribed_exercises.dart';
import 'program_week.dart' show dayOnly;
import 'week_start.dart';

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _norm(String s) => s.toLowerCase().trim();

String _str(Object? v) {
  if (v == null) return '';
  final s = v.toString().trim();
  return s == 'null' ? '' : s;
}

/// Tolerant datetime parse. Live Sheets renders datetimes with a
/// one-digit hour ("2026-10-01 9:00:00", "2026-10-01 9:05"), which
/// DateTime.tryParse rejects — zero-pad the hour first.
DateTime? _dateTime(Object? v) {
  if (v is DateTime) return v;
  final s = _str(v).replaceFirstMapped(
    RegExp(r'^(\d{4}-\d{2}-\d{2})[ T](\d):'),
    (m) => '${m[1]} 0${m[2]}:',
  );
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
  final String source; // 'manual' | 'coach' | 'skip'
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

  /// An intentional skip (not a move) — see the library doc.
  bool get isSkip => source.trim().toLowerCase() == skipSource;

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

/// `program_moves.source` of a skip row.
const skipSource = 'skip';

/// Key of a skip: `yyyy-mm-dd(day)|item lowercased+trimmed` — the day the
/// item was skipped on (its effective day, after moves).
String skipKey(DateTime day, String item) => '${_ymd(dayOnly(day))}|${_norm(item)}';

/// Skips in [anyDay]'s week ([weekStartDay]), keyed by [skipKey] (latest
/// row per key wins — by createdAt, then list order).
Map<String, ProgramMove> activeSkips(
  Iterable<ProgramMove> all,
  DateTime anyDay, {
  int weekStartDay = DateTime.monday,
}) {
  final start = weekStartOf(anyDay, weekStartDay);
  final out = <String, ProgramMove>{};
  for (final m in _byCreated([
    for (final m in all)
      if (m.isSkip && weekStartOf(m.to, weekStartDay) == start) m,
  ])) {
    out[skipKey(m.to, m.item)] = m;
  }
  return out;
}

/// Every skip row for [item] on [day] — Undo skip deletes them all (a
/// stale duplicate would otherwise keep the item skipped).
List<ProgramMove> skipRowsFor(
        Iterable<ProgramMove> all, DateTime day, String item) =>
    [
      for (final m in all)
        if (m.isSkip && skipKey(m.to, m.item) == skipKey(day, item)) m,
    ];

/// `- Bench heavy — Wed 9/30: shoulder tweak` per skip (day order), or
/// `none` — the "SKIPPED THIS WEEK:" body shared by CoachBrain and
/// tool/missed_work.dart.
String skippedLines(Map<String, ProgramMove> skips) {
  if (skips.isEmpty) return 'none';
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final ss = skips.values.toList()..sort((a, c) => a.to.compareTo(c.to));
  return [
    for (final s in ss)
      '- ${s.item} — ${wd[s.to.weekday - 1]} ${s.to.month}/${s.to.day}: '
          '${s.note.isEmpty ? '(no reason given)' : s.note}',
  ].join('\n');
}

/// Stable order: createdAt ascending (null first), ties keep list order.
List<ProgramMove> _byCreated(List<ProgramMove> ms) {
  final indexed = [for (var i = 0; i < ms.length; i++) (i, ms[i])];
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
  return [for (final (_, m) in indexed) m];
}

/// How far a move may pull work EARLIER across the week boundary.
const pullForwardMaxDays = 7;

/// Whether a move [from] → [to] is allowed under [weekStartDay] weeks (see
/// the library doc): same week, or pulled forward by ≤
/// [pullForwardMaxDays] days. to == from ("back home") is allowed.
bool isAllowedMove(DateTime from, DateTime to,
    {int weekStartDay = DateTime.monday}) {
  final f = dayOnly(from), t = dayOnly(to);
  if (sameWeek(f, t, weekStartDay)) return true;
  if (!t.isBefore(f)) return false; // later across the boundary
  return DateTime.utc(f.year, f.month, f.day)
          .difference(DateTime.utc(t.year, t.month, t.day))
          .inDays <=
      pullForwardMaxDays;
}

/// Latest VALID move per key (by createdAt, then list order — a row
/// without a createdAt sorts as oldest; rows failing [isAllowedMove] are
/// dropped first, so they never supersede a valid one), restricted to
/// moves touching [anyDay]'s week: from OR to inside it. That includes
/// next week's items pulled INTO this week (to inside, from after) and
/// this week's items pulled into the previous one (from inside, to
/// before) — [effectiveWeek] renders the former on its target day and
/// the latter as a ghost on its home day. A latest row with to == from is
/// "back home": it yields no active move for that key. Skip rows
/// ([ProgramMove.isSkip]) are not moves and are ignored here.
Map<String, ProgramMove> activeMoves(
  Iterable<ProgramMove> all,
  DateTime anyDay, {
  int weekStartDay = DateTime.monday,
}) {
  final start = weekStartOf(anyDay, weekStartDay);
  final latest = <String, ProgramMove>{};
  for (final m in _byCreated([
    for (final m in all)
      if (!m.isSkip && isAllowedMove(m.from, m.to, weekStartDay: weekStartDay))
        m,
  ])) {
    latest[m.key] = m;
  }
  latest.removeWhere((_, m) =>
      m.to == m.from ||
      (weekStartOf(m.from, weekStartDay) != start &&
          weekStartOf(m.to, weekStartDay) != start));
  return latest;
}

/// Home days OUTSIDE [anyDay]'s week that [moves] pull work from — the
/// extra days a caller must prescribe (and price) so pulled-forward
/// items can be placed ([prescribedWeek]'s `extraDays`).
Set<DateTime> pulledInHomeDays(
  Map<String, ProgramMove> moves,
  DateTime anyDay, {
  int weekStartDay = DateTime.monday,
}) {
  final start = weekStartOf(anyDay, weekStartDay);
  return {
    for (final m in moves.values)
      if (weekStartOf(m.from, weekStartDay) != start) dayOnly(m.from),
  };
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
///
/// [weekStart] (the week's first day): when given, the result keeps ONLY
/// that week's seven days, in order — [prescribed] may also carry
/// next-week home days of pulled-forward items ([pulledInHomeDays]);
/// their ghosts and any previous-week targets fall outside and drop.
Map<DateTime, List<EffectiveItem>> effectiveWeek(
  Map<DateTime, List<PrescribedItem>> prescribed,
  Map<String, ProgramMove> moves, {
  DateTime? weekStart,
}) {
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
  if (weekStart != null) {
    final s = dayOnly(weekStart);
    final end = DateTime(s.year, s.month, s.day + 6);
    out.removeWhere((d, _) => d.isBefore(s) || d.isAfter(end));
    // Every week day present (an empty pulled-in-only week stays 7 days).
    for (var i = 0; i < 7; i++) {
      out.putIfAbsent(
          DateTime(s.year, s.month, s.day + i), () => <EffectiveItem>[]);
    }
    return Map.fromEntries(
        out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }
  return out;
}
