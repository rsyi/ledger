// Widget tests for lib/ui/widgets/forecast_section.dart (sim2, wave 3):
// the dials row re-runs the sim and changes the outputs, §8 presets
// apply (with the baseline-vs-scenario table), over-budget weeks render
// as red flags, both strength lines (app index + true expressed) are
// plotted, the §5 μ branch toggles, the §9.5 parameter sheet edits
// re-run the horizon, and the section reflows at 360dp.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/program_metrics.dart' show WeightRow;
import 'package:airledger/services/program_observed.dart'
    show observedWeightStats;
import 'package:airledger/services/sim2_harness.dart';
import 'package:airledger/ui/widgets/forecast_section.dart';

final _today = DateTime(2026, 9, 26);

List<WeightRow> observedDaily() => [
      for (var i = 90; i >= 0; i--)
        WeightRow(
          date: _today.subtract(Duration(days: i)),
          // Gentle downtrend + a little scatter around the seed bw.
          weightLbs: 163.0 + i * 0.08 + (i % 3 - 1) * 0.4,
        ),
    ];

ForecastInputs inputs() => ForecastInputs(
      blocks: sim2DefaultBlocks(),
      observedDaily: observedDaily(),
      stats: observedWeightStats(observedDaily(), _today),
      observedBw: 163.0,
      observedIndexTotal: 878.0,
    );

/// Synchronous-ish MC runner (few paths, no isolate) so tests stay
/// deterministic and fast; the production default is Isolate.run.
Future<Sim2McSummary> testMcRunner(Sim2McJob j) async => sim2MonteCarlo(
      params: j.params,
      blocks: j.blocks,
      start: j.start,
      presetId: j.presetId,
      overrides: j.overrides,
      muDeficit: j.muDeficit,
      observedBw: j.observedBw,
      observedIndexTotal: j.observedIndexTotal,
      paths: 40,
    );

Future<void> pumpSection(
  WidgetTester tester, {
  Size surface = const Size(800, 5200),
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ForecastSection(
          inputs: inputs(),
          today: _today,
          mcRunner: testMcRunner,
        ),
      ),
    ),
  ));
  await tester.pump(); // let the MC futures land
  await tester.pump();
}

LineChartData chartData(WidgetTester tester, String key) {
  final chart = tester.widget<LineChart>(
    find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(LineChart),
    ),
  );
  return chart.data;
}

String summaryText(WidgetTester tester) {
  final texts = tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(const ValueKey('sim2-summary')),
      matching: find.byType(Text),
    ),
  );
  return texts.map((t) => t.data).join(' | ');
}

Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 400,
      scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

