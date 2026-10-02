# Ledger UI redesign — design (2026-10-02, user-approved)

Goal: usability + a clean, consistent, dense aesthetic across the app.
Audit (device screenshots 2026-10-02) found: one-tall-row-per-set
planned work (Sat = 21 rows ≈ 3 screens); raw developer names (Log list
`daily_notes`/`whoop_workouts`/`program_moves`, a "no" icon; form labels
`start_time`/`rpe`/`set_type`/`video_url`; stale Google-Photos helper
text); five-plus text styles/card styles for the same information; model
jargon on Plan (§9.5, sim2, S_obs); bugs: double "Coach" app bar on the
threads screen, Program "Muscle Up Green Band" rendered struck-through,
bodyweight moves priced as a load ("Pull Up 161.5 lb").

## Design system — `lib/ui/design/`

- Type: three roles only — title 16/600, row 14/500 (names), meta 12/400
  muted (sets×reps · load, notes). Section labels 11/600 letter-spaced
  muted.
- Density: list rows ≈44 px, section gap 12 px, side gutter 16 px; one
  card style (surfaceContainer, radius 12, no outline).
- Colour (dark theme kept, one accent = current blue): green done, amber
  partial, red only for real problems; warm-ups and skipped items muted
  grey everywhere.
- Components: `ExerciseRow` (status mark · name · one meta line ·
  optional set chips · trailing ⋮), `SetChip`, `SectionHeader`,
  `StatStrip` (compact label/value pairs), `StatusChip`, `DetailSheet`.
  Every screen uses these; no ad-hoc ListTiles for these patterns.
- Bodyweight movements show "BW" (not a load).

## Screens (phase order)

1. Design system widgets + tokens (no visible change on its own).
2. Log timeline: planned work grouped ONE ROW PER EXERCISE+SLOT
   (warm-ups → one muted collapsible line "warm-up 45·50·70·95";
   top set row; back-off row; accessories), each with set chips
   `[105×6] [105×6] [105×6]` — tap a chip = log that set (existing
   log-now flow), long-press = edit. Group header keeps n/N, Log all,
   delete. Logged rows stay compact one-line.
3. Today: KEEP its sections (user choice) — restyle only: the recovery
   strip as a StatStrip, AI note + macro bars + Trained + Clips +
   Program card in the shared type/density/card style.
4. Week: goal rows in the shared row pattern; per-lift progress as
   compact inline bars instead of wrapping chips.
5. Log list + forms: human names + proper icons (dashboards.yaml labels
   or a name map), uniform row height, entry vs connected sections;
   forms with readable labels ("Start time", "RPE", "Set type",
   "Video"), helper text only where needed, quick-pick chips for RPE and
   set type; update the video helper text.
6. Plan + Program: plain-language summaries; model internals behind one
   "Model details" disclosure; Program keeps its dense per-exercise
   lines (the reference style).
Bug fixes ride along with the phase that owns the screen (coach double
header with phase 5; Muscle Up strikethrough + BW with phase 6/2).

Each phase: widget tests for the new components/rows, analyze baseline
29, full test baseline (7 known), build + install (no launch), user
checks on device.
