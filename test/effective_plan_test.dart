// effective_plan.dart — the priced week after program_moves (moves +
// skips), against the LIVE program.yaml and the live travel-week rows.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/effective_plan.dart';
import 'package:airledger/services/program_current.dart' show currentVersion;
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/program_week.dart';
import 'package:airledger/services/routine_display.dart';
import 'package:airledger/services/week_planner.dart';

import 'support/travel_week_moves.dart';

const _fitnessRepo = '../airledger-fitness/coach';

Map<Object?, Object?> _yaml(String path) {
  final y = loadYaml(File(path).readAsStringSync());
  return y is Map ? Map<Object?, Object?>.from(y) : {};
}

void main() {
  final program = _yaml('$_fitnessRepo/program.yaml');
  final phase = _yaml('$_fitnessRepo/phase.yaml');
  final docs = (program: program, phase: phase, strategy: null);
  final version = currentVersion(program)!;
  const wms = {
    'squat': 320.0,
    'bench': 240.0,
    'deadlift': 330.0,
    'press': 140.0,
  };
  final mon = DateTime(2026, 10, 5);
  final all = travelWeekMoves();
  final moves = activeMoves(all, mon);
  final skips = activeSkips(all, mon);
  final prescribed = prescribedWeek(docs, mon);
  final built = buildWeekPlannedEntries(program, DateTime.utc(2026, 10, 5),
      workingMaxes: wms, snapToWeekStart: false);

  List<Map<String, Object?>> on(List<Map<String, Object?>> es, int day) =>
      [for (final e in es) if (e['date'] == DateTime.utc(2026, 10, day)) e];
  List<String> rows(List<Map<String, Object?>> es) => [
        for (final e in es)
          '${e['exercise']} ${e['weight'] ?? '-'}x${e['reps']}'
              '${e['warmup'] == true ? ' (wu)' : ''}'
              '${e['moved_from'] == null ? '' : ' <${weekdayShort(e['moved_from'] as DateTime)}'}',
      ];

  test('fixture mirrors the oracle: 11 moves + 16 skips', () {
    expect(moves.length, 11);
    expect(skips.length, 16);
  });

  test('no moves/skips → entries pass through untouched', () {
    expect(
        identical(
            effectivePlannedEntries(built, prescribed,
                warmupProtocol: version['warmup_protocol']),
            built),
        isTrue);
  });

  group('travel week (Mon Oct 5)', () {
    final eff = effectivePlannedEntries(built, prescribed,
        moves: moves,
        skips: skips,
        warmupProtocol: version['warmup_protocol']);

    test('Mon: own squat work stays; bench volume + triceps skipped; Wed '
        'bench heavy/back-offs + pull-ups and Sat OHP heavy/back-offs '
        'land with HOME-day pricing and their warm-up ramps', () {
      final r = rows(on(eff, 5));
      final wedBench = [
        for (final e in on(built, 7))
          if (e['exercise'] == 'Flat Barbell Bench Press' &&
              e['warmup'] != true)
            '${e['weight']}x${e['reps']}',
      ];
      final monBench = [
        for (final e in on(eff, 5))
          if (e['exercise'] == 'Flat Barbell Bench Press' &&
              e['warmup'] != true)
            '${e['weight']}x${e['reps']}',
      ];
      expect(monBench, wedBench, reason: 'Wed pricing, Mon volume gone');
      expect(r.where((s) => s.startsWith('Barbell Squat') && !s.contains('(wu)')),
          isNotEmpty);
      expect(r.any((s) => s.contains('Triceps')), isFalse);
      expect(r.any((s) => s.startsWith('Overhead Press') && s.endsWith('<Sat')),
          isTrue);
      expect(r.any((s) => s.startsWith('Pull Up') && s.endsWith('<Wed')),
          isTrue);
      // Bench + OHP ramps come along (one ramp per lift, before its top).
      final benchFirst = r.indexWhere((s) => s.startsWith('Flat Barbell'));
      expect(r[benchFirst], contains('(wu)'));
      final ohpFirst = r.indexWhere((s) => s.startsWith('Overhead Press'));
      expect(r[ohpFirst], contains('(wu)'));
      expect(
          r.where((s) => s.startsWith('Flat Barbell') && s.contains('(wu)'))
              .length,
          on(built, 7)
              .where((e) =>
                  e['exercise'] == 'Flat Barbell Bench Press' &&
                  e['warmup'] == true)
              .length);
    });

    test('Tue: Fri deadlift heavy/back-offs + RDL and Sat row + face pulls',
        () {
      final r = rows(on(eff, 6));
      expect(r.first, contains('Barbell Deadlift'));
      expect(r.first, contains('(wu)'));
      expect(r.any((s) => s.startsWith('Seated Cable Row') && s.endsWith('<Sat')),
          isTrue);
      expect(r.any((s) => s.contains('Face Pull') && s.endsWith('<Sat')),
          isTrue);
      expect(r.any((s) => s.contains('Romanian') && s.endsWith('<Fri')),
          isTrue);
    });

    test('Wed–Sat: nothing planned', () {
      for (final d in [7, 8, 9, 10]) {
        expect(on(eff, d), isEmpty, reason: 'Oct $d');
      }
    });

    test('Sun: the moved 4x4 has no strength rows (rest stays rest)', () {
      expect(on(eff, 11), isEmpty);
    });
  });

  group('effectiveDayInfo / effectiveDaySummary', () {
    final week = effectiveWeek(prescribed, moves);
    final eff = effectivePlannedEntries(built, prescribed,
        moves: moves,
        skips: skips,
        warmupProtocol: version['warmup_protocol']);
    final lines = sessionLinesByDay(eff);
    List<SessionLine> ls(int d) =>
        lines[DateTime.utc(2026, 10, d)] ?? const [];

    test('Mon reads the effective lifts; skips noted', () {
      final info = effectiveDayInfo(DateTime(2026, 10, 5), week, skips);
      expect(effectiveDaySummary(info, ls(5)),
          'squat heavy · bench heavy · press heavy');
      expect(info.skipped, {
        'travel Wed–Sat': ['Bench volume', 'Triceps extension'],
      });
      expect(info.movedIn.map((e) => e.item.name), [
        'Bench heavy', 'Bench back-offs', 'Pull-ups', 'OHP heavy',
        'OHP back-offs',
      ]);
    });

    test('Tue: deadlift heavy + the hard climb', () {
      final info = effectiveDayInfo(DateTime(2026, 10, 6), week, skips);
      expect(effectiveDaySummary(info, ls(6)), 'deadlift heavy · hard climb');
      expect(info.movedOut.values.single, ['Norwegian']);
    });

    test('Wed–Sat: Skipped — travel', () {
      for (final d in [7, 8, 9, 10]) {
        final info = effectiveDayInfo(DateTime(2026, 10, d), week, skips);
        expect(effectiveDaySummary(info, ls(d)), 'Skipped — travel Wed–Sat',
            reason: 'Oct $d');
      }
      final wed = effectiveDayInfo(DateTime(2026, 10, 7), week, skips);
      expect(wed.movedOut, {
        DateTime(2026, 10, 5): ['Bench heavy', 'Bench back-offs', 'Pull-ups'],
      });
    });

    test('Sun: the moved-in 4x4', () {
      final info = effectiveDayInfo(DateTime(2026, 10, 11), week, skips);
      expect(effectiveDaySummary(info, ls(11)), '4x4');
    });

    test('untouched day → null (template summary stays)', () {
      final info = effectiveDayInfo(DateTime(2026, 10, 12), week, skips);
      expect(effectiveDaySummary(info, const []), isNull);
    });
  });
}
