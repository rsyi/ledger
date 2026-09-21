import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
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

  testWidgets('STRENGTH renders est-1RM / WM / best columns from the '
      'strength ledger even without a wm store', (tester) async {
    HomeDashboardState.clearBestE1rmCache();
    final strengthRepo = _FakeStatusRepo([
      {
        'date': DateTime(2026, 9, 21),
        'exercise': 'Barbell Squat',
        'weight': 300,
        'reps': 1, // e1rm 310 — inside the 42-day window
      },
      {
        'date': DateTime(2025, 1, 6),
        'exercise': 'Barbell Squat',
        'weight': 320,
        'reps': 1, // e1rm ~330.7 — all-time best, outside the window
      },
    ]);
    await tester.pumpWidget(_wrap(HomeDashboard(
      strengthView: _strengthView,
      strengthRepo: strengthRepo,
      today: DateTime(2026, 9, 23),
    )));
    await tester.pumpAndSettle();
    expect(find.text('e1RM'), findsOneWidget); // column headers
    expect(find.text('WM'), findsOneWidget);
    expect(find.text('best'), findsOneWidget);
    expect(find.text('310'), findsOneWidget); // 42-day reference
    expect(find.text('331'), findsOneWidget); // all-time best (rounded)
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

  testWidgets('STRENGTH detail sheet explains WM vs est 1RM', (tester) async {
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
    expect(find.text('WM (working max)'), findsOneWidget);
    expect(
      find.textContaining('not your measured max'),
      findsOneWidget,
    );
    expect(find.textContaining('trailing 42 days'), findsOneWidget);
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
}
