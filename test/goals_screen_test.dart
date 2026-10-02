// Week tab rows — program sets per lift + sets per muscle group.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/goals_service.dart';
import 'package:airledger/ui/goals_screen.dart';

Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

const muscleEval = GoalEval(
  config: GoalConfig(
    id: 'muscle_stimulus',
    label: 'Sets per muscle group',
    description: 'Working sets per muscle group this week.',
  ),
  status: GoalStatus.partial,
  value: '1 of 2 groups in 8–12',
  detail: '1 behind pace · Mon–Sun',
  muscles: [
    GoalMuscleRow(
      group: 'hamstrings_glutes',
      sets: 2.5,
      lo: 8,
      hi: 12,
      pace: 5.7,
      contributors: [MapEntry('Romanian Deadlift', 2.0)],
    ),
    GoalMuscleRow(
      group: 'back',
      sets: 9.25,
      lo: 8,
      hi: 12,
      pace: 5.7,
      contributors: [
        MapEntry('Climbing sessions', 6.0),
        MapEntry('Pull Up', 3.25),
      ],
    ),
  ],
);

final programEval = GoalEval(
  config: const GoalConfig(id: 'hard_sets', label: 'Program sets per lift'),
  status: GoalStatus.partial,
  value: '15 of 25 program sets · 1/4 lifts done',
  detail: 'on schedule · Mon–Sun program week',
  ticks: const [
    GoalLiftTick(
      lift: 'squat',
      hardSets: 2,
      target: 4,
      done: 4,
      fromProgram: true,
      scheduledDays: [DateTime.monday, DateTime.wednesday],
    ),
    GoalLiftTick(
      lift: 'deadlift',
      hardSets: 0,
      target: 3,
      done: 0,
      fromProgram: true,
      scheduledDays: [DateTime.friday],
      remainingDays: [DateTime.friday],
    ),
    GoalLiftTick(
      lift: 'press',
      hardSets: 3,
      target: 7,
      done: 3,
      fromProgram: true,
      scheduledDays: [DateTime.wednesday, DateTime.saturday],
      remainingDays: [DateTime.saturday],
    ),
  ],
);

void main() {
  testWidgets('muscle row renders groups in plain words, no abbreviations',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(
        host(GoalCard(goal: muscleEval, onTap: () => tapped = true)));
    expect(find.text('Sets per muscle group'), findsOneWidget);
    expect(find.text('1 of 2 groups in 8–12'), findsOneWidget);
    expect(find.text('hamstrings and glutes 2.5'), findsOneWidget);
    expect(find.text('back 9.3'), findsOneWidget);
    expect(find.textContaining('hamstrings_glutes'), findsNothing);
    await tester.tap(find.text('Sets per muscle group'));
    expect(tapped, isTrue);
  });

  testWidgets('muscle detail lists sets, band state and contributors',
      (tester) async {
    await tester.pumpWidget(host(const GoalDetail(goal: muscleEval)));
    expect(
      find.text('hamstrings and glutes: 2.5 sets · under (8–12) · behind pace'),
      findsOneWidget,
    );
    expect(find.text('back: 9.3 sets · in range (8–12)'), findsOneWidget);
    expect(find.text('from: Climbing sessions 6.0 · Pull Up 3.3'),
        findsOneWidget);
  });

  testWidgets('program chips: done/prescribed + not-yet-due day hint',
      (tester) async {
    await tester.pumpWidget(
        host(GoalCard(goal: programEval, onTap: () {})));
    expect(find.text('Program sets per lift'), findsOneWidget);
    expect(find.text('squat 4/4'), findsOneWidget);
    expect(find.text('deadlift 0/3 · Fri'), findsOneWidget);
    expect(find.text('overhead press 3/7 · Sat'), findsOneWidget);
    await tester.pumpWidget(host(GoalDetail(goal: programEval)));
    expect(
      find.text('overhead press: 3 of 7 program sets (3 at RPE 7 or higher)'
          ' · still due Sat'),
      findsOneWidget,
    );
  });
}
