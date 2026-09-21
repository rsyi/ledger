// Shared-fixture harness for the working-max controller: runs every case
// in airledger-fitness/coach/fixtures/wm_evaluate_cases.yaml through the
// Dart evaluate() (lib/services/working_max.dart). The TS twin in
// ledger-mcp (test/working_max.test.ts) loads THE SAME file — drift
// between the two ports fails one suite or the other.
//
// The Dart controller is the reference implementation: fixture
// expectations were generated from it, so this suite passing pins the
// fixture; the TS suite passing pins the port.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/working_max.dart';

const _fitnessRepo = '../airledger-fitness/coach';

dynamic _loadYamlFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
        'Missing $path — is the airledger-fitness checkout present?');
  }
  return loadYaml(file.readAsStringSync());
}

final RegExp _grinderNotes =
    RegExp(r'grind|slow|stall|miss', caseSensitive: false);

void main() {
  final program =
      _loadYamlFile('$_fitnessRepo/program.yaml') as Map<Object?, Object?>;
  final version = currentVersion(program)!;
  final policies = loadPolicies(version);
  LoadPolicy byName(String n) => policies.firstWhere((p) => p.name == n);

  final fixtures = _loadYamlFile('$_fitnessRepo/fixtures/wm_evaluate_cases.yaml')
      as Map<Object?, Object?>;
  final cases = fixtures['cases'] as List;

  test('has at least 15 cases', () {
    expect(cases.length, greaterThanOrEqualTo(15));
  });

  for (final raw in cases) {
    final c = raw as Map;
    test('fixture: ${c['name']}', () {
      final policy = byName(c['policy'].toString());
      final lift = c['lift'].toString();
      final wm = (c['wm'] as num).toDouble();
      final date = DateTime.parse(c['date'].toString());

      // Reading (optional): variant + grinder derived exactly like the
      // production pipeline (§1.2/§1.4).
      Reading? reading;
      final r = c['reading'];
      if (r is Map) {
        final weight = (r['weight'] as num).toDouble();
        final rpe = (r['rpe'] as num).toDouble();
        final notes = r['notes']?.toString();
        final variant = parseVariant(lift, notes);
        reading = Reading(
          date: date,
          lift: lift,
          variant: variant.variant,
          weightLb: weight / variant.factor,
          rawWeightLb: weight,
          reps: (r['reps'] as num).toInt(),
          rpe: rpe,
          kind: r['kind'].toString(),
          grinder: rpe >= 9.5 ||
              (notes != null && _grinderNotes.hasMatch(notes)),
          missed: r['missed'] == true,
          variantMismatch: variant.mismatch,
        );
      }

      // Prior decision state (streak / consecutive drop / pain-cap clean).
      final priors = <WmDecision>[];
      final p = c['prior'];
      if (p is Map) {
        priors.add(WmDecision(
          date: date.subtract(const Duration(days: 7)),
          lift: lift,
          action: p['action']?.toString() ?? 'hold',
          wmBefore: wm,
          wmAfter: wm,
          source: 'rule',
          reason: 'fixture prior',
          raiseEligible: p['raise_eligible'] == true,
          flags: [if (p['pain_cap_clean'] == true) 'PAIN_CAP_CLEAN'],
        ));
      }

      final d = evaluate(
        lift: lift,
        policy: policy,
        workingMax: wm,
        date: date,
        reading: reading,
        priorDecisions: priors,
        painCapActive: c['pain_cap'] == true,
        twoSignalsThisWeek: c['two_signals'] == true,
        weeksWithoutReading:
            (c['weeks_without_reading'] as num?)?.toInt() ?? 0,
      );

      final expected = c['expect'] as Map;
      expect(d.action, expected['decision'].toString(), reason: 'decision');
      expect(d.wmAfter, (expected['new_wm'] as num).toDouble(),
          reason: 'new_wm');
      expect(d.source, expected['source']?.toString() ?? 'rule',
          reason: 'source');
      if (expected.containsKey('cap')) {
        expect(d.capNextTopSetRpe, (expected['cap'] as num).toDouble(),
            reason: 'cap');
      } else {
        expect(d.capNextTopSetRpe, isNull, reason: 'cap');
      }
      final expectedFlags = [
        for (final f in (expected['flags'] as List? ?? const [])) f.toString(),
      ];
      expect(d.flags, expectedFlags, reason: 'flags');
      expect(d.noTopSetsNextWeek, expected['no_top_sets_next_week'] == true,
          reason: 'no_top_sets_next_week');
      expect(d.raiseEligible, expected['raise_eligible'] == true,
          reason: 'raise_eligible');
      if (expected.containsKey('converted_weight')) {
        expect(reading!.weightLb,
            closeTo((expected['converted_weight'] as num).toDouble(), 0.05),
            reason: 'converted_weight');
      }
      if (expected.containsKey('implied_max')) {
        expect(reading!.impliedMax,
            closeTo((expected['implied_max'] as num).toDouble(), 0.05),
            reason: 'implied_max');
      }
    });
  }
}
