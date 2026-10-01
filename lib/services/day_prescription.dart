/// Pure summariser for a day's PRESCRIBED session — the program routine's
/// morning/afternoon prose for a date. Feeds the Today tab's Tomorrow card
/// and the Log tab's program reference. The prose is the complete picture
/// (it names front-lever work, hanging leg raises, muscle-ups, etc. that
/// the structured planner omits), so surfacing it verbatim keeps the
/// program tightly coupled to what the user sees.
///
/// Zero Flutter/IO imports; testable in pure Dart.
library;

/// A display-ready prescription for one day.
class DayPrescription {
  final String label; // "Today" / "Tomorrow"
  final String weekday; // "Mon", …
  final bool isRest;
  final String? morning; // AM prose
  final String? afternoon; // PM prose
  final String? blockNote;

  const DayPrescription({
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
  return (s.isEmpty || s == 'null') ? null : s;
}

/// Builds a [DayPrescription] from a program slice's `todayTemplate` map.
/// [template] is `slice.todayTemplate`, or null/`{}` when the date is
/// outside every program block — rendered as rest.
DayPrescription dayPrescription({
  required String label,
  required String weekday,
  Map<Object?, Object?>? template,
}) {
  final t = template ?? const <Object?, Object?>{};
  final morning = _prose(t['morning']);
  final afternoon = _prose(t['afternoon']);
  return DayPrescription(
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
