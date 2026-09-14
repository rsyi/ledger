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
