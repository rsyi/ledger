// Widget tests for lib/ui/widgets/forecast_section.dart — the
// SINGLE-TRAJECTORY forecast (2026-09-28 directive): no lever UI
// (presets/dials/compare/μ toggle all gone), the NUTRITION card is the
// input surface with the calorie-delta what-if as the ONLY lever, the
// calendar extends past the declared blocks as a flat recomp
// steady-state, and the model-tracking line reflects the nightly
// recalibration state.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/forecast_calibration.dart'
    show ForecastMeta, RecalEvent;
import 'package:airledger/services/nutrition_model.dart';
import 'package:airledger/services/program_metrics.dart' show WeightRow;
import 'package:airledger/services/program_observed.dart'
    show observedWeightStats;
import 'package:airledger/services/recomp_review.dart' show MealRow;
import 'package:airledger/services/sim2_harness.dart';
import 'package:airledger/ui/widgets/forecast_section.dart';

final _today = DateTime(2026, 9, 26);

List<WeightRow> observedDaily() => [
      for (var i = 90; i >= 0; i--)
        WeightRow(
          date: _today.subtract(Duration(days: i)),
          // Steady cut trend ~0.75 lb/wk down to 163.
          weightLbs: 163.0 + i * (0.75 / 7),
        ),
    ];

/// 14 full Macrofactor days at 2000 kcal / 165 P / 220 C — against the
/// 0.75 lb/wk downtrend the implied maintenance is ~2375.
List<MealRow> meals() => [
      for (var i = 0; i < 14; i++)
        MealRow(
          eatenAt: DateTime.utc(2026, 9, 26 - i, 12).subtract(Duration.zero),
          calories: 2000,
          proteinG: 165,
          carbsG: 220,
          fatG: 60,
        ),
    ];

NutritionForecast nutrition() => buildNutritionForecast(
      meals: meals(),
      weighIns: observedDaily(),
      today: _today,
    );

ForecastInputs inputs({NutritionForecast? n, ForecastMeta? meta}) =>
    ForecastInputs(
      blocks: sim2DefaultBlocks(),
      observedDaily: observedDaily(),
      stats: observedWeightStats(observedDaily(), _today),
      observedBw: 163.0,
      observedIndexTotal: 878.0,
      nutrition: n,
      meta: meta,
    );

/// Synchronous-ish MC runner (few paths, no isolate) so tests stay
/// deterministic and fast; the production default is Isolate.run.
Future<Sim2McSummary> testMcRunner(Sim2McJob j) async => sim2MonteCarlo(
      params: j.params,
      blocks: j.blocks,
      start: j.start,
      blockOverrides: j.blockOverrides,
      observedBw: j.observedBw,
      observedIndexTotal: j.observedIndexTotal,
      paths: 20,
    );

Future<void> pumpSection(
  WidgetTester tester, {
  ForecastInputs? section,
  Size surface = const Size(800, 5200),
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ForecastSection(
          inputs: section ?? inputs(n: nutrition()),
          today: _today,
          mcRunner: testMcRunner,
        ),
      ),
    ),
  ));
  await tester.pump(); // let the MC future land
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

String textOf(WidgetTester tester, String key) =>
    (tester.widget<Text>(find.byKey(ValueKey(key)))).data ?? '';

Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 400,
      scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

