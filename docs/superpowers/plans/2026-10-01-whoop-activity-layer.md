# Whoop Activity Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Use Whoop workouts as the activity signal — local-date-correct rows, climbing credited from Whoop ∪ Kaya, an optional weekly zone-2 run goal, coach awareness of unlogged activity, and a slimmer daily-notes form.

**Architecture:** Fix the UTC→local date bug in the pure Whoop transforms (`whoop_api.dart`). Add one pure module (`whoop_activity.dart`) that turns `whoop_workouts` rows into typed activities (kind, zone-2 test, unlogged test, checklist credit). Every consumer (goals, home dashboard, Today checklist, day synthesis, CoachBrain) reads activities through it. MCP's existing `workouts_recent` block gains `kind` + `avg_hr`. Config lives where it already does: `dashboards.yaml` goals, `program.yaml` (append-only v15), `daily_notes.input.yml`.

**Tech Stack:** Flutter/Dart (app, `flutter test`), YAML configs in `~/repos/airledger-fitness` (pushed to rsyi/airledger-fitness), TypeScript Cloudflare worker `~/repos/ledger-mcp` (`npm test`, `npx wrangler deploy`).

**Spec:** `docs/superpowers/specs/2026-10-01-whoop-activity-layer-design.md`. Deviations decided while planning (same intent, less code): §6 MCP extends the existing `workouts_recent` block instead of adding `activity_7d`; §5 v15 changes only the CUT Sunday (post-cut Sunday prose already says "optional easy Zone 2"); §7 recomp_review already prefers Whoop sleep (`mergeRecoveryRows`) — only the form changes; §4 credits climbs only (the prose parser drops `Optional:` lines, so there is no run item to tick — the goal covers the run).

**Repo rules (from CLAUDE.md):** commits use conventional style and end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. NEVER push `~/repos/airledger` (it has no remote now). Push `~/repos/airledger-fitness` after schema/config edits (SchemaSync reverts unpushed edits). `flutter analyze` baseline = 29 issues; `flutter test` baseline = 7 known failures (3 integration + 4 schema_loader).

---

## File map

| File | Change |
|---|---|
| `lib/services/integrations/whoop_api.dart` | local-time transforms, recovery keyed by sleep_id, stale-day diff |
| `test/whoop_local_time_test.dart` | NEW — offset/local-date tests |
| `lib/services/whoop_activity.dart` | NEW — WhoopActivity, kind classifier, zone-2, unlogged, checklist credit |
| `test/whoop_activity_test.dart` | NEW |
| `lib/services/prescribed_exercises.dart` | PrescribedItem gains `creditNote` |
| `lib/services/goals_service.dart` | `optional`, zone2_run, climbing union, `GoalStatus.optional` |
| `test/goals_service_test.dart` | new groups |
| `lib/ui/goals_screen.dart` | whoop view/repo params, maxHr, optional status rendering |
| `lib/ui/home_dashboard.dart` | climb dates ∪ Whoop |
| `lib/ui/widgets/program_day_card.dart` | climb credit from Whoop |
| `lib/services/day_synthesis.dart` + `day_synthesis_service.dart` | activity line, climb credit |
| `lib/services/coach_brain.dart` | "Activity (Whoop, 14d)" section |
| `lib/ui/home_screen.dart` | pass `dashWorkoutsView` to the above |
| `~/repos/airledger-fitness/app/dashboards.yaml` | zone2_run goal (cut + recomp) |
| `~/repos/airledger-fitness/coach/program.yaml` | v15: cut Sunday optional run prose |
| `~/repos/airledger-fitness/coach/fixtures/program_current_cases.yaml` | block-0 Sunday case |
| `~/repos/airledger-fitness/views/daily_notes.input.yml` | hide sleep_hours/sleep_quality/readiness |
| `test/cut_week_structure_test.dart`, `test/program_screen_test.dart` | Sunday expectations |
| `~/repos/ledger-mcp/src/tools.ts` + `test/coach_context.test.ts` | workouts_recent kind/avg_hr |
| `CLAUDE.md` | feature-state entry |

---

### Task 1: Whoop local time (workouts + sleep)

**Files:**
- Modify: `lib/services/integrations/whoop_api.dart`
- Test: `test/whoop_local_time_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/whoop_local_time_test.dart`:

```dart
import 'package:airledger/services/integrations/whoop_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('whoopOffset', () {
    test('parses signed offsets', () {
      expect(whoopOffset('-07:00'), const Duration(hours: -7));
      expect(whoopOffset('+05:30'), const Duration(hours: 5, minutes: 30));
      expect(whoopOffset('Z'), Duration.zero);
    });
    test('null on absent / malformed', () {
      expect(whoopOffset(null), isNull);
      expect(whoopOffset('pacific'), isNull);
      expect(whoopOffset(7), isNull);
    });
  });

  group('workouts use the local day', () {
    test('evening Pacific session stays on its local day', () {
      // 02:30Z on the 23rd = 19:30 PDT on the 22nd.
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w1',
          'start': '2026-09-23T02:30:00.000Z',
          'end': '2026-09-23T02:55:59.000Z',
          'timezone_offset': '-07:00',
          'sport_name': 'walking',
          'score': {'strain': 5.1},
        },
      ]);
      final r = rows.single;
      expect((r['date'] as Map)['value'], '2026-09-22');
      expect((r['start_time'] as Map)['value'], '2026-09-22T19:30:00');
      expect((r['end_time'] as Map)['value'], '2026-09-22T19:55:59');
    });
    test('no offset → UTC (legacy behaviour)', () {
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w2',
          'start': '2026-09-23T02:30:00.000Z',
          'end': '2026-09-23T02:55:00.000Z',
          'sport_name': 'walking',
          'score': {'strain': 5.1},
        },
      ]);
      expect((rows.single['date'] as Map)['value'], '2026-09-23');
    });
  });

  group('sleep wake day is local', () {
    test('wake shortly after local midnight is not pushed forward', () {
      // end 06:30Z on the 2nd = 23:30 PDT on the 1st (late nap-free night
      // shift edge) → wake day is the 1st locally.
      final recs = whoopSleepToRecovery([
        {
          'id': 's1',
          'nap': false,
          'start': '2026-10-01T23:00:00.000Z',
          'end': '2026-10-02T06:30:00.000Z',
          'timezone_offset': '-07:00',
          'score': {'sleep_performance_percentage': 90},
        },
      ]);
      expect((recs.single['date'] as Map)['value'], '2026-10-01');
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/whoop_local_time_test.dart`
Expected: compile FAIL — `whoopOffset` isn't defined.

- [ ] **Step 3: Implement**

In `lib/services/integrations/whoop_api.dart`, add below the `const _kRollingWindow` line:

