# Missed-work Carryover + Manual Rescheduling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let program items move between days of the current week — by hand from the program day card, or by accepting a coach "moves" proposal — and detect/report missed work so the coach proposes where it goes.

**Architecture:** One synced `program_moves` view is the single source of truth for relocations (manual + coach). Pure services compute the week's prescription (`program_week.dart`), apply moves (`program_moves.dart`), and detect missed work (`missed_work.dart`). UI (ProgramDayCard), the in-app coach (new `propose_moves` tool + proposal card type), the nightly Mac briefing (new `tool/missed_work.dart` + proposal post), and MCP all read through them.

**Tech Stack:** Flutter/Dart (`flutter test`), YAML schemas in `~/repos/airledger-fitness` (push after edits), bash nightly script, TypeScript worker `~/repos/ledger-mcp` (`npm test`, `npx wrangler deploy`).

**Spec:** `docs/superpowers/specs/2026-10-02-missed-work-carryover-design.md`.

**Repo rules:** main branch; commit trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`; surgical edits (never `dart format` a whole existing file); `flutter analyze` baseline 29 issues; full `flutter test` baseline = exactly 7 known failures (3 integration `setUpAll` + 4 `schema_loader_test`). NEVER touch or push `~/repos/airledger`. Push `~/repos/airledger-fitness` after schema edits. Don't push `~/repos/ledger`.

**Existing facts implementers need:**
- `lib/ui/widgets/program_day_card.dart` `_load()` builds a day: `provider.load()` → `IntentDocs docs`; `programCurrent(docs.program, docs.phase, date)` → `slice`; `dayPrescription(label:, weekday: weekdayAbbr(date), template: slice?.todayTemplate)` → `DayPrescription` (`.morning`, `.afternoon`, `.isRest`, `.label`, `.weekday`); `parsePrescribedProse(morning, afternoon)` → `List<PrescribedItem>` (name, scheme, period, targetSets, loggedSets, creditNote; `done`); `markPrescribedDone(items, loggedNames)`; Part-1 `creditClimbItems(items, dayWhoopActivities)`.
- Weeks are Mon–Sun for this feature (the review/schedule week), NOT the Saturday accounting week.
- `lib/models/coach_proposal.dart` `CoachProposal` (v1: view/date/template/summary/entries; `encode()`, `tryParse()`); card `lib/ui/widgets/coach_proposal_card.dart`; state store `lib/services/coach_proposal_store.dart` (device-local); chat `lib/ui/coach_chat_screen.dart` (`_postProposal`, proposal rendering ~line 456, Schedule handler writes PlanStore); tools `lib/services/coach_tools.dart` (`propose_schedule`, `read_program_day`); `lib/services/coach_brain.dart` (`buildSystemPrompt`, `_activitySection` from Part 1).
- `tool/coach_msg.dart post --role coach --kind briefing|reply|user --thread <t>` reads text on stdin and appends a coach_chat row via the service account; `tool/coach_nightly.sh` builds PROMPT and posts the briefing to thread `briefings`.
- Part-1 helpers in `lib/services/whoop_activity.dart`: `whoopActivitiesFromRecords`, `climbDaysUnion(kayaDates, whoopDays)`, `whoopClimbDays`, `isClimbItem(PrescribedItem)`.
- home_screen.dart resolves views by name in the dashboard build (`dashWorkoutsView` etc.) and builds repos with `dashboardRepoFor(view, readOnlyRepo: data.readOnlyRepo, forView: data.registry.forView)`; `data.registry.forView(view)` for writable engine views.

---

### Task 1: `program_moves` schema

**Files (airledger-fitness):** create `views/program_moves.view.yml`, `views/program_moves.input.yml`.

- [ ] Create the view (match conventions of `views/whoop_workouts.view.yml`):

```yaml
name: program_moves
description: "Program item relocations within a Mon-Sun week — one row per move (manual from the program day card, or an accepted coach proposal). Latest row per (from_date, item) wins; deleting the row undoes the move. Read by the app, the nightly coach, and MCP."
datasource: gsheets
table: program_moves
entities:
  - { name: move, type: primary, key: id }
