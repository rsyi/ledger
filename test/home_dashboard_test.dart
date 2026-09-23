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

  // dashboards.yaml with the explicit last-bulk window (start derived
  // from the weigh-in trough; no `phases:` → the legacy grid renders).
  Future<String?> lastBulkFetcher(String path) async =>
      path == 'app/dashboards.yaml'
          ? '''
domains:
  - name: strength
    views: [strength]
last_bulk:
  start: "2025-02-05"
  end: "2025-10-06"
  label: "2025 bulk"
'''
          : null;

  testWidgets('STRENGTH renders recent-e1RM vs last-bulk columns with '
      'wilks points; all-time is off the card', (tester) async {
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
    final strengthRepo = _FakeStatusRepo([
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Barbell Squat',
        'weight': 300,
        'reps': 1, // e1rm 310 — recent (2d old at `today`)
      },
      {
        'date': DateTime(2025, 6, 10),
        'exercise': 'Barbell Squat',
        'weight': 315,
        'reps': 2, // actual 315 — the last-bulk top (inside the window)
      },
      {
        'date': DateTime(2025, 1, 6),
        'exercise': 'Barbell Squat',
        'weight': 320,
        'reps': 1, // actual 320 — all-time top, BEFORE the bulk window
      },
    ]);
    // Current bw: 7-day mean 165 (Sep 17–23). Contemporaneous bw for
    // the Jun '25 bulk top: (184+186)/2 = 185; for the Jan '25
    // all-time top: (174+176)/2 = 175.
    final weightRepo = _FakeStatusRepo([
      for (var i = 17; i <= 23; i++)
        {'date': DateTime(2026, 9, i), 'weight_lbs': 165.0},
      {'date': DateTime(2025, 6, 5), 'weight_lbs': 184.0},
      {'date': DateTime(2025, 6, 20), 'weight_lbs': 186.0},
      {'date': DateTime(2025, 1, 2), 'weight_lbs': 174.0},
      {'date': DateTime(2025, 1, 28), 'weight_lbs': 176.0},
    ]);
    await tester.pumpWidget(_wrap(HomeDashboard(
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      weightView: _weightView,
      weightRepo: weightRepo,
      dashboards: DomainConfigProvider(lastBulkFetcher),
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    // Two columns (2026-09-22, second rebuild): recent e1RM + the
    // last-bulk top; the all-time top moved to the detail sheet and
    // the working-max column to Program › Configuration.
    expect(find.text('recent e1RM'), findsOneWidget);
    expect(find.text('last bulk'), findsOneWidget);
    expect(find.text('all-time top'), findsNothing);
    expect(find.text('working max'), findsNothing);
    // Basis tag: compact on the card (the recent header already says
    // e1RM); the sheet's basis entry carries the full two-basis note.
    expect(find.text('bulk: actual'), findsOneWidget);
    // Cells: lb · wilks · when. Recent = e1RM (310 = 300×(1+1/30)) at
    // current bw 165 with an AGE tag; last bulk = ACTUAL top inside
    // the window (315 — the 315×2 counts as 315; NOT the 320 all-time,
    // which predates the window) at its contemporaneous Jun-'25 bw 185
    // with a PR-MONTH tag. wilksPointsLb(310, 165) = 120.04…;
    // wilksPointsLb(315, 185) = 113.82… (both independently computed
    // in wilks_test.dart).
    expect(
      find.textContaining('310 · 120.0w · 2d', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining("315 · 113.8w · Jun '25", findRichText: true),
      findsOneWidget,
    );
    // The all-time 320 renders nowhere on the card.
    expect(find.textContaining('320', findRichText: true), findsNothing);
  });

  testWidgets('no last_bulk config → the card renders the single recent '
      'column, no bulk header, no basis tag', (tester) async {
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
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
      // No dashboards provider at all — the pre-last_bulk world.
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    expect(find.text('recent e1RM'), findsOneWidget);
    expect(find.text('last bulk'), findsNothing);
    expect(find.text('bulk: actual'), findsNothing);
    expect(
      find.textContaining('310 · 2d', findRichText: true),
      findsOneWidget, // no weigh-ins served → no wilks tag either
    );
  });

  testWidgets('tapping a card opens its detail sheet; Open action present',
      (tester) async {
    HomeDashboardState.clearBestWeightCache();
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

  testWidgets('STRENGTH detail sheet: last-bulk window explained, the '
      'all-time top now lives HERE (per-lift line above its explainer), '
      'both wilks bases, and where the working max went', (tester) async {
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
    await tester.pumpWidget(_wrap(HomeDashboard(
      strengthView: _strengthView,
      strengthRepo: _FakeStatusRepo([
        {
          'date': DateTime(2026, 9, 21),
          'exercise': 'Barbell Squat',
          'weight': 300,
          'reps': 1,
        },
        {
          'date': DateTime(2025, 6, 10),
          'exercise': 'Barbell Squat',
          'weight': 315,
          'reps': 2,
        },
        {
          'date': DateTime(2025, 1, 6),
          'exercise': 'Barbell Squat',
          'weight': 320,
          'reps': 1,
        },
      ]),
      dashboards: DomainConfigProvider(lastBulkFetcher),
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STRENGTH'));
    await tester.pumpAndSettle();
    // Card columns appear in the header AND the sheet; the all-time
    // top is sheet-only (relegated 2026-09-22 — "relegate all-time to
    // the click-in view").
    expect(find.text('recent e1RM'), findsNWidgets(2));
    expect(find.text('last bulk'), findsNWidgets(2));
    expect(find.text('all-time top'), findsOneWidget);
    // The all-time VALUE line sits in the sheet (no weigh-ins served →
    // no wilks tag), month-tagged like the card's bulk column.
    expect(find.textContaining("squat 320 (Jan '25)"), findsOneWidget);
    expect(find.textContaining("squat 315 (Jun '25)"), findsOneWidget);
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
    // The last-bulk entry names its window + provenance (derived
    // start, user-editable in dashboards.yaml).
    expect(
      find.textContaining('2025 bulk (Feb 5 2025 – Oct 6 2025)'),
      findsOneWidget,
    );
    expect(find.textContaining('derived from the bodyweight trough'),
        findsOneWidget);
    // Actual-weight conventions (405×2 → 405); the basis entry names
    // both bases — recent e1RM = Epley estimate, bulk & all-time =
    // actual, sharing the Wilks trend chart's actual-max basis.
    expect(find.textContaining('ACTUALLY lifted'), findsNWidgets(2));
    expect(find.textContaining('405×2 counts as 405'), findsOneWidget);
    expect(find.textContaining('reps capped at'), findsOneWidget);
    expect(find.textContaining('actual-max basis'), findsOneWidget);
    // The compact tag stays on the card; the sheet's basis entry
    // carries the full two-basis note.
    expect(find.text('bulk: actual'), findsOneWidget);
    expect(find.text('recent: e1RM · bulk & top: actual'), findsOneWidget);
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
    HomeDashboardState.clearBestWeightCache();
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
    HomeDashboardState.clearBestWeightCache();
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

  testWidgets('weekly_drivers → THIS WEEK renders the driver checklist '
      'and the activity tallies are gone', (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
    const dashYamlWithDrivers = '''
$dashYamlWithPhases
    weekly_drivers:
      - id: top_single_per_lift
        label: singles
        lifts: [squat, bench, deadlift, press]
        outcome: "Wilks preserved"
        why: "One heavy single per lift holds neural strength."
      - id: bench_frequency
        label: bench 2x
        target: 2
        outcome: "bench holds"
        why: "Bench detrains fastest."
      - id: climbing_cap
        label: climb
        cap: 2
        outcome: "recovery budget"
        why: "A third session taxes lift recovery."
''';
    Future<String?> driverFetcher(String path) async => switch (path) {
          'coach/phase.yaml' => phaseYaml,
          'coach/program.yaml' => programYaml,
          'app/dashboards.yaml' => dashYamlWithDrivers,
          _ => null,
        };
    // One bench single this week (its own §2.5 reference → near-max);
    // two climb session days — at the cap, which is fine.
    final strengthRepo = _FakeStatusRepo([
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Flat Barbell Bench Press',
        'weight': 225,
        'reps': 1,
        'rpe': 8,
      },
    ]);
    final climbingRepo = _FakeStatusRepo([
      {'date': DateTime(2026, 9, 21)},
      {'date': DateTime(2026, 9, 22)},
      {'date': DateTime(2026, 9, 22)},
    ]);
    final climbingView = ViewSchema(
      name: 'climbing',
      datasource: 'gsheets',
      table: 'kaya_ascents',
      entities: const [],
      measures: const [],
      dimensions: [
        Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
      ],
      readOnly: true,
    );
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(driverFetcher),
      dashboards: DomainConfigProvider(driverFetcher),
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      climbingView: climbingView,
      climbingRepo: climbingRepo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();

    expect(find.text('THIS WEEK'), findsOneWidget);
    // Driver pills: per-lift ticks (bench done, others open), the
    // bench-frequency count, and the climb CAP at 2/≤2 (fine).
    expect(
      find.textContaining('singles', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('B✓', findRichText: true), findsOneWidget);
    expect(find.textContaining('S·', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('2/≤2', findRichText: true),
      findsOneWidget,
    );
    // Output>>input: the activity tallies are not on the strip.
    expect(find.text('sets'), findsNothing);
    expect(find.text('near-max'), findsNothing);
  });

  testWidgets('no phases section → legacy four-card grid unchanged',
      (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
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
