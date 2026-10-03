/// Shared validation for proposed program moves — the in-app
/// `propose_moves` tool (coach_tools.dart) and the nightly ```moves block
/// (tool/coach_msg.dart --split-moves) run the SAME rules, so a proposal
/// card can never say "Scheduled" for a move the resolver then ignores:
///
/// * to inside [today]'s week (the CONFIGURED week — [weekStartDay],
///   week_start.dart), not before today, to != from;
/// * from inside the same week — or, PULLING FORWARD (2026-10-03), in a
///   later week with to at most `pullForwardMaxDays` (7) days earlier
///   ([isAllowedMove]). Pushing work later never crosses the week end,
///   so missed work still expires then;
/// * the item exists on from_date in the program: prescribed there
///   (case-insensitive exact name), or currently LIVING there after an
///   earlier move — then the move is re-keyed to the item's home day,
///   since `program_moves` keys on `from_date + item` (the program's
///   original day).
///
/// Pure: no Flutter/IO imports.
library;

import '../models/coach_proposal.dart';
import 'program_moves.dart' show EffectiveItem, isAllowedMove, pullForwardMaxDays;
import 'program_week.dart' show dayOnly;
import 'week_start.dart';

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _norm(String s) => s.toLowerCase().trim();

/// Validates [m] against [today]'s week and, when [week] (the effective
/// week of [today] — plus NEXT week's days, so a pulled-forward item's
/// from day can be checked) is non-null, against the program's items.
/// Returns the normalized move (canonical item name, home-day from).
/// Throws a [StateError] prefixed with [label] — model-visible, so it can
/// retry. A null [week] (program unavailable) skips the item check.
ProposedMove checkProposedMove(
  ProposedMove m, {
  required DateTime today,
  Map<DateTime, List<EffectiveItem>>? week,
  String label = 'move',
  int weekStartDay = DateTime.monday,
}) {
  final t = dayOnly(today);
  final mon = weekStartOf(t, weekStartDay); // the week's first day
  final sun = weekEndOf(t, weekStartDay); // ...and its last
  bool inWeek(DateTime d) => !d.isBefore(mon) && !d.isAfter(sun);
  final range = '${_ymd(mon)}..${_ymd(sun)}';
  final from = dayOnly(m.from);
  final to = dayOnly(m.to);
  if (m.item.trim().isEmpty) throw StateError('$label.item is required');
  if (!inWeek(to)) {
    throw StateError('$label.to_date ${_ymd(to)} is outside this '
        'week ($range) — moves land within the week');
  }
  final pulled = from.isAfter(sun);
  if (!inWeek(from) &&
      !(pulled && isAllowedMove(from, to, weekStartDay: weekStartDay))) {
    throw StateError(pulled
        ? '$label.from_date ${_ymd(from)} is too far ahead — work can be '
            'pulled forward from next week at most $pullForwardMaxDays '
            'days earlier'
        : '$label.from_date ${_ymd(from)} is outside this week ($range)');
  }
  if (to.isBefore(t)) {
    throw StateError('$label.to_date ${_ymd(to)} is in the past — '
        'pick a remaining day (${_ymd(t)}..${_ymd(sun)})');
  }
  if (to == from) {
    throw StateError('$label.to_date equals from_date (${_ymd(to)})');
  }
  if (week == null) return m;

  final want = _norm(m.item);
  final entries = week[from] ?? const <EffectiveItem>[];
  // 1. Prescribed on from (its home) — ghosts included: re-moving an
  //    already-moved item keys on its home day.
  for (final e in entries) {
    if (dayOnly(e.home) == from && _norm(e.item.name) == want) {
      return ProposedMove(
        item: e.item.name,
        from: from,
        to: to,
        period: m.period.isEmpty ? e.item.period : m.period,
        note: m.note,
      );
    }
  }
  // 2. Living on from after an earlier move → re-key to its home day.
  for (final e in entries) {
    if (e.isGhost || e.movedFrom == null) continue;
    if (_norm(e.item.name) != want) continue;
    final home = dayOnly(e.home);
    if (home == to) {
      throw StateError('$label: "${e.item.name}" was moved to '
          '${_wd[from.weekday - 1]} from its program day ${_ymd(home)}; '
          'moving it back home is not a proposal — leave it out or pick '
          'another day');
    }
    if (!isAllowedMove(home, to, weekStartDay: weekStartDay)) {
      throw StateError('$label: "${e.item.name}" (program day '
          '${_ymd(home)}) can\'t go to ${_ymd(to)} — later moves stay '
          'within its week; earlier ones at most $pullForwardMaxDays days');
    }
    return ProposedMove(
      item: e.item.name,
      from: home,
      to: to,
      period: m.period.isEmpty ? e.item.period : m.period,
      note: m.note,
    );
  }
  final valid = <String>[];
  for (final e in entries) {
    final live = !e.isGhost || dayOnly(e.home) == from;
    if (live && !valid.contains(e.item.name)) valid.add(e.item.name);
  }
  final day = '${_wd[from.weekday - 1]} ${_ymd(from)}';
  throw StateError(valid.isEmpty
      ? '$label.item "${m.item}": nothing is prescribed on $day — '
          'from_date must be the day the item is on'
      : '$label.item "${m.item}" is not on $day. Valid items for that '
          'day (copy exactly): ${valid.map((n) => '"$n"').join(', ')}');
}

/// Keeps the moves of [p] that pass [checkProposedMove] (normalized);
/// each dropped one yields a warning. Proposal null when none survive.
({MovesProposal? proposal, List<String> warnings}) filterValidMoves(
  MovesProposal p, {
  required DateTime today,
  Map<DateTime, List<EffectiveItem>>? week,
  int weekStartDay = DateTime.monday,
}) {
  final kept = <ProposedMove>[];
  final warnings = <String>[];
  for (var i = 0; i < p.moves.length; i++) {
    try {
      kept.add(checkProposedMove(p.moves[i],
          today: today,
          week: week,
          label: 'moves[$i]',
          weekStartDay: weekStartDay));
    } on StateError catch (e) {
      warnings.add(e.message);
    }
  }
  return (
    proposal:
        kept.isEmpty ? null : MovesProposal(summary: p.summary, moves: kept),
    warnings: warnings,
  );
}