```dart
/// Whoop's per-record `timezone_offset` ("-07:00", "+05:30", "Z") as a
/// Duration. Null when absent or malformed — callers then fall back to
/// the UTC instant (the pre-2026-10-01 behaviour), never throw.
Duration? whoopOffset(Object? raw) {
  if (raw is! String) return null;
  final s = raw.trim();
  if (s == 'Z') return Duration.zero;
  final m = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(s);
  if (m == null) return null;
  final mins = int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!);
  return Duration(minutes: m.group(1) == '-' ? -mins : mins);
}

/// The wall-clock reading of [instant] at [offset], as a UTC DateTime
/// whose fields ARE the local time (so `_isoDate`/`_isoDateTime` print
/// local values). Null offset → the UTC reading.
DateTime _wall(DateTime instant, Duration? offset) =>
    instant.toUtc().add(offset ?? Duration.zero);
```

In `whoopSleepToRecovery`, replace

```dart
    final day = _isoDate(end.toUtc());
```

with

```dart
    // Wake day = the sleep end's LOCAL date (timezone_offset); UTC when
    // the record carries no offset.
    final day = _isoDate(_wall(end, whoopOffset(s['timezone_offset'])));
```

and update the comment block above it (delete the "Trust the timestamp's own date portion…" paragraph; it described the bug).

In `whoopWorkoutsToRows`, replace

```dart
    final day = _isoDate(start.toUtc());
```

with

```dart
    final off = whoopOffset(w['timezone_offset']);
    final day = _isoDate(_wall(start, off));
```

and replace the two datetime cells:

```dart
      'start_time': {'kind': 'date_time', 'value': _isoDateTime(_wall(start, off))},
      'end_time': {'kind': 'date_time', 'value': _isoDateTime(_wall(end, off))},
```

Update the doc comment on `whoopWorkoutsToRows`: replace "The workout DATE is the start timestamp's own date portion (trust the wire instant as the activity wall-clock, Kaya convention — converting to the device zone would shove an evening session back a day)." with "The workout DATE and start/end times are LOCAL wall-clock via the record's `timezone_offset` (UTC when absent) — the raw UTC date put evening Pacific sessions on the next day (fixed 2026-10-01)."

- [ ] **Step 4: Run tests**

