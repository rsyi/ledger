import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/whoop_activity.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _row(String sport, String date,
        {String start = '10:00:00',
        num? strain = 10,
        num? avgHr = 120,
        num? dur = 40}) =>
    {
      'workout_id': '$sport-$date-$start',
      'date': date,
      'start_time': '$date $start',
      'sport': sport,
      'strain': strain,
      'avg_hr': avgHr,
      'max_hr': 150,
      'duration_min': dur,
    };

void main() {
  test('activityKindOf', () {
    expect(activityKindOf('rock-climbing'), ActivityKind.climb);
    expect(activityKindOf('Rock Climbing'), ActivityKind.climb);
    expect(activityKindOf('running'), ActivityKind.run);
    expect(activityKindOf('weightlifting'), ActivityKind.lift);
    expect(activityKindOf('walking'), ActivityKind.walk);
    expect(activityKindOf('hiking-rucking'), ActivityKind.other);
    expect(activityKindOf('activity'), ActivityKind.other);
  });

  test('activityKindOf (I3): "climb" substring is not enough — a stair '
      'climber / stairmaster machine is NOT climbing', () {
    expect(activityKindOf('stair-climber'), ActivityKind.other);
    expect(activityKindOf('stairmaster'), ActivityKind.other);
    expect(activityKindOf('climbing'), ActivityKind.climb);
    expect(activityKindOf('bouldering'), ActivityKind.climb);
    expect(activityKindOf('rock-climbing'), ActivityKind.climb);
  });

  test('whoopActivitiesFromRecords parses strings + DateTimes, sorts', () {
    final acts = whoopActivitiesFromRecords([
      _row('running', '2026-09-27', start: '13:45:00'),
      {
        ..._row('rock-climbing', '2026-09-22'),
        'date': DateTime(2026, 9, 22),
      },
      {'sport': 'running'}, // no date → skipped
    ]);
    expect(acts.map((a) => a.kind),
        [ActivityKind.climb, ActivityKind.run]);
    expect(acts.last.date, DateTime(2026, 9, 27));
    expect(acts.last.start, DateTime(2026, 9, 27, 13, 45));
    expect(acts.last.durationMin, 40);
  });

  group('isZone2Run', () {
    final run = whoopActivitiesFromRecords(
        [_row('running', '2026-09-27', avgHr: 122, dur: 43)]).single;
    test('easy 43-min run at max 200 qualifies', () {
      expect(isZone2Run(run, maxHr: 200), isTrue);
    });
    test('too hard', () {
      expect(isZone2Run(run, maxHr: 150), isFalse); // 122 > 112.5
    });
    test('too short', () {
      final short = whoopActivitiesFromRecords(
          [_row('running', '2026-09-27', dur: 15)]).single;
      expect(isZone2Run(short, maxHr: 200), isFalse);
    });
    test('not a run', () {
      final walk = whoopActivitiesFromRecords(
          [_row('walking', '2026-09-27')]).single;
      expect(isZone2Run(walk, maxHr: 200), isFalse);
    });
  });

  test('isUnlogged', () {
    final acts = whoopActivitiesFromRecords([
      _row('rock-climbing', '2026-09-22'),
      _row('rock-climbing', '2026-09-25'),
      _row('weightlifting', '2026-09-23'),
      _row('running', '2026-09-27'),
    ]);
    final strengthDays = {DateTime(2026, 9, 23)};
    final climbDays = {DateTime(2026, 9, 22)};
    expect(
      [
        for (final a in acts)
          isUnlogged(a, strengthDays: strengthDays, climbDays: climbDays)
      ],
      // acts come back date-sorted (22 climb, 23 lift, 25 climb, 27 run),
      // not insertion order (22, 25, 23, 27) — climb22 and lift23 are
      // both in their "logged" set, climb25 and run27 are not.
      [false, false, true, true],
    );
  });

  test('creditClimbItems ticks the PM climb item with strain', () {
    final items = parsePrescribedProse(
        null, 'PM: Climb — LIGHT session (technique/volume).');
    final acts = whoopActivitiesFromRecords(
        [_row('rock-climbing', '2026-10-02', strain: 14.8)]);
    final out = creditClimbItems(items, acts);
    final climb = out.firstWhere((i) => isClimbItem(i));
    expect(climb.done, isTrue);
    expect(climb.creditNote, 'strain 14.8');
    // No climb activity → unchanged.
    expect(creditClimbItems(items, const []).first.done, isFalse);
  });
}
