// ignore_for_file: avoid_print
//
// Regenerates the SHARED phase-tracking twin fixture consumed by
//   * test/phase_tracking_twin_test.dart (this repo — Dart must match), and
//   * ~/repos/ledger-mcp/test/phase_tracking.test.ts (the TS twin).
// The expected values are computed by the Dart implementation
// (lib/services/projection_tracking.dart + projection_snapshot.dart), so
// a semantic change on the Dart side shows up as a twin-test failure in
// the worker until this is re-run and the TS mirror updated.
//
//   dart run tool/gen_phase_tracking_fixture.dart [out.json]
//   (default out: ../ledger-mcp/test/fixtures/phase_tracking_cases.json)

import 'dart:convert';
import 'dart:io';

import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/projection_snapshot.dart';
import 'package:airledger/services/projection_tracking.dart';

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime p(String s) => DateTime.parse(s);

double? r6(double? v) => v == null ? null : double.parse(v.toStringAsFixed(6));

Map<String, Object?> actualsCase(
  String name,
  String day, {
  List<List<Object?>> weighIns = const [],
  List<List<Object?>> bodyFat = const [],
  List<List<Object?>> strength = const [],
  List<List<Object?>> climbs = const [],
}) {
  final a = projectionActualsAt(
    day: p(day),
    weighIns: [
      for (final w in weighIns)
        WeightRow(date: p(w[0] as String), weightLbs: (w[1] as num).toDouble()),
    ],
    bodyFat: [
      for (final b in bodyFat)
        BodyFatReading(p(b[0] as String), (b[1] as num).toDouble()),
    ],
    strength: [
      for (final s in strength)
        StrengthRow(
          date: p(s[0] as String),
          exercise: s[1] as String,
          weight: (s[2] as num).toDouble(),
          reps: (s[3] as num).toInt(),
          rpe: (s[4] as num?)?.toDouble(),
        ),
    ],
    climbs: [
      for (final c in climbs) (date: p(c[0] as String), vGrade: c[1] as int?),
    ],
  );
  return {
    'name': name,
    'day': day,
    'weigh_ins': weighIns,
    'body_fat': bodyFat,
    'strength': strength,
    'climbs': climbs,
    'expected': {for (final e in a.entries) e.key: r6(e.value)},
  };
}

List<List<Object?>> linePoints(
  double v0,
  double perWeek,
  double band, {
  String start = '2026-09-21',
  int weeks = 13,
}) => [
  for (var k = 0; k < weeks; k++)
    [
      ymd(p(start).add(Duration(days: 7 * k))),
      v0 + perWeek * k,
      v0 + perWeek * k - band,
      v0 + perWeek * k + band,
    ],
];

Map<String, Object?> trackingCase(
  String name,
  String metric,
  String? emphasis,
  List<List<Object?>> points,
  String day,
  double? actual,
) {
  final pts = [
    for (final x in points)
      ProjectionPoint(
        DateTime.utc(
          p(x[0] as String).year,
          p(x[0] as String).month,
          p(x[0] as String).day,
        ),
        (x[1] as num).toDouble(),
        (x[2] as num).toDouble(),
        (x[3] as num).toDouble(),
      ),
  ];
  final t = trackMetric(
    metric: metric,
    points: pts,
    day: p(day),
    actual: actual,
    emphasis: emphasis,
  );
  return {
    'name': name,
    'metric': metric,
    'emphasis': emphasis,
    'points': points,
    'day': day,
    'actual': actual,
    'expected': {
      'projected': r6(t.projected),
      'lo': r6(t.lo),
      'hi': r6(t.hi),
      'delta': r6(t.delta),
      'status': t.status.wire,
      'line': t.line,
    },
  };
}

