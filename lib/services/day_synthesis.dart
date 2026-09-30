/// Day-synthesis context assembly: gathers "how is today going vs the
/// plan" into a compact prompt for the LLM, and derives the small tally
/// the post-log notification uses. Pure — no Flutter, no IO, no LLM call
/// (that rides the existing LlmClient seam). Every branch is covered by
/// test/day_synthesis_test.dart.
///
/// The synthesis answers, in plain language: what have I done so far today
/// (meals + macros, sets, 4x4, climbing) vs what today's PROGRAM calls for
/// vs what's LEFT — with timing- and remaining-work-aware nutrition /
/// training advice. It ADVISES; it never fabricates. If the routine has a
/// PM climb and none is logged, the prompt states the climb is still to
/// come — so the model can't call it a rest day.
library;

/// A meal eaten today (macros already summed per record; nulls = not
/// reported). [atHour] is the local hour it was eaten (0–23), or null.
class SynthMeal {
  final double? calories;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;
  final int? atHour;

  const SynthMeal({
    this.calories,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.atHour,
  });
}

/// A strength set logged today.
class SynthSet {
  final String exercise;
  final double? weight;
  final int? reps;

  const SynthSet({required this.exercise, this.weight, this.reps});
}

/// The macro targets in force today (from the program slice). Any may be
/// null (block-0 nulls → "no target").
class SynthTargets {
  /// [lo, hi] grams/day; the low end is the floor we compare against.
  final List<double>? proteinGDay;
  final List<double>? carbsGDay;
  final double? fatGDayMin;

  const SynthTargets({this.proteinGDay, this.carbsGDay, this.fatGDayMin});
}

/// The program's call for today, distilled from the routine prose + planned
/// strength lines.
class SynthProgramDay {
  /// Routine morning prose (e.g. "AM 4x4 intervals").
  final String morning;

  /// Routine afternoon prose (e.g. "PM hard climbing session").
  final String afternoon;

  /// Planned strength exercise names for today (from PlanStore / planner).
  final List<String> plannedLifts;

  /// True when today's routine calls for a 4x4 cardio session.
  final bool wants4x4;

  /// The climbing flavor for today ("hard session", "limit session", …)
  /// or null when no climb is scheduled.
  final String? climbCall;

  const SynthProgramDay({
    this.morning = '',
    this.afternoon = '',
    this.plannedLifts = const [],
    this.wants4x4 = false,
    this.climbCall,
  });
}

/// What was actually logged today across domains.
class SynthLogged {
  final List<SynthMeal> meals;
  final List<SynthSet> sets;

  /// True when a 4x4 cardio session is logged today.
  final bool did4x4;

  /// Count of climbing rows/ascents logged today (>0 = climbed).
  final int climbCount;

  const SynthLogged({
    this.meals = const [],
    this.sets = const [],
    this.did4x4 = false,
    this.climbCount = 0,
  });
}

/// The assembled, phase- and time-aware picture the prompt renders from,
/// and the notification tally reads.
class DaySynthesisContext {
  final int hour; // 0–23 local
  final String phase; // 'cut' | 'recomp' | … | '' when unknown
  final SynthProgramDay program;
  final SynthLogged logged;
  final SynthTargets targets;

  const DaySynthesisContext({
    required this.hour,
    required this.phase,
    required this.program,
    required this.logged,
    required this.targets,
  });

  double get proteinSoFar => _sum(logged.meals, (m) => m.proteinG);
  double get carbsSoFar => _sum(logged.meals, (m) => m.carbsG);
  double get fatSoFar => _sum(logged.meals, (m) => m.fatG);
  double get kcalSoFar => _sum(logged.meals, (m) => m.calories);

  /// Distinct exercise names logged (lower-cased, insertion order).
  List<String> get liftsDone {
    final seen = <String>[];
    for (final s in logged.sets) {
      final n = s.exercise.trim().toLowerCase();
      if (n.isNotEmpty && !seen.contains(n)) seen.add(n);
    }
    return seen;
  }

  /// Distinct planned lift names (lower-cased, insertion order).
  List<String> get liftsPlanned {
    final seen = <String>[];
    for (final e in program.plannedLifts) {
      final n = e.trim().toLowerCase();
      if (n.isNotEmpty && !seen.contains(n)) seen.add(n);
    }
    return seen;
  }

  /// Planned lifts not yet logged today.
  List<String> get liftsRemaining {
    final done = liftsDone.toSet();
    return [for (final l in liftsPlanned) if (!done.contains(l)) l];
  }

  /// True when the routine wants a climb today and none is logged yet.
  bool get climbToCome => program.climbCall != null && logged.climbCount == 0;

  /// True when the routine wants a 4x4 and none is logged yet.
  bool get cardioToCome => program.wants4x4 && !logged.did4x4;
}