void main() {
  testWidgets('single trajectory: nutrition card, extended horizon, '
      'tracking on, P(V8)', (tester) async {
    await pumpSection(tester);

    // NUTRITION card: maintenance ≈ 2375 ± band, implied rate ≈ −0.75.
    expect(find.byKey(const ValueKey('nutrition-card')), findsOneWidget);
    expect(textOf(tester, 'nutrition-maintenance'), contains('~2375'));
    expect(textOf(tester, 'nutrition-maintenance'), contains('energy balance'));
    expect(textOf(tester, 'nutrition-rate'), contains('-0.7'));

    // Summary runs to the steady-state horizon (Dec '27 + 52 wk), not
    // the declared calendar end.
    final summary = summaryText(tester);
    expect(summary, contains("Dec 3 '28"));
    expect(summary, isNot(contains("Dec 5 '27")));
    expect(summary, contains('P(V8)')); // MC landed
    expect(textOf(tester, 'forecast-tracking'),
        contains('model tracking: on'));
    expect(textOf(tester, 'forecast-tracking'),
        contains('rate from logged intake'));

    // Expressed chart: capacity (in-cut default ON) + index + true.
    final expressed = chartData(tester, 'sim2-expressed-chart');
    expect(expressed.lineBarsData.length, 3);
    final idxLine = expressed.lineBarsData[1];
    final trueLine = expressed.lineBarsData[2];
    expect(idxLine.spots.first.y, lessThan(trueLine.spots.first.y - 4));
  });

  testWidgets('no lever UI: presets, dials, compare card and μ toggle '
      'are gone', (tester) async {
    await pumpSection(tester);
    expect(find.byKey(const ValueKey('sim2-preset-baseline')), findsNothing);
    expect(find.byKey(const ValueKey('sim2-preset-bulk_plan')), findsNothing);
    expect(find.byKey(const ValueKey('sim2-dial-n')), findsNothing);
    expect(find.byKey(const ValueKey('sim2-dial-r')), findsNothing);
    expect(find.byKey(const ValueKey('sim2-compare')), findsNothing);
    expect(find.byKey(const ValueKey('sim2-mu-zero')), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('calorie delta is the only lever: stepper shifts the '
      'projection, reset restores it', (tester) async {
    await pumpSection(tester);
    final before = summaryText(tester);

    await tester.tap(find.byKey(const ValueKey('nutrition-delta-plus')));
    await tester.pump();
    await tester.pump();
    expect(textOf(tester, 'nutrition-delta-value'), '+100 kcal/day');
    // What-if line: 2100 kcal, macros scaled proportionally.
    final whatIf = textOf(tester, 'nutrition-whatif');
    expect(whatIf, contains('2100 kcal'));
    expect(whatIf, contains('scaled proportionally'));
    final after = summaryText(tester);
    expect(after, isNot(before), reason: 'the projection re-runs');

    await tester.tap(find.byKey(const ValueKey('nutrition-delta-reset')));
    await tester.pump();
    await tester.pump();
    expect(summaryText(tester), before);
    expect(find.byKey(const ValueKey('nutrition-whatif')), findsNothing);
  });

  testWidgets('capacity toggle removes the (default-on) capacity line',
      (tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey('sim2-capacity-toggle')));
    await tester.pump();
    expect(chartData(tester, 'sim2-expressed-chart').lineBarsData.length, 2);
  });

  testWidgets('no nutrition data → honest note + declared-rate fallback',
      (tester) async {
    await pumpSection(tester, section: inputs(n: null));
    expect(find.byKey(const ValueKey('nutrition-empty')), findsOneWidget);
    expect(textOf(tester, 'forecast-tracking'),
        contains('declared rates (no nutrition data)'));
    expect(find.byKey(const ValueKey('nutrition-delta-plus')), findsNothing);
  });

  testWidgets('recalibration meta: adjusted tracking line + maintenance '
      'offset applied to the projection', (tester) async {
    final meta = ForecastMeta(
      tracking: 'adjusted',
      aScale: 0.8,
      bScale: 0.8,
      maintenanceOffsetKcal: -150,
      events: [RecalEvent(DateTime.utc(2026, 9, 25), 'capacity gain ×0.80')],
    );
    await pumpSection(tester, section: inputs(n: nutrition(), meta: meta));
    final tracking = textOf(tester, 'forecast-tracking');
    expect(tracking, contains('adjusted Sep 25'));
    expect(tracking, contains('capacity gain ×0.80'));
    // Maintenance shown with the recal offset folded in (2375 − 150).
    expect(textOf(tester, 'nutrition-maintenance'), contains('~2225'));
    expect(textOf(tester, 'nutrition-maintenance'), contains('recal -150'));
  });

  testWidgets('over-budget weeks render as red spans on F', (tester) async {
    await pumpSection(tester);
    await scrollTo(tester, find.byKey(const ValueKey('sim2-fold-fatigue')));
    await tester.tap(find.byKey(const ValueKey('sim2-fold-fatigue')));
    await tester.pumpAndSettle();
    final f = chartData(tester, 'sim2-f-chart');
    final red = [
      for (final a in f.rangeAnnotations.verticalRangeAnnotations)
        if ((a.color?.a ?? 0) > 0.12) a,
    ];
    expect(red, isNotEmpty,
        reason: 'the cut runs over the deficit budget → red spans');
    expect(find.textContaining('over-budget weeks:'), findsOneWidget);
    expect(find.textContaining('confidence'), findsOneWidget);
  });

  testWidgets('§9.5 parameter sheet stays as PROVENANCE: edit re-runs, '
      'reset restores (incl. recal scales)', (tester) async {
    await pumpSection(tester);
    await scrollTo(tester, find.byKey(const ValueKey('sim2-params-tile')));
    await tester.tap(find.byKey(const ValueKey('sim2-params-tile')));
    await tester.pumpAndSettle();
    expect(find.textContaining('PROVENANCE sheet, not levers'),
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

    await scrollTo(tester, find.byKey(const ValueKey('sim2-params-reset')));
    await tester.tap(find.byKey(const ValueKey('sim2-params-reset')));
    await tester.pump();
    await tester.pump();
    expect(summaryText(tester), before);
  });

  testWidgets('expectation bands: faint band + "range, not target" label',
      (tester) async {
    const exp = Sim2Expectations(
      bodyweightLb: [158, 163],
      bfPct: [12, 14],
      benchLb: [260, 280],
      squatLb: [345, 375],
      deadliftLb: [370, 405],
      ohpLb: [150, 165],
    );
    expect(exp.sbdTotalLb, [975, 1060]);
    final withExp = ForecastInputs(
      blocks: sim2DefaultBlocks(),
      observedDaily: observedDaily(),
      stats: observedWeightStats(observedDaily(), _today),
      expectations: exp,
      nutrition: nutrition(),
    );
    await pumpSection(tester, section: withExp);
    final strength = chartData(tester, 'sim2-expressed-chart')
        .rangeAnnotations.horizontalRangeAnnotations;
    expect(strength, hasLength(1));
    expect(strength.single.y1, 975);
    expect(find.byKey(const ValueKey('sim2-expectation-strength')),
        findsOneWidget);
    expect(find.textContaining('expectation range, not target'),
        findsOneWidget);
  });

  testWidgets('folds collapsed by default; body comp expands', (tester) async {
    await pumpSection(tester);
    for (final k in [
      'sim2-fold-body',
      'sim2-fold-climb',
      'sim2-fold-vo2',
      'sim2-fold-fatigue',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('sim2-bw-chart')), findsNothing);
    await scrollTo(tester, find.byKey(const ValueKey('sim2-fold-body')));
    await tester.tap(find.byKey(const ValueKey('sim2-fold-body')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sim2-bw-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim2-bf-chart')), findsOneWidget);
  });

  testWidgets('reflows without overflow at 360dp', (tester) async {
    await pumpSection(tester, surface: const Size(360, 6500));
    expect(find.byKey(const ValueKey('nutrition-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim2-expressed-chart')), findsOneWidget);
    // Reaching here without a RenderFlex overflow report = pass.
  });
}
