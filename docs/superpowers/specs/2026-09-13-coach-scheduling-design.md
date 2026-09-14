# Coach scheduling — design

2026-09-13. Two-part feature: (A) coach-doc edits in `airledger-fitness`
so the coach plans from what actually happened last week, and (B) the
coach chat gains a propose → confirm → schedule → highlight → undo loop
in the app.

## Problem

The coach gives wrong plans because `routine.md` has no weekday anchors
(nothing says Monday is a press day), no carryover rule (nothing tells
it to check which main lifts were actually completed in the trailing
week and fold skipped ones forward — e.g. OHP skipped Saturday → Monday
should become the combined press day), and the cut/deficit is stated in
`goals.md` but never translated into programming consequences. Beyond
advice, the coach has no way to *act*: `CoachBrain` is a single-shot
text call (512-token cap, no tools), so scheduling a plan means the
user retypes everything into the timeline by hand.

## Part A — coach docs (`~/repos/airledger-fitness/coach/`)

All edits go in `routine.md` (it is injected into both the nightly
briefing and in-app replies, so one edit fixes both surfaces). Three
additions:

1. **Weekday anchor.** New "Weekday anchors" note: Monday = press day
   (bench + rows). Only Monday is anchored; the rest of the week stays
   rule-based.
2. **Carryover rule.** When planning any session, check which main
   lifts (squat, deadlift, bench, OHP) were actually logged in the
   trailing 7 days. A skipped main lift folds into the next compatible
   day — skipped OHP → Monday becomes the combined press day
   (`strength.cut_press_heavy`, bench first), keeping rows if recovery
   allows. Like the parity rule, the coach must state its carryover
   reasoning in one line so mistakes are visible.
3. **Deficit consequences.** Short block making the cut
   programming-relevant: recovery is reduced; when folding a skipped
   lift forward, drop accessories before mains and never stack extra
   volume; maintain loads, no PR chasing; energy/hunger flags in daily
   notes outrank the plan.

No `PROMPT.md` or `goals.md` changes. **Must be pushed** — coach docs
are fetched from GitHub; unpushed edits are invisible to the app.

## Part B — app (`~/repos/ledger`)

### B1. CoachBrain moves to the ChatRunner tool loop

`CoachBrain.reply` stops calling `LlmClient.complete` (single-shot,
max_tokens 512) and drives the existing `ChatRunner` streaming
tool-use loop instead (Anthropic streaming, max_tokens 4096, tools,
self-correcting tool errors). Context assembly is unchanged:
`buildPrompt`'s output (coach docs + 28-day ledger dump + thread
history) becomes the system prompt; the newest user message(s) form
the conversation. The reply bubble appears when the turn completes, as
today — no streaming UI.

Coach toolset (small, YAGNI):

- `list_templates` / `read_template` — the `ChatToolset`
  implementations, extended with a `view` parameter (`strength` or
  `cardio`) since the coach isn't scoped to one view.
- `propose_schedule` — new. **Never writes to PlanStore or the
  ledger.** Input: `view` (strength|cardio), `date` (ISO yyyy-MM-dd),
  optional `template` name, `entries` (array of field→value maps).
  Validates the view exists and every entry's fields against the view
  schema (unknown field or missing required field → error tool_result
  so the model self-corrects). On success its only write is the
  `kind=proposal` chat row (B2) via the normal repository create, and
  it returns "proposal presented to user — they will confirm or
  decline in the UI".

The system prompt's "you cannot act" language is updated: the coach
should propose a concrete schedule via `propose_schedule` when the
user asks to plan something, and must not claim it has scheduled
anything (the user confirms in the UI).

### B2. Proposal persistence

A proposal becomes a normal synced `coach_chat` row:
`role=coach, kind=proposal`, `thread` = current thread, `text` = a
JSON payload (version, view, date, template, entries, plus a short
human summary string). **Deliberately no schema change** — no new
coach_chat column, so no Rust/engine/dylib work.

Device-local state (SharedPreferences, keyed by the proposal row id):
`{status: pending|scheduled|undone|dismissed, localIds: [...]}` —
consistent with planned entries themselves being device-local.
Rendering a `kind=proposal` row whose text fails to parse as the
payload falls back to a plain text bubble.

### B3. Proposal card in the chat

`kind=proposal` rows render as a card inside the coach bubble: date,
view, template name, bulleted entries, `[Schedule] [Not now]`.

- **Schedule** → `PlanStore.addAll` for the entries (with
  `templateName` set so the timeline groups them under a header),
  persist `{scheduled, localIds}`, then push the timeline (B4). Card
  flips to `✓ Scheduled · [Undo]`.
- **Undo** → `PlanStore.remove` each stored localId, status `undone`;
  card shows "Undone" with Schedule available again (re-scheduling
  mints fresh localIds).
- **Not now** → status `dismissed`; card collapses to a quiet
  "Dismissed" state (still re-schedulable).

Buttons are disabled while a write is in flight; PlanStore failures
surface as a snackbar and leave the status unchanged.

### B4. Timeline navigation + highlight

`TimelineScreen` gains two optional params: `initialDate` (seeds
`_selectedDate` instead of today) and `highlightKeys`
(`Set<String>` of planned localIds). Highlighted tiles get an accent
tint/border that fades after a few seconds. The timeline is pushed on
top of the chat route, so the system back gesture returns to the
conversation — no extra UI.

### B5. Plumbing

`CoachChatScreen` gets an `openTimeline(viewName, date, highlightKeys)`
callback constructed by `HomeScreen` (which already builds
TimelineScreens with their full dependency set), so the chat screen
doesn't inherit the timeline's dependencies. CoachBrain additionally
needs the template loader path it already implicitly has via
`TemplateLoader` (asset-based, no new deps) and a `ChatRunner`
(constructed from the same Anthropic `ModelConfig` the chat model
uses).

## Error handling summary

- Tool validation errors → error tool_result, model self-corrects
  within the loop's iteration cap.
- Loop truncation (iteration cap) → surfaced like today's reply
  failure snackbar.
- Malformed proposal payload on render → plain text bubble.
- PlanStore write/remove failure → snackbar, card state unchanged.
- Proposal rows sync to Sheets like any coach_chat row (they're just
  rows with JSON text); single-device usage means no cross-device
  state concerns.

## Testing

- Unit: proposal payload encode/parse round-trip (incl. malformed
  fallback); `propose_schedule` validation (unknown view, unknown
  field, missing required field, happy path); schedule/undo PlanStore
  effects + localId bookkeeping.
- Widget: proposal card renders pending → scheduled → undone; buttons
  disabled mid-flight.
- Existing CoachBrain prompt tests updated for the system-prompt
  change.
- Gates: `flutter analyze` stays at baseline (~32 infos);
  `flutter test` — only the 7 known pre-existing failures.

## Out of scope (YAGNI)

- Coach writing logged rows directly (draft-rows v1 stays removed).
- `run_query`/analytics for the coach.
- Streaming-text chat bubbles.
- Multi-proposal batching; editing a proposal's values in the card
  (decline and ask the coach to revise instead).
- Any coach_chat schema change.

## Deploy notes

- Part A: edit + **push** `airledger-fitness` (SchemaSync/doc fetch
  trap).
- Part B: app-only Dart changes — no engine/dylib rebuild needed.
  Build + install via `dart run tool/brand.dart --config
  ~/repos/airledger-fitness/ledger.yaml`.
