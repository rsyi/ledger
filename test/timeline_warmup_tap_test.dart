// Bug 1 (2026-10-05, user): "Clicking on one warm-up accidentally logged
// everything, all of my sets in the template". Today's Monday plan: the
// collapsed warm-up row only expands, a warm-up chip logs exactly one set,
// and the group header's one-tap "Log all" — which slides down under the
// finger as each logged row is inserted ABOVE the plan — must confirm
// before promoting the whole group.
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

final _mon = DateTime(2026, 10, 5);

PlannedEntry _e(String ex, num reps, num weight, {bool warmup = false}) =>
    PlannedEntry.create(
      view: _view,
      date: _mon,
      values: {
        'exercise': ex,
        'reps': reps,
        'weight': weight,
        if (warmup) 'set_type': 'warmup',
      },
      templateName: WeekPlanner.templateLabel,
    );

/// Today's program (Mon 2026-10-05), as the planner wrote it.
List<PlannedEntry> _monday() => [
  _e('Barbell Squat', 10, 45, warmup: true),
  _e('Barbell Squat', 5, 110, warmup: true),
  _e('Barbell Squat', 3, 160, warmup: true),
  _e('Barbell Squat', 1, 215, warmup: true),
  _e('Barbell Squat', 4, 270),
  for (var k = 0; k < 3; k++) _e('Barbell Squat', 6, 235),
  for (var k = 0; k < 2; k++) _e('Bulgarian Split Squat', 12, 20),
  _e('Flat Barbell Bench Press', 10, 45, warmup: true),
  _e('Flat Barbell Bench Press', 5, 95, warmup: true),
  _e('Flat Barbell Bench Press', 3, 135, warmup: true),
  _e('Flat Barbell Bench Press', 1, 165, warmup: true),
  _e('Flat Barbell Bench Press', 4, 205),
  for (var k = 0; k < 4; k++) _e('Flat Barbell Bench Press', 8, 175),
  for (var k = 0; k < 3; k++) _e('Lateral Dumbbell Raise', 12, 20),
];

Future<_FakeRepo> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.6;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  await PlanStore.addAll(_view, _monday());
  final repo = _FakeRepo();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(),
        extensions: const [StatusColors.dark],
      ),
      home: TimelineScreen(view: _view, repository: repo, initialDate: _mon),
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
  Finder warmupRow(String meta) => find
      .ancestor(of: find.textContaining(meta), matching: find.byType(ExerciseRow))
      .first;

  testWidgets('tapping the collapsed warm-up row only expands it', (
    tester,
  ) async {
    final repo = await _pump(tester);
    expect(find.text('0 / 22'), findsOneWidget);
    expect(find.text('45×10'), findsNothing);
    await tester.tap(warmupRow('45·110·160·215'));
    await _settle(tester);
    expect(repo.created, isEmpty);
    expect(find.text('45×10'), findsOneWidget);
    expect(find.text('215×1'), findsOneWidget);
    expect(await PlanStore.loadForDate(_view, _mon), hasLength(22));
    // Tapping the row's title line again collapses — still nothing logged.
    await tester.tap(find.textContaining('45·110·160·215'));
    await _settle(tester);
    expect(find.text('215×1'), findsNothing);
    expect(repo.created, isEmpty);
  });

  testWidgets('one warm-up chip logs exactly that set; the rest of the group '
      'stays interactive', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(warmupRow('45·110·160·215'));
    await _settle(tester);
    await tester.tap(find.text('45×10').first);
    await _settle(tester);
    expect(repo.created, hasLength(1));
    expect(repo.created.single['exercise'], 'Barbell Squat');
    expect(repo.created.single['weight'], 45);
    expect(repo.created.single['set_type'], 'warmup');
    expect(find.text('1 / 22'), findsOneWidget);
    expect(await PlanStore.loadForDate(_view, _mon), hasLength(21));
    // Still expanded, other chips still log one at a time.
    expect(find.text('110×5'), findsOneWidget);
    await tester.tap(find.text('110×5'));
    await _settle(tester);
    expect(repo.created, hasLength(2));
    await tester.tap(find.text('270×4'));
    await _settle(tester);
    expect(repo.created, hasLength(3));
    expect(find.text('3 / 22'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a tap landing on the group header\'s Log all (it slides down '
      'under the finger once the first logged row appears above) asks '
      'before logging the whole group', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(warmupRow('45·110·160·215'));
    await _settle(tester);
    // Where the user's finger is: the right half of the warm-up row.
    final rowRect = tester.getRect(warmupRow('45·110·160·215'));
    final target = Offset(351, rowRect.top + 70);
    expect(rowRect.contains(target), isTrue);
    await tester.tap(find.text('45×10').first);
    await _settle(tester);
    expect(repo.created, hasLength(1));
    // The LOGGED section grew above → the header's Log all is now there.
    expect(tester.getRect(find.byTooltip('Log all')).contains(target), isTrue);
    await tester.tapAt(target);
    await _settle(tester);
    expect(repo.created, hasLength(1), reason: 'one stray tap must not log '
        'the remaining 21 sets');
    expect(find.text('Log all 21 remaining sets?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(repo.created, hasLength(1));
    expect(await PlanStore.loadForDate(_view, _mon), hasLength(21));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a stale chip (the planner rewrote the day under the open '
      'screen) logs once and never leaves a duplicate planned copy', (
    tester,
  ) async {
    final repo = await _pump(tester);
    // Planner rewrite: same content, fresh localIds.
    final before = await PlanStore.loadForDate(_view, _mon);
    await PlanStore.removeWhere(_view, (_) => true);
    await PlanStore.addAll(_view, [
      for (final e in before)
        PlannedEntry.create(
          view: _view,
          date: e.date,
          values: Map.of(e.values),
          templateName: e.templateName,
        ),
    ]);
    await tester.tap(find.text('270×4')); // the on-screen (stale) chip
    await _settle(tester);
    expect(repo.created, hasLength(1));
    final left = await PlanStore.loadForDate(_view, _mon);
    expect(left, hasLength(21));
    expect(
      left.where((e) => e.values['weight'] == 270 && e.values['reps'] == 4),
      isEmpty,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
