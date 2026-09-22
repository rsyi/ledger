// Tests for the program.current resolver against the SHARED fixtures in
// airledger-fitness (sibling checkout). The TS twin in ledger-mcp runs
// the same cases; drift between resolvers = a failure on either side.
// The lib under test stays pure — only the test does IO.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/program_current.dart';

const _fitnessRepo = '../airledger-fitness/coach';

dynamic _loadYamlFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
        'Missing $path — is the airledger-fitness checkout present?');
  }
  return loadYaml(file.readAsStringSync());
}

bool _deepEq(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEq(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a.toDouble() == b.toDouble();
  return a == b;
}

void main() {
  final program =
      _loadYamlFile('$_fitnessRepo/program.yaml') as Map<Object?, Object?>;
  final phase =
      _loadYamlFile('$_fitnessRepo/phase.yaml') as Map<Object?, Object?>;
  final fixtures =
      _loadYamlFile('$_fitnessRepo/fixtures/program_current_cases.yaml') as Map;
  final cases = fixtures['cases'] as List;

  test('fixtures file has at least 10 cases', () {
    expect(cases.length, greaterThanOrEqualTo(10));
  });

  test('currentVersion resolves last non-pending entry', () {
    final v = currentVersion(program);
    expect(v, isNotNull);
    expect(v!['id'], 'bulk-2026-27');
    expect(v['version'], 7);
    // A trailing pending entry must be skipped.
    final withPending = {
      'versions': [
        ...(program['versions'] as List),
        {'version': 99, 'pending': true, 'id': 'draft'},
      ],
    };
    expect(currentVersion(withPending)!['version'], 7);
  });

  for (final c in cases) {
    final caseMap = c as Map;
    final name = caseMap['name'].toString();
    final date = DateTime.parse(caseMap['date'].toString());
    final expected = caseMap['expect'];

    test('fixture: $name (${caseMap['date']})', () {
      final slice = programCurrent(program, phase, date);
      if (expected == null) {
        expect(slice, isNull, reason: 'expected null slice for $name');
        return;
      }
      expect(slice, isNotNull, reason: 'expected a slice for $name');
      final exp = expected as Map;
      expect(slice!.block['number'], exp['block'], reason: '$name block');
      expect(slice.block['emphasis'], exp['emphasis'],
          reason: '$name emphasis');
      expect(slice.weekInBlock, exp['week_in_block'],
          reason: '$name week_in_block');
      expect(slice.weekType, exp['week_type'], reason: '$name week_type');
      expect(slice.todayTemplate['weekday'], exp['weekday'],
          reason: '$name weekday');

      // Check today_template fields when the fixture specifies them.
      if (exp.containsKey('today_template')) {
        final expTmpl = exp['today_template'] as Map;
        for (final key in expTmpl.keys) {
          final actual = slice.todayTemplate[key.toString()];
          expect(_deepEq(actual, expTmpl[key]), isTrue,
              reason:
                  '$name today_template.$key: expected ${expTmpl[key]}, got $actual');
        }
      }

      // Check version when the fixture specifies it.
      if (exp.containsKey('version')) {
        expect(slice.version, exp['version'], reason: '$name version');
      }

      final expTargets = exp['targets'] as Map;
      for (final key in expTargets.keys) {
        final actual = slice.targetsInForce[key.toString()];
        expect(_deepEq(actual, expTargets[key]), isTrue,
            reason:
                '$name targets.$key: expected ${expTargets[key]}, got $actual');
      }

      // Slice invariants beyond the fixture subset.
      expect(slice.id, 'bulk-2026-27');
      expect(slice.rulesInForce, contains('NEAR_MAX_LOW'));
      expect(slice.rulesInForce.length, 16);
      final wd = slice.todayTemplate['weekday'];
      expect(['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'], contains(wd));
    });
  }

  test('today_template carries the weekly_template text for Mondays (non-block-0)', () {
    final slice =
        programCurrent(program, phase, DateTime.parse('2027-03-01'))!;
    expect(slice.todayTemplate['morning'], contains('Squat heavy'));
    expect(slice.todayTemplate['afternoon'], isNull);
  });

  test('block 0 slice uses weekly_template_block_0 and carries block_0_loads note', () {
    final slice =
        programCurrent(program, phase, DateTime.parse('2026-09-21'))!;
    expect(slice.todayTemplate['morning'], contains('one hard single at RPE 8'));
    expect(slice.todayTemplate['block_note'], contains('Maintenance'));
  });

  group('weekStartDayOf (v7 week_start)', () {
    test('parses saturday; defaults to monday when absent/garbage/null', () {
      expect(weekStartDayOf({'week_start': 'saturday'}), DateTime.saturday);
      expect(weekStartDayOf({'week_start': 'Saturday '}), DateTime.saturday);
      expect(weekStartDayOf({'week_start': 'sunday'}), DateTime.sunday);
      expect(weekStartDayOf({}), DateTime.monday);
      expect(weekStartDayOf({'week_start': 'caturday'}), DateTime.monday);
      expect(weekStartDayOf(null), DateTime.monday);
    });

    test('the LIVE program.yaml v7 declares saturday (user amendment '
        '2026-09-22)', () {
      expect(weekStartDayOf(currentVersion(program)), DateTime.saturday);
    });
  });
}