dimensions:
  - { name: id, type: string, expr: id, description: Unique row identifier (UUID) }
  - { name: date, type: date, expr: date, description: "Target day the item now lives on" }
  - { name: from_date, type: date, expr: from_date, description: "Day the program prescribed the item" }
  - { name: item, type: string, expr: item, description: "Prescribed item display name (case-insensitive key with from_date)" }
  - { name: period, type: string, expr: period, description: "AM / PM slot of the original item" }
  - { name: source, type: string, expr: source, description: "manual | coach" }
  - { name: created_at, type: datetime, expr: created_at, description: "When the move was made (latest wins)" }
  - { name: note, type: string, expr: note, description: "Optional reason" }
measures:
  - { name: move_count, type: count }
```

and input:

```yaml
target: program_moves.view.yml
icon: calendar
date_field: date
list_display:
  title: item
  subtitle: from ${from_date} • ${source}
fields:
  id:
    editable: false
  date:
    widget: date
    required: true
  from_date:
    widget: date
    required: true
  item:
    widget: text
    required: true
  period:
    widget: text
  source:
    widget: text
    editable: false
  created_at:
    widget: datetime
    editable: false
  note:
    widget: text
```

(Check an existing input.yml for a valid `icon` name and `widget` names; `calendar` must exist in the icon map — grep `lib/` for the icon registry.) Validate both parse: run `flutter test test/schema_loader_test.dart` is NOT enough (known failures) — instead write a throwaway check via `dart run` of the existing loader or simply run the app-side schema parse test pattern used elsewhere; at minimum `python3 -c "import yaml;yaml.safe_load(open(...))"`.

- [ ] Commit in airledger-fitness (`feat(schema): program_moves view`) and `git push`.

---

### Task 2: `program_week.dart` + `program_moves.dart` (pure)

**Files:** create `lib/services/program_week.dart`, `lib/services/program_moves.dart`; tests `test/program_week_test.dart`, `test/program_moves_test.dart`.

- [ ] `program_week.dart`:

```dart
/// Monday of [d]'s Mon–Sun week (local midnight).
DateTime mondayOf(DateTime d);

/// The prescribed items for each day Mon..Sun of the week containing
/// [anyDay], resolved exactly like ProgramDayCard does for one day
/// (programCurrent → dayPrescription → parsePrescribedProse). Days with
/// no program (pre-program, missing docs) map to an empty list.
Map<DateTime, List<PrescribedItem>> prescribedWeek(IntentDocs docs, DateTime anyDay, {String label = 'Today'});
```

Refactor `ProgramDayCard._load` to use a shared single-day helper (`prescribedDay(docs, date)` returning `(DayPrescription?, List<PrescribedItem>)`) so the card and the week builder can't drift. Test against the real program.yaml the same way `test/cut_week_structure_test.dart` loads it (copy its loader): for the week of Mon 2026-09-28, Fri has a climb item (`isClimbItem`) and Sun has none (optional run is skipped); Tue has no lifting items.

- [ ] `program_moves.dart`:

```dart
class ProgramMove {
  final String id;
  final DateTime to;        // local midnight
  final DateTime from;      // local midnight
  final String item;        // display name
  final String period;      // 'AM' | 'PM' | ''
  final String source;      // 'manual' | 'coach'
  final DateTime? createdAt;
  final String note;
  String get key;           // '${yyyy-mm-dd(from)}|${item.toLowerCase().trim()}'
  static ProgramMove? fromRecord(Map<String, Object?> r); // tolerant parse (String/DateTime dates); null when id/date/from_date/item missing
  Map<String, Object?> toRecord(); // for repo.create
}

/// Latest move per key (by createdAt, then list order), restricted to
/// moves whose from AND to fall in [monday]'s week and to != from.
Map<String, ProgramMove> activeMoves(Iterable<ProgramMove> all, DateTime monday);

class EffectiveItem {
  final PrescribedItem item;
  final DateTime home;        // day it was prescribed
  final DateTime? movedTo;    // non-null on the ORIGIN day ghost
  final DateTime? movedFrom;  // non-null on the TARGET day
  final ProgramMove? move;
  bool get isGhost => movedTo != null;
}

