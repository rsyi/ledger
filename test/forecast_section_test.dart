// Widget tests for lib/ui/widgets/forecast_section.dart (W3): levers
// re-run the sim and change the plotted series + summary, the reset
// chip restores program defaults, the climbing forecast is
// offset-anchored, and the section reflows at 360dp.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/program_metrics.dart' show WeightRow;
import 'package:airledger/services/program_observed.dart'
    show observedWeightStats;
import 'package:airledger/services/sim_core.dart';
import 'package:airledger/services/sim_fit.dart';
import 'package:airledger/services/world_model.dart' show SimRules;
import 'package:airledger/ui/widgets/forecast_section.dart';

/// The v7 program shape (sim_core_test fixture).
SimProgram v7Program() => SimProgram(
      cutTargetLb: 154,
      cutEndDate: DateTime(2026, 12, 13),
      blocks: [
        SimBlock(
            n: 1,
            start: DateTime(2026, 12, 14),
            end: DateTime(2027, 1, 3),
            emphasis: 'reverse'),
        SimBlock(
            n: 2,
            start: DateTime(2027, 1, 4),
            end: DateTime(2027, 2, 28),
            emphasis: 'climbing',
            rate: 0.4),
        SimBlock(
            n: 3,
            start: DateTime(2027, 3, 1),
            end: DateTime(2027, 4, 25),
            emphasis: 'lifting',
            rate: 0.4),
        SimBlock(
            n: 7,
            start: DateTime(2027, 10, 11),
            end: DateTime(2027, 12, 5),
            emphasis: 'lifting',
            rate: 0.2),
      ],
    );

SimInitialState currentState() => SimInitialState(
      monday: DateTime(2026, 9, 21),
      bw: 160.6,
      e1rm: const {
        'squat': 311.7,
        'bench': 247.5,
        'deadlift': 351.8,
        'press': 144.0,
      },
      gradeP75: 5.0,
      actualMaxSbdTotalLbs: 275.0 + 225.0 + 315.0,
    );

SimCoefficients shippedCoefficients() => const SimCoefficients(
      strength: {
        'squat': LiftResponse(a: -0.280, bBw: 2.295),
        'bench': LiftResponse(a: -0.099, bBw: 0.919),
        'deadlift': LiftResponse(a: 0.775, bBw: 0.795),
        'press': LiftResponse(a: -0.143, bBw: 0.352),
      },
      pooled: null,
      climbC0: 8.56,
      climbCBw: -0.0288,
      climbBf: 0.0032,
    );

List<WeightRow> observedDaily() => [
      for (var i = 90; i >= 0; i--)
        WeightRow(
          date: DateTime(2026, 9, 25).subtract(Duration(days: i)),
          // Gentle downtrend + a little scatter.
          weightLbs: 160.6 + i * 0.08 + (i % 3 - 1) * 0.4,
        ),
    ];

ForecastInputs inputs({List<String> drifted = const []}) => ForecastInputs(
      initial: currentState(),
      program: v7Program(),
      coefficients: shippedCoefficients(),
      rules: const SimRules(),
      drifted: drifted,
      strengthMaeLb: const {
        'squat': 20.0,
        'bench': 15.6,
        'deadlift': 22.4,
        'press': 8.7,
      },
      gradeMaeV: 0.54,
      observedDaily: observedDaily(),
      stats: observedWeightStats(observedDaily(), DateTime(2026, 9, 25)),
      observedP75: 5.0,
    );

Future<void> pumpSection(
  WidgetTester tester, {
  Size surface = const Size(800, 2600),
  List<String> drifted = const [],
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ForecastSection(
          inputs: inputs(drifted: drifted),
          today: DateTime(2026, 9, 25),
        ),
      ),
    ),
  ));
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
  final text = tester.widget<Text>(
    find.descendant(
      of: find.byKey(const ValueKey('forecast-summary')),
      matching: find.byType(Text),
    ),
  );
  return text.data!;
}

