// Widget tests for the restructured Program (routine) screen against
// the LIVE airledger-fitness program.yaml:
//   * day tiles: one summary line + bare exercise rows with load and
//     %-of-TM (no template prose, no paragraphs);
//   * TRAINING MAXES at the top: per-lift current value + 2-week
//     signal, Confirm on pending values;
//   * jargon audit: nothing on the screen says "wave", "Rx", or "§";
//   * determinism: a manual TM edit immediately reprices every
//     displayed load (store cache busted on write + full refetch).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/ui/design/design.dart' show AppCard;

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/app_settings.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/wm_store.dart';
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/ui/program_screen.dart';

import 'support/travel_week_moves.dart';

const _fitnessRepo = '../airledger-fitness/coach';

class _FakeWmStore extends WmStore {
  _FakeWmStore(this.rows)
      : super(spreadsheetId: 'test', serviceAccountKeyJson: '{}');

  final List<WorkingMaxRow> rows;
  int snapshots = 0;

  @override
  Future<WmSnapshot?> snapshot({bool force = false}) async {
    snapshots++;
    return (workingMax: List.of(rows), readings: const <ReadingRow>[]);
  }

  @override
  Future<void> confirmSeed(String lift) async {
    final current = currentWorkingMax(rows, lift);
    if (current == null) return;
    rows.add(WorkingMaxRow(
      lift: lift,
      variant: current.variant,
      valueLb: current.valueLb,
      effectiveFrom: DateTime.utc(2026, 9, 30),
      source: 'seed',
      reason: 'confirmed in test',
      confirmed: true,
    ));
  }

  @override
  Future<void> setWorkingMax({
    required String lift,
    required double valueLb,
    required String reason,
  }) async {
    rows.add(WorkingMaxRow(
      lift: lift,
      variant: 'paused',
      valueLb: valueLb,
      effectiveFrom: DateTime.utc(2026, 9, 30),
      source: 'manual',
      reason: reason,
      confirmed: true,
    ));
  }
}

/// Strength history stub (accessory double progression reads it).
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

/// Last week's bodyweight work, logged the app's way: weight = the
/// lifter's bodyweight on the day (the form prefills it).
List<Record> _bodyweightHistory() => [
      for (final (day, ex, w, reps) in [
        (23, 'Pull Up', 160.5, 8),
        (23, 'Muscle Up', 161.0, 1),
        (24, 'Muscle Up Green Band', 173.0, 4),
        (24, 'Hanging Leg Raise', 161.0, 10),
        (24, 'Parallel Bar Triceps Dip', 173.0, 9),
      ])
        for (var i = 0; i < 3; i++)
          {
            'date': DateTime(2026, 9, day),
            'exercise': ex,
            'weight': w,
            'reps': reps,
            'rpe': 7,
          },
    ];

final _movesView = ViewSchema(
  name: 'program_moves',
  datasource: 'gsheets',
  table: 'program_moves',
  entities: const [],
  measures: const [],
  dimensions: [
    Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
  ],
);

List<WorkingMaxRow> _seedRows({bool confirmed = false}) => [
      for (final (lift, variant, value) in [
        ('bench', 'paused', 240.0),
        ('squat', 'belted', 320.0),
        ('deadlift', 'belted', 330.0),
        ('press', 'strict', 140.0),
      ])
        WorkingMaxRow(
          lift: lift,
          variant: variant,
          valueLb: value,
          effectiveFrom: DateTime.utc(2026, 9, 21),
          source: 'seed',
          reason: 'seed',
          confirmed: confirmed,
        ),
    ];

