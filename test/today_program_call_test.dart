// Tests for todayProgramCallByView (lib/services/today_program_call.dart)
// against the live airledger-fitness program.yaml — the per-Log-domain
// "today:" badge text for each weekday of the current cut week.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/today_program_call.dart';

const _fitnessRepo = '../airledger-fitness/coach';

Map<Object?, Object?> _loadYamlMap(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
        'Missing $path — is the airledger-fitness checkout present?');
  }
  final y = loadYaml(file.readAsStringSync());
  return y is Map ? Map<Object?, Object?>.from(y) : {};
}

void main() {
  final program = _loadYamlMap('$_fitnessRepo/program.yaml');

  // Cut-wave anchor week: Monday 2026-09-28 is wave week 1.
  final mon = DateTime.utc(2026, 9, 28);
  DateTime day(int offset) => mon.add(Duration(days: offset));

  Map<String, String> call(DateTime d) => todayProgramCallByView(program, null, d);

  group('cut week per-domain today badges', () {
    test('Monday — squat heavy + bench volume, no cardio/climb', () {
      final c = call(day(0));
      expect(c['strength'], isNotNull);
      expect(c['strength'], contains('squat heavy'));
      expect(c['strength'], contains('bench volume'));
      expect(c['strength'], contains('+'));
      expect(c.containsKey('cardio'), isFalse);
      expect(c.containsKey('climbing'), isFalse);
    });

    test('Tuesday — 4x4 + hard climb, NO strength', () {
      final c = call(day(1));
      expect(c.containsKey('strength'), isFalse);
      expect(c['cardio'], '4x4');
      expect(c['climbing'], 'hard session');
    });

    test('Wednesday — bench heavy + squat/press volume, no cardio/climb', () {
      final c = call(day(2));
      expect(c['strength'], contains('bench heavy'));
      expect(c['strength'], contains('squat volume'));
      expect(c.containsKey('cardio'), isFalse);
      expect(c.containsKey('climbing'), isFalse);
    });

    test('Thursday — calisthenics skill + accessories', () {
      final c = call(day(3));
      expect(c['calisthenics'], 'skill work');
      // Dips/curls/HLR are strength-view accessories.
      expect(c['strength'], 'accessories');
      expect(c.containsKey('cardio'), isFalse);
    });

    test('Friday — deadlift heavy + light climb', () {
      final c = call(day(4));
      expect(c['strength'], contains('deadlift heavy'));
      expect(c['climbing'], 'light session');
      expect(c.containsKey('cardio'), isFalse);
    });

    test('Saturday — press heavy, no cardio/climb', () {
      final c = call(day(5));
      expect(c['strength'], contains('press heavy'));
      expect(c.containsKey('cardio'), isFalse);
      expect(c.containsKey('climbing'), isFalse);
    });

    test('Sunday — rest, empty map', () {
      final c = call(day(6));
      expect(c, isEmpty);
    });
  });

  group('edge cases', () {
    test('pre-program day returns empty', () {
      // Well before any block start.
      final c = call(DateTime.utc(2020, 1, 1));
      expect(c, isEmpty);
    });
  });
}
