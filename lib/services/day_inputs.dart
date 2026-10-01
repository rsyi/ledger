/// Pure summariser for a single day's planned INPUTS — the program's
/// prescribed session for a date. Feeds the Today tab's Day/Tomorrow
/// strip (the day-scale input surface: "what am I supposed to do today,
/// and what's coming tomorrow").
///
/// Zero Flutter/IO imports; testable in pure Dart. The UI layer
/// (DayInputsCard) resolves each date's `ProgramSlice.todayTemplate` and
/// passes it here.
library;

/// A compact, display-ready summary of one day's planned session.
class DayInputSummary {
  /// Relative label shown to the user ("Today", "Tomorrow").
  final String label;

  /// Weekday abbreviation ("Mon", "Tue", …) shown beside the label.
  final String weekday;

  /// True when the day has no planned morning or afternoon work — a rest
  /// day, or a date outside every program block.
  final bool isRest;

  /// Morning (AM) prose from the template, trimmed; null when absent.
  final String? morning;

  /// Afternoon (PM) prose from the template, trimmed; null when absent.
  final String? afternoon;

  /// Optional block note (e.g. wave week) when the template carries one.
  final String? blockNote;

  const DayInputSummary({
    required this.label,
    required this.weekday,
    required this.isRest,
    this.morning,
    this.afternoon,
    this.blockNote,
  });
}

String? _prose(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

/// Builds a [DayInputSummary] from a program slice's `todayTemplate` map.
///
/// [template] is `slice.todayTemplate`, or `null`/`{}` when the date falls
/// outside every program block — rendered as a rest day. A day counts as
/// rest exactly when both morning and afternoon prose are empty (mirrors
/// `DayPlan.isOff`).
DayInputSummary summarizeDayInputs({
  required String label,
  required String weekday,
  Map<Object?, Object?>? template,
}) {
  final t = template ?? const <Object?, Object?>{};
  final morning = _prose(t['morning']);
  final afternoon = _prose(t['afternoon']);
  return DayInputSummary(
    label: label,
    weekday: weekday,
    isRest: morning == null && afternoon == null,
    morning: morning,
    afternoon: afternoon,
    blockNote: _prose(t['block_note']),
  );
}

const _weekdayAbbr = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Three-letter weekday abbreviation for [d] (Mon-first).
String weekdayAbbr(DateTime d) => _weekdayAbbr[d.weekday - 1];
