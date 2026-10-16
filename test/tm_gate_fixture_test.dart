// Shared-fixture harness for the HITL training-max gate: runs every case
// in airledger-fitness/coach/fixtures/tm_gate_cases.yaml through the Dart
// reference (lib/services/wm_tabs.dart). The TS twin in ledger-mcp
// (test/tm_gate.test.ts) loads THE SAME file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/services/working_max.dart';

const _fixture = '../airledger-fitness/coach/fixtures/tm_gate_cases.yaml';

double? _num(Object? v) => v is num ? v.toDouble() : null;

void main() {
  final file = File(_fixture);
  if (!file.existsSync()) {
    throw StateError('Missing $_fixture — airledger-fitness checkout?');
  }
  final doc = loadYaml(file.readAsStringSync()) as Map;

  group('gate', () {
    for (final raw in doc['gate'] as List) {
      final c = raw as Map;
      test('${c['name']}', () {
        final got = gateTmCandidate(
          accepted: _num(c['accepted'])!,
          candidate: _num(c['candidate']),
          pending: _num(c['pending']),
          declined: _num(c['declined']),
        );
        expect(got.name, c['expect']);
      });
    }
  });

  group('state', () {
    for (final raw in doc['state'] as List) {
      final c = raw as Map;
      test('${c['name']}', () {
        final lift = c['lift'].toString();
        final rows = [
          for (final r in (c['rows'] as List).cast<Map>())
            WorkingMaxRow(
              lift: lift,
              variant: defaultVariantByLift[lift]!,
              valueLb: _num(r['value'])!,
              effectiveFrom: DateTime.parse('${r['date']}T00:00:00Z'),
              source: r['source'].toString(),
              reason: r['reason']?.toString() ?? '',
              readingId: r['reading_id']?.toString() ?? '',
              confirmed: r['confirmed'] as bool?,
            ),
        ];
        final e = c['expect'] as Map;
        expect(currentWorkingMax(rows, lift)?.valueLb, _num(e['accepted']));
        expect(pendingTmProposal(rows, lift)?.valueLb, _num(e['pending']));
        expect(declinedTmValue(rows, lift), _num(e['declined']));
        expect(needsConfirmation(rows, lift), e['needs_confirmation']);
      });
    }
  });

  group('evidence', () {
    for (final raw in doc['evidence'] as List) {
      final c = raw as Map;
      test('${c['name']}', () {
        expect(
          tmEvidence(
            weightLb: _num(c['weight'])!,
            reps: (c['reps'] as num).toInt(),
            rpe: _num(c['rpe'])!,
            impliedMax: _num(c['implied'])!,
            estMedian: _num(c['est_median']),
            estSets: (c['est_sets'] as num?)?.toInt(),
            grinder: c['grinder'] == true,
            missed: c['missed'] == true,
          ),
          c['expect'],
        );
      });
    }
  });
}
