# Whoop activity layer — design (Part 1)

Date: 2026-10-01 · Status: approved (user) · Part 2 (missed-work
carryover / rescheduling) is a separate design.

## Problem

Kaya exports are rate-limited (~weekly), so climbing sessions are often
invisible to the app and the coach for days. Whoop already records every
session (sport + strain + HR) via the `whoop_workouts` integration, plus
activity that is never logged anywhere (e.g. the Sunday zone-2 run). The
app should use Whoop as the activity signal alongside manual logs and
Kaya, without double counting.

## Decisions (user-approved)

- Whoop is the source of truth for *whether* a session happened; Kaya
  enriches climbing days with grades when an export lands.
- "Program adjusts" in Part 1 = credit + awareness (checklist ticks,
  weekly goals, coach context). No strain-based load modulation (Part 2).
- Zone-2 run goal: any day, `running` ≥ 20 min, avg HR ≤ 75% of
  `user_max_hr`. Sunday is only the program's default slot.
- Daily notes drop sleep_hours / sleep_quality / readiness from the form.

## 1. Local dates (bug fix)

Whoop v2 timestamps are UTC; today `whoopWorkoutsToRows` /
`whoopSleepToRecovery` take the UTC date portion, so evening Pacific
sessions land on the next day (e.g. a 19:30 PT walk dated tomorrow).

- Each workout and sleep record carries `timezone_offset` ("-07:00").
  Local instant = UTC + offset. `date`, `start_time`, `end_time` (workouts)
  and the wake date (sleep) derive from the LOCAL instant. Missing/
  malformed offset → UTC (current behaviour), never a throw.
- Recovery records have no offset: key them on their `sleep_id`'s local
  wake date when that sleep is in the batch, else `created_at` shifted by
  the batch's most recent sleep offset, else UTC.
- Fields are integration-owned, so one Full reconcile rewrites existing
  rows. Workouts are matched by `workout_id`, so a corrected date updates
  in place (no duplicates). Recovery is match-by-date: a row whose date
  moves would leave the old date's row behind. Add a deleted-days diff to
  the recovery pull (known days inside the window not re-emitted →
  `deleted_dates`, Withings pattern; same empty-fetch mass-delete guard
  as workouts) so the stale row is removed.

## 2. Activity classifier — `lib/services/whoop_activity.dart` (pure)

- `WhoopActivity` value: localDate, start, end, sport, kind, strain,
  avgHr, maxHr, durationMin — built from `whoop_workouts` rows.
- `kind`: `climb` (rock-climbing), `run` (running), `lift`
  (weightlifting), `walk` (walking), `other` (everything else, incl. the
  generic "activity", hiking-rucking, mountain-biking, gymnastics).
  Matching is on the normalized sport string (lowercase, `_`/space → `-`).
- `isZone2Run(a, {maxHr, minMinutes = 20, maxAvgPct = 0.75})`.
- `isUnlogged(a, loggedSessions)`: true when no logged row of the matching
  domain exists on that local date (climb → climbing/Kaya; lift →
  strength; run/walk/other → never logged in-app, so always unlogged).

## 3. Climbing days = Whoop ∪ Kaya

Wherever climbing dates are collected (goals_screen.dart climbingDates,
home_dashboard `_loadClimbDates`), add the local dates of Whoop `climb`
activities. Goals count DISTINCT dates (existing behaviour), so a day
with both a Whoop climb and Kaya ascents counts once.

## 4. Program checklist credit

`ProgramDayCard` ticks a prescribed climbing item (prose item whose name
matches /climb/i) done when a Whoop `climb` activity exists on the card's
date; the counter shows `strain N.N`. Strength items keep ticking from
logged sets only. The card gains optional `whoopWorkoutsView/Repo` params
(null → current behaviour).

## 5. Weekly zone-2 run (optional goal)

- program.yaml v14 (append-only): `routine.week.sun` and the post-cut
  override's Sunday gain prose "Optional: easy zone-2 run, 30-45 min".
  Prose only — the planner never plans optionals.
- `app/dashboards.yaml`: new goal `zone2_run` in cut + recomp goal sets:
  `{ id: zone2_run, label: Zone-2 run, optional: true, per_week: 1,
  min_minutes: 20, max_avg_hr_pct: 0.75, description: ... }`.
- goals_service: new `zone2_run` evaluator over Whoop activities in the
  accounting week. `optional: true` (generic, any goal) → unmet renders
  neutral "nice to have", never red; met renders ✓ as usual. Missing
  `user_max_hr` → the goal reads "set max HR" (no guess).

## 6. Coach awareness

- CoachBrain system context: new "Activity (Whoop, last 14 days)" section
  — one line per workout: local date + time, sport, strain, duration,
  avg/max HR, `[unlogged]` flag per §2.
- Day synthesis (Today summary): today's + yesterday's Whoop activities in
  the prompt; bump its cache version.
- ledger-mcp `get_coach_context`: `activity_7d` block (same shape, from
  the `whoop_workouts` tab, local dates as stored). Twin tests; deploy the
  worker. Keep the context under its token budget (cap 20 lines).

## 7. Daily notes cleanup

- `views/daily_notes.input.yml`: hide sleep_hours, sleep_quality,
  readiness from the form (dims stay in the view; sheet data untouched).
- recomp_review recovery section: sleep hours/quality from the `recovery`
  view (Whoop), subjectives (fatigue/soreness/pain) still from
  daily_notes. Day synthesis already reads `recovery`.

## Out of scope

Strain-based load modulation and missed-work rescheduling (Part 2).
4x4 goal stays on manual cardio logs (Whoop tags it generic "activity").

## Testing

Unit: local-date transform (offset present / missing / day-crossing),
recovery sleep_id keying, classifier table, isZone2Run edges, union
counting (Whoop-only, Kaya-only, both same day), zone2_run goal (met /
unmet optional rendering / no max HR), checklist climb credit. MCP twin
tests for `activity_7d`. Device: Full reconcile, confirm the 9/22 evening
walk re-dates to 9/22 and the 9/27 Sunday run fulfils the goal week.
