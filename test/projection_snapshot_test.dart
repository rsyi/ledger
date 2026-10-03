import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/projection_snapshot.dart';
import 'package:airledger/services/sim2_harness.dart';
import 'package:airledger/services/sim2_model.dart';

final _blocks = [
  Sim2Block(
    0,
    DateTime.utc(2026, 9, 21),
    DateTime.utc(2026, 12, 13),
    'cut',
    -0.75,
  ),
  Sim2Block(
    1,
    DateTime.utc(2026, 12, 14),
    DateTime.utc(2027, 1, 3),
    'reverse',
    0.15,
  ),
];

const _anchors = ProjectionAnchors(
  bodyweight: 161.0,
  bodyFat: 12.0,
  climbingGrade: 5.0,
  e1rm: {'squat': 320, 'bench': 240, 'deadlift': 340, 'press': 140},
);

ProjectionSnapshot _build({
  ProjectionAnchors anchors = _anchors,
  double? r,
  int paths = 20,
  int block = 0,
}) => buildProjectionSnapshot(
  params: Sim2Params.fitted(),
  blocks: _blocks,
  blockN: block,
  anchors: anchors,
  madeAt: DateTime.utc(2026, 10, 2, 6, 30),
  programVersion: '16',
  rLbWk: r,
  mcPaths: paths,
  extraInputs: const {
    'tms': {'squat': 320},
  },
)!;

