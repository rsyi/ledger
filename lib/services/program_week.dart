/// The program's PRESCRIBED items for a day and for a Mon–Sun week.
///
/// One pipeline for both shapes — `programCurrent → dayPrescription →
/// parsePrescribedProse` — so the program day card (single day) and the
/// moves / missed-work layer (whole week) can never drift apart. Weeks
/// here are the Mon–Sun schedule/review week, NOT the Saturday
/// accounting week.
///
/// Pure: no Flutter/IO imports.
library;

import 'day_prescription.dart';
import 'prescribed_exercises.dart';
import 'program_current.dart' show programCurrent;
import 'program_provider.dart' show IntentDocs;

/// Local-midnight calendar day of [d] (its y/m/d, whatever its zone).
DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Monday of [d]'s Mon–Sun week (local midnight).
DateTime mondayOf(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - 1));

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

/// The prescribed items for each day Mon..Sun of the week containing
/// [anyDay] (keys are local midnights, in order), resolved exactly like
/// ProgramDayCard does for one day. Days with no program (pre-program,
/// missing docs) map to an empty list.
Map<DateTime, List<PrescribedItem>> prescribedWeek(
  IntentDocs docs,
  DateTime anyDay, {
  String label = 'Today',
}) {
  final mon = mondayOf(anyDay);
  return {
    for (var i = 0; i < 7; i++)
      DateTime(mon.year, mon.month, mon.day + i): prescribedDay(
        docs,
        DateTime(mon.year, mon.month, mon.day + i),
        label: label,
      ).$2,
  };
}
