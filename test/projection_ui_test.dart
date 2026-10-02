/// Frozen phase projections in the UI (spec 2026-10-02): the projection
/// card's band + projected line + actuals + tracking chip, the labelled
/// live fallback, the Weight / Strength / Lift pages fed by a snapshot
/// store, the Progress phase timeline's tracking + past-block result,
/// and the past-phase view.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/program_current.dart' show ProgramSlice;
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/projection_snapshot.dart';
import 'package:airledger/services/projection_snapshot_store.dart';
import 'package:airledger/services/projection_tracking.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/design/design.dart' show StatusChip;
import 'package:airledger/ui/lift_screen.dart';
import 'package:airledger/ui/phase_projection_screen.dart';
import 'package:airledger/ui/plan_data.dart';
import 'package:airledger/ui/strength_screen.dart';
import 'package:airledger/ui/weight_screen.dart';
import 'package:airledger/ui/widgets/plan_sections.dart';
import 'package:airledger/ui/widgets/projection_card.dart';

class _FakeRepo implements WarehouseConnector {
  final List<Record> rows;
  _FakeRepo(this.rows);

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async => rows;
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

ViewSchema _view(String name) => ViewSchema(
  name: name,
  datasource: 'gsheets',
  table: name,
  entities: const [],
  measures: const [],
  dimensions: [Dimension(name: 'date', type: DimensionType.date, expr: 'date')],
  readOnly: true,
);

final _today = DateTime(2026, 10, 5);

const _phaseYaml = '''
versions:
  - version: 1
    value: cut
    effective_from: "2026-09-21"
    target_rate_lb_per_week: -0.75
''';

const _programYaml = '''
versions:
  - version: 16
    effective_from: "2026-09-21"
    blocks:
      - { n: 0, dates: ["2026-09-21", "2026-12-13"], emphasis: cut, weight: [163, 154] }
      - { n: 1, dates: ["2026-12-14", "2027-01-03"], emphasis: reverse, weight: [154, 155] }
''';

Future<String?> _fetch(String path) async => switch (path) {
  'coach/phase.yaml' => _phaseYaml,
  'coach/program.yaml' => _programYaml,
  _ => null,
};

/// 162 at Sep 21, dropping 0.3 lb/day → well below a −0.75 lb/wk line.
List<Record> _weighIns() => [
  for (var i = 0; i < 20; i++)
    {
      'date': DateTime(2026, 9, 16).add(Duration(days: i)),
      'weight_lbs': 163.5 - i * 0.3,
      'body_fat_withing': 12.5,
    },
];

List<Record> _strength() => [
  {
    'date': DateTime(2026, 9, 28),
    'exercise': 'Barbell Squat',
    'weight': 300,
    'reps': 1,
    'rpe': 8,
  }, // e1RM 330
  {
    'date': DateTime(2026, 9, 29),
    'exercise': 'Flat Barbell Bench Press',
    'weight': 225,
    'reps': 1,
    'rpe': 8,
  }, // 247.5
  {
    'date': DateTime(2026, 9, 30),
    'exercise': 'Barbell Deadlift',
    'weight': 305,
    'reps': 1,
    'rpe': 8,
  }, // 335.5
];

List<ProjectionPoint> _line(
  double v0,
  double perWeek,
  double band, {
  DateTime? start,
  int weeks = 13,
}) => [
  for (var k = 0; k < weeks; k++)
    ProjectionPoint(
      (start ?? DateTime.utc(2026, 9, 21)).add(Duration(days: 7 * k)),
      v0 + perWeek * k,
      v0 + perWeek * k - band,
      v0 + perWeek * k + band,
    ),
];

ProjectionSnapshot _cutSnapshot() => ProjectionSnapshot(
  block: 0,
  madeAt: DateTime.utc(2026, 10, 2, 23),
  programVersion: '16',
  inputs: const {
    'block_emphasis': 'cut',
    'block_start': '2026-09-21',
    'block_end': '2026-12-13',
  },
  metrics: {
    ProjectionMetric.bodyweight: _line(162.2, -0.75, 1.25),
    ProjectionMetric.bodyFat: _line(12.4, -0.3, 1.0),
    ProjectionMetric.strengthTotal: _line(905, -2, 27),
    ProjectionMetric.e1rmSquat: _line(320, -0.8, 9.6),
    ProjectionMetric.vo2max: _line(52.3, 0.4, 1.0),
  },
);

PlanSources _sources({List<ProjectionSnapshot>? snapshots}) => PlanSources(
  provider: ProgramProvider(_fetch),
  weightRepo: _FakeRepo(_weighIns()),
  weightView: _view('weight'),
  strengthRepo: _FakeRepo(_strength()),
  strengthView: _view('strength'),
  projectionStore: snapshots == null
      ? null
      : ProjectionSnapshotStore.memory(snapshots),
);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data ?? '';

String _chip(WidgetTester tester, String metric) => tester
    .widget<StatusChip>(find.byKey(ValueKey('projection-chip-$metric')))
    .label;

PhaseProjections _projections() => PhaseProjections.fromSnapshots(
  [_cutSnapshot()],
  weighIns: [
    for (final r in _weighIns())
      WeightRow(
        date: r['date'] as DateTime,
        weightLbs: r['weight_lbs'] as double,
      ),
  ],
);

/// A finished cut: weigh-ins through the block's last week (155.8) and
/// an e1RM total at the end (−1.5% vs the 905 start).
PhaseProjections _pastProjections() => PhaseProjections.fromSnapshots(
  [_cutSnapshot()],
  weighIns: [
    for (var i = 0; i < 7; i++)
      WeightRow(date: DateTime(2026, 12, 7 + i), weightLbs: 155.8),
  ],
  strength: [
    StrengthRow(
      date: DateTime(2026, 12, 8),
      exercise: 'Barbell Squat',
      weight: 290,
      reps: 1,
      rpe: 8,
    ), // 319
    StrengthRow(
      date: DateTime(2026, 12, 9),
      exercise: 'Flat Barbell Bench Press',
      weight: 220,
      reps: 1,
      rpe: 8,
    ), // 242
    StrengthRow(
      date: DateTime(2026, 12, 10),
      exercise: 'Barbell Deadlift',
      weight: 309.5,
      reps: 1,
      rpe: 8,
    ), // 340.45
  ],
);

void main() {
  setUp(ProgramProvider.clearCache);

  group('ProjectionCard', () {
    testWidgets('frozen: band + projected + actual lines, chip, one line', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectionCard(
              metric: ProjectionMetric.bodyweight,
              snapshot: _cutSnapshot(),
              projections: _projections(),
              today: _today,
            ),
          ),
        ),
      );
      final chart = tester.widget<LineChart>(
        find.descendant(
          of: find.byKey(const ValueKey('projection-chart-bodyweight')),
          matching: find.byType(LineChart),
        ),
      );
      // lo, hi (band edges), projected, actual.
      expect(chart.data.lineBarsData, hasLength(4));
      expect(chart.data.betweenBarsData, hasLength(1));
      expect(chart.data.lineBarsData[2].dashArray, isNotNull);
      expect(chart.data.lineBarsData[3].spots, isNotEmpty);
      // 7d avg Oct 5 (Sep 29–Oct 5 weigh-ins) ≈ 158.7 vs projected
      // ≈ 160.7 ± 1.25 → below the band in a cut = ahead.
      expect(_chip(tester, 'bodyweight'), 'ahead');
      expect(
        _text(tester, 'projection-line-bodyweight'),
        matches(RegExp(r'^\d+\.\d lb ahead of projection$')),
      );
      expect(
        _text(tester, 'projection-detail-bodyweight'),
        startsWith('Now 15'),
      );
      expect(
        find.byKey(const ValueKey('projection-none-bodyweight')),
        findsNothing,
      );
    });

    testWidgets('no snapshot: live line labelled, "not frozen" chip', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectionCard(
              metric: ProjectionMetric.bodyweight,
              projections: _projections(),
              today: _today,
              liveLine: [
                (DateTime.utc(2026, 10, 12), 160.0),
                (DateTime.utc(2026, 10, 19), 159.0),
              ],
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('projection-none-bodyweight')),
        findsOneWidget,
      );
      expect(find.textContaining('No frozen projection yet'), findsOneWidget);
      expect(_chip(tester, 'bodyweight'), 'not frozen');
      final chart = tester.widget<LineChart>(
        find.descendant(
          of: find.byKey(const ValueKey('projection-chart-bodyweight')),
          matching: find.byType(LineChart),
        ),
      );
      expect(chart.data.betweenBarsData, isEmpty);
    });

    testWidgets('VO2 (no measured source) → "no data" chip', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectionCard(
              metric: ProjectionMetric.vo2max,
              snapshot: _cutSnapshot(),
              projections: _projections(),
              today: _today,
            ),
          ),
        ),
      );
      expect(_chip(tester, 'vo2max'), 'no data');
      expect(_text(tester, 'projection-line-vo2max'), 'No data yet');
    });
  });

  group('pages with a frozen snapshot', () {
    testWidgets('weight page: frozen bodyweight + body fat with chips', (
      tester,
    ) async {
      _tall(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: WeightScreen(
            sources: _sources(snapshots: [_cutSnapshot()]),
            today: _today,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_chip(tester, 'bodyweight'), 'ahead');
      expect(
        find.byKey(const ValueKey('projection-line-body_fat')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('projection-none-bodyweight')),
        findsNothing,
      );
    });

    testWidgets('strength page: frozen strength total tracks the logged '
        'e1RM total', (tester) async {
      _tall(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: StrengthScreen(
            sources: _sources(snapshots: [_cutSnapshot()]),
            today: _today,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 330 + 247.5 + 335.5 = 913 vs ≈ 901 ± 27 → on track.
      expect(_chip(tester, 'strength_total'), 'on track');
      expect(
        _text(tester, 'projection-line-strength_total'),
        contains('vs projection (within range)'),
      );
    });

    testWidgets('lift page: frozen e1RM card + rolling outlook in Model '
        'details', (tester) async {
      _tall(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LiftScreen(
            lift: 'squat',
            summary: const LiftSummary(),
            sources: _sources(snapshots: [_cutSnapshot()]),
            today: _today,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 330 vs ≈ 318.9 ± 9.6 → above the band = ahead.
      expect(_chip(tester, 'e1rm_squat'), 'ahead');
      expect(find.byKey(const ValueKey('lift-projection')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('lift-model-details')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lift-projection')), findsOneWidget);
    });
  });

  group('phase timeline + past-phase view', () {
    final version = {
      'blocks': [
        {
          'n': 0,
          'dates': ['2026-09-21', '2026-12-13'],
          'emphasis': 'cut',
          'weight': [163, 154],
        },
        {
          'n': 1,
          'dates': ['2026-12-14', '2027-01-03'],
          'emphasis': 'reverse',
          'weight': [154, 155],
        },
      ],
    };

    testWidgets('current block row: headline bodyweight tracking', (
      tester,
    ) async {
      int? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockTimeline(
              programVersion: version,
              slice: const ProgramSlice(
                id: 'x',
                version: 16,
                block: {'number': 0},
                weekInBlock: 3,
                weekType: 'normal',
                todayTemplate: {},
                targetsInForce: {},
                rulesInForce: [],
              ),
              today: _today,
              projections: _projections(),
              onOpenBlock: (n) => opened = n,
            ),
          ),
        ),
      );
      expect(
        _text(tester, 'plan-block-tracking-0'),
        matches(RegExp(r'^Bodyweight: \d+\.\d lb ahead of projection$')),
      );
      await tester.tap(find.byKey(const ValueKey('plan-block-0')));
      expect(opened, 0);
    });

    testWidgets('no projections → plain timeline', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockTimeline(
              programVersion: version,
              slice: null,
              today: DateTime(2026, 12, 20),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('plan-block-result-0')), findsNothing);
    });

    testWidgets('past block row: one-line result, tap opens the view', (
      tester,
    ) async {
      int? opened;
      final p = _pastProjections();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockTimeline(
              programVersion: version,
              slice: null,
              today: DateTime(2026, 12, 20),
              projections: p,
              onOpenBlock: (n) => opened = n,
            ),
          ),
        ),
      );
      final result = tester
          .widget<Text>(find.byKey(const ValueKey('plan-block-result-0')))
          .data!;
      // Tracked at the block's last day (Dec 13): projected bw
      // 162.2 − 0.75 × (11 + 6/7) ≈ 153.3; strength 905 → ≈ 881.3
      // projected (−2.6%) vs 901.45 actual (−0.4%).
      expect(
        result,
        'Cut: 162.2 → 155.8 vs projected 153.3; strength −0.4% vs '
        'projected −2.6%',
      );
      await tester.tap(find.byKey(const ValueKey('plan-block-0')));
      expect(opened, 0);
      // Block 1 has no snapshot → no result, not tappable.
      expect(find.byKey(const ValueKey('plan-block-result-1')), findsNothing);
    });

    testWidgets('past-phase view: result line + every frozen metric card', (
      tester,
    ) async {
      _tall(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: PhaseProjectionScreen(
            snapshot: _cutSnapshot(),
            projections: _pastProjections(),
            today: DateTime(2026, 12, 20),
          ),
        ),
      );
      expect(find.text('Block 0 · Cut'), findsOneWidget);
      expect(find.text('RESULT'), findsOneWidget);
      expect(_text(tester, 'phase-projection-result'), startsWith('Cut: '));
      for (final m in [
        'bodyweight',
        'body_fat',
        'strength_total',
        'e1rm_squat',
        'vo2max',
      ]) {
        expect(
          find.byKey(ValueKey('projection-card-$m')),
          findsOneWidget,
          reason: m,
        );
      }
    });
  });
}
