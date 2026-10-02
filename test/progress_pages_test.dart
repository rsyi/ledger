/// IA restructure 2026-10-02 — the Plan tab folded into Progress:
/// 4-tab nav, the Weight / Strength forecast pages, and the per-lift
/// page (e1RM chart, recent top sets, training-max history, projection)
/// with fixture data. The Progress tab's phase timeline + row routing
/// are pinned in home_dashboard_test; 360dp overflow guards for the
/// pages live in readability_overflow_test.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/program_metrics.dart' show StrengthRow;
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/ui/home_tabs.dart';
import 'package:airledger/ui/lift_screen.dart';
import 'package:airledger/ui/plan_data.dart';
import 'package:airledger/ui/strength_screen.dart';
import 'package:airledger/ui/weight_screen.dart';

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

final _today = DateTime(2026, 9, 23);

const _phaseYaml = '''
versions:
  - version: 1
    value: cut
    effective_from: "2025-10-06"
    target_weight_lb: 154
    target_rate_lb_per_week: -0.75
    reason: "hold strength while dropping to 154"
    exit_criteria: "154 lb or Wilks floor breached"
''';

const _programYaml = '''
versions:
  - version: 1
    effective_from: "2026-09-21"
    id: bulk-2026-27
    blocks:
      - { n: 0, dates: ["2026-09-21", "2026-12-13"], emphasis: cut, weight: [163, 154] }
      - { n: 1, dates: ["2026-12-14", "2027-01-31"], emphasis: reverse, weight: [154, 158] }
    targets:
      near_max_sets_wk: 4
''';

Future<String?> _fetch(String path) async => switch (path) {
      'coach/phase.yaml' => _phaseYaml,
      'coach/program.yaml' => _programYaml,
      _ => null,
    };

List<Record> _weighIns() => [
      for (var i = 0; i < 28; i++)
        {
          'date': DateTime(2026, 8, 27).add(Duration(days: i)),
          'weight_lbs': 165.0 - i * (0.75 / 7),
        },
      for (var m = 1; m <= 8; m++)
        {'date': DateTime(2025, m, 15), 'weight_lbs': 180.0 + m},
    ];

List<Record> _strength() => [
      {
        'date': DateTime(2025, 6, 10),
        'exercise': 'Barbell Squat',
        'weight': 315,
        'reps': 2,
      },
      {
        'date': DateTime(2026, 9, 7),
        'exercise': 'Barbell Squat',
        'weight': 295,
        'reps': 3,
        'rpe': 8,
      },
      {
        'date': DateTime(2026, 9, 14),
        'exercise': 'Barbell Squat',
        'weight': 305,
        'reps': 2,
        'rpe': 8.5,
      },
      // Sep 21: a warm-up + the top set — the session's best is the top.
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Barbell Squat',
        'weight': 225,
        'reps': 5,
        'rpe': 5,
      },
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Barbell Squat',
        'weight': 300,
        'reps': 1,
        'rpe': 8,
      },
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Flat Barbell Bench Press',
        'weight': 200,
        'reps': 1,
        'rpe': 8,
      },
      {
        'date': DateTime(2026, 9, 22),
        'exercise': 'Barbell Deadlift',
        'weight': 315,
        'reps': 1,
        'rpe': 8,
      },
    ];

