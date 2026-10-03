/// The program's PRESCRIBED items for a day and for a week.
///
/// One pipeline for both shapes — `programCurrent → dayPrescription →
/// parsePrescribedProse` — so the program day card (single day) and the
/// moves / missed-work layer (whole week) can never drift apart. Weeks
/// are the CONFIGURED week (week_start.dart's resolver — the caller
/// passes the resolved start day); each day's content still resolves
/// from the day itself (its routine weekday, block, wave).
///
/// Pure: no Flutter/IO imports.
library;

import 'day_prescription.dart';
import 'prescribed_exercises.dart';
import 'program_current.dart' show programCurrent;
import 'intent_docs.dart';
import 'week_start.dart';

export 'week_start.dart' show weekStartOf, weekDaysOf, weekEndOf;

/// Local-midnight calendar day of [d] (its y/m/d, whatever its zone).
DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// The prescription + parsed items for one [date], exactly as the
/// program day card renders it. Prescription is null when there is no
/// program doc (the card hides); a date outside every block is a rest
/// prescription with no items.
(DayPrescription?, List<PrescribedItem>) prescribedDay(
  IntentDocs docs,
  DateTime date, {
  String label = 'Today',
}) {
  final program = docs.program;
  if (program == null) return (null, const <PrescribedItem>[]);
  final day = dayOnly(date);
  final slice = programCurrent(program, docs.phase, day);
  final prescription = dayPrescription(
    label: label,
    weekday: weekdayAbbr(day),
    template: slice?.todayTemplate,
  );
  return (
    prescription,
    parsePrescribedProse(prescription.morning, prescription.afternoon),
  );
}

/// The prescribed items for each day of the [weekStartDay] week
/// containing [anyDay] (keys are local midnights, in order), resolved
/// exactly like ProgramDayCard does for one day — plus [extraDays]
/// outside the week (next-week home days of pulled-forward moves —
/// `pulledInHomeDays`), appended after. Days with no program
/// (pre-program, missing docs) map to an empty list.
Map<DateTime, List<PrescribedItem>> prescribedWeek(
  IntentDocs docs,
  DateTime anyDay, {
  String label = 'Today',
  int weekStartDay = DateTime.monday,
  Iterable<DateTime> extraDays = const [],
}) {
  final days = weekDaysOf(anyDay, weekStartDay);
  final extra = [
    for (final d in extraDays.map(dayOnly).toSet())
      if (!days.contains(d)) d,
  ]..sort();
  return {
    for (final d in [...days, ...extra])
      d: prescribedDay(docs, d, label: label).$2,
  };
}