/// The week after moves: each day = its own items (moved-out ones become
/// ghosts, in place) + moved-in items appended (tagged movedFrom).
Map<DateTime, List<EffectiveItem>> effectiveWeek(
    Map<DateTime, List<PrescribedItem>> prescribed, Map<String, ProgramMove> moves);
```

An item matches a move when `same day && item.name.toLowerCase().trim() == move.item.toLowerCase().trim()` (first unmatched occurrence only, so two same-named items on a day move one at a time). Tests: move Wed→Fri (Wed ghost, Fri gains movedFrom Wed); re-move later createdAt wins; move outside the week ignored; to==from ignored; unknown item name ignored (no crash); fromRecord with Sheets-shaped strings ("2026-10-02", "2026-10-02 08:00:00").

- [ ] Run tests, analyze (29), commit `feat(program): week prescription + program moves (pure)`.

---

### Task 3: `missed_work.dart` (pure)

**Files:** create `lib/services/missed_work.dart`; test `test/missed_work_test.dart`.

```dart
class MissedItem {
  final PrescribedItem item;   // as prescribed
  final DateTime day;          // the day it was due (after moves)
  final DateTime home;         // original program day
  final int setsShort;         // 0 for session items (climb / 4x4) — use 1
  final String kind;           // 'lift' | 'climb' | 'cardio'
}

class MissedWork {
  final List<MissedItem> missed;          // due before today, not done
  final List<DateTime> remainingDays;     // today..Sunday
  bool get isEmpty;
  String toPromptLines();                 // "- Bench heavy (Wed, 0/1 sets) …" one per item; '' when empty
}

