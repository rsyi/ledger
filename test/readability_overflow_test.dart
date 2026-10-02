/// Readability-pass no-overflow guards for the DOMAIN and PROGRAM
/// surfaces (app-wide AppText sweep, 2026-09-25 — companion to the
/// home-surface tests in home_dashboard_test.dart).
///
/// The pass raised primary values to 16sp and floored everything else
/// at 12sp; the layout rule is REFLOW over ellipsis. These tests pump
/// the two dense non-home surfaces at a narrow 360dp phone width —
/// any RenderFlex overflow fails the test through the standard
/// FlutterError reporter, so "reaching the expects" IS the assertion.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/domain_config.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/domain_screen.dart';
import 'package:airledger/ui/plan_screen.dart';
import 'package:airledger/ui/program_screen.dart';

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
      dimensions: [
        Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
      ],
      readOnly: true,
    );

/// ~4 weeks of declining weigh-ins plus a bulk-era point — enough for
/// 7-day averages, rates, and the Wilks bodyweight reference.
List<Record> _weighIns() => [
      for (var i = 0; i < 28; i++)
        {
          'date': DateTime(2026, 8, 27).add(Duration(days: i)),
          'weight_lbs': 165.0 - i * (0.75 / 7),
        },
      {'date': DateTime(2025, 6, 5), 'weight_lbs': 184.0},
    ];

List<Record> _strengthRows() => [
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Barbell Squat',
        'weight': 300,
        'reps': 1,
        'rpe': 8,
      },
      {
        'date': DateTime(2026, 9, 18),
        'exercise': 'Barbell Bench Press',
        'weight': 225,
        'reps': 3,
        'rpe': 8.5,
      },
      {
        'date': DateTime(2025, 6, 10),
        'exercise': 'Barbell Deadlift',
        'weight': 405,
        'reps': 2,
        'rpe': 9,
      },
    ];

void _sizeAt(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  const phaseYaml = '''
versions:
  - version: 1
    value: cut
    effective_from: "2025-10-06"
    target_weight_lb: 154
    target_rate_lb_per_week: -0.75
    reason: "hold strength while dropping to 154"
    exit_criteria: "154 lb or Wilks floor breached"
''';
  const programYaml = '''
versions:
  - version: 1
    effective_from: "2026-09-21"
    id: bulk-2026-27
    blocks:
      - { n: 0, dates: ["2026-09-21", "2026-12-13"], emphasis: cut, weight: [163, 154], target_weight: [163, 154] }
    targets:
      near_max_sets_wk: 4
''';
  const dashboardsYaml = '''
domains:
  - name: strength
    views: [strength]
    metrics:
      - id: wilks_series
        kind: series
        label: Wilks (monthly)
        from: "2026-09-21"
        floor_pct: 2.5
        window_years: 4
''';

  testWidgets(
      'domain screen (headline strip, record list, Trends charts) '
      'reflows without overflow at 360dp', (tester) async {
    DomainConfigProvider.clearCache();
    _sizeAt(tester, const Size(360, 690));

    // Integration-paradigm strength-flavored domain: exercises the
    // headline strip (16sp values beside the Log/Trends toggle), the
    // date-grouped record list, and the Trends metric dashboard with
    // stat chips + a full-height chart.
    const domain = DomainConfig(
      name: 'strength',
      paradigm: DomainParadigm.integration,
      views: ['strength'],
      metrics: [
        MetricConfig(id: 'e1rm_reference', lifts: ['squat', 'bench']),
        MetricConfig(id: 'wilks'),
        MetricConfig(
          id: 'wilks_series',
          kind: MetricKind.series,
          label: 'Wilks (monthly)',
          floorPct: 2.5,
        ),
      ],
      listFields: [
        DomainListField(field: 'exercise'),
        DomainListField(field: 'weight', unit: 'lb'),
        DomainListField(field: 'reps'),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: DomainScreen(
        domain: domain,
        view: _view('strength'),
        repository: _FakeRepo(_strengthRows()),
        weightView: _view('weight'),
        weightRepository: _FakeRepo(_weighIns()),
        today: DateTime(2026, 9, 23),
      ),
    ));
    await tester.pumpAndSettle();

    // Records mode rendered: day heading + record line + mode toggle.
    expect(find.text('Trends'), findsOneWidget);
    expect(
      find.textContaining('Barbell Squat', findRichText: true),
      findsWidgets,
    );

    // Toggle to Trends: full metric dashboard (chips + chart) must
    // also hold at 360dp.
    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();
    expect(find.text('WILKS (MONTHLY)'), findsOneWidget);
    // Reaching here without a RenderFlex overflow report = pass.
  });

  testWidgets(
      'plan screen (declared/blocks/progress/verdict) '
      'reflows without overflow at 360dp', (tester) async {
    ProgramProvider.clearCache();
    DomainConfigProvider.clearCache();
    _sizeAt(tester, const Size(360, 690));

    Future<String?> fetcher(String path) async => switch (path) {
          'coach/phase.yaml' => phaseYaml,
          'coach/program.yaml' => programYaml,
          'app/dashboards.yaml' => dashboardsYaml,
          _ => null,
        };

    await tester.pumpWidget(MaterialApp(
      home: PlanScreen(
        provider: ProgramProvider(fetcher),
        weightRepo: _FakeRepo(_weighIns()),
        weightView: _view('weight'),
        strengthRepo: _FakeRepo(_strengthRows()),
        strengthView: _view('strength'),
        today: DateTime(2026, 9, 23),
      ),
    ));
    await tester.pumpAndSettle();

    // Top sections up at 360dp, plain-language summary FIRST (UI
    // redesign phase 6): verdict above the phase card + block timeline
    // (the "You are here" row wraps instead of overflowing).
    expect(find.text('VERDICT'), findsOneWidget);
    expect(find.text('PHASE'), findsOneWidget);
    expect(tester.getTopLeft(find.text('VERDICT')).dy,
        lessThan(tester.getTopLeft(find.text('PHASE')).dy));
    expect(find.textContaining('You are here'), findsOneWidget);

    // Scroll the rest of the lazy ListView into layout — projection
    // summary, strength chart, nutrition card, folds, the Model details
    // disclosure — so every section gets overflow-checked at this width.
    await tester.dragUntilVisible(
      find.text('Model details'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Model details'), findsOneWidget);
    // Reaching here without a RenderFlex overflow report = pass.
  });

  testWidgets(
      'program (routine) screen — header, day tiles, session rows '
      'reflow without overflow at 360dp', (tester) async {
    ProgramProvider.clearCache();
    _sizeAt(tester, const Size(360, 690));

    Future<String?> fetcher(String path) async => switch (path) {
          'coach/phase.yaml' => phaseYaml,
          'coach/program.yaml' => programYaml,
          _ => null,
        };

    await tester.pumpWidget(MaterialApp(
      home: ProgramScreen(
        provider: ProgramProvider(fetcher),
        strengthRepo: _FakeRepo(_strengthRows()),
        strengthView: _view('strength'),
        today: DateTime(2026, 9, 23),
      ),
    ));
    await tester.pumpAndSettle();

    // Header card with the week range + day tiles.
    expect(find.textContaining('Block 0'), findsOneWidget);
    expect(find.text('Mon'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Sun'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    // Reaching here without a RenderFlex overflow report = pass.
  });
}
