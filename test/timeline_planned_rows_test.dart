// Log timeline planned work — ONE ROW PER EXERCISE+SLOT (UI redesign
// phase 2): Saturday's 21 planned sets render as 8 ExerciseRows; a chip
// tap logs exactly that one set (the old log circle's path); the row
// shrinks, then shows ✓; warm-ups collapse; the row menu removes sets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/planned_entry.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/plan_store.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/week_planner.dart' show WeekPlanner;
import 'package:airledger/ui/design/design.dart';
import 'package:airledger/ui/timeline_screen.dart';

class _FakeRepo implements WarehouseConnector {
  final created = <Record>[];
  final deleted = <Record>[];

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async => [
    for (final r in created) Map<String, Object?>.from(r),
  ];
  @override
  Future<Record> create(ViewSchema view, Record record) async {
    created.add(Map<String, Object?>.from(record));
    return record;
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {
    deleted.add(record);
    created.removeWhere((r) => r['id'] == record['id']);
  }
}

Dimension _d(String name, DimensionType t) =>
    Dimension(name: name, type: t, expr: name);

final _view = ViewSchema(
  name: 'strength',
  datasource: 'gsheets',
  table: 'strength',
  entities: const [],
  measures: const [],
  dateField: 'date',
  dimensions: [
    _d('id', DimensionType.string),
    _d('date', DimensionType.date),
    _d('start_time', DimensionType.string),
    _d('exercise', DimensionType.string),
    _d('weight', DimensionType.number),
    _d('reps', DimensionType.number),
    _d('set_type', DimensionType.string),
  ],
  listDisplay: ListDisplay(title: 'exercise', subtitle: r'${weight} × ${reps}'),
  plannable: Plannable(logField: 'start_time', logFormat: LogFormat.timeString),
);

final _sat = DateTime(2026, 10, 3);

List<PlannedEntry> _saturday() {
  PlannedEntry e(String ex, num reps, num weight, {bool warmup = false}) =>
      PlannedEntry.create(
        view: _view,
        date: _sat,
        values: {
          'exercise': ex,
          'reps': reps,
          'weight': weight,
          if (warmup) 'set_type': 'warmup',
        },
        templateName: WeekPlanner.templateLabel,
      );
  return [
    e('Overhead Press', 10, 45, warmup: true),
    e('Overhead Press', 5, 50, warmup: true),
    e('Overhead Press', 3, 70, warmup: true),
    e('Overhead Press', 1, 95, warmup: true),
    e('Overhead Press', 5, 120),
    for (var k = 0; k < 3; k++) e('Overhead Press', 6, 105),
    for (var k = 0; k < 3; k++) e('Seated Cable Row', 8, 110),
    for (var k = 0; k < 3; k++) e('Pull Up', 6, 161.5),
    for (var k = 0; k < 3; k++) e('Lateral Dumbbell Raise', 12, 20),
    for (var k = 0; k < 2; k++) e('Cable Face Pull', 12, 17.5),
    for (var k = 0; k < 2; k++) e('Cable External Rotation', 12, 7.5),
  ];
}

Future<_FakeRepo> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.6;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  await PlanStore.addAll(_view, _saturday());
  final repo = _FakeRepo();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(),
        extensions: const [StatusColors.dark],
      ),
      home: TimelineScreen(view: _view, repository: repo, initialDate: _sat),
    ),
  );
  await _settle(tester);
  return repo;
}

/// Lets real async (prefs / failed row-cache opens) finish between frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Saturday: 21 planned sets → 8 rows with set chips', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(ExerciseRow), findsNWidgets(8));
    expect(find.text('FROM YOUR PROGRAM'), findsOneWidget);
    expect(find.text('0 / 21'), findsOneWidget);
    expect(find.textContaining('1×5 · 120 lb'), findsOneWidget);
    expect(find.textContaining('3×6 · 105 lb'), findsOneWidget);
    expect(find.textContaining('3×6 · BW'), findsOneWidget);
    expect(find.text('120×5'), findsOneWidget);
    expect(find.text('105×6'), findsNWidgets(3));
    expect(find.text('BW×6'), findsNWidgets(3));
    // Warm-ups: one muted row, collapsed until tapped.
    expect(find.textContaining('45·50·70·95'), findsOneWidget);
    expect(find.text('45×10'), findsNothing);
    await tester.tap(find.textContaining('Warm-up'));
    await _settle(tester);
    expect(find.text('45×10'), findsOneWidget);
    expect(find.text('95×1'), findsOneWidget);
    // The old one-row-per-set log circles are gone.
    expect(find.byIcon(Icons.history), findsNothing);
  });

  testWidgets('chip tap logs exactly that set; row shrinks then ✓', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await tester.tap(find.text('105×6').first);
    await _settle(tester);
    expect(repo.created, hasLength(1));
    final row = repo.created.single;
    expect(row['exercise'], 'Overhead Press');
    expect(row['weight'], 105);
    expect(row['reps'], 6);
    expect(row['start_time'], isNotNull);
    expect(row['id'], isNotNull);
    // Row keeps its 3×6 meta but one chip fewer; header counts it.
    expect(find.text('105×6'), findsNWidgets(2));
    expect(find.textContaining('3×6 · 105 lb'), findsOneWidget);
    expect(find.text('1 / 21'), findsOneWidget);
    expect((await PlanStore.loadForDate(_view, _sat)), hasLength(20));
    // Logged section shows it.
    expect(find.text('LOGGED'), findsOneWidget);

    await tester.tap(find.text('120×5'));
    await _settle(tester);
    expect(find.text('120×5'), findsNothing);
    expect(find.textContaining('1×5 · 120 lb'), findsOneWidget);
    final top = tester.widget<ExerciseRow>(
      find.ancestor(
        of: find.textContaining('1×5 · 120 lb'),
        matching: find.byType(ExerciseRow),
      ),
    );
    expect(top.status, ItemStatus.done);
    expect(find.text('2 / 21'), findsOneWidget);
    await _flushTimers(tester);
  });

  testWidgets('Log all logs every planned set', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byTooltip('Log all'));
    await _settle(tester);
    // Confirms first (a stray tap must never log the whole group).
    expect(repo.created, isEmpty);
    expect(find.text('Log all 21 remaining sets?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Log all'));
    await _settle(tester);
    expect(repo.created, hasLength(21));
    expect(find.text('21 / 21 ✓'), findsOneWidget);
    expect(find.byType(ExerciseRow), findsNothing);
    await _flushTimers(tester);
  });

  testWidgets('row menu removes the row\'s planned sets', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.textContaining('Seated Cable Row'));
    await _settle(tester);
    expect(find.text('Log next set'), findsOneWidget);
    await tester.tap(find.text('Remove 3 planned sets'));
    await _settle(tester);
    await tester.tap(find.text('Remove'));
    await _settle(tester);
    expect(find.textContaining('Seated Cable Row'), findsNothing);
    expect(find.text('0 / 18'), findsOneWidget);
    expect((await PlanStore.loadForDate(_view, _sat)), hasLength(18));
    expect(repo.created, isEmpty);
  });

  testWidgets('menu Select enters selection; bulk delete works', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('Options').first);
    await _settle(tester);
    await tester.tap(find.text('Select'));
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget); // the top set
    await tester.tap(find.byTooltip('Delete selected'));
    await _settle(tester);
    await tester.tap(find.text('Delete'));
    await _settle(tester);
    expect(find.text('120×5'), findsNothing);
    expect((await PlanStore.loadForDate(_view, _sat)), hasLength(20));
  });
}
