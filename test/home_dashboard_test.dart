import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/domain_config.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/home_dashboard.dart';

/// Serves canned program_status rows. No network.
class _FakeStatusRepo implements WarehouseConnector {
  final List<Record> rows;
  _FakeStatusRepo(this.rows);

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      rows;
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

final _statusView = ViewSchema(
  name: 'program_status',
  datasource: 'gsheets',
  table: 'program_status',
  entities: const [],
  measures: const [],
  dimensions: [
    Dimension(
        name: 'week_monday', type: DimensionType.date, expr: 'week_monday'),
  ],
);

final _strengthView = ViewSchema(
  name: 'strength',
  datasource: 'gsheets',
  table: 'strength',
  entities: const [],
  measures: const [],
  dimensions: [
    Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
  ],
);

final _weightView = ViewSchema(
  name: 'weight',
  datasource: 'gsheets',
  table: 'weight',
  entities: const [],
  measures: const [],
  dimensions: [
    Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
  ],
);

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  ProgramProvider.clearCache();

  testWidgets('renders nothing when no progress plumbing is configured',
      (tester) async {
    await tester.pumpWidget(_wrap(const HomeDashboard()));
    await tester.pumpAndSettle();
    expect(find.text('BODY'), findsNothing);
  });

  testWidgets('degrades to placeholders when every source is offline',
      (tester) async {
    // A provider whose fetcher always throws — docs resolve to null.
    final provider = ProgramProvider((_) async => throw Exception('offline'));
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: provider,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    // All four cards render their skeletons with graceful placeholders.
    expect(find.text('BODY'), findsOneWidget);
    expect(find.text('STRENGTH'), findsOneWidget);
    expect(find.text('EXECUTION'), findsOneWidget);
    expect(find.text('ENGINE'), findsOneWidget);
    expect(find.text('no weigh-in data'), findsOneWidget);
    expect(find.text('no strength data yet'), findsOneWidget);
    expect(find.text('no status data'), findsNWidgets(2));
  });

