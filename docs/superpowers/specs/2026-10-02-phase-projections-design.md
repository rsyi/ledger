# Phase projections — frozen at phase start, tracked against (2026-10-02)

Status: user-approved direction. Builds on the Progress IA merge (Weight /
Strength / Lift pages) — implement after it lands.

## Problem

The forecast tab is recomputed nightly (replace-all) with guarded
auto-recalibration, so there is never a fixed line to judge yourself
against. User: "Projections should happen at the start of a fixed phase
(though we should keep historical projections and my performance relative
to them), and show the projection as well as how I'm tracking relative to
it." Applies to all projections: bodyweight, body fat / body comp,
strength total, per-lift e1RM, VO2 max, climbing.

## Decisions

- A **phase** = a program.yaml block (cut, reverse, climbing, lifting…).
- At a block's first nightly run, the nightly writer
  (tool/program_status_update.dart, same pipeline as the forecast) freezes
  a **projection snapshot** for that block: weekly projected path +
  expectation band for each metric from block start to block end, plus
  the inputs used (TMs, intake/maintenance, fitted/recalibrated params,
  program version, model version).
- Snapshots are **append-only** in a new sheet tab `projection_snapshots`
  (one row per block × metric × week; columns: block, metric, week_start,
  projected, band_lo, band_hi, made_at, program_version, inputs_json on the
  week-0 row). NEVER rewritten; a re-snapshot (e.g. program version change
  mid-block) appends a new `made_at` set and the UI uses the block's FIRST
  snapshot unless the user explicitly re-baselines (out of scope v1).
- **Backfill** block 0 (cut, started 2026-09-21) by replaying the model
  from 2026-09-21 with only the data available then (forecast_calibration
  already replays from past anchors).
- UI shows the **frozen phase projection only** (band + projected line)
  with actuals overlaid; the nightly-recalibrated end-of-horizon outlook
  ("Squat 404 by Dec '28", P(V8)…) moves into Model details (user
  choice).
- **Tracking** per metric: actual (7-day avg for bodyweight; latest e1RM /
  totals; latest DEXA/scale BF) vs the projection at that date → "0.4 lb
  ahead of projection", "−12 lb vs projection (within range)"; status chip
  on track (inside band) / ahead / behind (outside band, direction-aware
  per metric — losing faster than projected on a cut = "ahead" for
  bodyweight but may be "behind" for strength).
- **History**: Progress Phase timeline rows for past blocks open that
  block's projection-vs-actual chart + a one-line result ("Cut: 163 → 155.8
  vs projected 154; strength −1.5% vs projected −3%").
- Coach/MCP: get_coach_context gains `phase_tracking` (per metric: actual,
  projected, delta, status) from the snapshot tab + live actuals.

## Testing

Pure: snapshot builder (from a sim run), tracking deltas/status per
metric incl. direction semantics, first-snapshot selection, backfill
replay anchoring. Nightly: snapshot written once per block (idempotent),
never rewritten. Widget: Weight/Strength/Lift charts render band + actuals
+ tracking chip; past-phase view. MCP twin test for phase_tracking.
