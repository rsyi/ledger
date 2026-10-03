// The Today program card and the coach's read (day synthesis) resolve the
// day through the SAME DayStatus — they cannot disagree. Regression for
// 2026-10-02: the card ticked Fri's PM "Climb — LIGHT session" from a
// Whoop MORNING climb while the read said "make sure that PM light
// climbing session actually happens". Runs against the LIVE
// airledger-fitness program.yaml (cut week of Mon 2026-09-28).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/day_status.dart';
import 'package:airledger/services/day_synthesis.dart';
import 'package:airledger/services/day_synthesis_service.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/week_state_loader.dart';
import 'package:airledger/ui/widgets/program_day_card.dart';

const _fitness = '../airledger-fitness';

class _Repo implements WarehouseConnector {
  final List<Record> rows;
  _Repo([List<Record>? rows]) : rows = rows ?? [];
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      [...rows];
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
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
            type:
                d.endsWith('date') ? DimensionType.date : DimensionType.string,
            expr: d,
          ),
      ],
    );

void main() {
  final hasFitness = File('$_fitness/coach/program.yaml').existsSync();
  String? read(String path) {
    final f = File('$_fitness/$path');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  final fri = DateTime(2026, 10, 2);
  final strengthView =
      _view('strength', ['id', 'date', 'exercise', 'weight', 'reps']);
  final workoutsView = _view('whoop_workouts',
      ['id', 'date', 'start_time', 'sport', 'strain', 'duration_min']);
  final movesView = _view('program_moves',
      ['id', 'date', 'from_date', 'item', 'period', 'source', 'note']);

  Record set(String id, String ex, num w, int r) =>
      {'id': id, 'date': fri, 'exercise': ex, 'weight': w, 'reps': r};
  final strength = _Repo([
    set('t1', 'Barbell Deadlift', 275, 6),
    set('b1', 'Barbell Deadlift', 245, 5),
    set('b2', 'Barbell Deadlift', 245, 5),
    set('r1', 'Romanian Deadlift', 185, 10),
    set('r2', 'Romanian Deadlift', 185, 10),
  ]);
  // The 10:25 Whoop rock-climbing session (live row; Sheets-style
  // space-separated datetime).
  final workouts = _Repo([
    {
      'id': 'w1',
      'date': '2026-10-02',
      'start_time': '2026-10-02 10:25:00',
      'sport': 'rock-climbing',
      'strain': 8,
      'duration_min': 25,
    },
  ]);

  setUp(() {
    ProgramProvider.clearCache();
    WeekStateLoader.clearKayaCache();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('card ticks the morning climb; the read says DONE, not pending',
      (tester) async {
    if (!hasFitness) return;
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProgramDayCard(
            provider: ProgramProvider((p) async => read(p)),
            label: 'Today',
            date: fri,
            now: () => DateTime(2026, 10, 2, 15),
            strengthView: strengthView,
            strengthRepo: strength,
            workoutsView: workoutsView,
            workoutsRepo: workouts,
            programMovesView: movesView,
            programMovesRepo: _Repo(),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // Card: the PM climb is ticked from Whoop ("strain 8.0").
    expect(find.textContaining('Climb — LIGHT session  strain 8.0'),
        findsOneWidget);
    // Fri: deadlift heavy + back-offs + RDL + climb done; bench volume open.
    expect(find.text('4 / 5 done'), findsOneWidget);

    // Synthesis over the SAME sources.
    late DaySynthesisContext c;
    await tester.runAsync(() async {
      c = await DaySynthesisService(
        llm: null,
        modelName: null,
        mealsView: null,
        mealsRepo: null,
        strengthView: strengthView,
        strengthRepo: strength,
        cardioView: null,
        cardioRepo: null,
        climbingView: null,
        climbingRepo: null,
        workoutsView: workoutsView,
        workoutsRepo: workouts,
        programMovesView: movesView,
        programMovesRepo: _Repo(),
        provider: ProgramProvider((p) async => read(p)),
        now: () => DateTime(2026, 10, 2, 15),
      ).buildContext();
    });
    final st = c.status!;
    expect(st.doneCount, 4);
    expect(st.live.length, 5);
    final climb = st.items.singleWhere((i) => i.kind == 'climb');
    expect(climb.state, DayItemState.done);
    expect(c.climbToCome, isFalse);
    final p = buildDaySynthesisPrompt(c);
    expect(p, contains('- DONE Climb — LIGHT session — Whoop rock-climbing '
        '10:25, strain 8.0, 25 min (planned PM, done earlier — complete)'));
    expect(p, isNot(contains('PENDING Climb')));
    expect(p, contains('- PENDING Bench volume'));
    expect(p, contains('TRAINING LEFT TODAY: Bench volume'));
  });
}
