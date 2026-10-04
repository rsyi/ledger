import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/google_auth/sheets_auth.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/domain_config.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/wilks.dart'
    show weeklyWilksSeries, wilksWeekDecomposition;
import 'package:airledger/services/wm_store.dart';
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/ui/design/design.dart';
import 'package:airledger/ui/home_dashboard.dart';
import 'package:airledger/ui/lift_screen.dart' show LiftSummary;
import 'package:airledger/ui/widgets/skeleton.dart';

/// A connector whose reads never complete — holds every card in its
/// loading state so the skeleton (not the filled value) is on screen.
class _HangingRepo implements WarehouseConnector {
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) =>
      Completer<List<Record>>().future; // never resolves
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

/// Serves a canned WM snapshot (readings tab). No network.
class _FakeWmStore extends WmStore {
  final WmSnapshot snap;
  _FakeWmStore(this.snap)
      : super(spreadsheetId: 'test', auth: ServiceAccountSheetsAuth('{}'));

  @override
  Future<WmSnapshot?> snapshot({bool force = false}) async => snap;
}

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

  testWidgets('loading cards show stable SKELETONS, never a bare "…" '
      '(staggered-load fix 2026-09-30)', (tester) async {
    // Every source hangs → all four cards stay in their loading state.
    final hang = _HangingRepo();
    await tester.pumpWidget(_wrap(HomeDashboard(
      wmStore: null,
      strengthView: _strengthView,
      strengthRepo: hang,
      weightView: _weightView,
      weightRepo: hang,
      statusView: _statusView,
      statusRepo: hang,
      today: DateTime(2026, 9, 23),
    )));
    // One frame only — do NOT settle (the futures never complete).
    await tester.pump();
    // The old reflowing "…" placeholder is gone everywhere.
    expect(find.text('…'), findsNothing);
    // Skeleton bars are on screen instead, pulsing.
    expect(find.byType(SkeletonBar), findsWidgets);
    expect(find.byType(PulsingOpacity), findsWidgets);
    // Card chrome (titles) still renders — layout is stable, the cards
    // don't appear/disappear as data arrives.
    expect(find.text('BODY'), findsOneWidget);
    expect(find.text('STRENGTH'), findsOneWidget);
    // Clean up the still-animating pulse controllers.
    await tester.pumpWidget(const SizedBox());
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
    expect(find.text('recent e1RM (RPE-adj)'), findsOneWidget);
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
    expect(find.text('recent e1RM (RPE-adj)'), findsOneWidget);
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
    expect(find.text('recent e1RM (RPE-adj)'), findsNWidgets(2));
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
    expect(find.text('recent: RPE-adj e1RM · bulk & top: actual'), findsOneWidget);
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

  testWidgets('M4: live climb count surfaces from Whoop workouts alone — '
      'no Kaya climbing view required', (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
    final strengthRepo = _FakeStatusRepo(const []);
    final workoutsRepo = _FakeStatusRepo([
      {'date': DateTime(2026, 9, 22), 'sport': 'rock-climbing'},
    ]);
    final workoutsView = ViewSchema(
      name: 'whoop_workouts',
      datasource: 'gsheets',
      table: 'whoop_workouts',
      entities: const [],
      measures: const [],
      dimensions: [
        Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
        Dimension(name: 'sport', type: DimensionType.string, expr: 'sport'),
      ],
    );
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(fetcher),
      dashboards: DomainConfigProvider(fetcher),
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      workoutsView: workoutsView,
      workoutsRepo: workoutsRepo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();

    // No climbingRepo/climbingView plumbed at all — before the M4 fix,
    // the climb quota was gated solely on climbingRepo != null, so a
    // Whoop-only climb day was ignored and rendered as a dash.
    expect(find.text('climb'), findsOneWidget);
    expect(find.text('1/—'), findsOneWidget);
    expect(find.text('—/—'), findsNothing);
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

  testWidgets('hero STRENGTH row opens the weekly-Wilks sheet: the '
      'decomposition lines sum to the stat, carries are dated, the '
      'basis note reconciles the STRENGTH card', (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
    // Weigh-ins covering Aug 27 → Sep 23; Monday weeks (no week_start
    // in the fixture program).
    final weighInRecords = [
      for (var i = 0; i < 28; i++)
        {
          'date': DateTime(2026, 8, 27).add(Duration(days: i)),
          'weight_lbs': 165.0 - i * (0.75 / 7),
        },
    ];
    // Deadlift trained the week of Sep 14 only → the current week
    // (Sep 21) CARRIES it; squat + bench are this week's actual lifts.
    final strengthRecords = [
      {
        'date': DateTime(2026, 9, 14),
        'exercise': 'Barbell Deadlift',
        'weight': 315,
        'reps': 1,
        'rpe': 8,
      },
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Barbell Squat',
        'weight': 295,
        'reps': 1,
        'rpe': 8,
      },
      {
        'date': DateTime(2026, 9, 22),
        'exercise': 'Flat Barbell Bench Press',
        'weight': 225,
        'reps': 2,
        'rpe': 8,
      },
    ];
    var openedStrength = false;
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(fetcher),
      dashboards: DomainConfigProvider(fetcher),
      weightView: _weightView,
      weightRepo: _FakeStatusRepo(weighInRecords),
      strengthView: _strengthView,
      strengthRepo: _FakeStatusRepo(strengthRecords),
      onOpenStrengthDomain: () => openedStrength = true,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();

    // Expected numbers straight from the tested pure engine — the same
    // inputs the dashboard feeds it.
    final weeks = weeklyWilksSeries(
      [
        for (final r in strengthRecords)
          StrengthRow(
            date: r['date'] as DateTime,
            exercise: r['exercise'] as String,
            weight: (r['weight'] as num).toDouble(),
            reps: (r['reps'] as num).toInt(),
          ),
      ],
      [
        for (final r in weighInRecords)
          WeightRow(
            date: r['date'] as DateTime,
            weightLbs: r['weight_lbs'] as double,
          ),
      ],
      through: DateTime(2026, 9, 23),
    );
    final week = weeks.last;
    final parts = wilksWeekDecomposition(week);
    final stat = week.wilks.toStringAsFixed(1);
    // Sanity on the fixture itself: displayed parts sum to the stat.
    expect(
      parts.fold<double>(0, (s, p) => s + p.displayPoints),
      closeTo(double.parse(stat), 1e-9),
    );

    // The hero row shows the stat…
    expect(find.textContaining('Wilks $stat'), findsOneWidget);

    // …and tapping the row opens the sheet (no direct navigation).
    await tester.tap(find.text('STRENGTH').first);
    await tester.pumpAndSettle();
    expect(openedStrength, isFalse);
    expect(find.text('Strength — weekly Wilks'), findsOneWidget);
    expect(find.text('decomposition'), findsOneWidget);

    // The decomposition: actual weights, dated carry, per-lift points,
    // and the exact sum line matching the stat.
    final decomposition = [
      'squat 295 → ${parts[0].displayPoints.toStringAsFixed(1)} points',
      'bench 225 → ${parts[1].displayPoints.toStringAsFixed(1)} points',
      'deadlift 315 (carried from Sep 14) → '
          '${parts[2].displayPoints.toStringAsFixed(1)} points',
      '= $stat',
    ].join('\n');
    expect(find.text(decomposition), findsOneWidget);

    // The two-surface basis note.
    expect(
      find.textContaining('14-day best e1RM ESTIMATES'),
      findsOneWidget,
    );

    // The sheet's action navigates onward to the strength domain.
    await tester.tap(find.text('Open Strength'));
    await tester.pumpAndSettle();
    expect(openedStrength, isTrue);
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
    expect(
      find.textContaining('bench ✓', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('squat —', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('2/≤2', findRichText: true),
      findsOneWidget,
    );
    // Output>>input: the activity tallies are not on the strip.
    expect(find.text('sets'), findsNothing);
    expect(find.text('near-max'), findsNothing);
    // Clarity ban-list (2026-09-29): the single-letter tick
    // compressions are gone for good.
    for (final banned in ['B✓', 'S·', 'D·', 'P·', 'S✓']) {
      expect(find.textContaining(banned, findRichText: true), findsNothing,
          reason: 'cryptic tick "$banned" leaked onto the strip');
    }
  });

  testWidgets('muscle-volume driver: full per-group breakdown ON the '
      'strip (2026-09-29 — the "N of M groups" summary pill is gone) + '
      'per-group vertical list in the detail sheet', (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
    // Program with a muscle map covering four groups — one of them
    // the underscore key that used to collapse to a colliding letter,
    // and one (back) pushed OVER the band to exercise the amber state.
    const muscleProgramYaml = '''
versions:
  - version: 1
    effective_from: "2026-09-21"
    id: bulk-2026-27
    blocks:
      - { n: 0, dates: ["2026-09-21", "2026-12-13"], emphasis: cut, weight: [163, 154] }
    targets:
      near_max_sets_wk: 4
    exercise_muscle_map:
      exercises:
        "Flat Barbell Bench Press": { chest: 1.0 }
        "Barbell Squat": { quads: 1.0, hamstrings_glutes: 0.5 }
        "Barbell Row": { back: 1.0 }
''';
    const muscleDashYaml = '''
$dashYamlWithPhases
    weekly_drivers:
      - id: hypertrophy_volume
        label: muscle sets
        band: [8, 12]
        muscle_groups: [quads, hamstrings_glutes, chest, back]
        outcome: "muscle retained"
        why: "8-12 productive sets per muscle group per week."
''';
    Future<String?> muscleFetcher(String path) async => switch (path) {
          'coach/phase.yaml' => phaseYaml,
          'coach/program.yaml' => muscleProgramYaml,
          'app/dashboards.yaml' => muscleDashYaml,
          _ => null,
        };
    // 9 bench sets → chest 9 (in range); 2 squat sets → quads 2 under,
    // hamstrings+glutes 1 under (the 0.5 credit); 13 row sets →
    // back 13 (over the 12 top — the amber warning).
    final strengthRepo = _FakeStatusRepo([
      for (var i = 0; i < 9; i++)
        {
          'date': DateTime(2026, 9, 21),
          'exercise': 'Flat Barbell Bench Press',
          'weight': 185,
          'reps': 8,
          'rpe': 8,
        },
      for (var i = 0; i < 2; i++)
        {
          'date': DateTime(2026, 9, 22),
          'exercise': 'Barbell Squat',
          'weight': 225,
          'reps': 8,
          'rpe': 8,
        },
      for (var i = 0; i < 13; i++)
        {
          'date': DateTime(2026, 9, 22),
          'exercise': 'Barbell Row',
          'weight': 155,
          'reps': 8,
          'rpe': 8,
        },
    ]);
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(muscleFetcher),
      dashboards: DomainConfigProvider(muscleFetcher),
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();

    // Strip: dim header (label + band, full words), then one chip per
    // muscle group with its actual count — never the "N of M groups"
    // summary that hid them, never the per-group letter soup.
    expect(
      find.text('muscle sets · 8-12 per group this week'),
      findsOneWidget,
    );
    expect(
      find.textContaining('quads 2', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('hamstrings and glutes 1', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('chest 9', findRichText: true),
      findsOneWidget,
    );
    // Over the band is spelled out on the chip itself.
    expect(
      find.textContaining('back 13 over', findRichText: true),
      findsOneWidget,
    );
    // The summary pill is retired from the strip.
    expect(
      find.textContaining('groups in the', findRichText: true),
      findsNothing,
    );
    for (final banned in ['hyp sets', 'Q 2/8', 'H 1/8', 'C 9/8']) {
      expect(find.textContaining(banned, findRichText: true), findsNothing,
          reason: 'cryptic muscle tick "$banned" leaked onto the strip');
    }

    // Detail sheet: one line per group — full name, sets, clear state —
    // plus the explanatory copy (kept).
    await tester.tap(find.text('THIS WEEK'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('quads — 2 sets (under)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('hamstrings and glutes — 1 set (under)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('chest — 9 sets (in range)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('back — 13 sets (over the range)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('1 of 4 groups in the 8-12-set range'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Under mid-week is normal'),
      findsOneWidget,
    );
  });

  testWidgets('singles driver is readings-based + parity-aware '
      '(2026-09-25, spelled out 2026-09-29): tab ∪ live readings tick, '
      'heavy/light week alternation tags, heavy-single recency line '
      'under the pills', (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
    // Program with the squat/deadlift alternation anchor (Mon 9/21 → the
    // week of Sep 21 is an A week: squat heavy, deadlift light).
    const altProgramYaml = '''
versions:
  - version: 1
    effective_from: "2026-09-21"
    id: bulk-2026-27
    blocks:
      - { n: 0, dates: ["2026-09-21", "2026-12-13"], emphasis: cut, weight: [163, 154] }
    planned_alternation:
      anchor_monday: "2026-09-21"
    targets:
      near_max_sets_wk: 4
''';
    const dashYaml = '''
$dashYamlWithPhases
    weekly_drivers:
      - id: top_single_per_lift
        label: singles
        lifts: [squat, bench, deadlift, press]
        heavy_single_max_days: 14
        outcome: "Wilks preserved"
        why: "Heavy every two weeks; lighter stimulus alternate weeks."
''';
    Future<String?> readingsFetcher(String path) async => switch (path) {
          'coach/phase.yaml' => phaseYaml,
          'coach/program.yaml' => altProgramYaml,
          'app/dashboards.yaml' => dashYaml,
          _ => null,
        };
    // The stored readings tab carries Monday's squat 275x2@8 — NOT a
    // §2.5 near-max set, which must no longer matter.
    final wmStore = _FakeWmStore((
      workingMax: <WorkingMaxRow>[],
      readings: <ReadingRow>[
        ReadingRow(
          id: '2026-09-21|squat',
          date: DateTime.utc(2026, 9, 21),
          lift: 'squat',
          variant: 'belted',
          weightLb: 275,
          reps: 2,
          rpe: 8,
          kind: 'heavy_top',
          grinder: false,
          missed: false,
          impliedMax: 308.3,
          decision: 'hold',
          wmAfter: 320,
        ),
      ],
    ));
    // Live gap-fill: a bench top set the nightly hasn't stored yet.
    final strengthRepo = _FakeStatusRepo([
      {
        'date': DateTime(2026, 9, 22),
        'exercise': 'Flat Barbell Bench Press',
        'weight': 225,
        'reps': 1,
        'rpe': 8,
      },
    ]);
    await tester.pumpWidget(_wrap(HomeDashboard(
      wmStore: wmStore,
      provider: ProgramProvider(readingsFetcher),
      dashboards: DomainConfigProvider(readingsFetcher),
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();

    // Ticks: squat from the TAB reading (parity-tagged heavy), bench
    // from the LIVE extraction; deadlift wears its light-week tag.
    expect(
      find.textContaining('squat ✓ (heavy week)', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('bench ✓', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('deadlift — (light week)', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('press —', findRichText: true),
      findsOneWidget,
    );
    // Clarity ban-list (2026-09-29): letters + (H)/(L) never return.
    for (final banned in ['S✓', 'B✓', 'D·', 'P·', '(H)', '(L)']) {
      expect(find.textContaining(banned, findRichText: true), findsNothing,
          reason: 'cryptic tick "$banned" leaked onto the strip');
    }
    // The two-week heavy rule's secondary line: squat's 275x2@8 is a
    // heavy exposure (2 days ago); deadlift has none recorded → overdue.
    expect(
      find.text('Heavy single: squat 2 days ago · '
          'deadlift none yet — overdue'),
      findsOneWidget,
    );

    // The detail sheet explains the parity + two-week mechanics.
    await tester.tap(find.text('THIS WEEK'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('a lighter top set still ticks on its light week'),
      findsOneWidget,
    );
    expect(
      find.textContaining('every-two-weeks rule'),
      findsOneWidget,
    );
    expect(
      find.textContaining('amber past 14 days'),
      findsOneWidget,
    );
  });

  testWidgets('THIS WEEK strip carries no flags chip (removed 2026-09-25); '
      'its sheet points at Program › status instead', (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
    final statusRepo = _FakeStatusRepo([
      {
        'week_monday': DateTime(2026, 9, 21),
        'working_sets': 6,
        'near_max_sets': 0,
        'bench_days': 0,
        'flags': 'NEAR_MAX_LOW,WORKING_LOW,TUESDAY_LOWER,BIKE_DROP,'
            'TWO_SIGNALS',
      },
    ]);
    var openedStatus = false;
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(fetcher),
      dashboards: DomainConfigProvider(fetcher),
      statusView: _statusView,
      statusRepo: statusRepo,
      onOpenStatus: () => openedStatus = true,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();

    // Hero layout with the condensed strip — and no ⚑ chip anywhere.
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.textContaining('⚑'), findsNothing);

    // The sheet: no flag dump, one pointer line at the real home of
    // the coach's signal history.
    await tester.tap(find.text('THIS WEEK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('NEAR_MAX_LOW'), findsNothing);
    expect(find.text('Coach signals'), findsOneWidget);
    expect(find.text('Program › status'), findsOneWidget);
    expect(
      find.textContaining('signal history lives'),
      findsOneWidget,
    );
    // The onward action still reaches the status ledger.
    await tester.tap(find.text('Open status ledger'));
    await tester.pumpAndSettle();
    expect(openedStatus, isTrue);
  });

  // ---------------------------------------------------------------------
  // Readability pass 2026-09-25 (AppText, 16sp values / 12sp floor):
  // the bigger type must REFLOW — no RenderFlex overflows at phone
  // widths, and the STRENGTH card stacks per-lift rows when the
  // half-width legacy grid can't hold two 16sp columns.
  // ---------------------------------------------------------------------

  Future<void> pumpHeroSurfaceAt(WidgetTester tester, Size size) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Richest live surface: hero (weight + Wilks rows with sparklines),
    // driver checklist pills, STRENGTH card with both columns.
    const dashYaml = '''
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
last_bulk:
  start: "2025-02-05"
  end: "2025-10-06"
  label: "2025 bulk"
''';
    Future<String?> heroFetcher(String path) async => switch (path) {
          'coach/phase.yaml' => phaseYaml,
          'coach/program.yaml' => programYaml,
          'app/dashboards.yaml' => dashYaml,
          _ => null,
        };
    final weightRepo = _FakeStatusRepo([
      for (var i = 0; i < 28; i++)
        {
          'date': DateTime(2026, 8, 27).add(Duration(days: i)),
          'weight_lbs': 165.0 - i * (0.75 / 7),
        },
      {'date': DateTime(2025, 6, 5), 'weight_lbs': 184.0},
    ]);
    final strengthRepo = _FakeStatusRepo([
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Barbell Squat',
        'weight': 300,
        'reps': 1,
        'rpe': 8,
      },
      {
        'date': DateTime(2025, 6, 10),
        'exercise': 'Barbell Deadlift',
        'weight': 405,
        'reps': 2,
        'rpe': 9,
      },
    ]);
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(heroFetcher),
      dashboards: DomainConfigProvider(heroFetcher),
      weightView: _weightView,
      weightRepo: weightRepo,
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    expect(find.text('CUT'), findsOneWidget);
    expect(find.text('THIS WEEK'), findsOneWidget);
    // Any RenderFlex overflow would have failed the test via the
    // FlutterError reporter — reaching here means the reflow held.
  }

  testWidgets('hero surface reflows without overflow at 360x690',
      (tester) async {
    await pumpHeroSurfaceAt(tester, const Size(360, 690));
    // Full-width strength card still has room for the aligned columns.
    expect(find.text('recent e1RM (RPE-adj)'), findsOneWidget);
    expect(find.text('last bulk'), findsOneWidget);
  });

  testWidgets('hero surface reflows without overflow at 412x900',
      (tester) async {
    await pumpHeroSurfaceAt(tester, const Size(412, 900));
    expect(find.text('recent e1RM (RPE-adj)'), findsOneWidget);
  });

  testWidgets('legacy half-width STRENGTH card at 360dp stacks per-lift '
      'rows (layout reflow, not ellipsis) without overflow',
      (tester) async {
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final strengthRepo = _FakeStatusRepo([
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
    ]);
    final weightRepo = _FakeStatusRepo([
      for (var i = 17; i <= 23; i++)
        {'date': DateTime(2026, 9, i), 'weight_lbs': 165.0},
      {'date': DateTime(2025, 6, 5), 'weight_lbs': 184.0},
      {'date': DateTime(2025, 6, 20), 'weight_lbs': 186.0},
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
    // Stacked mode: the column header row is gone; each basis renders
    // its own full-width line with the value string intact.
    expect(find.text('recent e1RM (RPE-adj)'), findsNothing);
    expect(
      find.textContaining('310 · 120.0w · 2d', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining("315 · 113.8w · Jun '25", findRichText: true),
      findsOneWidget,
    );
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

  testWidgets('recomp phase → THIS WEEK renders the one-screen recomp '
      'rows (tracking spec 2026-09-27) and replaces the driver strip',
      (tester) async {
    ProgramProvider.clearCache();
    HomeDashboardState.clearBestWeightCache();
    DomainConfigProvider.clearCache();
    const recompPhaseYaml = '''
versions:
  - version: 1
    value: bulk
    effective_from: "2026-12-14"
''';
    const recompProgramYaml = '''
versions:
  - version: 1
    effective_from: "2026-12-14"
    id: bulk-2026-27
    variant: recomposition
    blocks:
      - { n: 1, dates: ["2026-12-14", "2027-01-03"], emphasis: reverse, weight: [154, 155] }
    targets:
      protein_g_day: [160, 175]
      fat_g_day_min: [55, 65]
      carbs_g_day: [225, 300]
      bike_4x4_wk: 1
    hypertrophy_targets:
      sets_per_muscle_wk: [8, 12]
      muscle_groups: [chest]
    exercise_muscle_map:
      exercises:
        "Flat Barbell Bench Press": { chest: 1.0 }
''';
    const recompDashYaml = '''
domains:
  - name: strength
    views: [strength]
phases:
  recomp:
    eigenvectors:
      - id: weight_hold
        label: weight
        rate_band: [-0.1, 0.25]
    weekly_drivers:
      - id: bike_4x4
        label: 4x4
        target: 1
        outcome: "VO2"
        why: "never dropped"
''';
    Future<String?> recompFetcher(String path) async => switch (path) {
          'coach/phase.yaml' => recompPhaseYaml,
          'coach/program.yaml' => recompProgramYaml,
          'app/dashboards.yaml' => recompDashYaml,
          _ => null,
        };
    // Tue Dec 15 2026 — review week Mon 12/14 .. Sun 12/20.
    final today = DateTime(2026, 12, 15);
    final strengthRepo = _FakeStatusRepo([
      for (var i = 0; i < 8; i++)
        {
          'date': DateTime(2026, 12, 14),
          'exercise': 'Flat Barbell Bench Press',
          'weight': 185,
          'reps': 6,
          'rpe': 8,
          'set_type': 'hypertrophy',
        },
      {
        'date': DateTime(2026, 12, 14),
        'exercise': 'Flat Barbell Bench Press',
        'weight': 95,
        'reps': 5,
        'rpe': 3,
        'set_type': 'warmup', // excluded from productive counting
      },
    ]);
    final mealsRepo = _FakeStatusRepo([
      {
        'eaten_at': DateTime(2026, 12, 14, 12),
        'calories': 2500,
        'protein_g': 170,
        'carbs_g': 260,
        'fat_g': 60,
      },
    ]);
    final mealsView = ViewSchema(
      name: 'meals',
      datasource: 'gsheets',
      table: 'meals',
      entities: const [],
      measures: const [],
      dimensions: [
        Dimension(
            name: 'eaten_at', type: DimensionType.date, expr: 'eaten_at'),
      ],
    );
    final notesRepo = _FakeStatusRepo([
      {
        'date': DateTime(2026, 12, 14),
        'sleep_hours': 7.5,
        'fatigue': 2,
        'pain': 'left elbow twinge',
      },
    ]);
    final notesView = ViewSchema(
      name: 'daily_notes',
      datasource: 'gsheets',
      table: 'daily_notes',
      entities: const [],
      measures: const [],
      dimensions: [
        Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
      ],
    );
    await tester.pumpWidget(_wrap(HomeDashboard(
      provider: ProgramProvider(recompFetcher),
      dashboards: DomainConfigProvider(recompFetcher),
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      mealsView: mealsView,
      mealsRepo: mealsRepo,
      notesView: notesView,
      notesRepo: notesRepo,
      today: today,
    )));
    await tester.pumpAndSettle();

    expect(find.text('THIS WEEK'), findsOneWidget);
    // The spec's seven rows (STRENGTH also labels the strength card →
    // at least one).
    for (final label in [
      'BODY', 'NUTRITION', 'HYPERTROPHY', 'STRENGTH', 'SKILLS',
      'CARDIO', 'RECOVERY',
    ]) {
      expect(find.text(label), findsAtLeastNWidgets(1), reason: label);
    }
    // Nutrition averages + protein adherence from the logged day.
    expect(
      find.textContaining('2500 kcal', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('target met 1/1 days', findRichText: true),
      findsOneWidget,
    );
    // Hypertrophy: 8 productive bench sets (warmup excluded) — chest in
    // band; RIR 2 from RPE 8.
    expect(
      find.textContaining('1 of 1 muscle groups in range',
          findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('2.0 reps in reserve', findRichText: true),
      findsOneWidget,
    );
    // Recovery: pain flag surfaces (and outranks the numbers).
    expect(
      find.textContaining('PAIN', findRichText: true),
      findsOneWidget,
    );
    // Graceful placeholders: waist + DEXA not yet flowing.
    expect(
      find.textContaining('DEXA —', findRichText: true),
      findsOneWidget,
    );
    // The recomp rows REPLACE the driver checklist (its 4x4 pill would
    // say "4x4 0/1"; the CARDIO row carries that content instead).
    expect(find.text('4x4'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // PROGRESS tab (progressOnly) — UI redesign 2026-10-02: shared design
  // system (SectionHeader / AppCard / ExerciseRow / StatusChip), plain
  // language, per-lift rows instead of the dense two-column table.
  // -------------------------------------------------------------------------

  group('Progress tab (progressOnly)', () {
    const progressDashYaml = '''
$dashYamlWithPhases
last_bulk:
  start: "2025-02-05"
  end: "2025-10-06"
  label: "2025 bulk"
''';
    Future<String?> progressFetcher(String path) async => switch (path) {
          'coach/phase.yaml' => phaseYaml,
          'coach/program.yaml' => programYaml,
          'app/dashboards.yaml' => progressDashYaml,
          _ => null,
        };

    Future<void> pumpProgress(
      WidgetTester tester, {
      VoidCallback? onOpenProgram,
      VoidCallback? onOpenWeight,
      VoidCallback? onOpenStrength,
      void Function(String lift, LiftSummary summary)? onOpenLift,
      Size? size,
    }) async {
      ProgramProvider.clearCache();
      HomeDashboardState.clearBestWeightCache();
      DomainConfigProvider.clearCache();
      if (size != null) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      await tester.pumpWidget(_wrap(HomeDashboard(
        progressOnly: true,
        provider: ProgramProvider(progressFetcher),
        dashboards: DomainConfigProvider(progressFetcher),
        weightView: _weightView,
        weightRepo: _FakeStatusRepo([
          for (var i = 0; i < 28; i++)
            {
              'date': DateTime(2026, 8, 27).add(Duration(days: i)),
              'weight_lbs': 165.0 - i * (0.75 / 7),
            },
          {'date': DateTime(2025, 6, 5), 'weight_lbs': 184.0},
        ]),
        strengthView: _strengthView,
        strengthRepo: _FakeStatusRepo([
          // squat: recent e1RM 310 (300×1), bulk best 315 → −5 (holding)
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
          // bench: recent e1RM 207 (200×1), bulk best 245 → −38 (>10%)
          {
            'date': DateTime(2026, 9, 19),
            'exercise': 'Flat Barbell Bench Press',
            'weight': 200,
            'reps': 1,
          },
          {
            'date': DateTime(2025, 6, 12),
            'exercise': 'Flat Barbell Bench Press',
            'weight': 245,
            'reps': 1,
          },
        ]),
        onOpenProgram: onOpenProgram,
        onOpenWeight: onOpenWeight,
        onOpenStrength: onOpenStrength,
        onOpenLift: onOpenLift,
        today: DateTime(2026, 9, 23),
      )));
      await tester.pumpAndSettle();
    }

    testWidgets('phase section: SectionHeader + one plain meta line + '
        'verdict rows with StatusChips; no input strip', (tester) async {
      await pumpProgress(tester);
      expect(find.text('CUT'), findsOneWidget); // SectionHeader upper-cases
      expect(
        find.text('block 0 · week 1 · day 3 of 84 · 163 → 154 lb by Dec 13'),
        findsOneWidget,
      );
      expect(find.textContaining('Weight', findRichText: true), findsWidgets);
      expect(find.text('On track'), findsOneWidget); // weight on pace
      expect(find.textContaining('lb/week'), findsOneWidget);
      expect(find.textContaining('target -0.75'), findsOneWidget);
      expect(find.byType(StatusChip), findsNWidgets(2));
      // verdict rows + phase timeline + lifts
      expect(find.byType(AppCard), findsNWidgets(3));
      // Outputs only: the input strip and the legacy cards are gone.
      expect(find.text('THIS WEEK'), findsNothing);
      expect(find.text('BODY'), findsNothing);
      expect(find.text('ON TRACK'), findsNothing); // old shouting pill
    });

    testWidgets('lifts: one row per lift — e1RM, status-coloured change vs '
        'last bulk, age in words', (tester) async {
      await pumpProgress(tester);
      expect(find.text('LIFTS'), findsOneWidget);
      expect(find.text('e1RM vs last bulk'), findsOneWidget);
      for (final n in ['Squat', 'Bench', 'Deadlift', 'Overhead press']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      expect(find.text('310 lb'), findsOneWidget);
      expect(find.text('207 lb'), findsOneWidget);
      expect(find.text("2 days ago · last bulk 315 (Jun '25)"), findsOneWidget);
      expect(find.text("4 days ago · last bulk 245 (Jun '25)"), findsOneWidget);
      expect(
        find.text('no recent work · no last-bulk best'),
        findsNWidgets(2), // deadlift + press
      );
      // Change figures carry the status colour: squat within 5% → done,
      // bench > 10% below → problem.
      const colors = StatusColors.light;
      expect(tester.widget<Text>(find.text('−5 lb')).style?.color,
          colors.done);
      expect(tester.widget<Text>(find.text('−38 lb')).style?.color,
          colors.problem);
    });

    testWidgets('ban-list: no cryptic compressions on the surface',
        (tester) async {
      await pumpProgress(tester);
      for (final banned in [
        RegExp(r'\d\.\dw\b'), // per-lift Wilks "128.2w"
        RegExp(r'\bwk\b'),
        RegExp(r'\b\d+d\b'), // "4d"
        RegExp('RPE-adj'),
        RegExp('bulk: actual'),
      ]) {
        expect(find.textContaining(banned, findRichText: true), findsNothing,
            reason: banned.pattern);
      }
    });

    testWidgets('phase timeline (IA restructure): blocks with the '
        'you-are-here marker between the verdict rows and the lifts; no '
        'target card, no separate verdict card', (tester) async {
      await pumpProgress(tester);
      expect(find.text('PHASE'), findsOneWidget);
      expect(find.byKey(const ValueKey('progress-block-timeline')),
          findsOneWidget);
      expect(find.textContaining('Block 0 · Cut', findRichText: true),
          findsOneWidget);
      expect(find.text('You are here · week 1 of 12'), findsOneWidget);
      // The Plan tab's target card + verdict card are gone from here.
      expect(find.textContaining('Target 154'), findsNothing);
      expect(find.text('VERDICT'), findsNothing);
      // Order: verdict rows (CUT) → PHASE → LIFTS.
      final cutY = tester.getTopLeft(find.text('CUT')).dy;
      final phaseY = tester.getTopLeft(find.text('PHASE')).dy;
      final liftsY = tester.getTopLeft(find.text('LIFTS')).dy;
      expect(cutY, lessThan(phaseY));
      expect(phaseY, lessThan(liftsY));
    });

    testWidgets('lift row opens the lift page with the Progress numbers; '
        'no info icon on the Lifts header', (tester) async {
      String? opened;
      LiftSummary? got;
      await pumpProgress(tester, onOpenLift: (lift, summary) {
        opened = lift;
        got = summary;
      });
      // The (i) icon + Lifts text sheet are gone (user: "seems useless").
      expect(find.byTooltip('How these are measured'), findsNothing);
      expect(find.byIcon(Icons.info_outline), findsNothing);
      await tester.tap(find.text('Squat'));
      await tester.pumpAndSettle();
      expect(find.byType(DetailSheet), findsNothing);
      expect(opened, 'squat');
      expect(got!.recent!.value.round(), 310);
      expect(got!.lastBulk!.value, 315);
      expect(got!.best!.value, 315);
      expect(got!.bulkWindow!.label, '2025 bulk');
    });

    testWidgets('weight row → Weight page, strength row → Strength page',
        (tester) async {
      var weight = 0, strength = 0, program = 0;
      await pumpProgress(
        tester,
        onOpenProgram: () => program++,
        onOpenWeight: () => weight++,
        onOpenStrength: () => strength++,
      );
      await tester.tap(find.textContaining('Weight', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(weight, 1);
      await tester.tap(
          find.textContaining('Strength', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(strength, 1);
      expect(find.byType(DetailSheet), findsNothing); // no Wilks sheet now
      expect(program, 0);
    });

    testWidgets('weight row without a Weight page opener keeps the legacy '
        'Program navigation', (tester) async {
      var opened = false;
      await pumpProgress(tester, onOpenProgram: () => opened = true);
      await tester.tap(find.textContaining('Weight', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(opened, isTrue);
    });

    testWidgets('no overflow at 360x690', (tester) async {
      await pumpProgress(tester, size: const Size(360, 690));
      expect(find.text('CUT'), findsOneWidget);
    });
  });
}
