// Week tab rows — program sets per lift + sets per muscle group.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/goals_service.dart';
import 'package:airledger/ui/design/design.dart';
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

const zone2Optional = GoalEval(
  config: GoalConfig(id: 'zone2_run', label: 'Zone-2 run', optional: true),
  status: GoalStatus.optional,
  value: '0/1 run',
  detail: 'nice to have',
);

const zone2Met = GoalEval(
  config: GoalConfig(id: 'zone2_run', label: 'Zone-2 run', optional: true),
  status: GoalStatus.met,
  value: '1/1 run',
  detail: '43 min · avg HR 122',
);

const climbing = GoalEval(
  config: GoalConfig(id: 'climbing', label: 'Climbing'),
  status: GoalStatus.met,
  value: '3/2 sessions',
);

void main() {
  testWidgets(
    'muscle row: summary meta + one mini bar per group, plain words',
    (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        host(GoalRow(goal: muscleEval, onTap: () => tapped = true)),
      );
      expect(find.textContaining('Sets per muscle group'), findsOneWidget);
      expect(find.textContaining('1 of 2 groups in 8–12'), findsOneWidget);
      expect(find.text('hamstrings and glutes'), findsOneWidget);
      expect(find.text('2.5'), findsOneWidget);
      expect(find.text('back'), findsOneWidget);
      expect(find.text('9.3'), findsOneWidget);
      expect(find.textContaining('hamstrings_glutes'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      await tester.tap(find.textContaining('Sets per muscle group'));
      expect(tapped, isTrue);
    },
  );

  testWidgets('muscle detail lists sets, band state and contributors', (
    tester,
  ) async {
    await tester.pumpWidget(host(const GoalDetail(goal: muscleEval)));
    expect(
      find.text('hamstrings and glutes: 2.5 sets · under (8–12) · behind pace'),
      findsOneWidget,
    );
    expect(find.text('back: 9.3 sets · in range (8–12)'), findsOneWidget);
    expect(
      find.text('from: Climbing sessions 6.0 · Pull Up 3.3'),
      findsOneWidget,
    );
    expect(find.text('1 behind pace · Mon–Sun'), findsOneWidget);
  });

  testWidgets('program row: one bar line per lift, done/prescribed + due day', (
    tester,
  ) async {
    await tester.pumpWidget(host(GoalRow(goal: programEval, onTap: () {})));
    expect(find.textContaining('Program sets per lift'), findsOneWidget);
    // Meta sums the per-lift counts (capped at each prescription).
    expect(find.textContaining('7 of 14 sets'), findsOneWidget);
    expect(find.text('squat'), findsOneWidget);
    expect(find.text('4/4'), findsOneWidget);
    expect(find.text('deadlift'), findsOneWidget);
    expect(find.text('0/3 · Fri'), findsOneWidget);
    expect(find.text('overhead press'), findsOneWidget);
    expect(find.text('3/7 · Sat'), findsOneWidget);
    // Bars, not wrapping chips.
    expect(find.byType(GoalBars), findsOneWidget);
    expect(find.byType(Wrap), findsOneWidget); // ExerciseRow's chip slot
    await tester.pumpWidget(host(GoalDetail(goal: programEval)));
    expect(
      find.text(
        'overhead press: 3 of 7 program sets (3 at RPE 7 or higher)'
        ' · still due Sat',
      ),
      findsOneWidget,
    );
  });

  testWidgets('optional goal not met reads a neutral "Nice to have"', (
    tester,
  ) async {
    await tester.pumpWidget(host(GoalRow(goal: zone2Optional, onTap: () {})));
    expect(find.text('Nice to have'), findsOneWidget);
    expect(find.textContaining('0/1 run'), findsOneWidget);
    // The boilerplate detail isn't repeated in the meta.
    expect(find.textContaining('nice to have'), findsNothing);
    final mark = tester.widget<StatusMark>(find.byType(StatusMark));
    expect(mark.status, ItemStatus.pending);
  });

  testWidgets('met goal: done mark, result detail in the meta, no chip', (
    tester,
  ) async {
    await tester.pumpWidget(host(GoalRow(goal: zone2Met, onTap: () {})));
    expect(
      find.textContaining('1/1 run · 43 min · avg HR 122'),
      findsOneWidget,
    );
    expect(find.text('Nice to have'), findsNothing);
    expect(
      tester.widget<StatusMark>(find.byType(StatusMark)).status,
      ItemStatus.done,
    );
  });

  testWidgets('goal list: one card, one row per goal, tap routes the goal', (
    tester,
  ) async {
    GoalEval? opened;
    await tester.pumpWidget(
      host(
        GoalList(
          goals: [programEval, muscleEval, climbing, zone2Met],
          onTap: (g) => opened = g,
        ),
      ),
    );
    expect(find.byType(GoalRow), findsNWidgets(4));
    expect(find.byType(AppCard), findsOneWidget);
    await tester.tap(find.textContaining('Climbing'));
    expect(opened?.config.id, 'climbing');
  });

  test('display helpers', () {
    final fri = DateTime(2026, 10, 2);
    expect(programWeekRange(fri), 'Mon Sep 28 – Sun Oct 4');
    expect(programWeekRange(DateTime(2026, 10, 4)), 'Mon Sep 28 – Sun Oct 4');
    expect(
      goalWindowNote(climbing, fri, DateTime.saturday),
      'Counted Sat Sep 26 – Fri Oct 2 (your accounting week).',
    );
    expect(goalWindowNote(climbing, fri, DateTime.monday), isNull);
    expect(goalWindowNote(programEval, fri, DateTime.saturday), isNull);
    expect(goalWindowNote(muscleEval, fri, DateTime.saturday), isNull);
    expect(goalMeta(climbing), '3/2 sessions');
    expect(goalMeta(muscleEval), '1 of 2 groups in 8–12');
    expect(goalStatusWord(GoalStatus.optional), 'Nice to have');
    const behind = GoalLiftTick(
      lift: 'bench',
      hardSets: 1,
      target: 8,
      done: 2,
      fromProgram: true,
      behind: true,
    );
    expect(liftProgressText(behind), '2/8');
    expect(
      goalMeta(
        GoalEval(
          config: const GoalConfig(id: 'hard_sets'),
          status: GoalStatus.unmet,
          value: 'x',
          ticks: const [behind],
        ),
      ),
      '2 of 8 sets · behind on bench',
    );
  });
}
