// program_week.dart — the Mon–Sun prescription builder shared by the
// program day card (single day) and the missed-work / moves layer (week).
// Pinned against the LIVE airledger-fitness program.yaml, loaded the same
// way cut_week_structure_test.dart does.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/day_prescription.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_provider.dart' show IntentDocs;
import 'package:airledger/services/program_week.dart';
import 'package:airledger/services/whoop_activity.dart';

const _fitnessRepo = '../airledger-fitness/coach';

Map<Object?, Object?>? _yaml(String name) {
  final f = File('$_fitnessRepo/$name');
  if (!f.existsSync()) return null;
  final y = loadYaml(f.readAsStringSync());
  return y is Map ? Map<Object?, Object?>.from(y) : null;
}

void main() {
  group('mondayOf', () {
    test('maps every day of a Mon–Sun week to its local-midnight Monday',
        () {
      final mon = DateTime(2026, 9, 28);
      for (var i = 0; i < 7; i++) {
        expect(mondayOf(DateTime(2026, 9, 28 + i, 17, 45)), mon);
      }
      expect(mondayOf(DateTime(2026, 10, 5)), DateTime(2026, 10, 5));
      expect(mondayOf(DateTime(2026, 10, 4, 23, 59)), mon);
    });

    test('UTC input keeps its calendar date', () {
      expect(mondayOf(DateTime.utc(2026, 10, 2)), DateTime(2026, 9, 28));
    });
  });

  group('no program', () {
    const IntentDocs empty = (program: null, phase: null, strategy: null);

    test('prescribedDay → null prescription, no items', () {
      final (p, items) = prescribedDay(empty, DateTime(2026, 9, 30));
      expect(p, isNull);
      expect(items, isEmpty);
    });

    test('prescribedWeek → seven empty days keyed Mon..Sun', () {
      final w = prescribedWeek(empty, DateTime(2026, 10, 1));
      expect(w.keys.toList(),
          [for (var i = 0; i < 7; i++) DateTime(2026, 9, 28 + i)]);
      expect(w.values.every((l) => l.isEmpty), isTrue);
    });

    test('pre-program date (outside every block) → rest, no items', () {
      final program = _yaml('program.yaml');
      if (program == null) return; // fitness checkout absent
      final docs = (program: program, phase: null, strategy: null);
      final (p, items) = prescribedDay(docs, DateTime(2000, 1, 3));
      expect(p, isNotNull);
      expect(p!.isRest, isTrue);
      expect(items, isEmpty);
    });
  });

  group('live program.yaml — cut week of Mon 2026-09-28', () {
    final program = _yaml('program.yaml');
    final phase = _yaml('phase.yaml');
    final IntentDocs docs = (program: program, phase: phase, strategy: null);
    final mon = DateTime(2026, 9, 28);
    DateTime day(int i) => DateTime(2026, 9, 28 + i);

    test('week keys are the seven local-midnight days Mon..Sun', () {
      if (program == null) return;
      final w = prescribedWeek(docs, DateTime(2026, 10, 2, 9));
      expect(w.keys.toList(), [for (var i = 0; i < 7; i++) day(i)]);
      expect(w.keys.first, mon);
    });

    test('each day equals the single-day helper (card ≡ week, no drift)',
        () {
      if (program == null) return;
      final w = prescribedWeek(docs, mon);
      for (var i = 0; i < 7; i++) {
        final (_, items) = prescribedDay(docs, day(i));
        expect([for (final e in w[day(i)]!) '${e.period}|${e.name}|${e.scheme}'],
            [for (final e in items) '${e.period}|${e.name}|${e.scheme}'],
            reason: 'day $i');
      }
    });

    test('single-day helper matches the card pipeline verbatim', () {
      if (program == null) return;
      final d = day(2); // Wednesday
      final slice = programCurrent(program, phase, d);
      final expected = dayPrescription(
          label: 'Today', weekday: weekdayAbbr(d), template: slice?.todayTemplate);
      final (p, items) = prescribedDay(docs, d, label: 'Today');
      expect(p!.label, 'Today');
      expect(p.weekday, 'Wed');
      expect(p.morning, expected.morning);
      expect(p.afternoon, expected.afternoon);
      expect([for (final e in items) e.name], [
        for (final e
            in parsePrescribedProse(expected.morning, expected.afternoon))
          e.name
      ]);
      expect(items, isNotEmpty);
    });

    test('Friday carries a climb item', () {
      if (program == null) return;
      final w = prescribedWeek(docs, mon);
      expect(w[day(4)]!.any(isClimbItem), isTrue);
    });

    test('Sunday has no items (the optional run never parses)', () {
      if (program == null) return;
      final w = prescribedWeek(docs, mon);
      expect(w[day(6)], isEmpty);
    });

    test('Tuesday has no lifting items (4x4 + climb only)', () {
      if (program == null) return;
      final w = prescribedWeek(docs, mon);
      final tue = w[day(1)]!;
      expect(tue, isNotEmpty);
      const lifts = [
        'squat', 'bench', 'deadlift', 'press', 'row', 'curl', 'dip',
        'pull', 'raise', 'rdl', 'romanian', 'bulgarian', 'lateral',
      ];
      for (final it in tue) {
        final low = it.name.toLowerCase();
        expect(lifts.any(low.contains), isFalse,
            reason: 'Tuesday lifting item leaked: ${it.name} ${it.scheme}');
      }
      // The PM hard climb parses ("partner day" sits inside its parens,
      // where skip words don't apply).
      expect(tue.where(isClimbItem), hasLength(1));
    });
  });
}
