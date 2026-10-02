// ProgramDayCard — effective (post-moves) items, Move to… / Undo, and the
// "Missed this week" section. Runs against the LIVE airledger-fitness
// program.yaml (cut week of Mon 2026-09-28), like program_week_test.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/log_event_bus.dart';
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/week_state_loader.dart';
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/ui/widgets/program_day_card.dart';

const _fitness = '../airledger-fitness';

class _FakeRepo implements WarehouseConnector {
  final List<Record> rows;
  final created = <Record>[];
  final deleted = <Record>[];
  int lists = 0;

  /// When set, list() waits on it (holds a reload mid-flight).
  Completer<void>? gate;
  _FakeRepo([List<Record>? rows]) : rows = rows ?? [];

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    lists++;
    await gate?.future;
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

  setUp(() {
    ProgramProvider.clearCache();
    WeekStateLoader.clearKayaCache();
  });

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
    WmSnapshot? wm,
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
              wmSnapshot: wm == null ? null : () async => wm,
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

  testWidgets('a log event reloads WITHOUT a spinner and without '
      're-reading the Kaya climbing tab', (tester) async {
    if (!hasFitness) return;
    final climbing = _FakeRepo([
      {'id': 'c1', 'date': DateTime(2026, 9, 29)},
    ]);
    final strength = _FakeRepo();
    await pump(tester,
        date: fri, moves: _FakeRepo(), strength: strength, climbing: climbing);
    expect(climbing.lists, 1);
    final strengthLists = strength.lists;
    expect(find.text('0 / 5 done'), findsOneWidget);

    strength.gate = Completer<void>();
    LogEventBus.instance.publish(const LogEvent('strength', {}));
    await tester.pump(); // event delivered → reload in flight
    await tester.pump();
    expect(strength.lists, strengthLists + 1, reason: 'reload started');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('0 / 5 done'), findsOneWidget,
        reason: 'previous data stays up while reloading');
    strength.gate!.complete();
    await tester.pumpAndSettle();
    expect(strength.lists, strengthLists + 1);
    expect(climbing.lists, 1, reason: 'Kaya climb days cached');
  });

  // ---- Plan-tab pricing + skips (2026-10-02) ----

  WmSnapshot tms() => (
        workingMax: [
          for (final (lift, v) in [
            ('squat', 320.0),
            ('bench', 245.0),
            ('deadlift', 340.0),
            ('press', 145.0),
          ])
            WorkingMaxRow(
              lift: lift,
              variant: '',
              valueLb: v,
              effectiveFrom: DateTime(2026, 9, 1),
              source: 'manual',
              reason: 'test',
            ),
        ],
        readings: const <ReadingRow>[],
      );

  testWidgets('rows show the Plan tab\'s priced sets × reps @ load', (
    tester,
  ) async {
    if (!hasFitness) return;
    await pump(tester, date: fri, moves: _FakeRepo(), wm: tms());
    // Deadlift TM 340 × wave wk1 81% = 275; back-offs 75% = 255.
    expect(find.text('1×5 · 275 lb (81%)'), findsOneWidget);
    expect(find.text('2×4 · 255 lb (75%)'), findsOneWidget);
    expect(find.text('Romanian Deadlift 2×8-12'), findsOneWidget);
    // One line per item; climb keeps its prose.
    expect(find.text('Deadlift heavy'), findsOneWidget);
    expect(find.textContaining('technique/volume'), findsOneWidget);
  });

  testWidgets('a moved-in item keeps its home day\'s priced load', (
    tester,
  ) async {
    if (!hasFitness) return;
    await pump(tester, date: fri, moves: _FakeRepo([benchMove()]), wm: tms());
    // Wed bench top: 245 × 0.811 → 200.
    expect(find.text('1×5 · 200 lb (81%)'), findsOneWidget);
  });

  testWidgets('info sheet leads with the program; no "+5 lb" over it', (
    tester,
  ) async {
    if (!hasFitness) return;
    final strength = _FakeRepo([
      {'id': 'w', 'date': DateTime(2026, 9, 25), 'exercise': 'Barbell Deadlift', 'weight': 225, 'reps': 3},
      {'id': 'a', 'date': DateTime(2026, 9, 25), 'exercise': 'Barbell Deadlift', 'weight': 315, 'reps': 1, 'rpe': 7.5},
      {'id': 'b', 'date': DateTime(2026, 9, 25), 'exercise': 'Barbell Deadlift', 'weight': 275, 'reps': 3, 'rpe': 7},
      {'id': 'r', 'date': DateTime(2026, 9, 28), 'exercise': 'Romanian Deadlift', 'weight': 135, 'reps': 10, 'rpe': 6},
    ]);
    await pump(tester,
        date: fri, moves: _FakeRepo(), strength: strength, wm: tms());
    await tester.tap(find.text('Deadlift heavy'));
    await tester.pumpAndSettle();
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('1×5 · 275 lb (81%) (wave wk1, 81% TM)'), findsOneWidget);
    expect(find.text('LAST SESSION · Fri 9/25'), findsOneWidget);
    expect(find.text('1 set · 1 reps · top 315 lb · RPE 7.5'), findsOneWidget);
    expect(find.textContaining('Add ~5 lb'), findsNothing);
    expect(find.textContaining("don't add load"), findsOneWidget);
  });

  testWidgets('Skip… writes a skip row; the row reads "skipped — reason"', (
    tester,
  ) async {
    if (!hasFitness) return;
    final moves = _FakeRepo();
    await pump(tester, date: fri, moves: moves);
    expect(find.text('0 / 5 done'), findsOneWidget);
    await tester.tap(menuOf('Deadlift heavy'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Skip…'));
    await tester.pumpAndSettle();
    // Reason is required.
    final skipBtn = find.widgetWithText(FilledButton, 'Skip');
    expect(tester.widget<FilledButton>(skipBtn).onPressed, isNull);
    await tester.tap(find.widgetWithText(ActionChip, 'pain'));
    await tester.enterText(find.byType(TextField), 'pain');
    await tester.pumpAndSettle();
    await tester.tap(skipBtn);
    await tester.pumpAndSettle();

    final m = ProgramMove.fromRecord(moves.created.single)!;
    expect(m.source, 'skip');
    expect(m.isSkip, isTrue);
    expect(m.item, 'Deadlift heavy');
    expect(m.from, fri);
    expect(m.to, fri);
    expect(m.note, 'pain');
    expect(find.text('skipped — pain'), findsOneWidget);
    expect(find.text('0 / 4 done'), findsOneWidget, reason: 'not counted');
    expect(find.text('→ Fri'), findsNothing, reason: 'a skip is not a move');
  });

  testWidgets('Undo skip deletes the skip row', (tester) async {
    if (!hasFitness) return;
    final moves = _FakeRepo([
      ProgramMove(
        id: 's1',
        to: fri,
        from: fri,
        item: 'Deadlift heavy',
        period: 'AM',
        source: 'skip',
        note: 'time',
      ).toRecord(),
    ]);
    await pump(tester, date: fri, moves: moves);
    expect(find.text('skipped — time'), findsOneWidget);
    await tester.tap(menuOf('Deadlift heavy'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(PopupMenuItem<String>, 'Move to…'),
        findsNothing);
    await tester.tap(find.text('Undo skip'));
    await tester.pumpAndSettle();
    expect([for (final r in moves.deleted) r['id']], ['s1']);
    expect(find.text('skipped — time'), findsNothing);
    expect(find.text('0 / 5 done'), findsOneWidget);
  });

  testWidgets('Skip… on a missed row clears it from MISSED THIS WEEK', (
    tester,
  ) async {
    if (!hasFitness) return;
    final moves = _FakeRepo();
    await pump(tester, date: fri, moves: moves);
    expect(find.text('Squat heavy — Mon, 0/1 sets'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('Squat heavy — Mon, 0/1 sets'),
      matching: find.byType(Row),
    );
    await tester.tap(find.descendant(
        of: row.first, matching: find.widgetWithText(TextButton, 'Skip…')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fatigue');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Skip'));
    await tester.pumpAndSettle();
    final m = ProgramMove.fromRecord(moves.created.single)!;
    expect(m.source, 'skip');
    expect(m.to, DateTime(2026, 9, 28));
    expect(m.from, DateTime(2026, 9, 28));
    expect(find.text('Squat heavy — Mon, 0/1 sets'), findsNothing);
  });
}
