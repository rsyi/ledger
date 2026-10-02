// Twin guard for the ledger-mcp phase_tracking mirror: the shared cases
// in ~/repos/ledger-mcp/test/fixtures/phase_tracking_cases.json (written
// by tool/gen_phase_tracking_fixture.dart) must still match the Dart
// implementation. A failure here means Dart semantics moved — re-run the
// generator AND update src/phase_tracking.ts so the TS twin follows.
// Skipped when the sibling checkout is absent.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/projection_snapshot.dart';
import 'package:airledger/services/projection_tracking.dart';

final _fixture = File(
  '${Platform.environment['HOME']}/repos/ledger-mcp/test/fixtures/'
  'phase_tracking_cases.json',
);

DateTime _p(String s) => DateTime.parse(s);

void _close(Object? actual, Object? expected, String reason) {
  if (expected == null) {
    expect(actual, isNull, reason: reason);
  } else {
    expect(actual, isNotNull, reason: reason);
    expect(
      actual as double,
      closeTo((expected as num).toDouble(), 1e-6),
      reason: reason,
    );
  }
}

void main() {
  final skip = _fixture.existsSync() ? null : 'ledger-mcp checkout absent';
  final data = skip == null
      ? jsonDecode(_fixture.readAsStringSync()) as Map<String, dynamic>
      : const <String, dynamic>{};

  test('actuals cases match', () {
    for (final c in data['actuals'] as List) {
      final a = projectionActualsAt(
        day: _p(c['day']),
        weighIns: [
          for (final w in c['weigh_ins'])
            WeightRow(date: _p(w[0]), weightLbs: (w[1] as num).toDouble()),
        ],
        bodyFat: [
          for (final b in c['body_fat'])
            BodyFatReading(_p(b[0]), (b[1] as num).toDouble()),
        ],
        strength: [
          for (final s in c['strength'])
            StrengthRow(
              date: _p(s[0]),
              exercise: s[1],
              weight: (s[2] as num).toDouble(),
              reps: (s[3] as num).toInt(),
              rpe: (s[4] as num?)?.toDouble(),
            ),
        ],
        climbs: [
          for (final x in c['climbs']) (date: _p(x[0]), vGrade: x[1] as int?),
        ],
      );
      for (final e in (c['expected'] as Map).entries) {
        _close(a[e.key], e.value, '${c['name']} · ${e.key}');
      }
    }
  }, skip: skip);

  test('tracking cases match', () {
    for (final c in data['tracking'] as List) {
      final t = trackMetric(
        metric: c['metric'],
        emphasis: c['emphasis'],
        points: [
          for (final x in c['points'])
            ProjectionPoint(
              DateTime.utc(_p(x[0]).year, _p(x[0]).month, _p(x[0]).day),
              (x[1] as num).toDouble(),
              (x[2] as num).toDouble(),
              (x[3] as num).toDouble(),
            ),
        ],
        day: _p(c['day']),
        actual: (c['actual'] as num?)?.toDouble(),
      );
      final e = c['expected'] as Map;
      final n = c['name'];
      _close(t.projected, e['projected'], '$n projected');
      _close(t.lo, e['lo'], '$n lo');
      _close(t.hi, e['hi'], '$n hi');
      _close(t.delta, e['delta'], '$n delta');
      expect(t.status.wire, e['status'], reason: '$n status');
      expect(t.line, e['line'], reason: '$n line');
    }
  }, skip: skip);

  test('selection cases match', () {
    final sel = data['selection'] as Map;
    final rows = [
      for (final r in sel['rows'] as List) [for (final c in r as List) c],
    ];
    final first = firstSnapshotsByBlock(parseProjectionSnapshots(rows));
    expect({
      for (final e in first.entries)
        '${e.key}': e.value.madeAt.toIso8601String(),
    }, sel['first_made_at']);
    for (final f in sel['for_day'] as List) {
      expect(
        snapshotForDay(first, _p(f['day']))?.block,
        f['block'],
        reason: f['day'],
      );
    }
  }, skip: skip);
}
