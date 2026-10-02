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
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/ui/lift_screen.dart';
import 'package:airledger/ui/plan_data.dart';
import 'package:airledger/ui/strength_screen.dart';
import 'package:airledger/ui/weight_screen.dart';
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

  Future<String?> planFetcher(String path) async => switch (path) {
        'coach/phase.yaml' => phaseYaml,
        'coach/program.yaml' => programYaml,
        'app/dashboards.yaml' => dashboardsYaml,
        _ => null,
      };

  PlanSources sources() => PlanSources(
        provider: ProgramProvider(planFetcher),
        weightRepo: _FakeRepo(_weighIns()),
        weightView: _view('weight'),
        strengthRepo: _FakeRepo(_strengthRows()),
        strengthView: _view('strength'),
      );

  // IA restructure 2026-10-02: the Plan tab's content now lives on the
  // Weight / Strength pages (+ the Progress tab's phase timeline, pinned
  // in home_dashboard_test). Same 360dp no-overflow guarantee.
  testWidgets(
      'weight page (verdict, bodyweight trajectory, nutrition, body '
      'composition, phase notes) reflows without overflow at 360dp',
      (tester) async {
    ProgramProvider.clearCache();
    _sizeAt(tester, const Size(360, 690));
    await tester.pumpWidget(MaterialApp(
      home: WeightScreen(sources: sources(), today: DateTime(2026, 9, 23)),
    ));
    await tester.pumpAndSettle();

    // Verdict first (plain words), the phase name + since date in its
    // header; no "Target 154 lb" headline anywhere.
    expect(find.text('VERDICT'), findsOneWidget);
    expect(find.text('Cut · since Oct 6, 2025'), findsOneWidget);
    expect(find.textContaining('Target 154 lb'), findsNothing);
    expect(find.text('BODYWEIGHT'), findsOneWidget);
    expect(find.byKey(const ValueKey('sim2-bw-chart')), findsOneWidget);
    for (final banned in ['wks', 'lb/wk', 'SBD', 'OHP']) {
      expect(find.textContaining(banned, findRichText: true), findsNothing,
          reason: banned);
    }
    // Strength-only sections stay on the Strength page.
    expect(find.byKey(const ValueKey('sim2-expressed-chart')), findsNothing);
    expect(find.text('Model details'), findsNothing);

    await tester.dragUntilVisible(
      find.byKey(const ValueKey('phase-exit')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nutrition-card')), findsOneWidget);
    expect(find.text('Exit: 154 lb or Wilks floor breached'), findsOneWidget);
    // Reaching here without a RenderFlex overflow report = pass.
  });

  testWidgets(
      'strength page (weekly Wilks, projection, folds, model details) '
      'reflows without overflow at 360dp', (tester) async {
    ProgramProvider.clearCache();
    _sizeAt(tester, const Size(360, 690));
    await tester.pumpWidget(MaterialApp(
      home: StrengthScreen(sources: sources(), today: DateTime(2026, 9, 23)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('PROJECTION'), findsOneWidget);
    expect(find.byKey(const ValueKey('sim2-summary')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim2-capacity-toggle')),
        findsOneWidget);
    // The weight lever lives on the Weight page.
    expect(find.byKey(const ValueKey('nutrition-card')), findsNothing);
    await tester.dragUntilVisible(
      find.text('Model details'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Model details'), findsOneWidget);
    expect(find.text('Fatigue budget'), findsOneWidget);
    // Reaching here without a RenderFlex overflow report = pass.
  });

  testWidgets(
      'lift page (now, e1RM chart, top sets, training max, projection) '
      'reflows without overflow at 360dp', (tester) async {
    ProgramProvider.clearCache();
    _sizeAt(tester, const Size(360, 690));
    await tester.pumpWidget(MaterialApp(
      home: LiftScreen(
        lift: 'squat',
        summary: LiftSummary(
          recent: (value: 340, date: DateTime(2026, 9, 21), wilks: 98.4),
          lastBulk: (value: 315, date: DateTime(2025, 6, 10), wilks: 85.1),
          best: (value: 405, date: DateTime(2024, 3, 1), wilks: 110.2),
          bulkWindow: (
            start: DateTime(2025, 2, 5),
            end: DateTime(2025, 10, 6),
            label: '2025 bulk',
          ),
          currentBwLbs: 162.4,
        ),
        sources: sources(),
        wmSnapshot: () async => (
              workingMax: [
                WorkingMaxRow(
                  lift: 'squat',
                  variant: 'belted',
                  valueLb: 320,
                  effectiveFrom: DateTime(2026, 9, 21),
                  source: 'seed',
                  reason: 'starting value from the September readings',
                ),
              ],
              readings: const <ReadingRow>[],
            ),
        today: DateTime(2026, 9, 23),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lift-now')), findsOneWidget);
    expect(find.byKey(const ValueKey('lift-e1rm-chart')), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('lift-explainer')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lift-explainer')), findsOneWidget);
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