void main(List<String> args) {
  final out = args.isNotEmpty
      ? args.first
      : '${Platform.environment['HOME']}/repos/ledger-mcp/test/fixtures/'
            'phase_tracking_cases.json';

  final actuals = [
    actualsCase(
      'bodyweight: per-day means, 7-day window, later rows ignored',
      '2026-09-30',
      weighIns: [
        ['2026-09-23', 170],
        ['2026-09-24', 160],
        ['2026-09-24', 162],
        ['2026-09-30', 159],
        ['2026-10-01', 999],
      ],
    ),
    actualsCase(
      'body fat: week mean, else latest within 28 days',
      '2026-09-27',
      bodyFat: [
        ['2026-09-01', 13.0],
        ['2026-09-20', 12.0],
        ['2026-09-28', 11.6],
      ],
    ),
    actualsCase(
      'body fat: stale (> 27 days) → null',
      '2026-10-30',
      bodyFat: [
        ['2026-09-28', 11.6],
      ],
    ),
    actualsCase(
      'e1rm: latest trained week per lift, RPE-adjusted, reps capped',
      '2026-09-27',
      strength: [
        ['2026-09-08', 'Barbell Squat', 400, 1, 10],
        ['2026-09-21', 'Barbell Squat', 300, 1, 8],
        ['2026-09-23', 'Barbell Squat', 225, 5, null],
        ['2026-09-22', 'Flat Barbell Bench Press', 200, 1, 8],
        ['2026-09-16', 'Barbell Deadlift', 315, 3, 9],
        ['2026-09-25', 'Barbell Standing Military Press', 95, 15, 7],
        ['2026-09-30', 'Barbell Squat', 100, 1, null],
        ['2026-09-22', 'Dumbbell Curl', 40, 10, null],
        ['2026-09-22', 'Barbell Deadlift', 0, 5, null],
      ],
    ),
    actualsCase(
      'e1rm: rolling 7 days keeps the last top over mid-week volume; '
          'carry-back for an untrained lift',
      '2026-10-01',
      strength: [
        ['2026-09-26', 'Overhead Press', 120, 5, 8.5],
        ['2026-09-30', 'Overhead Press', 90, 10, 7],
        ['2026-09-01', 'Barbell Deadlift', 300, 3, 8],
        ['2026-08-28', 'Barbell Deadlift', 310, 1, 8],
        ['2026-08-20', 'Barbell Deadlift', 400, 1, 8],
        ['2026-09-29', 'Barbell Squat', 300, 1, 8],
        ['2026-09-24', 'Flat Barbell Bench Press', 225, 1, 8],
      ],
    ),
    actualsCase(
      'climbing: thin week steps back; null grades ignored',
      '2026-09-30',
      climbs: [
        for (final g in [3, 4, 5, 5, 6]) ['2026-09-02', g],
        ['2026-09-29', 7],
        ['2026-09-29', null],
      ],
    ),
    actualsCase(
      'climbing: p75 interpolates',
      '2026-09-10',
      climbs: [
        for (final g in [2, 4, 4, 5, 6, 7]) ['2026-09-08', g],
      ],
    ),
  ];

  final cut = linePoints(160, -0.7, 1);
  final tracking = [
    trackingCase(
      'cut bw on track (within, zero)',
      'bodyweight',
      'cut',
      cut,
      '2026-09-28',
      159.3,
    ),
    trackingCase(
      'cut bw within, negative',
      'bodyweight',
      'cut',
      cut,
      '2026-09-28',
      159.0,
    ),
    trackingCase(
      'cut bw below band = ahead',
      'bodyweight',
      'cut',
      cut,
      '2026-09-28',
      157.9,
    ),
    trackingCase(
      'cut bw above band = behind',
      'bodyweight',
      'cut',
      cut,
      '2026-09-28',
      160.8,
    ),
    trackingCase(
      'interpolated mid-week',
      'bodyweight',
      'cut',
      cut,
      '2026-09-24',
      158.0,
    ),
    trackingCase(
      'past the end clamps to the last point',
      'bodyweight',
      'cut',
      cut,
      '2027-03-01',
      151.6,
    ),
    trackingCase(
      'before the block → no_data',
      'bodyweight',
      'cut',
      cut,
      '2026-09-01',
      160,
    ),
    trackingCase(
      'strength within (cut)',
      'strength_total',
      'cut',
      linePoints(900, -2, 27),
      '2026-09-28',
      886,
    ),
    trackingCase(
      'strength behind',
      'strength_total',
      'cut',
      linePoints(900, -2, 27),
      '2026-09-28',
      860,
    ),
    trackingCase(
      'strength ahead',
      'e1rm_squat',
      'cut',
      linePoints(320, -1, 9.6),
      '2026-10-05',
      340,
    ),
    trackingCase(
      'body fat below = ahead',
      'body_fat',
      'lifting',
      linePoints(12, -0.1, 1),
      '2026-09-21',
      10.5,
    ),
    trackingCase(
      'hold bw above = behind (above projection)',
      'bodyweight',
      'lifting',
      linePoints(158, 0.05, 1.25),
      '2026-09-21',
      160,
    ),
    trackingCase(
      'hold bw below = behind (below projection)',
      'bodyweight',
      'lifting',
      linePoints(158, 0.05, 1.25),
      '2026-09-21',
      156,
    ),
    trackingCase(
      'gaining block bw above = ahead',
      'bodyweight',
      'reverse',
      linePoints(154, 0.3, 1.25),
      '2026-09-21',
      156,
    ),
    trackingCase(
      'climbing within',
      'climbing_grade',
      'cut',
      linePoints(5, 0.08, 0.5),
      '2026-10-05',
      5.3,
    ),
    trackingCase(
      'vo2 no actual',
      'vo2max',
      'cut',
      linePoints(52, 0.4, 1),
      '2026-10-05',
      null,
    ),
  ];

  // Selection: first snapshot per block + the block covering a day.
  List<Object?> row(
    int block,
    String metric,
    String week,
    double v,
    String made, {
    String inputs = '',
  }) => [block, metric, week, v, v - 1, v + 1, made, '16', inputs];
  String inp(String start, String end, String emphasis, {int? version = 2}) =>
      jsonEncode({
        'block_start': start,
        'block_end': end,
        'block_emphasis': emphasis,
        'actuals_version': ?version,
      });
  final selRows = <List<Object?>>[
    projectionSnapshotHeaders,
    // An older snapshot on the superseded v1 actual definitions —
    // earlier made_at, but the v2 set below must win selection.
    row(
      0,
      'bodyweight',
      '2026-09-21',
      170,
      '2026-10-01T00:00:00.000Z',
      inputs: inp('2026-09-21', '2026-12-13', 'cut', version: null),
    ),
    row(
      0,
      'bodyweight',
      '2026-09-21',
      150,
      '2026-10-05T06:00:00.000Z',
      inputs: inp('2026-09-21', '2026-12-13', 'cut'),
    ),
    row(
      0,
      'bodyweight',
      '2026-09-21',
      161,
      '2026-10-02T23:05:35.951398Z',
      inputs: inp('2026-09-21', '2026-12-13', 'cut'),
    ),
    row(0, 'bodyweight', '2026-09-28', 160.3, '2026-10-02T23:05:35.951398Z'),
    row(
      2,
      'bodyweight',
      '2027-01-04',
      155,
      '2027-01-05T07:00:00.000Z',
      inputs: inp('2027-01-04', '2027-02-28', 'climbing'),
    ),
  ];
  final parsed = parseProjectionSnapshots(selRows);
  final first = firstSnapshotsByBlock(parsed);
  final selection = {
    'rows': selRows,
    'first_made_at': {
      for (final e in first.entries)
        '${e.key}': e.value.madeAt.toIso8601String(),
    },
    'first_point_counts': {
      for (final e in first.entries)
        '${e.key}': e.value.metrics['bodyweight']?.length ?? 0,
    },
    'for_day': [
      for (final d in [
        '2026-09-01',
        '2026-10-05',
        '2026-12-13',
        '2026-12-20',
        '2027-01-10',
      ])
        {'day': d, 'block': snapshotForDay(first, p(d))?.block},
    ],
  };

  final json = const JsonEncoder.withIndent('  ').convert({
    'generated_by': 'ledger tool/gen_phase_tracking_fixture.dart',
    'note':
        'Dart is the reference; the TS twin must reproduce every '
        'expected value (numbers within 1e-6, strings exactly).',
    'actuals': actuals,
    'tracking': tracking,
    'selection': selection,
  });
  File(out)
    ..createSync(recursive: true)
    ..writeAsStringSync('$json\n');
  print(
    'wrote $out (${actuals.length} actuals, ${tracking.length} tracking '
    'cases)',
  );
}