void main() {
  // The cases below pin Mon–Sun weeks (the live program.yaml DEFAULTS to
  // saturday): the synced setting wins over the program default. The
  // SATURDAY-week case sets its own.
  setUp(() => AppSettings.debugSet('monday'));
  tearDown(() => AppSettings.debugSet(null));

  final programYaml =
      File('$_fitnessRepo/program.yaml').readAsStringSync();

  Future<String?> fetcher(String path) async =>
      path == 'coach/program.yaml' ? programYaml : null;

  Future<void> pump(WidgetTester tester, _FakeWmStore store,
      {List<Record>? history,
      Size size = const Size(420, 2400),
      List<Record>? moves,
      DateTime? today}) async {
    ProgramProvider.clearCache();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: ProgramScreen(
        provider: ProgramProvider(fetcher),
        wmStore: store,
        strengthRepo: history == null ? null : _FakeRepo(history),
        strengthView: history == null ? null : _strengthView,
        programMovesView: moves == null ? null : _movesView,
        programMovesRepo: moves == null ? null : _FakeRepo(moves),
        // Wed Sep 30 → displayed week = cut wave week 1 (Sep 28).
        today: today ?? DateTime(2026, 9, 30),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('header + day tiles: plain-words status, one summary line, '
      'bare rows with %-of-TM — and never the word wave', (tester) async {
    await pump(tester, _FakeWmStore(_seedRows(confirmed: true)));

    // Header: plain statement of the week.
    expect(find.text('Week 1 of 4 · top set 5 reps @ 81%'), findsOneWidget);

    // Monday: summary line + bare rows (squat 320 × 0.811 → 260;
    // bench 240 × 0.68 → 165). Warm-ups and prose are not rendered.
    expect(find.text('Squat heavy · bench volume'), findsOneWidget);
    expect(find.text('Squat 1×5 · 260 lb (81%)'), findsOneWidget);
    expect(find.text('Bench 4×8 · 165 lb (68%)'), findsOneWidget);
    expect(find.text('Bulgarian Split Squat 3×8-12'), findsOneWidget);
    expect(find.textContaining('Squat 1×10'), findsNothing); // no warm-ups
    expect(find.textContaining('Squat heavy: wave top'), findsNothing);

    // Backoff rule collapsed to one plain-words line.
    expect(find.text('Back-offs: keep RPE ≤ 8; if higher, drop 2.5–5%'),
        findsWidgets);

    // Each day is its own card; today's (Wed Sep 30) carries the accent
    // outline, the others don't.
    expect(
        tester
            .widget<AppCard>(
                find.byKey(const ValueKey('routine-day-2026-09-30')))
            .highlighted,
        isTrue);
    expect(
        tester
            .widget<AppCard>(
                find.byKey(const ValueKey('routine-day-2026-09-28')))
            .highlighted,
        isFalse);

    // Jargon audit over everything rendered.
    for (final banned in ['wave', 'Wave', 'Rx', '§']) {
      expect(find.textContaining(banned, findRichText: true), findsNothing,
          reason: 'jargon "$banned" leaked onto the routine screen');
    }
  });

  testWidgets('SATURDAY REGRESSION: the displayed Saturday is a full OHP '
      'session, never Rest', (tester) async {
    // Displayed week = Mon Sep 28 – Sun Oct 4; the accounting window
    // (week_start: saturday) is Sat Sep 26 – Fri Oct 2. The screen used
    // to price the SNAPPED window, so Sat Oct 3 rendered as "Rest".
    await pump(tester, _FakeWmStore(_seedRows(confirmed: true)));

    expect(find.text('Press heavy'), findsOneWidget);
    // Wave top: press 140 × 0.811 = 113.5 → 115 (81%).
    expect(find.text('Press 1×5 · 115 lb (81%)'), findsOneWidget);
    // Back-offs 3×6-8 @ 72%: 140 × 0.72 = 100.8 → 100.
    expect(find.text('Press 3×6 · 100 lb (72%)'), findsOneWidget);
    // The approved Saturday movements, verbatim.
    expect(find.text('Seated Cable Row 3×8-12'), findsOneWidget);
    expect(find.text('Cable Face Pull 2×12-20'), findsOneWidget);
    expect(find.text('Cable External Rotation 2×12-20'), findsOneWidget);
    // Exactly one rest day on screen: Sunday.
    expect(find.text('Rest'), findsOneWidget);
  });

  testWidgets('training maxes at the top: value + since-date, pending '
      'seeds confirmable', (tester) async {
    final store = _FakeWmStore(_seedRows());
    await pump(tester, store);

    expect(find.text('TRAINING MAXES'), findsOneWidget);
    expect(find.textContaining('Squat', findRichText: true), findsWidgets);
    expect(find.textContaining('since Sep 21', findRichText: true),
        findsNWidgets(4));
    expect(find.text('Confirm'), findsNWidgets(4));
    // ExerciseRow rows: lift name, the TM as the trailing figure, the
    // since-date as meta; press reads "Overhead press" (Progress names).
    final squatRow = find.byKey(const ValueKey('tm-row-squat'));
    expect(find.descendant(of: squatRow, matching: find.text('320 lb')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('tm-row-press')),
            matching: find.textContaining('Overhead press',
                findRichText: true)),
        findsOneWidget);

    // Confirm one seed → its button clears, others stay.
    await tester.tap(find.text('Confirm').first);
    await tester.pumpAndSettle();
    expect(find.text('Confirm'), findsNWidgets(3));
  });

  testWidgets('manual TM edit deterministically reprices every displayed '
      'load', (tester) async {
    final store = _FakeWmStore(_seedRows(confirmed: true));
    await pump(tester, store);
    expect(find.text('Bench 4×8 · 165 lb (68%)'), findsOneWidget);

    // Set bench 250 through the menu dialog (bench is the default lift).
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set training max…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '250');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();

    // The Monday bench volume slot reprices: 250 × 0.68 = 170.
    expect(find.text('Bench 4×8 · 170 lb (68%)'), findsOneWidget);
    expect(find.text('Bench 4×8 · 165 lb (68%)'), findsNothing);
    // And the TM row carries the new value + its date (the seed is
    // outside the 2-week lookback window here, so no "was" tail).
    expect(find.textContaining('since Sep 30', findRichText: true),
        findsOneWidget);
  });

  testWidgets('bodyweight movements read BW, never a priced load '
      '(audit: "Pull Up 3×6-10 · 160.5 lb")', (tester) async {
    await pump(tester, _FakeWmStore(_seedRows(confirmed: true)),
        history: _bodyweightHistory());

    expect(find.text('Pull Up 3×6-10 · BW'), findsWidgets);
    expect(find.text('Muscle Up Green Band 2×3-5 · BW'), findsOneWidget);
    expect(find.text('Parallel Bar Triceps Dip 3×8-12 · BW'), findsOneWidget);
    expect(find.text('Hanging Leg Raise 3×8-15 · BW'), findsOneWidget);
    final priced = RegExp(
        r'^(Pull Up|Muscle Up|Parallel Bar Triceps Dip|Hanging Leg Raise)'
        r'.* lb');
    expect(
        find.byWidgetPredicate(
            (w) => w is Text && priced.hasMatch(w.data ?? '')),
        findsNothing);
  });

  testWidgets('STRIKETHROUGH AUDIT: no routine line is decorated, and the '
      'list stops above the gesture-nav inset', (tester) async {
    // The device screenshot's "struck-through" Muscle Up Green Band was
    // the gesture-navigation pill drawn over the last visible line
    // (edge-to-edge, root-navigator route, no bottom bar).
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPadding);
    await pump(tester, _FakeWmStore(_seedRows(confirmed: true)),
        history: _bodyweightHistory(), size: const Size(420, 900));

    final listRect =
        tester.getRect(find.byKey(const ValueKey('routine-list')));
    expect(listRect.bottom, lessThanOrEqualTo(900 - 48));

    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      expect(t.style?.decoration, isNot(TextDecoration.lineThrough),
          reason: '"${t.data}" is struck through');
    }
  });

  testWidgets('TRAVEL WEEK: next week renders the EFFECTIVE days — Mon/Tue '
      'carry the moved work at home-day prices ("from Wed"), Wed–Sat read '
      'Skipped — travel, the 4x4 lands on Sunday', (tester) async {
    await pump(
      tester,
      _FakeWmStore(_seedRows(confirmed: true)),
      moves: [for (final m in travelWeekMoves()) m.toRecord()],
      // Mon Oct 5 → displayed week Oct 5–11 (cut wave week 2: 4 @ 84%).
      today: DateTime(2026, 10, 5),
    );
    Finder inDay(String ymd, Finder f) => find.descendant(
        of: find.byKey(ValueKey('routine-day-$ymd')), matching: f);
    Finder rich(String t) => find.text(t, findRichText: true);

    // Monday: own squat top + Wed bench + Sat OHP (summary over the
    // effective lines); Mon's bench volume + triceps skipped.
    expect(inDay('2026-10-05', find.text('Squat heavy · bench heavy · press heavy')),
        findsOneWidget);
    // Wed pricing: bench 240 × 0.837 = 200.9 → 200; back-offs 72% → 175.
    expect(inDay('2026-10-05', rich('Bench 1×4 · 200 lb (84%) · from Wed')),
        findsOneWidget);
    expect(inDay('2026-10-05', rich('Bench 3×6 · 175 lb (72%) · from Wed')),
        findsOneWidget);
    expect(inDay('2026-10-05', rich('Press 1×4 · 115 lb (84%) · from Sat')),
        findsOneWidget);
    expect(inDay('2026-10-05', find.textContaining('Pull Up', findRichText: true)),
        findsOneWidget);
    expect(inDay('2026-10-05', find.textContaining('68%', findRichText: true)),
        findsNothing, reason: 'Mon bench volume is skipped');
    expect(
        inDay('2026-10-05',
            find.text('Skipped: Bench volume, Triceps extension '
                '(travel Wed–Sat)')),
        findsOneWidget);

    // Tuesday: Fri deadlift + RDL, Sat row + face pulls, the hard climb;
    // the 4x4 moved out to Sunday.
    expect(inDay('2026-10-06', find.text('Deadlift heavy · hard climb')),
        findsOneWidget);
    expect(inDay('2026-10-06', rich('Deadlift 1×4 · 275 lb (84%) · from Fri')),
        findsOneWidget);
    expect(inDay('2026-10-06',
            find.textContaining('Seated Cable Row', findRichText: true)),
        findsOneWidget);
    expect(inDay('2026-10-06', find.text('Norwegian → Sun')), findsOneWidget);

    // Wed–Sat: travel — no priced lines left, muted skipped summary.
    for (final d in ['07', '08', '09', '10']) {
      expect(inDay('2026-10-$d', find.text('Skipped — travel Wed–Sat')),
          findsOneWidget, reason: 'Oct $d');
      expect(inDay('2026-10-$d', find.textContaining(' lb', findRichText: true)),
          findsNothing, reason: 'Oct $d');
    }
    expect(inDay('2026-10-07',
            find.text('Bench heavy, Bench back-offs, Pull-ups → Mon')),
        findsOneWidget);
    expect(inDay('2026-10-07', find.text('Skipped: Squat volume, OHP volume')),
        findsOneWidget);
    expect(inDay('2026-10-08', find.text('7 skipped')), findsOneWidget);

    // Sunday: the moved 4x4.
    expect(inDay('2026-10-11', find.text('4x4')), findsOneWidget);
    expect(inDay('2026-10-11', find.text('From Tue: Norwegian')),
        findsOneWidget);
  });

  testWidgets('SATURDAY WEEK (live travel moves): Sat 10/3 – Fri 10/9; '
      'next week\'s Sat items pulled forward onto Tue; the Tue→Sun '
      'Norwegian (a later move across the boundary) is ignored',
      (tester) async {
    AppSettings.debugSet('saturday');
    final moves = [for (final m in liveTravelMoves()) m.toRecord()];
    await pump(
      tester,
      _FakeWmStore(_seedRows(confirmed: true)),
      moves: moves,
      today: DateTime(2026, 10, 3), // Sat — the week's first day
    );
    Finder inDay(String ymd, Finder f) => find.descendant(
        of: find.byKey(ValueKey('routine-day-$ymd')), matching: f);
    Finder rich(String t) => find.text(t, findRichText: true);

    // Header: the configured range.
    expect(find.text('Oct 3 – Oct 9'), findsOneWidget);
    for (var d = 3; d <= 9; d++) {
      expect(find.byKey(ValueKey('routine-day-2026-10-0$d')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('routine-day-2026-10-10')), findsNothing);

    // Sat 10/3: the untouched OHP day (wave week of Mon 9/28: 5 @ 81%).
    expect(inDay('2026-10-03', rich('Press 1×5 · 115 lb (81%)')),
        findsOneWidget);
    // Sun 10/4: rest.
    expect(inDay('2026-10-04', find.text('Rest')), findsOneWidget);

    // Mon 10/5: squat top + Wed bench + pull-ups; the OHP now lives Tue.
    expect(inDay('2026-10-05', rich('Bench 1×4 · 200 lb (84%) · from Wed')),
        findsOneWidget);
    expect(inDay('2026-10-05', find.textContaining('from Sat',
            findRichText: true)),
        findsNothing);

    // Tue 10/6: Fri deadlift + Sat 10/10 (NEXT week) OHP/row/face pulls
    // pulled forward, priced on their home day (wave week of 10/5).
    expect(inDay('2026-10-06', rich('Deadlift 1×4 · 275 lb (84%) · from Fri')),
        findsOneWidget);
    expect(inDay('2026-10-06', rich('Press 1×4 · 115 lb (84%) · from Sat')),
        findsOneWidget);
    expect(inDay('2026-10-06',
            find.textContaining('Seated Cable Row', findRichText: true)),
        findsOneWidget);
    expect(inDay('2026-10-06',
            find.textContaining('Cable Face Pull', findRichText: true)),
        findsOneWidget);
    // Norwegian stays home (Tue→Sun 10/11 crosses into next week: not
    // allowed for a LATER move).
    expect(inDay('2026-10-06', find.text('Norwegian → Sun')), findsNothing);

    expect(
        inDay('2026-10-06',
            find.text('Deadlift heavy · press heavy · 4x4 · hard climb')),
        findsOneWidget);
    // Wed–Fri: travel.
    for (final d in ['07', '08', '09']) {
      expect(inDay('2026-10-$d', find.text('Skipped — travel Wed–Sat')),
          findsOneWidget, reason: 'Oct $d');
    }

    // Next week (Sat 10/10 – Fri 10/16): the pulled-forward items leave
    // Sat 10/10; its remaining items are the travel skips.
    await tester.tap(find.byTooltip('Next week'));
    await tester.pumpAndSettle();
    expect(find.text('Oct 10 – Oct 16'), findsOneWidget);
    expect(inDay('2026-10-10', find.textContaining(' lb', findRichText: true)),
        findsNothing);
    expect(inDay('2026-10-10', find.text('Skipped — travel Wed–Sat')),
        findsOneWidget);
    expect(inDay('2026-10-11', find.text('Rest')), findsOneWidget);
  });
}