MissedWork detectMissedWork({
  required Map<DateTime, List<EffectiveItem>> week,
  required List<({DateTime date, String exercise})> strengthRows,
  required Set<DateTime> climbDays,      // Part-1 climbDaysUnion
  required Set<DateTime> cardio4x4Days,
  required DateTime today,
});
```

Rules (spec §3): ignore ghosts; only days strictly before `today`; climb items (`isClimbItem`) → compare the count of climb items due before today vs `climbDays` in the week before today (excess due items, latest-first, are missed); 4x4 items (name/scheme contains '4x4', case-insensitive) → same against `cardio4x4Days`; everything else = lift items: per exercise token-set (reuse the `markPrescribedDone` matching — expose a public `matchesPrescribed(String logged, PrescribedItem item)` from prescribed_exercises.dart if needed), sets due through yesterday vs sets logged anywhere Mon..today in the week; allocate logged sets to due items in day order; shortfalls → MissedItem. Tests: Wed bench top unlogged → missed; logged Thu instead → not missed; moved Wed→Fri and today Thu → not missed (not due yet); moved Wed→Tue... (to an earlier day) and not logged → missed with day=Tue; climb Tue due, Whoop climb Wed → not missed; optional Sunday run never appears (no item); `toPromptLines` format.

- [ ] Commit `feat(program): missed-work detector (pure)`.

---

### Task 4: Moves proposals (model + card + apply)

**Files:** `lib/models/coach_proposal.dart`, `lib/ui/widgets/coach_proposal_card.dart`, `lib/ui/coach_chat_screen.dart`, tests (`test/coach_proposal_test.dart` exists? extend or create).

- [ ] Add a sibling model in the same file (keep v1 untouched):

```dart
class MovesProposal {
  static const type = 'moves';
  final String summary;
  final List<ProposedMove> moves; // {item, from (DateTime), to (DateTime), period, note}
  String encode();                // {"v":1,"type":"moves","summary":…,"moves":[{"item","from_date","to_date","period","note"}]}
  static MovesProposal? tryParse(String text); // null unless type == moves and ≥1 valid move
}
```

`CoachProposal.tryParse` must return null for `type: moves` payloads (so legacy code paths don't misrender).

- [ ] Card: when a `kind=proposal` row parses as `MovesProposal`, render the summary + one line per move ("Bench heavy: Wed → Fri") with **Schedule** / **Not now**, reusing the existing card's look and `CoachProposalStore` state. Schedule → for each move `repository.create(programMovesView, ProgramMove(... source: 'coach', createdAt: now).toRecord())`, then mark accepted. The chat screen needs the `program_moves` view + its repo (pass from home_screen through to CoachChatScreen; null → Schedule disabled with a hint).

- [ ] Tests: codec round-trip; legacy CoachProposal still parses; MovesProposal rejects garbage; widget test that Schedule calls create with the right records (use a fake WarehouseConnector like existing widget tests do).

- [ ] Commit `feat(coach): moves proposals (card + apply to program_moves)`.

---

### Task 5: Program day card — effective items, Move to…, Undo, Missed this week

**Files:** `lib/ui/widgets/program_day_card.dart`, `lib/ui/home_screen.dart`, widget test `test/program_day_card_test.dart` (create if missing).

- [ ] Card gains `programMovesView` / `programMovesRepo` (+ the strength/cardio/whoop inputs it already has or Part-1 added; add `cardioView/cardioRepo` and `climbingView/climbingRepo` for missed detection). `_load` builds `prescribedWeek` for the card's week, reads moves → `effectiveWeek`, takes the card date's `EffectiveItem`s, applies existing done-marking / Whoop credit to non-ghost items, and computes `detectMissedWork` (only when the card date is today).
- [ ] Rendering: ghost rows muted with trailing "→ Fri" and no checkbox; moved-in rows show a small "from Wed" chip; each non-ghost row gets a `PopupMenuButton` (keep the info icon tap on the row) with **Move to…** (bottom sheet listing the other 6 days of the week as "Thu 10/2", disabled for the item's current day) and, for moved-in rows, **Undo move** (deletes the move row via `repo.delete`). After write: `reload()` and `LogEventBus` not needed.
- [ ] "Missed this week" section (today's card only, when non-empty): one row per MissedItem ("Bench heavy — Wed, 0/1") with **Move to…** (writes a manual move from its due day).
- [ ] Wire both `ProgramDayCard(` call sites in home_screen.dart with the new views/repos (writable engine view → `data.registry.forView(view)`; climbing read-only → `dashboardRepoFor`).
- [ ] Widget tests: moved-in chip + ghost render; Move to… writes a record with from/to/item/source manual; Undo deletes it.
- [ ] Full test + analyze. Commit `feat(today): move program items between days; missed-this-week section`.

---

### Task 6: In-app coach — `propose_moves`, context, synthesis

**Files:** `lib/services/coach_tools.dart`, `lib/services/coach_brain.dart`, `lib/ui/coach_chat_screen.dart` (tool result → post MovesProposal row), `lib/services/day_synthesis_service.dart` (moved-in items count as today's program), tests.

- [ ] Tool `propose_moves` schema: `{summary: string, moves: [{item, from_date (yyyy-MM-dd), to_date, period?, note?}]}`; validate (to within this Mon–Sun week, to != from) and return the encoded MovesProposal for the chat screen to post as `kind=proposal` (mirror how `propose_schedule` results are posted).
- [ ] CoachBrain system prompt: a "## This week: moves + missed work" section — active moves (item: Wed → Fri, source) and `MissedWork.toPromptLines()` + remaining days, plus the placement rules verbatim from spec §6, and the instruction: "When something is missed, call propose_moves (never claim it's moved — the card handles it)". Loading mirrors `_activitySection` (try/catch → omit).
- [ ] Day synthesis: today's program items include moved-in items (use `effectiveWeek` for today); bump `_cacheVersion` to 5.
- [ ] Tests for the prompt section renderer (pure static like `renderActivitySection`) and the tool validation. Commit `feat(coach): propose_moves + moves/missed context`.

---

### Task 7: In-app daily fallback trigger

**Files:** new `lib/services/carryover_check.dart` (+ test), `lib/ui/home_screen.dart` (call on resume/first build).

- [ ] `CarryoverCheck.maybeRun({now, metaGet, metaSet, missed, hasMovesProposalToday, ask})`: runs only when `now.hour >= 6`, meta `carryover_checked_day` != today, `missed` non-empty, and no `kind=proposal` row with `type: moves` dated today exists in coach_chat; then sets the meta FIRST (at-most-once even on failure) and calls `ask()` which runs CoachBrain with a user-turn like "Missed work detected — propose where it goes this week." and posts its proposal + a local notification (reuse `NotificationService.instance`). Pure-ish with injected functions so it's unit-testable (test all gates).
- [ ] Wire in home_screen on app resume (`WidgetsBindingObserver` already present? grep `didChangeAppLifecycleState`) and after first bootstrap; requires the coach to be enabled (Anthropic model present). Commit `feat(coach): daily in-app carryover check (fallback)`.

---

### Task 8: Nightly Mac path

**Files:** create `tool/missed_work.dart`; modify `tool/coach_nightly.sh`, `tool/coach_msg.dart` (allow `--kind proposal`), `~/repos/airledger-fitness/coach/PROMPT.md`.

- [ ] `tool/missed_work.dart` (`// ignore_for_file: avoid_print`): loads program.yaml/phase.yaml from `~/repos/airledger-fitness/coach/`, reads `strength`, `cardio`, `whoop_workouts`, `kaya_ascents`, `program_moves` tabs via the service account (reuse coach_dump.dart / coach_msg.dart helpers: `readConfig`, `sheetsApi`, `loadView`), runs prescribedWeek → effectiveWeek → detectMissedWork for `--date` (default today), and prints: `MISSED THIS WEEK:` lines (or `none`), `MOVES THIS WEEK:` lines, `REMAINING DAYS:` with each remaining day's effective items. On Sunday also `EXPIRING TONIGHT:`.
- [ ] coach_msg.dart: accept `--kind proposal` (text = the JSON payload).
- [ ] coach_nightly.sh: `MISSED="$(cd "$APP" && dart run tool/missed_work.dart --date "$TARGET" 2>/dev/null)" || true`; add `# missed_work` section to PROMPT; after `OUT=…`, extract a fenced block ```` ```moves ```` … ```` ``` ```` (python3 one-liner or awk) → if present and parses as JSON with ≥1 move, wrap into the MovesProposal encoding (`{"v":1,"type":"moves",...}`) and post it with `coach_msg.dart post --role coach --kind proposal --thread briefings`; strip the block from OUT before posting the briefing. Failures in the proposal path must not block the briefing.
- [ ] PROMPT.md: add a "Missed work" section: when `# missed_work` lists items, decide placement per the rules (copy spec §6 verbatim), mention the plan in one line in the briefing, and emit exactly one fenced ```moves block: `{"summary": "...", "moves": [{"item": "<exact item name>", "from_date": "yyyy-mm-dd", "to_date": "yyyy-mm-dd", "period": "AM|PM", "note": "..."}]}`; omit the block when nothing should move.
- [ ] Test: unit-test the extraction helper if written in Dart (preferred: put extraction + wrapping in `tool/coach_msg.dart` as `post --kind proposal --from-moves-block` reading the whole OUT on stdin, so it's testable via a pure function in `lib/services/moves_block.dart` + `test/moves_block_test.dart`). Run `bash -n tool/coach_nightly.sh`. Dry-run `dart run tool/missed_work.dart` against live tabs and paste its output into the report.
- [ ] Commit ledger (`feat(nightly): missed-work list + moves proposal`) and fitness (`docs(coach): missed-work placement rules`) — push fitness.

---

### Task 9: MCP `moves_this_week`

**Files:** `~/repos/ledger-mcp/src/tools.ts`, `test/coach_context.test.ts`.

- [ ] `readMovesThisWeek` reads the `program_moves` tab (tolerant of missing tab → null), keeps latest per (from_date|item lower) within the current LA Mon–Sun week, returns `{moves: [{item, from, to, source}], note: 'Program items relocated this week (manual or accepted coach proposal). Missed-work detection runs app-side.'}`; add to get_coach_context after workouts_recent (omit when null); register `program_moves` in VIEWS. Tests; `npm test`; commit; `npx wrangler deploy`; `git push`.

---

### Task 10: Verify, deploy, document

- [ ] Full `flutter test` (7 known failures only), `flutter analyze` (29).
- [ ] `dart run tool/brand.dart --config ~/repos/airledger-fitness/ledger.yaml` (installs if the Pixel is connected; if not, build only and report).
- [ ] CLAUDE.md feature-state bullet "Missed-work carryover + manual moves (2026-10-02)" + remove the Part-2 open follow-up; commit.