void main() {
  group('buildProjectionSnapshot', () {
    test('weekly rows from block start Monday to the week after the end', () {
      final s = _build();
      expect(s.metrics.keys, ProjectionMetric.all);
      final bw = s.metrics[ProjectionMetric.bodyweight]!;
      expect(bw.first.weekStart, DateTime.utc(2026, 9, 21));
      // 12 sim weeks (Sep 21 … Dec 7) + the week-0 anchor = 13 points,
      // the last one the state entering Dec 14.
      expect(bw, hasLength(13));
      expect(bw.last.weekStart, DateTime.utc(2026, 12, 14));
      for (var i = 1; i < bw.length; i++) {
        expect(bw[i].weekStart.difference(bw[i - 1].weekStart).inDays, 7);
      }
    });

    test('week 0 is anchored on the observed values', () {
      final s = _build();
      double w0(String m) => s.metrics[m]!.first.projected;
      expect(w0(ProjectionMetric.bodyweight), closeTo(161.0, 1e-9));
      expect(w0(ProjectionMetric.bodyFat), closeTo(12.0, 1e-9));
      expect(w0(ProjectionMetric.strengthTotal), closeTo(900, 1e-9));
      expect(w0(ProjectionMetric.e1rmSquat), closeTo(320, 1e-9));
      expect(w0(ProjectionMetric.e1rmBench), closeTo(240, 1e-9));
      expect(w0(ProjectionMetric.e1rmDeadlift), closeTo(340, 1e-9));
      expect(w0(ProjectionMetric.e1rmPress), closeTo(140, 1e-9));
      expect(w0(ProjectionMetric.climbingGrade), closeTo(5.0, 1e-9));
    });

    test('declared cut rate drives bodyweight down ~0.75 lb/wk', () {
      final s = _build();
      final bw = s.metrics[ProjectionMetric.bodyweight]!;
      expect(bw.last.projected, closeTo(161 - 12 * 0.75, 1e-6));
      expect(s.inputs['r_source'], 'declared_block_rate');
    });

    test('nutrition r overrides the block rate', () {
      final s = _build(r: -0.5);
      final bw = s.metrics[ProjectionMetric.bodyweight]!;
      expect(bw.last.projected, closeTo(161 - 12 * 0.5, 1e-6));
      expect(s.inputs['r_source'], 'nutrition');
      expect(s.inputs['r_lb_wk'], -0.5);
    });

    test('band: floor at week 0, contains the line, widens with time', () {
      final s = _build();
      for (final m in ProjectionMetric.all) {
        for (final p in s.metrics[m]!) {
          expect(p.lo, lessThanOrEqualTo(p.projected), reason: m);
          expect(p.hi, greaterThanOrEqualTo(p.projected), reason: m);
        }
      }
      final bw = s.metrics[ProjectionMetric.bodyweight]!;
      expect(bw.first.hi - bw.first.lo, closeTo(2 * projectionBwFloorLb, 1e-9));
      // Rate bracket ±0.25 lb/wk over 12 weeks = ±3 lb at the end.
      expect(bw.last.hi - bw.last.projected, closeTo(3.0, 1e-6));
      expect(bw.last.projected - bw.last.lo, closeTo(3.0, 1e-6));
      final tot = s.metrics[ProjectionMetric.strengthTotal]!;
      expect(tot.first.hi - tot.first.projected, closeTo(27, 1e-6)); // 3%
      // Over one cut block the model's own strength noise stays inside
      // the ±3% measurement floor — the floor holds at every week.
      expect(
        tot.last.hi - tot.last.lo,
        greaterThanOrEqualTo(2 * 0.03 * tot.last.projected - 1e-9),
      );
    });

    test('without anchors the raw model (seeded) values pass through', () {
      final s = _build(anchors: const ProjectionAnchors());
      expect(
        s.metrics[ProjectionMetric.strengthTotal]!.first.projected,
        closeTo(sim2SeedIndexTotal, 1e-9),
      );
      expect(
        s.metrics[ProjectionMetric.bodyweight]!.first.projected,
        closeTo(sim2SeedBw, 1e-9),
      );
    });

    test('deterministic: same inputs → same rows', () {
      expect(jsonEncode(_build().toRows()), jsonEncode(_build().toRows()));
    });

    test('inputs record program/model versions, band method, extras', () {
      final s = _build();
      expect(s.inputs['program_version'], '16');
      expect(s.inputs['model_version'], projectionModelVersion);
      expect(s.inputs['band_method'], projectionBandMethod);
      expect(s.inputs['block_emphasis'], 'cut');
      expect(s.inputs['block_start'], '2026-09-21');
      expect(s.inputs['block_end'], '2026-12-13');
      expect((s.inputs['params'] as Map)['a'], Sim2Params.fitted().a);
      expect(s.inputs['tms'], {'squat': 320});
      expect(s.emphasis, 'cut');
    });

    test('unknown block → null', () {
      expect(
        buildProjectionSnapshot(
          params: Sim2Params.fitted(),
          blocks: _blocks,
          blockN: 9,
          anchors: _anchors,
          madeAt: DateTime.utc(2026),
          programVersion: '16',
        ),
        isNull,
      );
    });
  });

  group('codec', () {
    test('round trip; inputs_json only on the first row', () {
      final s = _build();
      final rows = s.toRows();
      expect(rows, hasLength(ProjectionMetric.all.length * 13));
      expect(rows.first[8], isNotEmpty);
      expect(rows.skip(1).every((r) => r[8] == ''), isTrue);
      final parsed = parseProjectionSnapshots([
        projectionSnapshotHeaders,
        ...rows,
      ]);
      expect(parsed, hasLength(1));
      final p = parsed.single;
      expect(p.block, 0);
      expect(p.programVersion, '16');
      expect(p.madeAt, s.madeAt);
      expect(p.inputs['block_emphasis'], 'cut');
      expect(p.start, DateTime.utc(2026, 9, 21));
      expect(p.end, DateTime.utc(2026, 12, 13));
      for (final m in ProjectionMetric.all) {
        expect(p.metrics[m], hasLength(13));
        expect(
          p.metrics[m]!.last.projected,
          closeTo(s.metrics[m]!.last.projected, 0.006),
        );
      }
    });

    test('malformed rows skipped; strings from Sheets parse', () {
      final parsed = parseProjectionSnapshots([
        projectionSnapshotHeaders,
        [
          '0',
          'bodyweight',
          '2026-09-21',
          '161',
          '159.75',
          '162.25',
          '2026-10-02T06:30:00.000Z',
          '16',
          'not json',
        ],
        ['x', 'bodyweight', '2026-09-28', '160', '', '', '2026-10-02', '16'],
        ['0', '', '2026-09-28', '160'],
      ]);
      expect(parsed, hasLength(1));
      expect(parsed.single.inputs, isEmpty);
      expect(parsed.single.metrics['bodyweight'], hasLength(1));
    });

    test('header check: exact header row required (empty tab is fine)', () {
      expect(projectionTabHeaderOk(const []), isTrue);
      expect(projectionTabHeaderOk([projectionSnapshotHeaders]), isTrue);
      expect(
        projectionTabHeaderOk([
          [...projectionSnapshotHeaders, 'extra_col'],
        ]),
        isTrue,
      );
      final rows = _build(paths: 2).toRows();
      expect(projectionTabHeaderOk(rows), isFalse); // header lost
      expect(
        projectionTabHeaderOk([
          ['block', 'metric', 'week'],
        ]),
        isFalse,
      );
    });

    test('repair-read: a headerless tab (row 1 = data) parses every row', () {
      final s = _build(paths: 2);
      final rows = s.toRows();
      final parsed = parseProjectionSnapshots(rows); // no header row
      expect(parsed, hasLength(1));
      expect(
        parsed.single.metrics[ProjectionMetric.bodyweight],
        hasLength(13),
      ); // row 1 (bodyweight week 0) kept, not eaten
      expect(parsed.single.inputs['block_emphasis'], 'cut');
    });

    test('empty / header-only tab → no snapshots', () {
      expect(parseProjectionSnapshots(const []), isEmpty);
      expect(parseProjectionSnapshots([projectionSnapshotHeaders]), isEmpty);
    });
  });

  group('selection', () {
    List<List<Object?>> rowsAt(
      int block,
      DateTime made,
      double v, {
      int? version = projectionActualsVersion,
      int? baseline,
    }) => [
      [
        block,
        'bodyweight',
        '2026-09-21',
        v,
        v - 1,
        v + 1,
        made.toIso8601String(),
        '16',
        version == null && baseline == null
            ? ''
            : jsonEncode({
                'actuals_version': ?version,
                'baseline_version': ?baseline,
              }),
      ],
    ];

    test('user re-baseline: the highest baseline_version wins even when '
        'made later; older sets stay readable', () {
      final all = parseProjectionSnapshots([
        projectionSnapshotHeaders,
        ...rowsAt(0, DateTime.utc(2026, 10, 2), 161, version: null), // v1
        ...rowsAt(0, DateTime.utc(2026, 10, 3), 147), // thin-data v2
        ...rowsAt(0, DateTime.utc(2026, 10, 4), 154, baseline: 2),
        ...rowsAt(0, DateTime.utc(2026, 10, 9), 150), // later re-freeze, b1
      ]);
      expect(all, hasLength(4));
      expect(firstSnapshotForBlock(all, 0)!.madeAt, DateTime.utc(2026, 10, 4));
      expect(firstSnapshotsByBlock(all)[0]!.baselineVersion, 2);
      expect(maxBaselineVersionForBlock(all, 0), 2);
      expect(maxBaselineVersionForBlock(all, 1), 1);
      expect(snapshotNeededForBlock(all, 0), isFalse);
      // A second set on the same baseline never displaces the first.
      final again = parseProjectionSnapshots([
        projectionSnapshotHeaders,
        ...rowsAt(0, DateTime.utc(2026, 10, 4), 154, baseline: 2),
        ...rowsAt(0, DateTime.utc(2026, 10, 6), 155, baseline: 2),
      ]);
      expect(firstSnapshotForBlock(again, 0)!.madeAt, DateTime.utc(2026, 10, 4));
    });

    test('rateSource reads the new field, else maps legacy r_source', () {
      ProjectionSnapshot s(Map<String, Object?> inputs) => ProjectionSnapshot(
        block: 0,
        madeAt: DateTime.utc(2026, 10, 2),
        programVersion: '16',
        metrics: const {},
        inputs: inputs,
      );
      expect(s({'rate_source': 'declared'}).rateSource, 'declared');
      expect(s({'r_source': 'nutrition'}).rateSource, 'logged_intake');
      expect(s({'r_source': 'declared_block_rate'}).rateSource, 'declared');
      expect(s({}).rateSource, isNull);
      expect(s({}).baselineVersion, 1);
    });

    test('first snapshot per block wins; re-snapshots are kept', () {
      final tab = [
        projectionSnapshotHeaders,
        ...rowsAt(0, DateTime.utc(2026, 10, 5), 150),
        ...rowsAt(0, DateTime.utc(2026, 10, 2), 161),
        ...rowsAt(1, DateTime.utc(2026, 12, 15), 155),
      ];
      final all = parseProjectionSnapshots(tab);
      expect(all, hasLength(3));
      final first = firstSnapshotForBlock(all, 0)!;
      expect(first.madeAt, DateTime.utc(2026, 10, 2));
      expect(first.metrics['bodyweight']!.single.projected, 161);
      expect(firstSnapshotForBlock(all, 2), isNull);
      final byBlock = firstSnapshotsByBlock(all);
      expect(byBlock.keys, [0, 1]);
      expect(byBlock[0]!.madeAt, DateTime.utc(2026, 10, 2));
    });

    test('snapshotNeededForBlock: once per block (idempotent)', () {
      final all = parseProjectionSnapshots([
        projectionSnapshotHeaders,
        ...rowsAt(0, DateTime.utc(2026, 10, 2), 161),
      ]);
      expect(snapshotNeededForBlock(all, 0), isFalse);
      expect(snapshotNeededForBlock(all, 1), isTrue);
      expect(snapshotNeededForBlock(const [], 0), isTrue);
    });

    test('actuals version: a block frozen only on a superseded definition '
        'is re-frozen once; the newest definition wins selection', () {
      final v1 = parseProjectionSnapshots([
        projectionSnapshotHeaders,
        ...rowsAt(0, DateTime.utc(2026, 10, 2), 161, version: null),
      ]);
      expect(v1.single.actualsVersion, 1); // no field → v1
      expect(snapshotNeededForBlock(v1, 0), isTrue);
      final both = parseProjectionSnapshots([
        projectionSnapshotHeaders,
        ...rowsAt(0, DateTime.utc(2026, 10, 2), 161, version: null),
        ...rowsAt(0, DateTime.utc(2026, 10, 3), 162),
        ...rowsAt(0, DateTime.utc(2026, 10, 9), 150), // later v2 re-snap
      ]);
      expect(snapshotNeededForBlock(both, 0), isFalse);
      final first = firstSnapshotForBlock(both, 0)!;
      expect(first.madeAt, DateTime.utc(2026, 10, 3));
      expect(firstSnapshotsByBlock(both)[0]!.madeAt, DateTime.utc(2026, 10, 3));
    });

    test('builder records the current actuals version', () {
      expect(_build(paths: 2).actualsVersion, projectionActualsVersion);
    });
  });

  test('snapshotForDay: covering block, else the latest started', () {
    ProjectionSnapshot snap(int n, String start, String end) =>
        ProjectionSnapshot(
          block: n,
          madeAt: DateTime.utc(2026, 10, 2),
          programVersion: '16',
          metrics: const {},
          inputs: {'block_start': start, 'block_end': end},
        );
    final by = {
      0: snap(0, '2026-09-21', '2026-12-13'),
      2: snap(2, '2027-01-04', '2027-02-28'),
    };
    expect(snapshotForDay(by, DateTime(2026, 10, 5))!.block, 0);
    expect(snapshotForDay(by, DateTime(2026, 12, 13))!.block, 0);
    // Dec 20 is block 1 (no snapshot) → block 0 keeps tracking.
    expect(snapshotForDay(by, DateTime(2026, 12, 20))!.block, 0);
    expect(snapshotForDay(by, DateTime(2027, 1, 10))!.block, 2);
    expect(snapshotForDay(by, DateTime(2026, 9, 1)), isNull);
  });
}