void main() {
  testWidgets('default levers: summary shows cut end, Wilks, deadlift',
      (tester) async {
    await pumpSection(tester);
    final summary = summaryText(tester);
    // Study trajectory: cut target trips 2026-11-16, Wilks ~329,
    // deadlift 400+ on the default 3y horizon.
    expect(summary, contains('154 by Nov 16'));
    expect(summary, contains('Wilks'));
    expect(summary, contains('deadlift 4'));
    // All three charts render.
    expect(find.byKey(const ValueKey('forecast-bw-chart')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('forecast-strength-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('forecast-climb-chart')), findsOneWidget);
    // No reset chip while at program defaults.
    expect(find.byKey(const ValueKey('forecast-reset')), findsNothing);
    // Climbing anchor caption: observed 5.0 vs raw model level.
    expect(find.textContaining('anchored to observed p75 V5.0'),
        findsOneWidget);
  });

  testWidgets('horizon lever re-sims: chart window + milestones change',
      (tester) async {
    await pumpSection(tester);
    final maxX3y = chartData(tester, 'forecast-bw-chart').maxX;

    await tester.tap(find.byKey(const ValueKey('forecast-horizon-1')));
    await tester.pump();
    final maxX1y = chartData(tester, 'forecast-bw-chart').maxX;
    expect(maxX1y, lessThan(maxX3y));
    // Strength chart re-windows too (same result object).
    expect(chartData(tester, 'forecast-strength-chart').maxX, maxX1y);

    await tester.tap(find.byKey(const ValueKey('forecast-horizon-5')));
    await tester.pump();
    expect(chartData(tester, 'forecast-bw-chart').maxX, greaterThan(maxX3y));
  });

  testWidgets('cut-rate slider changes the plotted forecast + summary; '
      'reset chip restores program defaults', (tester) async {
    await pumpSection(tester);
    final before = summaryText(tester);
    final bwBefore = chartData(tester, 'forecast-bw-chart')
        .lineBarsData
        .last // the dashed forecast line
        .spots
        .map((s) => s.y)
        .toList();

    // Drag the cut slider hard left (toward -1.6 lb/wk): the cut target
    // trips earlier.
    await tester.drag(
      find.byKey(const ValueKey('forecast-cut-slider')),
      const Offset(-300, 0),
    );
    await tester.pump();
    final after = summaryText(tester);
    expect(after, isNot(before));
    final bwAfter = chartData(tester, 'forecast-bw-chart')
        .lineBarsData
        .last
        .spots
        .map((s) => s.y)
        .toList();
    expect(bwAfter, isNot(bwBefore));

    // Reset restores the program-default trajectory.
    final reset = find.byKey(const ValueKey('forecast-reset'));
    expect(reset, findsOneWidget);
    await tester.tap(reset);
    await tester.pump();
    expect(summaryText(tester), before);
    expect(find.byKey(const ValueKey('forecast-reset')), findsNothing);
  });

  testWidgets('series chips toggle strength lines; press caveat follows',
      (tester) async {
    await pumpSection(tester);
    final barsAll = chartData(tester, 'forecast-strength-chart')
        .lineBarsData
        .length;
    expect(find.textContaining('press: the current cut shows a decline'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('forecast-series-press')));
    await tester.pump();
    final barsFewer =
        chartData(tester, 'forecast-strength-chart').lineBarsData.length;
    expect(barsFewer, lessThan(barsAll));
    // Press deselected → its caveat leaves with it.
    expect(find.textContaining('press: the current cut shows a decline'),
        findsNothing);
  });

  testWidgets('drift tag renders when the guard tripped', (tester) async {
    await pumpSection(tester, drifted: ['squat.b_bw']);
    expect(find.textContaining('model drift: squat.b_bw'), findsOneWidget);
  });

  testWidgets('reflows without overflow at 360dp', (tester) async {
    await pumpSection(tester, surface: const Size(360, 3200));
    expect(find.byKey(const ValueKey('forecast-bw-chart')), findsOneWidget);
    expect(find.textContaining('MILESTONES'), findsOneWidget);
    // Reaching here without a RenderFlex overflow report = pass.
  });
}