Run: `flutter test test/whoop_local_time_test.dart test/whoop_api_transform_test.dart test/whoop_workouts_transform_test.dart`
Expected: all PASS (the old tests carry no offset → UTC path unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/services/integrations/whoop_api.dart test/whoop_local_time_test.dart
git commit -m "fix(whoop): derive workout/sleep dates from local time (timezone_offset)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Recovery keyed by sleep_id + stale-day diff

**Files:**
- Modify: `lib/services/integrations/whoop_api.dart`
- Test: `test/whoop_local_time_test.dart` (append groups)

- [ ] **Step 1: Write the failing tests** — append inside `main()`:

```dart
  group('recovery day', () {
    test('keyed on its sleep_id wake day', () {
      final days = whoopSleepWakeDays([
        {
          'id': 's1',
          'nap': false,
          'end': '2026-10-02T06:30:00.000Z',
          'timezone_offset': '-07:00',
          'score': {},
        },
        {'id': 'nap1', 'nap': true, 'end': '2026-10-02T20:00:00.000Z'},
      ]);
      expect(days, {'s1': '2026-10-01'});
      final f = whoopRecoveryFields([
        {
          'sleep_id': 's1',
          'created_at': '2026-10-02T14:00:00.000Z',
          'score': {'recovery_score': 70},
        },
      ], sleepDays: days);
      expect(f.keys, ['2026-10-01']);
    });
    test('falls back to created_at shifted by the latest sleep offset', () {
      final f = whoopRecoveryFields([
        {
          'sleep_id': 'unknown',
          'created_at': '2026-10-02T03:00:00.000Z',
          'score': {'recovery_score': 70},
        },
      ], fallbackOffset: const Duration(hours: -7));
      expect(f.keys, ['2026-10-01']);
    });
    test('whoopLatestOffset picks the latest-ending sleep', () {
      expect(
        whoopLatestOffset([
          {'end': '2026-10-01T10:00:00Z', 'timezone_offset': '-04:00'},
          {'end': '2026-10-02T10:00:00Z', 'timezone_offset': '-07:00'},
        ]),
        const Duration(hours: -7),
      );
      expect(whoopLatestOffset(const []), isNull);
    });
  });

  group('whoopStaleDays', () {
    test('known in-window days not re-emitted are stale', () {
      expect(
        whoopStaleDays(
          known: {'2026-09-20', '2026-09-25', '2026-09-26'},
          emitted: {'2026-09-25'},
          diffFrom: '2026-09-22',
          fullReconcile: false,
        ),
        ['2026-09-26'],
      );
    });
    test('empty fetch against a non-empty in-window baseline → null (refuse)',
        () {
      expect(
        whoopStaleDays(
          known: {'2026-09-25'},
          emitted: const {},
          diffFrom: '2026-09-22',
          fullReconcile: false,
        ),
        isNull,
      );
    });
    test('full reconcile overrides the guard', () {
      expect(
        whoopStaleDays(
          known: {'2026-09-25'},
          emitted: const {},
          diffFrom: '2026-09-22',
          fullReconcile: true,
        ),
        ['2026-09-25'],
      );
    });
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/whoop_local_time_test.dart`
Expected: compile FAIL — `whoopSleepWakeDays` isn't defined.

- [ ] **Step 3: Implement** in `whoop_api.dart` (pure section, after `whoopSleepToRecovery`):

```dart
/// Sleep id → its LOCAL wake day, for keying recovery records (which
/// carry no offset of their own). Naps and records without id/end skip.
Map<String, String> whoopSleepWakeDays(List<dynamic> sleeps) {
  final out = <String, String>{};
  for (final s in sleeps) {
    if (s is! Map || s['nap'] == true) continue;
    final id = s['id']?.toString();
    final end = DateTime.tryParse(s['end']?.toString() ?? '');
    if (id == null || id.isEmpty || end == null) continue;
    out[id] = _isoDate(_wall(end, whoopOffset(s['timezone_offset'])));
  }
  return out;
}

/// The offset of the latest-ending sleep in the batch (the user's current
/// zone), or null when none carries one.
Duration? whoopLatestOffset(List<dynamic> sleeps) {
  DateTime? best;
  Duration? off;
  for (final s in sleeps) {
    if (s is! Map) continue;
    final end = DateTime.tryParse(s['end']?.toString() ?? '');
    final o = whoopOffset(s['timezone_offset']);
    if (end == null || o == null) continue;
    if (best == null || end.isAfter(best)) {
      best = end;
      off = o;
    }
  }
  return off;
}

/// Days the source previously wrote ([known]) inside the diff window
/// (>= [diffFrom]) that this pull did not re-emit — they moved (local-date
/// fix) or vanished upstream. Null = refuse to diff: nothing was emitted
/// but in-window days are known (an API glitch, not a wipe) unless
/// [fullReconcile].
List<String>? whoopStaleDays({
  required Set<String> known,
  required Set<String> emitted,
  required String diffFrom,
  required bool fullReconcile,
}) {
  final inWindow = [
    for (final d in known)
      if (d.compareTo(diffFrom) >= 0) d,
  ]..sort();
  if (emitted.isEmpty && inWindow.isNotEmpty && !fullReconcile) return null;
  return [for (final d in inWindow) if (!emitted.contains(d)) d];
}
```

Change `whoopRecoveryFields` signature and its day line:

```dart
Map<String, Map<String, dynamic>> whoopRecoveryFields(
  List<dynamic> records, {
  Map<String, String> sleepDays = const {},
  Duration? fallbackOffset,
}) {
```

replace `final day = _isoDate(created.toUtc());` with

```dart
    // Recovery is "this morning's" read: key it on its sleep's local wake
    // day; else created_at shifted by the user's current zone; else UTC.
    final day = sleepDays[r['sleep_id']?.toString()] ??
        _isoDate(_wall(created, fallbackOffset));
```

In `pull()`, replace the block from `final records = whoopMergeRecovery(` through the closing `}` of `if (records.isNotEmpty) { ... }` with:

```dart
      final records = whoopMergeRecovery(
        sleep: whoopSleepToRecovery(sleepRecs),
        recovery: whoopRecoveryFields(
          recoveryRecs,
          sleepDays: whoopSleepWakeDays(sleepRecs),
          fallbackOffset: whoopLatestOffset(sleepRecs),
        ),
      );
      final emitted = <String>{
        for (final r in records) ((r['date'] as Map)['value']) as String,
      };
      // Stale-day diff starts 2 days inside the window: the API filters
      // by START, so the window's first night can fall outside it.
      final stale = whoopStaleDays(
        known: known,
        emitted: emitted,
        diffFrom: _isoDate(
            now.subtract(window).add(const Duration(days: 2)).toUtc()),
        fullReconcile: fullReconcile,
      );
      if (records.isNotEmpty || (stale?.isNotEmpty ?? false)) {
        // match-by-date (no match_field) — one recovery row per day.
        // notes stays fill-if-blank so a manual note is never
        // overwritten by an empty Whoop pull.
        await repo.ingest(recoveryViewJson, {
          'source': 'whoop_api',
          'owned_fields': _ownedFields,
          'fill_if_blank_fields': const ['notes'],
          'records': records,
          if (stale != null && stale.isNotEmpty) 'deleted_dates': stale,
        });
        known
          ..addAll(emitted)
          ..removeAll(stale ?? const <String>[]);
        await repo.metaSet(_kDays, jsonEncode(known.toList()..sort()));
      }
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/whoop_local_time_test.dart test/whoop_api_transform_test.dart`
Expected: PASS. If `whoop_api_transform_test.dart` calls `whoopRecoveryFields(x)` positionally it still compiles (new params are named/optional).

- [ ] **Step 5: Commit**

```bash
git add lib/services/integrations/whoop_api.dart test/whoop_local_time_test.dart
git commit -m "fix(whoop): key recovery on its sleep's local day + unwind moved days

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `whoop_activity.dart` (pure)

**Files:**
- Create: `lib/services/whoop_activity.dart`
- Modify: `lib/services/prescribed_exercises.dart` (PrescribedItem.creditNote)
- Test: `test/whoop_activity_test.dart`

- [ ] **Step 1: Write the failing tests** — create `test/whoop_activity_test.dart`:

```dart
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
      [false, true, false, true],
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
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/whoop_activity_test.dart`
Expected: compile FAIL — `whoop_activity.dart` doesn't exist.

- [ ] **Step 3: Add `creditNote` to PrescribedItem** (`lib/services/prescribed_exercises.dart`). Replace the class body fields/constructor/withLogged with:

```dart
  /// Matching sets logged so far.
  final int loggedSets;

  /// Set when an external source (Whoop) credited this item instead of
  /// logged sets — shown in place of the "k/N" counter ("strain 14.8").
  final String? creditNote;

  const PrescribedItem({
    required this.name,
    required this.scheme,
    required this.period,
    this.targetSets = 1,
    this.loggedSets = 0,
    this.creditNote,
  });

  /// Complete only when every prescribed set is logged.
  bool get done => loggedSets >= targetSets;

  PrescribedItem withLogged(int n) => PrescribedItem(
        name: name,
        scheme: scheme,
        period: period,
        targetSets: targetSets,
        loggedSets: n,
        creditNote: creditNote,
      );

  /// Marks the item complete on an external source's say-so.
  PrescribedItem withCredit(String note) => PrescribedItem(
        name: name,
        scheme: scheme,
        period: period,
        targetSets: targetSets,
        loggedSets: targetSets,
        creditNote: note,
      );
```

- [ ] **Step 4: Create `lib/services/whoop_activity.dart`**

```dart
/// Whoop workouts as the app's ACTIVITY signal (2026-10-01, spec
/// docs/superpowers/specs/2026-10-01-whoop-activity-layer-design.md).
///
/// Pure: turns `whoop_workouts` rows into typed [WhoopActivity] values and
/// answers the questions consumers ask — what kind of session, was it an
/// easy zone-2 run, was it logged anywhere else, does it complete a
/// prescribed climb. Whoop says a session HAPPENED (+ strain); Kaya adds
/// climbing grades when an export lands; manual logs carry set detail.
library;

import 'prescribed_exercises.dart';

enum ActivityKind { climb, run, lift, walk, other }

class WhoopActivity {
  /// Local calendar day (midnight).
  final DateTime date;

  /// Local wall-clock start, when known.
  final DateTime? start;
  final String sport;
  final ActivityKind kind;
  final double? strain;
  final double? avgHr;
  final double? maxHr;
  final double? durationMin;

  const WhoopActivity({
    required this.date,
    required this.sport,
    required this.kind,
    this.start,
    this.strain,
    this.avgHr,
    this.maxHr,
    this.durationMin,
  });
}

/// Sport label → kind. Normalized (lowercase, spaces/underscores → '-').
ActivityKind activityKindOf(String sport) {
  final s = sport.trim().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');
  if (s.contains('climb') || s.contains('boulder')) return ActivityKind.climb;
  if (s == 'run' || s.contains('running')) return ActivityKind.run;
  if (s == 'weightlifting' ||
      s.contains('powerlifting') ||
      s.contains('strength')) {
    return ActivityKind.lift;
  }
  if (s == 'walking') return ActivityKind.walk;
  return ActivityKind.other;
}

DateTime? _dt(Object? v) {
  if (v is DateTime) return v;
  if (v == null) return null;
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v == null) return null;
  return double.tryParse(v.toString());
}