  testWidgets('STRENGTH renders recent-e1RM vs all-time-top columns with '
      'wilks points and age tags; working max is gone', (tester) async {
    HomeDashboardState.clearBestE1rmCache();
    final strengthRepo = _FakeStatusRepo([
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Barbell Squat',
        'weight': 300,
        'reps': 1, // e1rm 310 — recent (2d old at `today`)
      },
      {
        'date': DateTime(2025, 1, 6),
        'exercise': 'Barbell Squat',
        'weight': 320,
        'reps': 1, // e1rm ~330.7 — all-time top, long outside the window
      },
    ]);
    // Current bw: 7-day mean 165 (Sep 17–23). Contemporaneous bw for
    // the Jan '25 PR: that month's mean, (174+176)/2 = 175.
    final weightRepo = _FakeStatusRepo([
      for (var i = 17; i <= 23; i++)
        {'date': DateTime(2026, 9, i), 'weight_lbs': 165.0},
      {'date': DateTime(2025, 1, 2), 'weight_lbs': 174.0},
      {'date': DateTime(2025, 1, 28), 'weight_lbs': 176.0},
    ]);
    await tester.pumpWidget(_wrap(HomeDashboard(
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      weightView: _weightView,
      weightRepo: weightRepo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    // Two columns only (2026-09-22 rebuild) + the basis tag; the
    // working-max column moved to Program › Configuration.
    expect(find.text('recent e1RM'), findsOneWidget);
    expect(find.text('all-time top'), findsOneWidget);
    expect(find.text('working max'), findsNothing);
    expect(find.text('e1RM basis'), findsOneWidget);
    // Cells: lb · wilks (current bw 165 / contemporaneous bw 175) · age.
    // wilksPointsLb(310, 165) = 120.04…; wilksPointsLb(330.67, 175) =
    // 123.44… (independently computed in wilks_test.dart).
    expect(
      find.textContaining('310 · 120.0w · 2d', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('331 · 123.4w · 21mo', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('tapping a card opens its detail sheet; Open action present',
      (tester) async {
    HomeDashboardState.clearBestE1rmCache();
    final repo = _FakeStatusRepo([
      {
        'week_monday': DateTime(2026, 9, 21),
        'working_sets': 14,
        'near_max_sets': 3,
        'bench_days': 1,
        'flags': 'NEAR_MAX_LOW',
      },
    ]);
    var openedStatus = false;
    await tester.pumpWidget(_wrap(HomeDashboard(
      statusView: _statusView,
      statusRepo: repo,
      onOpenStatus: () => openedStatus = true,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('EXECUTION'));
    await tester.pumpAndSettle();
    // Detail sheet: definitions + current values + flags.
    expect(
      find.textContaining('sets at ≥ 80% of your reference e1RM'),
      findsOneWidget,
    );
    expect(find.textContaining('heavy quota'), findsOneWidget);
    expect(find.text('NEAR_MAX_LOW'), findsOneWidget);
    // The onward action navigates only from the sheet.
    await tester.tap(find.text('Open status ledger'));
    await tester.pumpAndSettle();
    expect(openedStatus, isTrue);
  });

  testWidgets('STRENGTH detail sheet explains the two columns, both wilks '
      'bases, and where the working max went', (tester) async {
    HomeDashboardState.clearBestE1rmCache();
    await tester.pumpWidget(_wrap(HomeDashboard(
      strengthView: _strengthView,
      strengthRepo: _FakeStatusRepo([
        {
          'date': DateTime(2026, 9, 21),
          'exercise': 'Barbell Squat',
          'weight': 300,
          'reps': 1,
        },
      ]),
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STRENGTH'));
    await tester.pumpAndSettle();
    // Column labels appear in the card header AND the sheet.
    expect(find.text('recent e1RM'), findsNWidgets(2));
    expect(find.text('all-time top'), findsNWidgets(2));
    // The copy explains each number's semantics + the wilks pricing.
    expect(
      find.textContaining('last 14 days of real work'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Wilks points at your current bodyweight'),
      findsOneWidget,
    );
    expect(find.textContaining('contemporaneous'), findsOneWidget);
    expect(find.textContaining('reps capped at'), findsOneWidget);
    // Both wilks bases are called out (chart = actual-max, card = e1RM).
    expect(find.textContaining('ACTUAL-MAX basis'), findsOneWidget);
    // Working max: no column, just the pointer to its new home.
    expect(find.text('working max'), findsOneWidget); // sheet entry only
    expect(find.text('Program › Configuration'), findsOneWidget);
    expect(
      find.textContaining('Program tab\'s Configuration card'),
      findsOneWidget,
    );
  });

  testWidgets('EXECUTION/ENGINE render status-row numbers and flag chip',
      (tester) async {
    ProgramProvider.clearCache();
    final repo = _FakeStatusRepo([
      {
        'week_monday': DateTime(2026, 9, 21),
        'working_sets': 14,
        'near_max_sets': 3,
        'bench_days': 1,
        'climbing_sessions': 1,
        'bike_4x4_count': 1,
        'bike_4x4_max_hr': 191,
        'flags': 'NEAR_MAX_LOW,WORKING_LOW',
      },
    ]);
    await tester.pumpWidget(_wrap(HomeDashboard(
      statusView: _statusView,
      statusRepo: repo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    expect(find.text('14/—'), findsOneWidget); // no targets without docs
    expect(find.text('2 ⚑'), findsOneWidget);
    expect(find.textContaining('4x4 max HR 191'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // PHASE hero (dashboards.yaml `phases:` section)
  // -------------------------------------------------------------------------

  const phaseYaml = '''
versions:
  - version: 1
    value: cut
    effective_from: "2025-10-06"
    target_weight_lb: 154
    target_rate_lb_per_week: -0.75
''';

  const programYaml = '''
versions:
  - version: 1
    effective_from: "2026-09-21"
    id: bulk-2026-27
    blocks:
      - { n: 0, dates: ["2026-09-21", "2026-12-13"], emphasis: cut, weight: [163, 154] }
    targets:
      near_max_sets_wk: 4
''';

  const dashYamlWithPhases = '''
domains:
  - name: strength
    views: [strength]
phases:
  cut:
    eigenvectors:
      - id: weight_loss
        label: weight
        rate_band: [-1.0, -0.5]
        act_above: 0.2
      - id: wilks_stability
        label: strength
        from: "2026-09-21"
        floor_pct: 2.5
''';

  Future<String?> fetcher(String path) async => switch (path) {
        'coach/phase.yaml' => phaseYaml,
        'coach/program.yaml' => programYaml,
        'app/dashboards.yaml' => dashYamlWithPhases,
        _ => null,
      };

  testWidgets('PHASE hero renders from phases config; grid condenses to '
      'STRENGTH + THIS WEEK', (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestE1rmCache();
    // Weigh-ins declining ~0.75 lb/wk into Sep 23 — cut on pace.
    final weightRepo = _FakeStatusRepo([
      for (var i = 0; i < 28; i++)
        {
          'date': DateTime(2026, 8, 27).add(Duration(days: i)),
          'weight_lbs': 165.0 - i * (0.75 / 7),
        },
    ]);
    final weightView = ViewSchema(
      name: 'weight',
      datasource: 'gsheets',
      table: 'weight',
      entities: const [],
      measures: const [],
      dimensions: [
        Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
      ],
    );
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(fetcher),
      dashboards: DomainConfigProvider(fetcher),
      weightView: weightView,
      weightRepo: weightRepo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();

    // Hero header + eigenvector rows.
    expect(find.text('CUT'), findsOneWidget);
    expect(find.textContaining('block 0'), findsOneWidget);
    expect(find.textContaining('163 → 154 lb by Dec 13'), findsOneWidget);
    expect(find.text('WEIGHT'), findsOneWidget);
    expect(find.text('STRENGTH'), findsNWidgets(2)); // hero row + card label
    expect(find.text('ON TRACK'), findsOneWidget); // weight on pace
    // No strength rows served → Wilks row is unknown, not an error.
    expect(find.textContaining('no Wilks history'), findsOneWidget);
    expect(find.textContaining('target -0.75'), findsOneWidget);

    // Condensed layout: BODY / EXECUTION / ENGINE cards are gone,
    // replaced by the merged THIS WEEK strip.
    expect(find.text('BODY'), findsNothing);
    expect(find.text('EXECUTION'), findsNothing);
    expect(find.text('ENGINE'), findsNothing);
    expect(find.text('THIS WEEK'), findsOneWidget);
  });

  testWidgets('hero weight row taps through to the Program screen',
      (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestE1rmCache();
    var openedProgram = false;
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(fetcher),
      dashboards: DomainConfigProvider(fetcher),
      onOpenProgram: () => openedProgram = true,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WEIGHT'));
    expect(openedProgram, isTrue);
  });

  testWidgets('no phases section → legacy four-card grid unchanged',
      (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestE1rmCache();
    Future<String?> noPhases(String path) async => switch (path) {
          'coach/phase.yaml' => phaseYaml,
          'coach/program.yaml' => programYaml,
          'app/dashboards.yaml' => 'domains:\n  - name: s\n    views: [s]\n',
          _ => null,
        };
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(noPhases),
      dashboards: DomainConfigProvider(noPhases),
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    expect(find.text('BODY'), findsOneWidget);
    expect(find.text('STRENGTH'), findsOneWidget);
    expect(find.text('EXECUTION'), findsOneWidget);
    expect(find.text('ENGINE'), findsOneWidget);
    expect(find.text('THIS WEEK'), findsNothing);
  });
}
