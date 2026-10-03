import 'dart:convert';

import 'package:intl/intl.dart';

/// A schedule proposal the coach made in chat. Serialized into the
/// `text` of a `role=coach, kind=proposal` coach_chat row — no schema
/// change, so no engine work. `tryParse` returning null is the
/// malformed-payload fallback: the row renders as a plain bubble.
class CoachProposal {
  static const version = 1;

  /// Target view name (e.g. `strength`).
  final String view;

  /// Date-only target day for the planned entries.
  final DateTime date;

  /// Template attribution for timeline grouping. Null for ad-hoc plans.
  final String? template;

  /// One-line human summary shown on the card header.
  final String summary;

  /// Field→value maps, one per planned entry. Values are plain JSON
  /// types (num/String/bool) matching the view's dimensions.
  final List<Map<String, Object?>> entries;

  CoachProposal({
    required this.view,
    required this.date,
    this.template,
    required this.summary,
    required this.entries,
  });

  String encode() => jsonEncode({
        'v': version,
        'view': view,
        'date': DateFormat('yyyy-MM-dd').format(date),
        if (template != null) 'template': template,
        'summary': summary,
        'entries': entries,
      });

  /// Null unless [text] is a valid v1 proposal payload.
  static CoachProposal? tryParse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['v'] != version) return null;
    // Typed payloads (e.g. `type: moves`) are not legacy row proposals.
    if (decoded['type'] != null) return null;
    final view = decoded['view'];
    final rawDate = decoded['date'];
    final rawEntries = decoded['entries'];
    if (view is! String || view.isEmpty) return null;
    if (rawDate is! String) return null;
    final date = DateTime.tryParse(rawDate);
    if (date == null) return null;
    if (rawEntries is! List || rawEntries.isEmpty) return null;
    final entries = <Map<String, Object?>>[];
    for (final e in rawEntries) {
      if (e is! Map) return null;
      entries.add(e.map((k, v) => MapEntry(k.toString(), v)));
    }
    return CoachProposal(
      view: view,
      date: DateTime(date.year, date.month, date.day),
      template: decoded['template'] as String?,
      summary: decoded['summary']?.toString() ?? '',
      entries: entries,
    );
  }
}

/// One proposed relocation of a prescribed program item within its
/// configured week (or pulled forward ≤7 days from next week). Accepting
/// it writes a `program_moves` row.
class ProposedMove {
  final String item; // display name, e.g. "Bench heavy"
  final DateTime from; // date-only — the day the program prescribed it
  final DateTime to; // date-only — the day it moves to
  final String period; // 'AM' | 'PM' | ''
  final String note;

  ProposedMove({
    required this.item,
    required DateTime from,
    required DateTime to,
    this.period = '',
    this.note = '',
  })  : from = DateTime(from.year, from.month, from.day),
        to = DateTime(to.year, to.month, to.day);

  Map<String, Object?> toJson() => {
        'item': item,
        'from_date': DateFormat('yyyy-MM-dd').format(from),
        'to_date': DateFormat('yyyy-MM-dd').format(to),
        'period': period,
        'note': note,
      };

  /// Null when item is blank, a date is missing/unparseable, or
  /// to == from (a no-op move).
  static ProposedMove? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final item = raw['item']?.toString().trim() ?? '';
    final from = DateTime.tryParse(raw['from_date']?.toString() ?? '');
    final to = DateTime.tryParse(raw['to_date']?.toString() ?? '');
    if (item.isEmpty || from == null || to == null) return null;
    final m = ProposedMove(
      item: item,
      from: from,
      to: to,
      period: raw['period']?.toString().trim() ?? '',
      note: raw['note']?.toString().trim() ?? '',
    );
    return m.from == m.to ? null : m;
  }
}

/// A coach proposal to move program items between days (missed-work
/// carryover). Serialized into the `text` of a `role=coach,
/// kind=proposal` coach_chat row, discriminated from the legacy
/// [CoachProposal] by `"type": "moves"`:
///
/// `{"v":1,"type":"moves","summary":"…","moves":[{"item":"Bench heavy",
/// "from_date":"2026-09-30","to_date":"2026-10-02","period":"PM",
/// "note":"…"}]}`
class MovesProposal {
  static const type = 'moves';
  static const version = 1;

  final String summary;
  final List<ProposedMove> moves;

  MovesProposal({required this.summary, required this.moves});

  String encode() => jsonEncode({
        'v': version,
        'type': type,
        'summary': summary,
        'moves': [for (final m in moves) m.toJson()],
      });

  /// Null unless [text] is a `type: moves` payload with at least one
  /// valid move. Invalid moves are dropped (LLM-authored payloads); a
  /// missing `v` is accepted, any other version is rejected.
  static MovesProposal? tryParse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['type'] != type) return null;
    final v = decoded['v'];
    if (v != null && v != version) return null;
    final raw = decoded['moves'];
    if (raw is! List) return null;
    final moves = [
      for (final m in raw) ?ProposedMove.fromJson(m),
    ];
    if (moves.isEmpty) return null;
    return MovesProposal(
      summary: decoded['summary']?.toString() ?? '',
      moves: moves,
    );
  }
}