/// `whoop_workouts` rows → activities, oldest first. Rows without a date
/// or sport are skipped (never throws).
List<WhoopActivity> whoopActivitiesFromRecords(
    Iterable<Map<String, Object?>> rows) {
  final out = <WhoopActivity>[];
  for (final r in rows) {
    final d = _dt(r['date']);
    final sport = r['sport']?.toString().trim() ?? '';
    if (d == null || sport.isEmpty) continue;
    out.add(WhoopActivity(
      date: DateTime(d.year, d.month, d.day),
      start: _dt(r['start_time']),
      sport: sport,
      kind: activityKindOf(sport),
      strain: _num(r['strain']),
      avgHr: _num(r['avg_hr']),
      maxHr: _num(r['max_hr']),
      durationMin: _num(r['duration_min']),
    ));
  }
  out.sort((a, b) => (a.start ?? a.date).compareTo(b.start ?? b.date));
  return out;
}

/// An easy run: kind run, ≥ [minMinutes], average HR ≤ [maxAvgPct] of
/// the user's max HR. Missing HR or duration → false (never guessed).
bool isZone2Run(
  WhoopActivity a, {
  required double maxHr,
  double minMinutes = 20,
  double maxAvgPct = 0.75,
}) =>
    a.kind == ActivityKind.run &&
    a.durationMin != null &&
    a.durationMin! >= minMinutes &&
    a.avgHr != null &&
    a.avgHr! <= maxHr * maxAvgPct;

/// True when nothing else in the app records this session: a climb with
/// no Kaya ascents that day, a lift with no logged strength sets that day,
/// and every other kind (never logged in-app).
bool isUnlogged(
  WhoopActivity a, {
  required Set<DateTime> strengthDays,
  required Set<DateTime> climbDays,
}) =>
    switch (a.kind) {
      ActivityKind.climb => !climbDays.contains(a.date),
      ActivityKind.lift => !strengthDays.contains(a.date),
      _ => true,
    };

/// Distinct local days with a Whoop climb.
Set<DateTime> whoopClimbDays(Iterable<WhoopActivity> acts) => {
      for (final a in acts)
        if (a.kind == ActivityKind.climb) a.date,
    };

/// A prescribed climbing item. The prose parser puts "PM: Climb — …" as
/// name "PM" + scheme "Climb — …", so match on both.
bool isClimbItem(PrescribedItem i) =>
    RegExp(r'climb', caseSensitive: false).hasMatch('${i.name} ${i.scheme}');

/// Ticks not-yet-done climb items when [dayActivities] (the card's day)
/// include a Whoop climb; the note carries the strain of the hardest one.
List<PrescribedItem> creditClimbItems(
    List<PrescribedItem> items, List<WhoopActivity> dayActivities) {
  final climbs =
      dayActivities.where((a) => a.kind == ActivityKind.climb).toList();
  if (climbs.isEmpty) return items;
  final strains = [for (final c in climbs) ?c.strain];
  final note = strains.isEmpty
      ? 'via Whoop'
      : 'strain ${strains.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)}';
  return [
    for (final i in items)
      isClimbItem(i) && !i.done ? i.withCredit(note) : i,
  ];
}
```

- [ ] **Step 5: Run tests**

Run: `flutter test test/whoop_activity_test.dart test/prescribed_exercises_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/services/whoop_activity.dart lib/services/prescribed_exercises.dart test/whoop_activity_test.dart
git commit -m "feat(activity): Whoop activity classifier, zone-2 + unlogged tests, climb credit

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Goals — climbing union, zone2_run, optional

**Files:**
- Modify: `lib/services/goals_service.dart`
- Test: `test/goals_service_test.dart`

- [ ] **Step 1: Write failing tests** — append a group to `main()` in `test/goals_service_test.dart` (add `import 'package:airledger/services/whoop_activity.dart';` at the top):

```dart
  group('whoop activity goals', () {
    // Tuesday 2026-09-29; Monday-start week = Sep 28 .. Oct 4.
    final today = DateTime(2026, 9, 29);
    WhoopActivity act(ActivityKind k, DateTime d,
            {double avg = 120, double dur = 40}) =>
        WhoopActivity(
            date: d, sport: k.name, kind: k, avgHr: avg, durationMin: dur);

    test('climbing counts Whoop ∪ Kaya days once', () {
      final evals = evaluateGoals(
        configs: [const GoalConfig(id: 'climbing', target: 2)],
        inputs: GoalInputs(
          climbingDates: [DateTime(2026, 9, 28)],
          activities: [
            act(ActivityKind.climb, DateTime(2026, 9, 28)), // same day
            act(ActivityKind.climb, DateTime(2026, 9, 29)),
          ],
        ),
        today: today,
      );
      expect(evals.single.value, '2/2 sessions');
      expect(evals.single.status, GoalStatus.met);
    });

    test('zone2_run met by an easy run', () {
      final evals = evaluateGoals(
        configs: [const GoalConfig(id: 'zone2_run', optional: true)],
        inputs: GoalInputs(
          maxHr: 200,
          activities: [act(ActivityKind.run, DateTime(2026, 9, 28))],
        ),
        today: today,
      );
      expect(evals.single.status, GoalStatus.met);
      expect(evals.single.value, '1/1 run');
    });

    test('optional unmet renders as optional, not unmet', () {
      final evals = evaluateGoals(
        configs: [const GoalConfig(id: 'zone2_run', optional: true)],
        inputs: GoalInputs(
          maxHr: 200,
          activities: [
            act(ActivityKind.run, DateTime(2026, 9, 28), avg: 170), // hard
          ],
        ),
        today: today,
      );
      expect(evals.single.status, GoalStatus.optional);
      expect(evals.single.detail, 'nice to have');
    });

    test('no max HR → unknown with a hint', () {
      final evals = evaluateGoals(
        configs: [const GoalConfig(id: 'zone2_run')],
        inputs: const GoalInputs(),
        today: today,
      );
      expect(evals.single.status, GoalStatus.unknown);
      expect(evals.single.value, 'set max HR');
    });

    test('parseGoals reads optional + zone-2 keys', () {
      final g = parseGoals('''
phases:
  cut:
    goals:
      - id: zone2_run
        optional: true
        target: 1
        min_minutes: 25
        max_avg_hr_pct: 0.7
''')!['cut']!.single;
      expect(g.optional, isTrue);
      expect(g.minMinutes, 25);
      expect(g.maxAvgHrPct, 0.7);
    });
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/goals_service_test.dart`
Expected: compile FAIL — `activities` / `optional` aren't defined.

- [ ] **Step 3: Implement** in `lib/services/goals_service.dart`:

1. Import: `import 'whoop_activity.dart';`
2. Doc header list: add `///   6. zone2_run     easy runs (Whoop) vs a weekly target — usually optional.` and note "climbing counts Whoop ∪ Kaya days".
3. `GoalConfig`: add fields + constructor params:

```dart
  /// A "nice to have" goal: unmet renders [GoalStatus.optional] (neutral),
  /// never the red unmet state.
  final bool optional;

  // --- zone2_run ---
  /// Minimum run length in minutes (default 20).
  final double? minMinutes;

  /// Max average HR as a fraction of the user's max HR (default 0.75).
  final double? maxAvgHrPct;
```

constructor: `this.optional = false, this.minMinutes, this.maxAvgHrPct,`

4. `parseGoals` → in `GoalConfig(...)` add:

```dart
          optional: gg['optional'] == true,
          minMinutes: (gg['min_minutes'] as num?)?.toDouble(),
          maxAvgHrPct: (gg['max_avg_hr_pct'] as num?)?.toDouble(),
```

5. `GoalStatus`: `enum GoalStatus { met, partial, unmet, unknown, optional }` and document `/// optional  a nice-to-have goal not (yet) met — neutral, never red.`
6. `_defaultLabels`: add `'zone2_run': 'Zone-2 run',`.
7. `GoalInputs`: add

```dart
  /// Whoop activities (whoop_activity.dart) — climbing credit + zone-2.
  final List<WhoopActivity> activities;

  /// The user's max HR (meta `user_max_hr`). Null → zone-2 can't judge.
  final double? maxHr;
```

with constructor defaults `this.activities = const [], this.maxHr,`.

8. `case 'climbing':` — replace the `sessions` set with:

```dart
        // Whoop says a climb happened even when Kaya hasn't exported
        // yet; counting distinct DAYS means a day in both counts once.
        final sessions = <DateTime>{
          for (final d in inputs.climbingDates)
            if (inWeek(d)) _day(d),
          for (final d in whoopClimbDays(inputs.activities))
            if (inWeek(d)) d,
        }.length;
```

9. New case before `default:`:

```dart
      case 'zone2_run':
        final maxHr = inputs.maxHr;
        if (maxHr == null || maxHr <= 0) {
          out.add(GoalEval(
            config: c,
            status: GoalStatus.unknown,
            value: 'set max HR',
            detail: 'Integrations → Whoop live heart rate',
          ));
          break;
        }
        final runs = [
          for (final a in inputs.activities)
            if (inWeek(a.date) &&
                isZone2Run(a,
                    maxHr: maxHr,
                    minMinutes: c.minMinutes ?? 20,
                    maxAvgPct: c.maxAvgHrPct ?? 0.75))
              a,
        ];
        final days = {for (final a in runs) a.date}.length;
        final t = (c.target ?? 1).round();
        final last = runs.isEmpty ? null : runs.last;
        out.add(GoalEval(
          config: c,
          status: days >= t
              ? GoalStatus.met
              : days > 0
                  ? GoalStatus.partial
                  : GoalStatus.unmet,
          value: '$days/$t run${t == 1 ? '' : 's'}',
          detail: last == null
              ? ''
              : '${last.durationMin!.round()} min · avg HR ${last.avgHr!.round()}',
        ));
```

10. Replace the final `return out;` with the generic optional pass:

```dart
  // Optional goals never go red: unmet → the neutral "nice to have".
  return [
    for (final e in out)
      e.config.optional && e.status == GoalStatus.unmet
          ? GoalEval(
              config: e.config,
              status: GoalStatus.optional,
              value: e.value,
              detail: e.detail.isEmpty ? 'nice to have' : e.detail,
              ticks: e.ticks,
            )
          : e,
  ];
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/goals_service_test.dart`
Expected: PASS. Then `flutter analyze lib/ui/goals_screen.dart` will report the non-exhaustive `GoalStatus` switch — fixed in Task 5.

- [ ] **Step 5: Commit**

```bash
git add lib/services/goals_service.dart test/goals_service_test.dart
git commit -m "feat(goals): climbing counts Whoop days; optional zone-2 run goal

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Wire Whoop into the Goals screen + home dashboard

**Files:**
- Modify: `lib/ui/goals_screen.dart`, `lib/ui/home_dashboard.dart`, `lib/ui/home_screen.dart`

- [ ] **Step 1: GoalsScreen params.** In `lib/ui/goals_screen.dart` add fields next to `cardioView/cardioRepo` (constructor too):

```dart
  /// Whoop workouts — climbing credit + the zone-2 run goal.
  final ViewSchema? workoutsView;
  final WarehouseConnector? workoutsRepo;
```

Imports: `import '../services/heart_rate_service.dart';` and `import '../services/whoop_activity.dart';`.

- [ ] **Step 2: GoalsScreen inputs.** In `_compute()`, after the cardio loop add:

```dart
    // Whoop workouts → activities (climb credit + zone-2 runs).
    final activities = whoopActivitiesFromRecords(
        await _rows(widget.workoutsRepo, widget.workoutsView));
    final maxHr = HeartRateService.instance?.maxHr.value?.toDouble();
```

and pass `activities: activities, maxHr: maxHr,` into `GoalInputs(...)`.

- [ ] **Step 3: Optional status rendering.** In the three `GoalStatus` switches (~lines 337-361) add:

```dart
    GoalStatus.optional => scheme.outline,
```
```dart
      GoalStatus.optional => 'Nice to have',
```
```dart
      GoalStatus.optional => Icons.radio_button_unchecked,
```

- [ ] **Step 4: Home dashboard climb dates.** In `lib/ui/home_dashboard.dart` add the same two fields + constructor params (`workoutsView`, `workoutsRepo`) to the widget, import `../services/whoop_activity.dart`, and change `_loadClimbDates` to append Whoop climb days before `return out;`:

```dart
      // Whoop climbs (Kaya exports lag ~weekly) — distinct-day counting
      // downstream dedups a day present in both.
      if (widget.workoutsRepo != null && widget.workoutsView != null) {
        try {
          out.addAll(whoopClimbDays(whoopActivitiesFromRecords(
              await widget.workoutsRepo!.list(widget.workoutsView!))));
        } catch (_) {/* honest: Kaya-only */}
      }
