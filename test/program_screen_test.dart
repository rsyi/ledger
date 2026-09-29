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

import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/wm_store.dart';
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/ui/program_screen.dart';

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
  final programYaml =
      File('$_fitnessRepo/program.yaml').readAsStringSync();

  Future<String?> fetcher(String path) async =>
      path == 'coach/program.yaml' ? programYaml : null;

  Future<void> pump(WidgetTester tester, _FakeWmStore store) async {
    ProgramProvider.clearCache();
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: ProgramScreen(
        provider: ProgramProvider(fetcher),
        wmStore: store,
        // Wed Sep 30 → displayed week = cut wave week 1 (Sep 28).
        today: DateTime(2026, 9, 30),
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
    expect(find.text('squat heavy · bench volume'), findsOneWidget);
    expect(find.text('Squat 1×5 · 260 lb (81%)'), findsOneWidget);
    expect(find.text('Bench 4×8 · 165 lb (68%)'), findsOneWidget);
    expect(find.text('Bulgarian Split Squat 3×8-12'), findsOneWidget);
    expect(find.textContaining('Squat 1×10'), findsNothing); // no warm-ups
    expect(find.textContaining('Squat heavy: wave top'), findsNothing);

    // Backoff rule collapsed to one short line.
    expect(find.textContaining('hold ≤8 · drop 2.5-5% if over'),
        findsWidgets);

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

    expect(find.text('press heavy'), findsOneWidget);
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
}