double _sum(List<SynthMeal> meals, double? Function(SynthMeal) f) {
  var total = 0.0;
  for (final m in meals) {
    total += f(m) ?? 0;
  }
  return total;
}

/// Builds the compact LLM prompt for the day synthesis. Short output is
/// requested explicitly (2–3 bullets or one short paragraph). The context
/// lines are all facts — the model reasons over them; it must not invent
/// numbers or claim unlogged work.
String buildDaySynthesisPrompt(DaySynthesisContext c) {
  final b = StringBuffer();
  b.writeln(
    'You are Robert\'s training coach giving a SHORT, unprompted read on '
    'how today is going against the plan. Be concise and actionable: 2–3 '
    'short bullets or one short paragraph, plain language, no preamble. '
    'Give timing- and remaining-work-aware nutrition/training advice '
    '(e.g. carbs before a climb, protein to hit the floor). Advise only '
    'from the facts below — never invent numbers and never claim work '
    'that is not logged. If a session is still to come, say so.',
  );
  b.writeln();
  b.writeln('Local time: ${_fmtHour(c.hour)}.');
  if (c.phase.isNotEmpty) b.writeln('Phase: ${c.phase}.');
  b.writeln();

  b.writeln('TODAY\'S PROGRAM:');
  final callParts = <String>[];
  if (c.program.plannedLifts.isNotEmpty) {
    callParts.add('lifting — ${c.liftsPlanned.join(', ')}');
  }
  if (c.program.wants4x4) callParts.add('4x4 cardio');
  if (c.program.climbCall != null) {
    callParts.add('climbing (${c.program.climbCall})');
  }
  if (callParts.isEmpty) {
    b.writeln('- rest day (no training scheduled)');
  } else {
    for (final p in callParts) {
      b.writeln('- $p');
    }
  }
  final prose = [c.program.morning, c.program.afternoon]
      .where((s) => s.trim().isNotEmpty)
      .join(' / ');
  if (prose.isNotEmpty) b.writeln('  routine: $prose');
  b.writeln();

  b.writeln('DONE SO FAR TODAY:');
  if (c.logged.meals.isEmpty) {
    b.writeln('- food: nothing logged yet');
  } else {
    b.writeln(
      '- food: ${_g(c.proteinSoFar)} protein, ${_g(c.carbsSoFar)} carbs, '
      '${_g(c.fatSoFar)} fat, ${c.kcalSoFar.round()} kcal '
      '(${c.logged.meals.length} meal(s))',
    );
  }
  if (c.liftsDone.isEmpty) {
    b.writeln('- lifting: none logged');
  } else {
    b.writeln('- lifting: ${c.liftsDone.join(', ')} '
        '(${c.logged.sets.length} sets)');
  }
  b.writeln('- 4x4: ${c.logged.did4x4 ? 'done' : 'not logged'}');
  b.writeln(
    '- climbing: ${c.logged.climbCount > 0 ? 'logged (${c.logged.climbCount})' : 'not logged'}',
  );
  b.writeln();

  b.writeln('MACRO TARGETS TODAY:');
  b.writeln('- protein floor: ${_target(c.targets.proteinGDay)}');
  b.writeln('- carbs: ${_target(c.targets.carbsGDay)}');
  b.writeln(
    '- fat floor: ${c.targets.fatGDayMin == null ? 'no target' : '${c.targets.fatGDayMin!.round()}g'}',
  );
  b.writeln();

  b.writeln('STILL TO COME:');
  final left = <String>[];
  if (c.liftsRemaining.isNotEmpty) {
    left.add('lifting: ${c.liftsRemaining.join(', ')}');
  }
  if (c.cardioToCome) left.add('4x4 cardio');
  if (c.climbToCome) left.add('climbing (${c.program.climbCall})');
  final pf = c.targets.proteinGDay;
  if (pf != null && c.proteinSoFar < pf[0]) {
    left.add('${(pf[0] - c.proteinSoFar).round()}g more protein to the floor');
  }
  if (left.isEmpty) {
    b.writeln('- nothing outstanding');
  } else {
    for (final l in left) {
      b.writeln('- $l');
    }
  }

  return b.toString().trimRight();
}

String _fmtHour(int h) {
  final hr = h % 24;
  final period = hr < 12 ? 'am' : 'pm';
  final h12 = hr % 12 == 0 ? 12 : hr % 12;
  return '$h12$period';
}

String _g(double v) => '${v.round()}g';

String _target(List<double>? band) {
  if (band == null || band.isEmpty) return 'no target';
  if (band.length >= 2 && band[1] != band[0]) {
    return '${band[0].round()}–${band[1].round()}g';
  }
  return '${band[0].round()}g';
}