```

Also remove the early `return const [];` guard at the top so Whoop still counts when the climbing view is absent: wrap only the Kaya read in `if (widget.climbingRepo != null && widget.climbingView != null) { ... }` inside the try.

- [ ] **Step 5: home_screen wiring.** In `lib/ui/home_screen.dart`, every `HomeDashboard(` and the `GoalsScreen(` call (grep `climbingView: dashClimbingView,` — lines ~1308, ~1401, ~1530) gains:

```dart
                        workoutsView: dashWorkoutsView,
                        workoutsRepo: dashboardRepoFor(
                          dashWorkoutsView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
```

- [ ] **Step 6: Verify**

Run: `flutter analyze` → 29 issues (baseline), no errors. `flutter test test/goals_screen_test.dart test/home_dashboard_test.dart` (whichever exist: `ls test | grep -E "goals_screen|home_dashboard"`) → PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/ui/goals_screen.dart lib/ui/home_dashboard.dart lib/ui/home_screen.dart
git commit -m "feat(goals): feed Whoop activities + max HR into goals and climb counts

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Today checklist climb credit

**Files:**
- Modify: `lib/ui/widgets/program_day_card.dart`, `lib/ui/home_screen.dart`

- [ ] **Step 1: Params.** Add to `ProgramDayCard` (+constructor):

```dart
  /// Whoop workouts — a Whoop climb on the card's day ticks the
  /// prescribed climb (Kaya exports lag). Null → logged sets only.
  final ViewSchema? workoutsView;
  final WarehouseConnector? workoutsRepo;
```

Import `../../services/whoop_activity.dart`.

- [ ] **Step 2: Credit in `_load()`.** Just before `return _DayData(prescription, items);` add:

```dart
    final wv = widget.workoutsView;
    final wr = widget.workoutsRepo;
    if (wv != null && wr != null && items.isNotEmpty) {
      try {
        final day = [
          for (final a in whoopActivitiesFromRecords(await wr.list(wv)))
            if (_sameDay(a.date, date)) a,
        ];
        items = creditClimbItems(items, day);
      } catch (_) {/* honest: logged-only */}
    }
```

- [ ] **Step 3: Counter shows the credit.** In `_ExerciseRow.build`, replace the `counter` expression with:

```dart
    // Whoop credit note ("strain 14.8") wins over the set counter.
    final counter = item.creditNote ??
        (showCheck && (item.loggedSets > 0 || item.targetSets > 1)
            ? '${item.loggedSets}/${item.targetSets}'
            : null);
```

- [ ] **Step 4: Wire both `ProgramDayCard(` calls in home_screen.dart** (~1257, ~1474) with `workoutsView: dashWorkoutsView, workoutsRepo: dashboardRepoFor(dashWorkoutsView, readOnlyRepo: data.readOnlyRepo, forView: data.registry.forView),`.

- [ ] **Step 5: Verify + commit**

Run: `flutter analyze` (29) and `flutter test test/whoop_activity_test.dart` (PASS).

```bash
git add lib/ui/widgets/program_day_card.dart lib/ui/home_screen.dart
git commit -m "feat(today): Whoop climb ticks the prescribed climb (shows strain)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Day synthesis activity line

**Files:**
- Modify: `lib/services/day_synthesis.dart`, `lib/services/day_synthesis_service.dart`, `lib/ui/home_screen.dart`
- Test: `test/day_synthesis_test.dart` (exists? `ls test | grep day_synthesis`; append there, else create)

- [ ] **Step 1: Failing test** (append):

```dart
  test('prompt lists Whoop activity and counts a Whoop climb', () {
    final c = DaySynthesisContext(
      hour: 20,
      phase: 'cut',
      program: const SynthProgramDay(climbCall: 'LIGHT'),
      logged: const SynthLogged(),
      targets: const SynthTargets(),
      activities: [
        WhoopActivity(
          date: DateTime(2026, 10, 1),
          start: DateTime(2026, 10, 1, 14, 58),
          sport: 'rock-climbing',
          kind: ActivityKind.climb,
          strain: 14.8,
          durationMin: 86,
        ),
      ],
    );
    expect(c.climbToCome, isFalse);
    final p = buildDaySynthesisPrompt(c);
    expect(p, contains('ACTIVITY (Whoop'));
    expect(p, contains('rock-climbing 14:58 · strain 14.8 · 86 min'));
  });
```

(Check `SynthProgramDay`/`SynthLogged`/`SynthTargets` constructors in day_synthesis.dart and use their real required params — the existing tests in that file show the minimal construction.)

- [ ] **Step 2: Run** `flutter test test/day_synthesis_test.dart` → FAIL (`activities` not a parameter).

- [ ] **Step 3: Implement.** In `day_synthesis.dart`: import `whoop_activity.dart`; `DaySynthesisContext` gains `final List<WhoopActivity> activities;` (default `const []`, documented "today's Whoop workouts, local time"). Change `climbToCome` to:

```dart
  bool get climbToCome =>
      program.climbCall != null &&
      logged.climbCount == 0 &&
      !activities.any((a) => a.kind == ActivityKind.climb);
```

In `buildDaySynthesisPrompt`, after the recovery block:

```dart
  if (c.activities.isNotEmpty) {
    b.writeln('ACTIVITY (Whoop, today — counts as done even if not logged):');
    for (final a in c.activities) {
      final t = a.start == null
          ? ''
          : ' ${a.start!.hour.toString().padLeft(2, '0')}:'
              '${a.start!.minute.toString().padLeft(2, '0')}';
      b.writeln('- ${a.sport}$t'
          '${a.strain == null ? '' : ' · strain ${a.strain!.toStringAsFixed(1)}'}'
          '${a.durationMin == null ? '' : ' · ${a.durationMin!.round()} min'}');
    }
    b.writeln();
  }
```

In `day_synthesis_service.dart`: add `workoutsView`/`workoutsRepo` fields + constructor params; in `buildContext()` after the climbing block:

```dart
    var activities = const <WhoopActivity>[];
    if (workoutsView != null && workoutsRepo != null) {
      try {
        activities = [
          for (final a in whoopActivitiesFromRecords(
              await workoutsRepo!.list(workoutsView!)))
            if (_sameDay(a.date, dayStart)) a,
        ];
      } catch (_) {/* honest empty */}
    }
```

pass `activities: activities` into the returned `DaySynthesisContext`, and bump `_cacheVersion = 4` with a doc line "v4 (2026-10-01): Whoop activity line + climb credit".

home_screen.dart `DaySynthesisService(` call: add `workoutsView: dashWorkoutsView, workoutsRepo: dashboardRepoFor(dashWorkoutsView, readOnlyRepo: data.readOnlyRepo, forView: data.registry.forView),`.

- [ ] **Step 4: Run** `flutter test test/day_synthesis_test.dart` → PASS; `flutter analyze` → 29.

- [ ] **Step 5: Commit**

```bash
git add lib/services/day_synthesis.dart lib/services/day_synthesis_service.dart lib/ui/home_screen.dart test/day_synthesis_test.dart
git commit -m "feat(today): day synthesis sees Whoop activity; Whoop climb counts as done

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: CoachBrain activity section

**Files:**
- Modify: `lib/services/coach_brain.dart`
- Test: `test/coach_brain_test.dart` (exists — append)

- [ ] **Step 1: Failing test** (append; pure static so no IO):

```dart
  test('renderActivitySection flags unlogged Whoop sessions', () {
    final s = CoachBrain.renderActivitySection(
      activities: [
        WhoopActivity(
            date: DateTime(2026, 9, 27),
            start: DateTime(2026, 9, 27, 13, 45),
            sport: 'running',
            kind: ActivityKind.run,
            strain: 9.3,
            avgHr: 122,
            maxHr: 170,
            durationMin: 43),
        WhoopActivity(
            date: DateTime(2026, 9, 28),
            sport: 'weightlifting',
            kind: ActivityKind.lift,
            strain: 11.8),
      ],
      strengthDays: {DateTime(2026, 9, 28)},
      climbDays: const {},
      today: DateTime(2026, 9, 29),
    );
    expect(s, contains('## Activity (Whoop, last 14 days)'));
    expect(s, contains('2026-09-27 13:45 running · strain 9.3 · 43 min · HR 122/170 [unlogged]'));
    expect(s, contains('2026-09-28 weightlifting · strain 11.8'));
    expect(s, isNot(contains('11.8 [unlogged]')));
  });
```

- [ ] **Step 2: Run** `flutter test test/coach_brain_test.dart` → FAIL.

- [ ] **Step 3: Implement** in `coach_brain.dart` (import `whoop_activity.dart`):

```dart
  /// "Activity (Whoop)" section: every Whoop workout in the last 14 days
  /// (local time), flagged `[unlogged]` when nothing else in the app
  /// records it — so the coach knows a climb/run/hike happened even with
  /// no Kaya export or manual log. Null when there are no activities.
  static String? renderActivitySection({
    required List<WhoopActivity> activities,
    required Set<DateTime> strengthDays,
    required Set<DateTime> climbDays,
    required DateTime today,
  }) {
    final from = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 13));
    final lines = <String>[];
    for (final a in activities) {
      if (a.date.isBefore(from)) continue;
      final d = '${a.date.year}-${a.date.month.toString().padLeft(2, '0')}-'
          '${a.date.day.toString().padLeft(2, '0')}';
      final t = a.start == null
          ? ''
          : ' ${a.start!.hour.toString().padLeft(2, '0')}:'
              '${a.start!.minute.toString().padLeft(2, '0')}';
      final parts = [
        '$d$t ${a.sport}',
        if (a.strain != null) 'strain ${a.strain!.toStringAsFixed(1)}',
        if (a.durationMin != null) '${a.durationMin!.round()} min',
        if (a.avgHr != null && a.maxHr != null)
          'HR ${a.avgHr!.round()}/${a.maxHr!.round()}',
      ];
      final flag = isUnlogged(a, strengthDays: strengthDays, climbDays: climbDays)
          ? ' [unlogged]'
          : '';
      lines.add('- ${parts.join(' · ')}$flag');
    }
    if (lines.isEmpty) return null;
    return '## Activity (Whoop, last 14 days)\n\n'
        'Whoop is the record that a session HAPPENED (+ strain 0-21). '
        '[unlogged] = no Kaya ascents / logged sets that day — treat it as '
        'done, not missed.\n\n${lines.join('\n')}';
  }

  Future<String?> _activitySection(DateTime today) async {
    final wv = views['whoop_workouts'];
    if (wv == null) return null;
    try {
      final acts = whoopActivitiesFromRecords(await repository.list(wv));
      DateTime? d(Object? v) => v is DateTime
          ? v
          : DateTime.tryParse(v?.toString() ?? '');
      Future<Set<DateTime>> days(String name) async {
        final v = views[name];
        if (v == null) return {};
        final repo = v.readOnly ? readOnlyRepo : repository;
        if (repo == null) return {};
        return {
          for (final r in await repo.list(v))
            if (d(r['date']) case final x?) DateTime(x.year, x.month, x.day),
        };
      }

      return renderActivitySection(
        activities: acts,
        strengthDays: await days('strength'),
        climbDays: await days('climbing'),
        today: today,
      );
    } catch (_) {
      return null;
    }
  }
```

(Check the field names `views`, `repository`, `readOnlyRepo` against the class — they're used the same way in `_ledgerDump`.) In `buildSystemPrompt`, add `final activity = await _activitySection(today);` and insert `?activity,` after the ledger-data section.

- [ ] **Step 4: Run** `flutter test test/coach_brain_test.dart` → PASS; analyze → 29.

- [ ] **Step 5: Commit**

```bash
git add lib/services/coach_brain.dart test/coach_brain_test.dart
git commit -m "feat(coach): Activity (Whoop) section with [unlogged] flags

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Config — zone2 goal, program v15, daily-notes form

**Files (all in `~/repos/airledger-fitness`):** `app/dashboards.yaml`, `coach/program.yaml`, `coach/fixtures/program_current_cases.yaml`, `views/daily_notes.input.yml`. Ledger tests: `test/cut_week_structure_test.dart`, `test/program_screen_test.dart`.

- [ ] **Step 1: dashboards.yaml.** In BOTH goal lists (cut ~line 414, recomp ~line 555), append after the `cardio_4x4` entry (match its indentation):

```yaml
      - id: zone2_run
        label: Zone-2 run
        description: "Nice to have: one easy run a week (the Sunday run) — detected from Whoop, no logging needed."
        optional: true
        target: 1
        min_minutes: 20
        max_avg_hr_pct: 0.75
```

Also update the comment listing goal ids (`# Goal ids: macros / ... / cardio_4x4`) to include `zone2_run`.

- [ ] **Step 2: program.yaml v15.** Append a new version by copying v14 verbatim (from the line `  - version: 14` to EOF) and editing the copy:

```bash
cd ~/repos/airledger-fitness
start=$(grep -n '^  - version: 14$' coach/program.yaml | cut -d: -f1)
tail -n +$start coach/program.yaml > /tmp/v15.yaml
```

In `/tmp/v15.yaml`: set `version: 15`, `effective_from: "2026-10-01"`, `reason: "Cut Sunday gains an OPTIONAL easy zone-2 run (user's weekly run with family): prose only — never planned, never a missed session; fulfilment is detected from Whoop by the zone2_run goal (dashboards.yaml). Post-cut Sunday already says optional easy Zone 2 — unchanged. Everything else UNCHANGED from v14."`. In the copy's `routine.week.sun` (the FIRST `sun:` under `routine:`, morning null / afternoon null) set:

```yaml
        sun:
          morning: "Optional: easy zone-2 run, 30-45 min (nice to have; Whoop detects it — no logging needed)."
          afternoon: null
```

Then `cat /tmp/v15.yaml >> coach/program.yaml` (ensure exactly one newline between versions). Validate: `python3 -c "import yaml;d=yaml.safe_load(open('coach/program.yaml'));print(d['versions'][-1]['version'])"` → `15`.

- [ ] **Step 3: Fixture.** In `coach/fixtures/program_current_cases.yaml`, case `block0_last_day_sunday_week12_still_normal` → `today_template.morning:` becomes the exact v15 string above. Any other block-0 `weekday: sun` case with a date ≥ 2026-10-01 gets the same change (grep `weekday: sun`).

- [ ] **Step 4: daily_notes form.** In `views/daily_notes.input.yml`, add `editable: false` to `sleep_hours`, `sleep_quality`, `readiness` (keep their other keys), and replace the section comment's first line with `# --- Daily recovery subjectives. sleep_hours / sleep_quality / readiness are HIDDEN from the form since 2026-10-01 — Whoop (recovery view) owns sleep + readiness; the dims stay so history is intact.` Change the `note` placeholder to `How training felt, soreness, life context…`.

- [ ] **Step 5: Run the twins + ledger tests.**

First check where these tests load program.yaml from: `grep -n "program.yaml" test/cut_week_structure_test.dart test/program_current_test.dart`. If they read `assets/` (not `~/repos/airledger-fitness`), copy the edited file in first: `cp ~/repos/airledger-fitness/coach/program.yaml <that assets path>`.

```bash
cd ~/repos/ledger
flutter test test/program_current_test.dart test/cut_week_structure_test.dart test/program_screen_test.dart test/v12_equivalence_test.dart
cd ~/repos/ledger-mcp && npm test
```

Expected failures to FIX, not ignore:
- `cut_week_structure_test.dart` "Sun: rest — no rows, empty template": change to assert NO planned rows and `today_template.morning` equals the v15 optional-run string (planner never plans optionals).
- `program_screen_test.dart` "Exactly one rest day on screen: Sunday": Sunday now shows the optional-run prose; assert zero `'Rest'` days and Sunday's summary contains `zone-2`.
- `v12_equivalence_test.dart`: if it compares v11↔v12 only, untouched; if it resolves "current", update to pin v14 explicitly.
- MCP `test/program.test.ts`: passes via the shared fixture.

- [ ] **Step 6: Commit both repos, push fitness.**

```bash
cd ~/repos/airledger-fitness
git add app/dashboards.yaml coach/program.yaml coach/fixtures/program_current_cases.yaml views/daily_notes.input.yml
git commit -m "feat: optional zone-2 run (program v15 + goal); hide Whoop-owned daily-note fields

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push
cd ~/repos/ledger
git add test/cut_week_structure_test.dart test/program_screen_test.dart test/v12_equivalence_test.dart
git commit -m "test: Sunday carries the optional zone-2 run prose (program v15)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: MCP `workouts_recent` gains kind + avg_hr

**Files:** `~/repos/ledger-mcp/src/tools.ts`, `~/repos/ledger-mcp/test/coach_context.test.ts`

- [ ] **Step 1: Failing test.** In the `workouts_recent` describe block, add a case asserting an entry from a row `sport: rock-climbing, avg_hr: 93` carries `kind: 'climb'` and `avg_hr: 93`, and `running` → `kind: 'run'` (copy the existing case's mock-tab setup verbatim and add the `avg_hr` header/cell).

- [ ] **Step 2: Run** `npm test -- coach_context` → FAIL.

- [ ] **Step 3: Implement** in `readWorkoutsRecent`:

```ts
const kindOf = (sport: string): string => {
  const s = sport.trim().toLowerCase().replace(/[\s_]+/g, '-');
  if (s.includes('climb') || s.includes('boulder')) return 'climb';
  if (s === 'run' || s.includes('running')) return 'run';
  if (s === 'weightlifting' || s.includes('powerlifting') || s.includes('strength')) return 'lift';
  if (s === 'walking') return 'walk';
  return 'other';
};
```

(mirror of Dart `activityKindOf` — keep them in sync). Add `const avgHrIdx = idx.get('avg_hr');`, `avg_hr: numOrNull(r, avgHrIdx)` to `W`, and in `toEntry` add `kind: kindOf(w.sport)` and `...(w.avg_hr !== null ? { avg_hr: w.avg_hr } : {})`. Extend `note` with: `"kind = climb|run|lift|walk|other. Whoop is the record that a session HAPPENED — a climb here with no Kaya ascents yet still counts toward the weekly climbing goal; an easy run (kind run, >=20 min, avg_hr <= 75% of max HR) fulfils the optional weekly zone-2 run."` Update the tool description string mentioning workouts_recent (line ~1924) the same way.

- [ ] **Step 4: Run** `npm test` → all green (previous total + 1).

- [ ] **Step 5: Commit + deploy**

```bash
cd ~/repos/ledger-mcp
git add src/tools.ts test/coach_context.test.ts
git commit -m "feat(coach_context): workouts_recent carries kind + avg_hr

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
npx wrangler deploy
git push
```

Smoke: `curl -s -X POST "https://ledger-mcp.ryime.workers.dev/mcp/$(cat ~/.config/airledger/mcp_token)" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_coach_context","arguments":{}}}' | grep -o '"kind\\\\":\\\\"[a-z]*' | head -3` → shows kinds.

---

### Task 11: Deploy, reconcile, verify, document

- [ ] **Step 1: Full checks.** `cd ~/repos/ledger && flutter analyze` → 29 issues; `flutter test` → only the 7 known failures.
- [ ] **Step 2: Build + install.** `dart run tool/brand.dart --config ~/repos/airledger-fitness/ledger.yaml` → "Installed and launched".
- [ ] **Step 3: Reconcile on device.** Home → back to the home screen first (so SchemaSync applies), Integrations → Whoop (sleep + recovery) ⋮ → Full reconcile.
- [ ] **Step 4: Verify the sheet** with a temporary script (copy of the peek used on 2026-10-01: read `whoop_workouts`): the walking row `400f34a2…` (02:30Z on 09-23) now reads date `2026-09-22`, start `2026-09-22 19:30:00`; no duplicate rows (count unchanged at the API's window total). `recovery` has one row per day, no blank dates.
- [ ] **Step 5: Verify the app.** Goals tab: Climbing counts this week's Whoop climbs; Zone-2 run row shows "Nice to have" (or ✓ after a Sunday run). Today (a climbing day with a Whoop climb): the PM climb item is ticked with "strain N.N". Daily notes form: no sleep hours / sleep quality / readiness.
- [ ] **Step 6: CLAUDE.md.** Add a feature-state bullet "**Whoop activity layer (2026-10-01)**" summarising: local-time fix (timezone_offset; recovery keyed by sleep_id; stale-day unwind), `whoop_activity.dart` as the single classifier (Dart) mirrored by ledger-mcp `kindOf` (edit BOTH), climbing = Whoop ∪ Kaya by distinct day, optional zone2_run goal (+ `GoalStatus.optional`), Today climb credit, synthesis/CoachBrain activity, program v15 Sunday prose, daily-notes sleep/readiness hidden. Add an open follow-up: "Part 2 — missed-exercise carryover/rescheduling (separate spec)". Commit:

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md — Whoop activity layer

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
