// ProgramDayCard — effective (post-moves) items, Move to… / Undo, and the
// "Missed this week" section. Runs against the LIVE airledger-fitness
// program.yaml (cut week of Mon 2026-09-28), like program_week_test.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/widgets/program_day_card.dart';

const _fitness = '../airledger-fitness';

class _FakeRepo implements WarehouseConnector {
  final List<Record> rows;
  final created = <Record>[];
  final deleted = <Record>[];
  int lists = 0;
  _FakeRepo([List<Record>? rows]) : rows = rows ?? [];

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    lists++;
    return [...rows, ...created];
  }

  @override
  Future<Record> create(ViewSchema view, Record record) async {
    created.add(record);
    return record;
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {
    deleted.add(record);
    rows.removeWhere((r) => r['id'] == record['id']);
  }
}

ViewSchema _view(String name, List<String> dims) => ViewSchema(
  name: name,
  datasource: 'gsheets',
  table: name,
  entities: const [],
  measures: const [],
  dimensions: [
    for (final d in dims)
      Dimension(
        name: d,
        type: d.endsWith('date') ? DimensionType.date : DimensionType.string,
        expr: d,
      ),
  ],
);

void main() {
  final programFile = File('$_fitness/coach/program.yaml');
  final hasFitness = programFile.existsSync();
  String? read(String path) {
    final f = File('$_fitness/$path');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  final strengthView = _view('strength', ['id', 'date', 'exercise']);
  final movesView = _view('program_moves', [
    'id',
    'date',
    'from_date',
    'item',
    'period',
    'source',
    'note',
  ]);
  final climbingView = _view('climbing', ['id', 'date']);
  final cardioView = _view('cardio', ['id', 'date', 'type']);
  final fri = DateTime(2026, 10, 2);
  final wed = DateTime(2026, 9, 30);

  setUp(ProgramProvider.clearCache);

  Record benchMove() => ProgramMove(
    id: 'm1',
    to: fri,
    from: wed,
    item: 'Bench heavy',
    period: 'AM',
    source: 'coach',
    createdAt: DateTime(2026, 10, 1, 23, 30),
  ).toRecord();

  Future<void> pump(
    WidgetTester tester, {
    required DateTime date,
    required _FakeRepo moves,
    _FakeRepo? strength,
    _FakeRepo? climbing,
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProgramDayCard(
              provider: ProgramProvider((p) async => read(p)),
              label: 'Today',
              date: date,
              now: () => DateTime(2026, 10, 2, 9),
              strengthView: strengthView,
              strengthRepo: strength ?? _FakeRepo(),
              programMovesView: movesView,
              programMovesRepo: moves,
              climbingView: climbingView,
              climbingRepo: climbing ?? _FakeRepo(),
              cardioView: cardioView,
              cardioRepo: _FakeRepo(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder menuOf(String name) => find.descendant(
    of: find
        .ancestor(of: find.text(name), matching: find.byType(InkWell))
        .first,
    matching: find.byIcon(Icons.more_vert),
  );

  testWidgets('moved-in item: "from Wed" chip on Fri, ghost "→ Fri" on Wed', (
    tester,
  ) async {
    if (!hasFitness) return;
    final moves = _FakeRepo([benchMove()]);
    await pump(tester, date: fri, moves: moves);
    expect(find.text('Bench heavy'), findsOneWidget);
    expect(find.text('from Wed'), findsOneWidget);
    // Fri's 5 own items + the moved-in bench.
    expect(find.text('0 / 6 done'), findsOneWidget);
    expect(moves.lists, 1, reason: 'moves read once per load');

    await pump(tester, date: wed, moves: _FakeRepo([benchMove()]));
    expect(find.text('Bench heavy'), findsOneWidget);
    expect(find.text('→ Fri'), findsOneWidget);
    // Ghost isn't counted (Wed: 4 live of 5); its menu is Undo-only
    // (covered below).
    expect(find.text('0 / 4 done'), findsOneWidget);
    // Not today → no missed section.
    expect(find.text('MISSED THIS WEEK'), findsNothing);
  });

  testWidgets('card allocates sets exclusively (agrees with the detector)', (
    tester,
  ) async {
    if (!hasFitness) return;
    // Fri: own bench volume (3 sets) + moved-in Bench heavy (1 set); 3
    // bench sets logged → own item complete, moved-in still open.
    final strength = _FakeRepo([
      for (var i = 0; i < 3; i++)
        {'id': 's$i', 'date': fri, 'exercise': 'Bench Press'},
    ]);
    await pump(tester, date: fri, moves: _FakeRepo([benchMove()]),
        strength: strength);
    expect(find.text('3/3'), findsOneWidget);
    expect(find.text('1 / 6 done'), findsOneWidget);
  });

  testWidgets('untagged ramp sets don\'t credit a prescribed item', (
    tester,
  ) async {
    if (!hasFitness) return;
    // Fri bench volume 3x8-10: 3 untagged ramp sets (95/135/155, no RPE)
    // + 2 working sets → 2/3, not done.
    final strength = _FakeRepo([
      for (final (i, w) in [(0, 95), (1, 135), (2, 155), (3, 225), (4, 225)])
        {'id': 's$i', 'date': fri, 'exercise': 'Bench Press', 'weight': w},
    ]);
    await pump(tester, date: fri, moves: _FakeRepo(), strength: strength);
    expect(find.text('2/3'), findsOneWidget);
    expect(find.text('0 / 5 done'), findsOneWidget);
  });

  testWidgets('Move to… writes a manual program_moves row', (tester) async {
    if (!hasFitness) return;
    final moves = _FakeRepo();
    await pump(tester, date: fri, moves: moves);
    await tester.tap(menuOf('Deadlift heavy'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Move to…'));
    await tester.pumpAndSettle();
    // Today is the current day → disabled.
    expect(find.text('Fri 10/2 · today'), findsOneWidget);
    await tester.tap(find.text('Fri 10/2 · today'));
    await tester.pumpAndSettle();
    expect(moves.created, isEmpty);
    await tester.tap(find.text('Sat 10/3'));
    await tester.pumpAndSettle();

    expect(moves.created, hasLength(1));
    final m = ProgramMove.fromRecord(moves.created.single)!;
    expect(m.item, 'Deadlift heavy');
    expect(m.from, fri);
    expect(m.to, DateTime(2026, 10, 3));
    expect(m.period, 'AM');
    expect(m.source, 'manual');
    expect(m.createdAt, isNotNull);
    // Reloaded: Fri now shows the ghost.
    expect(find.text('→ Sat'), findsOneWidget);
  });

  testWidgets('Undo move writes a back-home row (latest-wins cancel)', (
    tester,
  ) async {
    if (!hasFitness) return;
    final moves = _FakeRepo([benchMove()]);
    await pump(tester, date: fri, moves: moves);
    await tester.tap(menuOf('Bench heavy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo move'));
    await tester.pumpAndSettle();
    expect(moves.deleted, isEmpty);
    final back = ProgramMove.fromRecord(moves.created.single)!;
    expect(back.item, 'Bench heavy');
    expect(back.from, wed);
    expect(back.to, wed);
    expect(find.text('Bench heavy'), findsNothing);
    expect(find.text('from Wed'), findsNothing);
  });

  testWidgets('Undo move with an OLDER move row still sends it home', (
    tester,
  ) async {
    if (!hasFitness) return;
    final older = ProgramMove(
      id: 'm0',
      to: DateTime(2026, 10, 1),
      from: wed,
      item: 'Bench heavy',
      period: 'AM',
      source: 'manual',
      createdAt: DateTime(2026, 9, 30, 20),
    ).toRecord();
    final moves = _FakeRepo([older, benchMove()]);
    await pump(tester, date: fri, moves: moves);
    await tester.tap(menuOf('Bench heavy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo move'));
    await tester.pumpAndSettle();
    final all = [
      for (final r in [...moves.rows, ...moves.created])
        ProgramMove.fromRecord(r)!,
    ];
    expect(activeMoves(all, DateTime(2026, 9, 28)), isEmpty,
        reason: 'home, not back to the older Thu move');
  });

  testWidgets('ghost (moved-out) row: menu with Undo move only', (
    tester,
  ) async {
    if (!hasFitness) return;
    final moves = _FakeRepo([benchMove()]);
    await pump(tester, date: wed, moves: moves);
    expect(find.text('→ Fri'), findsOneWidget);
    await tester.tap(menuOf('Bench heavy'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(PopupMenuItem<String>, 'Move to…'),
        findsNothing);
    await tester.tap(find.text('Undo move'));
    await tester.pumpAndSettle();
    final back = ProgramMove.fromRecord(moves.created.single)!;
    expect(back.from, wed);
    expect(back.to, wed);
    expect(find.text('→ Fri'), findsNothing);
  });

  testWidgets('Move to… picker: past days disabled; home stays pickable '
      '(moving back home)', (tester) async {
    if (!hasFitness) return;
    final moves = _FakeRepo([benchMove()]);
    await pump(tester, date: fri, moves: moves);
    // Bench heavy lives on Fri (today), home Wed.
    await tester.tap(menuOf('Bench heavy'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Move to…'));
    await tester.pumpAndSettle();
    ListTile tile(String label) => tester.widget<ListTile>(
        find.ancestor(of: find.text(label), matching: find.byType(ListTile)));
    expect(tile('Mon 9/28').enabled, isFalse);
    expect(tile('Thu 10/1').enabled, isFalse);
    expect(tile('Wed 9/30').enabled, isTrue, reason: 'home = back home');
    expect(tile('Sat 10/3').enabled, isTrue);
    await tester.tap(find.text('Thu 10/1'));
    await tester.pumpAndSettle();
    expect(moves.created, isEmpty);
    await tester.tap(find.text('Wed 9/30'));
    await tester.pumpAndSettle();
    final back = ProgramMove.fromRecord(moves.created.single)!;
    expect(back.to, wed);
    expect(back.from, wed);
  });

  testWidgets('own-day items have Move to… but no Undo', (tester) async {
    if (!hasFitness) return;
    await pump(tester, date: fri, moves: _FakeRepo());
    await tester.tap(menuOf('Deadlift heavy'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(PopupMenuItem<String>, 'Move to…'),
      findsOneWidget,
    );
    expect(find.text('Undo move'), findsNothing);
  });

  testWidgets('Missed this week on today\'s card; Move to… writes from home', (
    tester,
  ) async {
    if (!hasFitness) return;
    final moves = _FakeRepo([benchMove()]);
    final strength = _FakeRepo([
      for (var i = 0; i < 3; i++)
        {'id': 's$i', 'date': wed, 'exercise': 'Pull-ups'},
    ]);
    final climbing = _FakeRepo([
      {'id': 'c1', 'date': DateTime(2026, 9, 29)},
    ]);
    await pump(
      tester,
      date: fri,
      moves: moves,
      strength: strength,
      climbing: climbing,
    );
    expect(find.text('MISSED THIS WEEK'), findsOneWidget);
    expect(find.text('Squat heavy — Mon, 0/1 sets'), findsOneWidget);
    expect(find.text('Norwegian — Tue, not logged'), findsOneWidget);
    // Climb logged Tue; pull-ups logged Wed; bench moved to today.
    expect(find.textContaining('Climb — HARD session —'), findsNothing);
    expect(find.textContaining('Pull-ups —'), findsNothing);
    expect(find.textContaining('Bench heavy —'), findsNothing);

    final row = find.ancestor(
      of: find.text('Squat heavy — Mon, 0/1 sets'),
      matching: find.byType(Row),
    );
    await tester.tap(
      find.descendant(
        of: row.first,
        matching: find.widgetWithText(TextButton, 'Move to…'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sat 10/3'));
    await tester.pumpAndSettle();
    final m = ProgramMove.fromRecord(moves.created.single)!;
    expect(m.item, 'Squat heavy');
    expect(m.from, DateTime(2026, 9, 28));
    expect(m.to, DateTime(2026, 10, 3));
    expect(m.source, 'manual');
    expect(find.text('Squat heavy — Mon, 0/1 sets'), findsNothing);
  });
}