PlanSources _sources() => PlanSources(
      provider: ProgramProvider(_fetch),
      weightRepo: _FakeRepo(_weighIns()),
      weightView: _view('weight'),
      strengthRepo: _FakeRepo(_strength()),
      strengthView: _view('strength'),
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(ProgramProvider.clearCache);

  test('nav: four tabs — Today · Log · Week · Progress; no Plan', () {
    expect(HomeTabs.count, 4);
    expect(homeNavDestinations, hasLength(HomeTabs.count));
    expect([for (final d in homeNavDestinations) d.label],
        ['Today', 'Log', 'Week', 'Progress']);
    expect(homeNavDestinations[HomeTabs.today].label, 'Today');
    expect(homeNavDestinations[HomeTabs.log].label, 'Log');
    expect(homeNavDestinations[HomeTabs.week].label, 'Week');
    expect(homeNavDestinations[HomeTabs.progress].label, 'Progress');
  });

  testWidgets('weight page: verdict in plain words, bodyweight trajectory, '
      'nutrition card, body fat, phase notes — no target headline',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(MaterialApp(
      home: WeightScreen(sources: _sources(), today: _today),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Weight'), findsOneWidget); // app bar
    expect(find.byKey(const ValueKey('weight-verdict')), findsOneWidget);
    expect(
      find.textContaining('Declared cut (target −0.75 lb/week)'),
      findsOneWidget,
    );
    // Frozen phase projections lead (no snapshot store here → the
    // live-model fallback, labelled); the rolling outlook sits in Model
    // details.
    expect(find.byKey(const ValueKey('projection-card-bodyweight')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('projection-none-bodyweight')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('projection-card-body_fat')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('nutrition-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('nutrition-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim2-bw-chart')), findsNothing);
    expect(find.byKey(const ValueKey('forecast-model-details')),
        findsOneWidget);
    expect(find.text('ABOUT THIS PHASE'), findsOneWidget);
    expect(find.text('Exit: 154 lb or Wilks floor breached'), findsOneWidget);
    expect(find.textContaining('Target 154'), findsNothing);
  });

  testWidgets('strength page: weekly Wilks decomposition, projection + '
      'capacity toggle, folds, model details', (tester) async {
    _tall(tester);
    await tester.pumpWidget(MaterialApp(
      home: StrengthScreen(sources: _sources(), today: _today),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Strength'), findsOneWidget); // app bar
    expect(find.byKey(const ValueKey('weekly-wilks')), findsOneWidget);
    expect(find.textContaining('Wilks '), findsWidgets);
    expect(find.text('Squat 300 lb'), findsOneWidget);
    expect(find.text('Bench 200 lb'), findsOneWidget);
    expect(find.text('Deadlift 315 lb'), findsOneWidget);
    expect(find.textContaining(' points'), findsNWidgets(3));
    expect(find.byKey(const ValueKey('projection-card-strength_total')),
        findsOneWidget);
    // The rolling outlook ("Staying on this program, by …") moved into
    // Model details (collapsed).
    expect(find.byKey(const ValueKey('sim2-summary')), findsNothing);
    expect(find.text('Model details'), findsOneWidget);
    expect(find.text('Climbing'), findsOneWidget);
    expect(find.text('VO2 max'), findsOneWidget);
    expect(find.text('Fatigue budget'), findsOneWidget);
  });

  group('lift page', () {
    final wm = (
      workingMax: [
        WorkingMaxRow(
          lift: 'squat',
          variant: 'belted',
          valueLb: 320,
          effectiveFrom: DateTime(2026, 9, 21),
          source: 'seed',
          reason: 'starting value',
        ),
        WorkingMaxRow(
          lift: 'bench',
          variant: 'paused',
          valueLb: 245,
          effectiveFrom: DateTime(2026, 9, 21),
          source: 'manual',
          reason: '',
        ),
        WorkingMaxRow(
          lift: 'squat',
          variant: 'belted',
          valueLb: 315,
          effectiveFrom: DateTime(2026, 9, 22),
          source: 'rule',
          reason: 'median of 5 top sets',
        ),
      ],
      readings: const <ReadingRow>[],
    );

    Future<void> pumpLift(WidgetTester tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(
        home: LiftScreen(
          lift: 'squat',
          summary: LiftSummary(
            recent: (value: 310, date: DateTime(2026, 9, 21), wilks: 95.2),
            lastBulk: (value: 315, date: DateTime(2025, 6, 10), wilks: 86.0),
            best: (value: 315, date: DateTime(2025, 6, 10), wilks: 86.0),
            bulkWindow: (
              start: DateTime(2025, 2, 5),
              end: DateTime(2025, 10, 6),
              label: '2025 bulk',
            ),
            currentBwLbs: 162.1,
          ),
          sources: _sources(),
          wmSnapshot: () async => wm,
          today: _today,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('now card, e1RM chart with cut/bulk shading, recent top '
        'sets, training-max history, projection, explainer text',
        (tester) async {
      await pumpLift(tester);
      expect(find.text('Squat'), findsOneWidget); // app bar

      // NOW: the Progress numbers, in words.
      expect(find.text('Recent estimated max'), findsOneWidget);
      expect(find.text('310 lb'), findsOneWidget);
      expect(find.text('Last bulk best'), findsOneWidget);
      expect(find.textContaining('change −5 lb'), findsOneWidget);
      expect(find.text('All-time best'), findsOneWidget);

      // Chart: one point per session — the default 1-year window holds
      // the three 2026 squat days — with cut + bulk shading.
      final chart = tester.widget<LineChart>(
        find.byKey(const ValueKey('lift-e1rm-chart')),
      );
      expect(chart.data.lineBarsData.single.spots, hasLength(3));
      expect(chart.data.rangeAnnotations.verticalRangeAnnotations,
          hasLength(2));
      expect(find.byKey(const ValueKey('lift-phase-legend')), findsOneWidget);
      expect(find.text('cut period'), findsOneWidget);
      expect(find.text('bulk period'), findsOneWidget);

      // Recent top sets: newest first, the Sep 21 top set (not the
      // warm-up), with RPE and its e1RM (300×1 @8 → 300×3 → 330).
      expect(find.text('RECENT TOP SETS'), findsOneWidget);
      expect(find.textContaining('Mon Sep 21', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('300 lb × 1 · RPE 8', findRichText: true),
          findsOneWidget);
      expect(find.text('330 lb'), findsOneWidget);
      expect(find.textContaining('225 lb × 5', findRichText: true),
          findsNothing);

      // Training max: current + history for THIS lift only, newest first,
      // plain source words.
      expect(find.text('TRAINING MAX'), findsOneWidget);
      expect(
        find.textContaining('Now 315 lb, since Sep 22, 2026'),
        findsOneWidget,
      );
      expect(find.textContaining('Sep 22, 2026 · auto', findRichText: true),
          findsOneWidget);
      expect(
        find.textContaining('Sep 21, 2026 · starting value',
            findRichText: true),
        findsOneWidget,
      );
      expect(find.text('median of 5 top sets'), findsOneWidget);
      expect(find.textContaining('245 lb', findRichText: true), findsNothing);
      final tmTop = tester.getTopLeft(find.text('median of 5 top sets')).dy;
      final tmOld = tester.getTopLeft(find.text('starting value')).dy;
      expect(tmTop, lessThan(tmOld));

      // Projection for this lift: the frozen card (live fallback here —
      // no snapshot store), the rolling outlook behind Model details.
      expect(find.text('PROJECTION'), findsOneWidget);
      expect(find.byKey(const ValueKey('projection-card-e1rm_squat')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lift-model-details')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lift-projection')))
            .data,
        matches(RegExp(r"^Squat \d+ lb by \w{3} \d+ '\d\d$")),
      );
      expect(find.textContaining('at the end of this cut block'),
          findsOneWidget);

      // Explanations as small text at the bottom — no info icon.
      expect(find.byKey(const ValueKey('lift-explainer')), findsOneWidget);
      expect(find.textContaining('Reps in reserve (10 − RPE) count as reps',
          findRichText: true), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsNothing);
    });
  });

  group('lift helpers', () {
    test('liftSessionTops: per-day best by RPE-adjusted e1RM, other lifts '
        'and empty sets dropped, date-ascending', () {
      final rows = [
        StrengthRow(
            date: DateTime(2026, 9, 21, 18),
            exercise: 'Barbell Squat',
            weight: 225,
            reps: 5,
            rpe: 5),
        StrengthRow(
            date: DateTime(2026, 9, 21, 18, 30),
            exercise: 'Barbell Squat',
            weight: 300,
            reps: 1,
            rpe: 8),
        StrengthRow(
            date: DateTime(2026, 9, 14),
            exercise: 'Barbell Squat',
            weight: 305,
            reps: 2,
            rpe: 8.5),
        StrengthRow(
            date: DateTime(2026, 9, 14),
            exercise: 'Barbell Deadlift',
            weight: 400,
            reps: 1),
        StrengthRow(
            date: DateTime(2026, 9, 10),
            exercise: 'Barbell Squat',
            weight: 0,
            reps: 5),
      ];
      final tops = liftSessionTops(rows, 'squat');
      expect(tops, hasLength(2));
      expect(tops.first.date, DateTime(2026, 9, 14));
      expect(tops.last.weight, 300);
      expect(tops.last.e1rm, closeTo(330, 0.01));
    });

    test('liftPhaseSpans: phase versions run to the next one / today; the '
        'last-bulk window adds a bulk span', () {
      final spans = liftPhaseSpans(
        {
          'versions': [
            {'value': 'cut', 'effective_from': '2025-10-06'},
            {
              'value': 'reverse',
              'effective_from': '2026-12-14',
              'pending': true,
            },
          ],
        },
        (start: DateTime(2025, 2, 5), end: DateTime(2025, 10, 6), label: 'b'),
        _today,
      );
      expect(spans, hasLength(2));
      expect(spans.first.kind, 'bulk');
      expect(spans.last.kind, 'cut');
      expect(spans.last.end, _today);
    });
  });
}
