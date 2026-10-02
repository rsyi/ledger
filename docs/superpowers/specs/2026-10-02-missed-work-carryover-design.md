# Missed-work carryover + manual rescheduling — design (Part 2)

Date: 2026-10-02 · Status: approved in chat (user), amended the same day
to add manual rescheduling (folded into one move mechanism) · Part 1:
`2026-10-01-whoop-activity-layer-design.md`.

## Problem

The program prescribes a fixed week (program.yaml `routine:`). When a day
goes sideways the app keeps showing the original plan: missed work just
disappears, nothing nudges it into the rest of the week, and the user
can't move an item to another day by hand. The deprecated
`coach/routine.md` carryover rule (skipped lift → next compatible day;
drop accessories before mains; never stack volume) exists only as prose.

## Decisions (user-approved)

- **Scope:** everything prescribed carries — main lifts, accessories,
  climbing sessions, the 4x4. `Optional …` items never count as missed.
- **Horizon:** the rest of the current Mon–Sun week (Sunday included).
  Unplaced work EXPIRES at week end; next week starts clean on its own
  wave step. Expired items are reported to the coach.
- **Who places automatic carryover:** the coach PROPOSES (Schedule / Not
  now card); nothing moves without a tap.
- **Trigger:** both — the nightly Mac briefing (primary) and an in-app
  check on the first open of the day (fallback when no carryover proposal
  exists for today).
- **Manual rescheduling:** the user can move any program item to another
  day of the current week from the program day card (amendment).

## 1. One move mechanism — `program_moves` view (synced)

New engine view (schema only — no Rust/dylib change; the tab
auto-creates; additive) in airledger-fitness `views/`:

| dim | type | meaning |
|---|---|---|
| id | string | UUID |
| date | date | TARGET day (date_field) |
| from_date | date | the day the program prescribed it |
| item | string | item display name (e.g. "Bench heavy") |
| period | string | AM / PM of the original slot |
| source | string | `manual` or `coach` |
| note | string | optional reason ("missed Wed — late meeting") |

- A move relocates ONE prescribed item instance (keyed by
  `from_date + item`, case-insensitive) to `date`. Moving again to another
  day = a new row; the latest `id`/row for a key wins. Deleting the row
  (Undo) puts the item back.
- `date == from_date` is invalid (UI never writes it). Moves outside
  `from_date`'s Mon–Sun week are ignored by the resolver.
- Synced (Sheets) so the Mac nightly and MCP see the same moves.

## 2. Effective week — `lib/services/program_moves.dart` (pure)

`effectiveWeek(prescribedByDay, moves) → Map<DateTime, List<EffectiveItem>>`
where `EffectiveItem` = the PrescribedItem + `movedFrom` (DateTime?) +
`movedTo` (DateTime?, set on the ORIGIN day's ghost entry). Origin days
keep a ghost row "→ Fri" (not counted); target days gain the item tagged
"moved from Wed". Completion ticking is unchanged (logged sets by name on
the day it now lives on; Whoop climb credit from Part 1).

## 3. Missed-work detector — `lib/services/missed_work.dart` (pure)

Inputs: the effective week, logged strength rows (name + date + count),
cardio 4x4 days, climb days (Part 1 `climbDaysUnion`), today.
- An item on a day strictly BEFORE today is **missed** when its logged
  sets on that day are below target, AND the same exercise has no surplus
  logged elsewhere in the week (doing Wed's bench on Thu without a move
  still clears it — week-to-date set accounting per exercise token).
- Climb items: missed when the week's climb days < climb items scheduled
  through yesterday. 4x4: same against cardio 4x4 days.
- `Optional …` prose never yields items (parser skip list) → never missed.
- Output: `MissedItem {item, fromDate, period, setsShort}` plus
  `remainingDays` (today..Sunday) for placement, and `expired` (on
  Sunday-night evaluation, anything still missed).

## 4. UI — manual moves on the program day card

`ProgramDayCard` (Today + Program screen): each item row gets a trailing
overflow menu (the info icon stays): **Move to…** → bottom sheet of the
other days of this week (labelled "Thu 10/2", with that day's load
summary), and **Undo move** on moved items. Writes/deletes a
`program_moves` row (source `manual`), then reloads. Moved-in items show
a small "from Wed" chip; origin days show the ghost "→ Fri" muted.
A "Missed this week" section (from §3) lists unplaced missed items with a
one-tap **Move to…**.

## 5. Coach proposals become move proposals

- `CoachProposal` gains `type: 'moves'` (absent = legacy rows proposal)
  with `moves: [{item, from_date, period, to_date, note}]` and a summary.
  The card renders "Bench heavy: Wed → Fri" lines; **Schedule** writes
  `program_moves` rows (source `coach`); **Not now** dismisses. Status
  stays device-local as today (`coach_proposal:<rowId>`).
- In-app coach: new tool `propose_moves` (CoachBrain / coach_tools.dart)
  taking that shape; system prompt gains the missed list + placement
  rules (§6).
- Nightly Mac: `coach_nightly.sh` runs new `tool/missed_work.dart`
  (prints the missed list, remaining-week prescription with moves, and
  expired items) into the prompt; PROMPT asks for an optional fenced
  ```moves JSON block; the script extracts it and posts one
  `kind=proposal` row (type moves) via `coach_msg.dart post --kind
  proposal`, alongside the briefing text (block stripped from the text).
- In-app fallback: on the first foreground of a day after 06:00, if
  `missedWork` is non-empty and no `kind=proposal` row of type moves is
  dated today in coach_chat, ask CoachBrain for a proposal (posts the
  card + a local notification). Guarded by a meta key
  `carryover_checked_day` so it runs at most once per day.

## 6. Placement rules (coach prompt; AI decides within them)

Within this week only · no lifting on Tuesday (program says "NO lifting
today, ever") · squat and deadlift never on the same day · at most one
carried MAIN lift per day · mains before accessories; if it can't all fit,
accessories expire first · never on a day with a pain flag in
daily_notes · respect low recovery (Whoop recovery < 34 → don't add
load that day) · state the reasoning in one line.

## 7. Coach awareness

CoachBrain context, the day synthesis (today's moved-in items count as
today's program), and MCP `get_coach_context` gain `missed_this_week`
(item, from, sets short) + `moves_this_week`. MCP reads the
`program_moves` tab; the missed computation stays app/Mac-side
(nightly writes nothing new — MCP shows moves only, plus the program
slice; documented).

## Out of scope

Strain-based load modulation; moving items across weeks; editing an
item's sets/load when moving (it moves as prescribed).

## Testing

Pure units: effectiveWeek (move, re-move latest wins, undo, cross-week
ignored, ghost rows), missed-work (same-day short, surplus elsewhere
clears, moved item judged on new day, optional never missed, climb/4x4
counting, expiry), proposal codec round-trip (legacy + moves), nightly
block extraction. Widget: move sheet writes a row; ghost + chip render.
Device: move Fri RDL → Sat, see it on Sat; skip an item, see the
proposal next morning.