void main() {
  testWidgets('baseline renders: summary, both strength lines, P(V8)',
      (tester) async {
    await pumpSection(tester);
    final summary = summaryText(tester);
    expect(summary, contains('Baseline'));
    expect(summary, contains("Dec 5 '27"));
    // MC landed (injected runner): the summary carries P(V8).
    expect(summary, contains('P(V8)'));

    // Expressed chart: index line AND true line (baseline hidden, no
    // capacity toggle → exactly 2 line series).
    final expressed = chartData(tester, 'sim2-expressed-chart');
    expect(expressed.lineBarsData.length, 2);
    final idxLine = expressed.lineBarsData[0]; // dashed index first
    final trueLine = expressed.lineBarsData[1];
    expect(idxLine.dashArray, isNotNull);
    expect(trueLine.dashArray, isNull);
    // The attempt-gate lag: index starts below true (the cut's N=3 is
    // an attempt week, so most of the 39 lb under-read closes fast —
    // ~11 lb left after week 1), converging by the horizon.
    expect(idxLine.spots.first.y, lessThan(trueLine.spots.first.y - 4));
    expect((idxLine.spots.last.y - trueLine.spots.last.y).abs(), lessThan(8));

    // The P(V8) caption is a real number, not the computing fallback.
    expect(find.textContaining('P(V8 sent'), findsOneWidget);
    // No compare card while at baseline.
    expect(find.byKey(const ValueKey('sim2-compare')), findsNothing);
  });

  testWidgets('capacity toggle adds the capacity line', (tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey('sim2-capacity-toggle')));
    await tester.pump();
    expect(chartData(tester, 'sim2-expressed-chart').lineBarsData.length, 3);
  });

  testWidgets('dials change outputs: N override re-runs the sim',
      (tester) async {
    await pumpSection(tester);
    final before = summaryText(tester);
    final yBefore =
        chartData(tester, 'sim2-expressed-chart').lineBarsData.last.spots.last.y;

    await tester.drag(
        find.byKey(const ValueKey('sim2-dial-n')), const Offset(300, 0));
    await tester.pump();
    await tester.pump(); // MC future

    expect(summaryText(tester), isNot(before));
    final yAfter =
        chartData(tester, 'sim2-expressed-chart').lineBarsData.last.spots.last.y;
    expect(yAfter, isNot(yBefore));
    // An override makes it a scenario: compare card + baseline line.
    expect(find.byKey(const ValueKey('sim2-compare')), findsOneWidget);

    // Reset restores the baseline.
    await tester.tap(find.byKey(const ValueKey('sim2-dials-reset')));
    await tester.pump();
    await tester.pump();
    expect(summaryText(tester), before);
    expect(find.byKey(const ValueKey('sim2-compare')), findsNothing);
  });

  testWidgets('preset application: Climb more shows the budget bite',
      (tester) async {
    await pumpSection(tester);
    final baseSummary = summaryText(tester);
    final baseTotal =
        chartData(tester, 'sim2-expressed-chart').lineBarsData.last.spots.last.y;

    await tester.tap(find.byKey(const ValueKey('sim2-preset-climb_more')));
    await tester.pump();
    await tester.pump(); // MC futures

    final summary = summaryText(tester);
    expect(summary, isNot(baseSummary));
    expect(summary, contains('Climb more'));
    expect(summary, contains('baseline:')); // §8: baseline reported next to it

    // Strength falls (report: 968 vs 1023) and the scenario chart now
    // carries the baseline line too (grey + index + true).
    final expressed = chartData(tester, 'sim2-expressed-chart');
    expect(expressed.lineBarsData.length, 3);
    expect(expressed.lineBarsData.last.spots.last.y, lessThan(baseTotal - 30));

    // Compare card present with over-budget row.
    await scrollTo(tester, find.byKey(const ValueKey('sim2-compare')));
    expect(find.byKey(const ValueKey('sim2-compare')), findsOneWidget);
    expect(find.textContaining('over-budget wks'), findsOneWidget);

    // Back to baseline.
    await tester.tap(find.byKey(const ValueKey('sim2-preset-baseline')));
    await tester.pump();
    await tester.pump();
    expect(summaryText(tester), baseSummary);
  });

  testWidgets('red flags: over-budget weeks render as red spans on F',
      (tester) async {
    await pumpSection(tester);
    await scrollTo(tester, find.byKey(const ValueKey('sim2-f-chart')));
    final f = chartData(tester, 'sim2-f-chart');
    final annotations = f.rangeAnnotations.verticalRangeAnnotations;
    // Block bands + red spans; the red ones carry the stronger alpha.
    final red = [
      for (final a in annotations)
        if ((a.color?.a ?? 0) > 0.12) a,
    ];
    expect(red, isNotEmpty,
        reason: 'the baseline cut runs L=6.9 > 6.0 → red spans');
    // The §8 confidence-collapse caption with the week count.
    expect(find.textContaining('over-budget weeks: 56'), findsOneWidget);
    expect(find.textContaining('confidence'), findsOneWidget);
  });

  testWidgets('§5 μ branch toggle moves BF%', (tester) async {
    await pumpSection(tester);
    await scrollTo(tester, find.byKey(const ValueKey('sim2-mu-zero')));
    final before = find
        .textContaining('horizon BF')
        .evaluate()
        .single
        .widget as Text;
    await tester.tap(find.byKey(const ValueKey('sim2-mu-zero')));
    await tester.pump();
    await tester.pump();
    final after = find
        .textContaining('horizon BF')
        .evaluate()
        .single
        .widget as Text;
    expect(after.data, isNot(before.data)); // 17.6% → 16.1%
    expect(find.textContaining('Nov DEXA'), findsOneWidget);
  });

  testWidgets('§9.5 parameter sheet: provenance tags + edit re-runs',
      (tester) async {
    await pumpSection(tester);
    await scrollTo(tester, find.byKey(const ValueKey('sim2-params-tile')));
    await tester.tap(find.byKey(const ValueKey('sim2-params-tile')));
    await tester.pumpAndSettle();

    // Every §9.5 def renders a row; the eDep caveat is in the footer.
    await scrollTo(tester, find.byKey(const ValueKey('sim2-param-e_dep')));
    expect(find.textContaining('replay checkpoints, NOT the window fit'),
        findsOneWidget);

    final before = summaryText(tester);
    await tester.tap(find.byKey(const ValueKey('sim2-param-a')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '5.0');
    await tester.tap(find.text('Apply'));
    await tester.pump();
    await tester.pump();
    expect(summaryText(tester), isNot(before));
    expect(find.textContaining('EDITED'), findsOneWidget);

    // Reset to fitted restores the baseline horizon.
    await scrollTo(tester, find.byKey(const ValueKey('sim2-params-reset')));
    await tester.tap(find.byKey(const ValueKey('sim2-params-reset')));
    await tester.pump();
    await tester.pump();
    expect(summaryText(tester), before);
  });

  testWidgets('reflows without overflow at 360dp', (tester) async {
    await pumpSection(tester, surface: const Size(360, 6500));
    expect(find.byKey(const ValueKey('sim2-expressed-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim2-f-chart')), findsOneWidget);
    // Reaching here without a RenderFlex overflow report = pass.
  });
}
