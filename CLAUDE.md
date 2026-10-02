# CLAUDE.md — Ledger

Operating guide + full context handoff (2026-09-13). Read this end-to-end
before non-trivial changes; it supersedes all older versions of this file.

## What Ledger is

Local-first, schema-driven personal tracker (Flutter, Android-only) with
an AI coach. Trackers are YAML views; rows live in a local SQLite ledger
owned by a Rust engine and sync bidirectionally to Google Sheets
(app-wins). The launcher app is **"Ledger"**, package
`com.robertyi.fitness` (NEVER change the package id — it orphans
on-device data). Device: Pixel 11 Pro, serial `66260DLKX00010`.

## Design principle: output metrics >> input metrics (2026-09-22)

User-declared, governs all future surface design. What matters is
OUTCOMES (bodyweight trajectory vs target, Wilks preserved through a
cut, e1RM trend), not activity (workouts done, sets logged, streaks).
The homepage exists to answer "is it working?", never "did I do
stuff?". Raw input tallies are vanity metrics; do not promote them.

Input metrics earn a surface ONLY when they are the ROTATED,
eigenvector inputs — the few causal drivers that actually produce the
outcome — and each must be tied to the outcome it drives. Examples:
"each muscle group hit 2x/week" is a legitimate eigenvector input
(it drives steady progress); "sets_total this week" is not. The
current per-lift day targets (bench_days 2, squat_days 2...) are
frequency eigenvectors for the big lifts; a generalized muscle-group
coverage metric would be the same idea extended. When adding any new
metric, ask: is this an output, or a causal input with a named
outcome? If neither, it doesn't ship.

## Repo map

```
~/repos/ledger              THIS repo — the Flutter app (GitHub rsyi/ledger,
                            formerly oxy-hq/airledger-archive; old links redirect)
~/repos/airledger           Rust engine: schema parser, eval, local store,
                            sync, ingest, FFI + sdk-dart (GitHub oxy-hq/airledger)
~/repos/airledger-fitness   LIVE schemas (views/*.view.yml + *.input.yml +
                            templates) + coach/ context docs + ledger.yaml
                            branding (GitHub rsyi/airledger-fitness)
~/repos/ledger-mcp          Remote MCP server, Cloudflare Worker `ledger-mcp`
                            (GitHub rsyi/ledger-mcp)
~/.config/airledger/        service-account.json, config.yaml, mcp_token,
                            coach/logs/   (secrets, not in git)
~/repos/ledger-schemas      STALE predecessor — never edit
```

Engine-side docs (architecture, store/ingest/provenance, integration
patterns, design specs + plans): `~/repos/airledger/CLAUDE.md` → docs/.

## Build + deploy loop

```sh
dart run tool/brand.dart --config ~/repos/airledger-fitness/ledger.yaml
```
— syncs schemas→assets, builds, installs, launches. Note: brand.dart
applies ledger.yaml's app_name transiently and reverts strings.xml
after building; the repo default in strings.xml is also "Ledger" now,
so plain `flutter build apk` carries the right label too. Manual:
`flutter analyze` (baseline ~32 infos, all pre-existing) →
`flutter build apk --release` → `adb -s 66260DLKX00010 install -r
build/app/outputs/flutter-apk/app-release.apk`. `flutter test`: 7 known
pre-existing failures (3 live-DB integration suites + 4 schema_loader);
anything else is a regression.

## THE TWO TRAPS (each has silently broken a deploy)

1. **Engine changes need a dylib rebuild**: `cd ~/repos/airledger/sdk-dart
   && ./scripts/build-android.sh`, then rebuild the APK. The app parses
   schemas THROUGH the bundled dylib (`useEngine = true`); a stale .so
   silently drops new schema keys. Sanity: `strings
   ~/repos/airledger/sdk-dart/build/jniLibs/arm64-v8a/
   libairledger_engine.so | grep <new_key>` — that path is what
   gradle bundles (jniLibs.srcDirs); the copies under this repo's
   build/ are stale intermediates and check the WRONG file.
2. **Push airledger-fitness after schema edits** — SchemaSync pulls
   `views/` from GitHub every ~5 min and PREFERS the synced copy; an
   unpushed edit gets reverted on device.

Schema additions go in BOTH places: Rust (`src/schema/`, `src/parse/`,
round-trip tests) and Dart mirrors (`lib/models/view_schema.dart`,
`lib/services/input_parser.dart`, `lib/services/engine_schema_adapter.dart`).

## Current feature state (all live on device as of 2026-09-28)

- **Progress/Goals bottom-nav split (2026-09-29)**: the output-over-input
  principle made literal (user directive). The old combined Home tab
  divided into TWO tabs; the shell is now 5-tab: **Progress · Goals ·
  Log · Coach · Plan** (home_screen.dart, `_tab` 0-4; openProgram → Plan
  index 4, coach preview → Coach index 3). PROGRESS (outputs only) =
  HomeDashboard in the new `progressOnly` mode — the PHASE hero (weight
  trajectory + body verdict) + the STRENGTH card + the Coach preview row
  (cross-cutting, kept on top); the THIS WEEK input strip is DROPPED
  there. GOALS (input eigenvectors) = `goals_screen.dart` +
  `goals_service.dart` (pure, 24 tests): the phase's input goals as
  plain-language met/partial/unmet rows over the current accounting week,
  DECLARED in `app/dashboards.yaml` `phases:`→`<phase>:`→`goals:` (same
  engine-free contract as the hero eigenvectors + weekly drivers;
  phase-selected via effectivePhaseKey — cut vs recomp differ). Goal ids:
  `macros` (protein g/lb or absolute grams + carbs floor), `calorie_band`
  (cut→deficit / bulk|recomp→surplus band, maintenance from
  nutrition_model's adaptive estimate), `hard_sets` (per main lift, sets
  RPE 8-9 this week toward ~10 — the hypertrophy landmark — + per-lift
  accessory-completion check, accessories declared from the routine),
  `climbing` (2/wk), `cardio_4x4` (1/wk). Both tabs keep pull-to-refresh
  (own GlobalKeys). Absent/malformed `goals:` → screen placeholder,
  never crashes. Current phase = cut, so the cut goal set is live; the
  recomp set flips the calorie band to surplus + protein to absolute
  160-175 from Dec 14. The retired driver-strip content (week_drivers)
  stays used only in HomeDashboard's non-progressOnly path (no live
  caller now — kept for back-compat + the recomp one-screen section).
- **Sync/store**: engine SQLite is source of truth; Sheets is the
  mirror. Ingest primitive: match-by-date OR match-by-dimension
  (`match_field` + `deleted_ids`, 2026-09-16 — row-grained sources
  like Kaya ascents; unknown match_field errors loudly), owned vs
  fill-if-blank (fill-if-blank SELF-CORRECTS the source's own
  unedited values via provenance — 2026-09-13), provenance merge on
  update, deleted_dates unwind. Main workbook 1C1rS…; cardio tab is
  literally named `4x4`. SchemaSync refresh is atomic + coalesced;
  the home poller tracks applied-vs-cached signatures separately
  (2026-09-16 — trackers used to vanish until a manual sync).
- **Kaya → climbing** (2026-09-17): per-ascent rows via Kaya's
  UNOFFICIAL GraphQL API (email/password login in-app; tokens in
  secure storage; browser-spoofed Origin/Referer required). Every
  pull walks the FULL logbook (ascents + sessions for outdoor
  destinations; no cursor — API sort order unverified, upserts by
  kaya_id are idempotent) then reconciles by raw-id diff. Deletion
  safety is triple-guarded: GraphQL shape drift throws (missing/null
  data field), fetchedIds come from RAW wire ids (never transform
  output), and an empty fetch against a non-empty baseline refuses
  to diff unless the card's Full reconcile is run. gym/location and
  lead ship explicit {'kind':'null'} so cross-boundary revisions
  clear stale owned values; other fields stay omit-don't-clear.
  Known-ids baseline in meta `integration_kaya_ids`. NOTE: `date`
  trusts the Z-suffixed string's date portion as gym wall-clock —
  verify an evening session lands on the right day; a wrong
  assumption self-corrects on the next walk after a kayaDay fix.
- **Withings → weight**: OAuth in-app WebView only (Custom Tabs break
  custom-scheme redirects). Reconcile re-ingests window values +
  day-set deletions. Known data issue: user should run one Full
  reconcile to fix a ghost 20.9 lb entry (2026-08-29).
- **Macrofactor → meals (2026-09-21, built; needs on-device verify)**:
  Macrofactor has no API — it exports nutrition to Android Health
  Connect; `MacrofactorIntegration` (macrofactor.dart) reads HC
  NUTRITION records through the injectable `HealthConnectGateway`
  seam (real adapter = health_connect_gateway.dart over the `health`
  plugin, PINNED 13.3.1 — 13.3.2's device_info_plus bump conflicts
  with flutter_secure_storage 9.x over win32). Row-grained kaya
  pattern: one meals row per HC record, ingest match_field `hc_id`
  (HC uuid; meals.view.yml gained hc_id/carbs_g/fat_g 2026-09-21 —
  ensure_sheet appends the new tab headers automatically). Owned:
  hc_id/eaten_at/meal_type/calories/protein_g/carbs_g/fat_g; meal +
  notes fill-if-blank (unnamed exports title as "Macrofactor
  <slot>"). First pull 90d (HC caps reads ~30d pre-grant), then
  rolling 14d reconcile; deletion diff uses RAW uuids scoped to the
  window via meta `integration_macrofactor_id_days` (id→day map),
  same wire-drift + mass-delete guards as Kaya. No source-app
  filter. "Connected" = meta flag after the system grant sheet; pull
  degrades to Reconnect if the grant is revoked in HC; disconnect
  does NOT revoke (would drop all HC grants). Android: MainActivity
  is now FlutterFragmentActivity (HC permission contract needs a
  ComponentActivity), READ_NUTRITION + rationale filters +
  activity-alias in the manifest, minSdk floor 26. NOT yet verified
  on device: permission grant + first pull with Macrofactor's HC
  export enabled.
- **Whoop live HR**: BLE Heart Rate Broadcast (0x180D) →
  `HeartRateService` → timer widget: live BPM badge, auto-stamps
  zone4/zone5 at ladders' `hr_pct` % of meta `user_max_hr`, writes
  max_hr on Stop, wakelock. Pairing card on Integrations; max HR
  editable via card menu + tapping the BPM chip. Whoop API (for real
  max HR / recovery) would need user-created dev-app OAuth creds.
- **Coach intent layers (v4, 2026-09-20)**: three layers per
  docs (airledger) specs/2026-09-20-coach-intent-layers-spec.md.
  INTENT: versioned coach/{program,phase,strategy}.yaml in
  airledger-fitness (append-only versions; current = last non-pending;
  strategy.yaml pending user seed text). routine.md RETIRED.
  OUTCOME: lib/services/program_metrics.dart (§2.5 formulas, §6
  backtest-gated — near_max amended to reps<=8, user-approved;
  tool/coach_backtest.dart re-runs the gate) → nightly
  tool/program_status_update.dart rewrites program_status +
  coach_flags tabs (non-ledger; read-only view in app). Resolvers:
  program_current.dart (Dart) + ledger-mcp src/program.ts (TS),
  cross-checked via coach/fixtures/program_current_cases.yaml — edit
  BOTH when program.yaml shape changes. MCP: get_coach_context v2
  (<2,500 tokens; flags_open = last 2 wks only) + get_program_status.
  Phases C (deviation capture) + D (set_strategy/set_phase pending
  writes) NOT built — see the plan doc.
- **Working-max controller (WM-1+WM-2, 2026-09-21)**: spec = airledger
  docs/superpowers/specs/2026-09-21-working-max-controller-spec.md.
  WM-1: lib/services/working_max.dart (pure) — §1.3 chart, §1.4
  variants, reading extraction, evaluate(), replayLift, §4
  buildPrescription; policies/chart/variants DECLARED in program.yaml
  v5 (pinned by test); §7.1 replay tool/wm_replay.dart. WM-2:
  wm_tabs.dart (pure codecs/state/runWmChain) + APPEND-ONLY sheet tabs
  `working_max` (lift, variant, value_lb, effective_from, source,
  reason, reading_id, confirmed) + `readings` (id=date|lift, …,
  decision, wm_after) written by nightly program_status_update.dart
  (seeds §5 when empty: confirmed=false pending + deadlift pain_cap
  marker; pain-cap state = explicit marker rows, cleared by a
  "pain cap lifted" reason row). NEVER rewrite those tabs.
  program_status gained working_max_<lift> + wm_decisions columns.
  App: wm_store.dart (direct Sheets, 3-min cache; confirmSeed appends
  a confirmed duplicate — append-only-honest; setWorkingMax appends
  source=manual) → planner v3 (weights = wm × chart[policy target]
  [reps], stamp plan_v3, reference-e1rm fallback), Week Plan §4
  prescription blocks on heavy days, Integrations "Working maxes"
  card. DELIBERATE: TWO_SIGNALS→freeze implemented in evaluate() but
  NOT wired from coach_flags (volume flags are bulk-calibrated and
  fire every block-0 cut week — would freeze all lifts vs §3); app
  on-log evaluation + MCP/TS twin = WM-3.
- **Post-cut FINAL spec (program.yaml v10, 2026-09-27)**: integrates the
  user's FINAL `coach/post-cut-final-spec.md` (canonical; supersedes
  post-cut-recomp-spec.md where they differ). On top of v9: STRENGTH
  WAVE — repeating 4-week 5/3/1/deload per lift @ RPE 7-8, anchored to
  BLOCK START so block week 4 (light) IS the wave deload and week 8
  (test) is the second deload carrying the block-result single; block 1
  (3 wk) runs 5/3/1 with no deload. Encoded as `strength_wave`; planned
  top rows carry `reps: top`, resolved by program_current.dart's
  strengthWaveTopReps (light→5 @ RPE-6 cap, test→1); readings still
  evaluate through the UNCHANGED load_policies (extraction is
  rep-agnostic). CONCRETE schedule: weekly_template rewritten verbatim
  (backoffs 3-4×5-8, deadlift 2×4-6; RDL/BSS/HLR/rows/laterals/triceps/
  face pulls/ext rot/curls/leg press/leg curl/calf raises) and the
  planner `planned` lists NOW INCLUDE ACCESSORIES (low-end reps, no
  rpe/notes/weight; HSPU/front-lever stay prose — no rep range in the
  spec). Tue = TECHNIQUE climbing (V3-V5) / Fri = LIMIT — v9 had them
  SWAPPED; fixed. `emphasis_volume` (climbing blocks: non-top sets
  ×0.6-0.7, tops preserved), `volume_ramp` (maintenance wk1 ×0.65 /
  wk2 ×0.85, accessories only, anchored 2026-12-14), wave deload ×0.5
  non-top on light/test — all applied by week_planner (plan_v4;
  entries may carry a `top` marker, not persisted). `expectations_1yr`
  (NOT targets) → faint "expectation range, not target" bands on the
  Program forecast (strength/bw/BF, sim2ExpectationsFromProgramDocs →
  ForecastInputs.expectations). `plateau_checklist` (7 causes before
  +100 kcal) in weight_rules/stall_rule. exercise_muscle_map extended
  with the new accessories (Hack Squat, Leg Curl, Calf Raise, Triceps
  Extension, Cable External Rotation, EZ-Bar Preacher/Strict Wall
  curls, dumbbell curls/rows, Back to Wall Handstand Pushup, Lateral
  Cable Raise — best-judgment credits, user review wanted). WM §4
  prescriptions are wave-aware (buildPrescription topReps; week-plan Rx
  shows "Top set (wave)" + planned-row backoffs). Sim2 v10 dials:
  N stays 4 (wave ≈ same heavy count); W recounted from the concrete
  schedule 57 lifting / 38 climbing / 50 reverse (v9 estimated 30 —
  CAVEAT: b fitted around W≈20, extrapolation), every post-cut block
  kLim=1 (Fri limit year-round; bulk preset pins its own kLim) →
  baseline 999 det / 59 over-budget (L 7.4 vs cap 7.0 on normal lifting
  weeks — the plan's honest red flag) / MC 997, P(V8) 0.79; bulk preset
  still pins 1023/1022/0.45, recomp gap ≈25 lb. Resolver slice shape
  UNCHANGED (ledger-mcp needed only test-pin updates, no deploy);
  shared fixtures pin v10 + the Tue/Fri swap.
- **v12: guarded implied-max TM + routine unification + tab split
  (2026-09-28, user-directed, LIVE — app installed, fitness pushed, MCP
  deployed)**: program.yaml v12 supersedes the band-rule WM controller
  and the two-template shape.
  - TM RULE: `tm_rule: guarded_implied_max` — after every evaluable
    top-set reading, TM = round5(weight/chart[rpe][reps]); raises
    capped +5/session, drops in FULL. Guards (all YAML-editable):
    `min_top_fraction` 0.78 (readings under 78% of TM — the %TM volume
    slots — are recorded, never evaluated: without it Wed squat
    3x8@65% would crater the TM weekly), grinder/missed always drop
    >= `min_drop_lb_on_grinder` 5 (in full when implied is lower —
    a ground PR still drops), light + cut-wave-DELOAD readings ignored
    (weekTypeOf returns 'deload' → kind 'deload'), pain caps freeze
    (clean = rpe < `clean_rpe_lt` 9). DELIBERATE: the test single is
    just a reading now (implied /0.922 IS the old reset, but the raise
    cap applies — TM converges +5/session, no jump); cut_late/reverse/
    test_week are UNFROZEN (caps kept, TM tracks everywhere); v12
    load_policies keep ONLY applies/target_rpe/cap_rpe/
    cap_after_drop_rpe/consecutive_drops_action/frozen(light)/
    readings_ignored — every band key is gone. Legacy band path stays
    in evaluate() for tmRule==null (pinned against the v11 history
    entry in tests). Shared fixtures REGENERATED from Dart (27 cases);
    both twins green. Nightly + wm_replay + MCP log_rows all pass
    tmRuleOf(version).
  - ACCESSORIES: RPE-nudged double progression
    (lib/services/accessory_progression.dart, pure + 16 tests): last
    comparable session → all sets at `reps_hi` at <= 2 RIR (RPE >= 8)
    → +5 lb (2.5 for the declared upper-isolation list); avg RPE > 9 →
    −5% rounded DOWN to step; else hold; no history/bodyweight → no
    weight. Config = v12 `accessory_progression`; planner
    (plan_v6) fills accessory weights from it (suggestions surface in
    planned rows' weight field); accessory rows NEVER get warm-up
    ramps; planned items carry `reps_hi` (never emitted into rows).
  - ROUTINE UNIFICATION: one `routine.week` base (the v11 cut week,
    VERBATIM strings) + `phase_overrides.postcut.week` (the v10
    final-spec week, verbatim; every day differs so all seven are
    replaced) + documentation-only climbing_emphasis/deload entries.
    weekly_template/_block_0 GONE from v12. Resolvers read through
    `routineWeekFor` (program_current.dart + program.ts twins, legacy
    fallback for old docs). EQUIVALENCE PROVEN:
    test/v12_equivalence_test.dart — planner output byte-equal v11↔v12
    across 9 representative weeks on both weight paths, today_template
    strings equal, sim block calendar unchanged (sim2 reads only
    `blocks` — counted W cannot move; dials untouched).
  - TAB SPLIT: nav slot 4 is now **Plan** (plan_screen.dart — phase
    card + block timeline + ONE combined progress chart w/ capacity
    line DEFAULT-ON during cuts + verdict; scenarios/body/climbing/
    VO2/fatigue/params fold behind ExpansionTiles = ForecastSection
    `compact: true`). **Program** (program_screen.dart, REWRITTEN) is
    the ROUTINE surface reached from Plan's app-bar dumbbell action +
    every old week-plan deep link (openWeekPlan alias kept): week-paged
    day cards (AM/PM prose + grouped session rows priced off TM/wave/
    double-progression + wave-state header + §4 Rx blocks with the
    backoff_rule annotation) + the WorkingMaxCard (configuration).
    week_plan_screen.dart DELETED (buildWeekPlan/week_plan.dart service
    survives).
  - MCP: get_coach_context next_prescriptions are WAVE-AWARE now (the
    recorded §4 gap fixed): TS buildPrescription gained topReps/topPct;
    heavyLiftsForDate reads the merged routine. Worker DEPLOYED +
    smoke-tested (serves version 12, wave top 5@260 for Mon squat).
- **v13: two-loop TM + Saturday display fix (2026-09-28, user-directed
  corrections, LIVE — fitness pushed, MCP deployed, tabs recomputed)**:
  - SATURDAY REGRESSION (root cause): the new Program screen displays
    a Monday-anchored week (buildWeekPlan) but buildWeekPlannedEntries
    snapped its 7-day window to the Sat-start ACCOUNTING week
    (`week_start: saturday` → Sat–Fri), so the DISPLAYED Saturday fell
    outside the priced window → zero session lines → daySummary read
    'Rest'. The v12 routine merge itself was correct (routine.week.sat
    has the full OHP day). Fix: `snapToWeekStart: false` param — the
    screen prices exactly the displayed Mon–Sun; PlanStore/rollup
    callers keep the snapped window. test/cut_week_structure_test.dart
    pins ALL SEVEN cut-week days verbatim + both window shapes;
    program_screen_test pins Saturday = full OHP session, one Rest day.
  - TWO-LOOP TM (`tm_rule: median_implied_max`, program.yaml v13 —
    user-specified: history → deterministic TM estimate → %-based
    program → workout → observed RPE → existing small auto-adjust).
    SLOW LOOP: TM = round5(median(implied maxes of qualifying top
    sets)) — day-max per lift, logged RPE, reps ≤ `max_reps` 8,
    variant-converted, ≥ 0.78×TM, non-light/deload — over the last
    `window_days` 21 ANCHORED AT THE NEWEST QUALIFYING SET (not the
    clock: identical history ⇒ identical TM), or the last `min_sets` 5
    sets, whichever holds MORE data. Median not trimmed-mean (at N=5
    they collapse; no trim params); grinder sets INCLUDED as evidence.
    The v12 ±5 raise cap is SUPERSEDED BY DESIGN (outlier-damping
    pinned by test: a +15 lb outlier day moves the TM 0 ≤ 5 lb);
    `raise_cap_lb` stays declared but is guarded-mode-only. FAST LOOP
    unchanged: backoff_rule, grinder/missed immediate drops (≥5, in
    full when implied is lower — and THROUGH manual pins), pain caps,
    sub-top guard, post-drop caps, consecutive-drop rule. MANUAL PIN:
    set_working_max pins until `manual_outvote_sets` 3 qualifying sets
    land after it; the estimator then runs on post-manual sets ONLY
    (overridden history never resurrects). runWmChain gained a NIGHTLY
    RECOMPUTE reconcile: TM converges to the estimate even with no new
    readings (rule changes, edited history, outvoted pins), writes a
    row only on change, idempotent (gate fixed-point ≤3 iterations),
    never raises past a freshest-qualifying grinder. Code:
    working_max.dart slowTmEstimate/qualifyingTmSamples/ManualPin +
    evaluate median branch; wm_tabs runWmChain samples from FULL
    strength history; TS twin working_max.ts + tools.ts log_rows path
    (samples = stored readings tab + the new reading) — fixtures
    REWRITTEN (history/manual_pin case keys, 34 cases, both twins
    green). Planner plan_v7 (regenerate with recomputed TMs); routine
    screen TM rows show source labels (rule → '· auto', manual →
    '· manual'). First live recompute 2026-09-28: press 140→145 (slow
    loop, 5 sets 08-08..09-26 median 145.6); squat 320 confirmed by
    the median; bench 245 + deadlift 340 manual-pinned (0 of 3
    post-manual sets). tool/wm_replay's §7.1 note is mode-aware.
- **Plan-tab forecast rework — SINGLE TRAJECTORY, nutrition is the
  lever (2026-09-28, user directive verbatim: "remove this whole
  lever-based computation… stick with this program long-term… the only
  lever really be based on my caloric intake — carbs, protein, total
  calories (from macrofactor)")**: supersedes the §8 scenario UI (the
  v12 TAB SPLIT bullet's `compact: true` mode is GONE — one layout).
  - REMOVED from forecast_section.dart: preset chips (incl. 'Bulk plan
    (inactive)'), the global dials row (all sliders/chip rows), the
    baseline-vs-scenario compare card, the §5 μ branch toggle (μ runs
    the §5 rule). The §9.5 param sheet STAYS (provenance, not levers;
    still tap-to-edit for inspection). The harness presets/dials
    machinery survives for tools + the sim2_model_test pins.
  - ONE trajectory: declared program calendar + `sim2ExtendSteadyState`
    (flat lifting-emphasis recomp continuation, r=sim2RecompR, 52 wk
    default — deliberately NO auto bulk/cut cycles; v1 sim_core's
    rule-4 cycle machine is retired from the default path).
  - NUTRITION AS INPUT (lib/services/nutrition_model.dart, pure, 15
    tests): meals rows → per-day sums (day "logged" iff ≥800 kcal —
    partial exports excluded; missing days are missing, never zero);
    adaptive maintenance over trailing 28d = mean of implied per-day
    samples m_d = kcal_d − 3500·Δtrend_d (7d-avg weigh-in trend, EXACT
    day pairing — carry-forward would fabricate zero-delta pairs);
    ≥21 pairs → OLS regression with sanity band on β (0.5–2× 1/3500),
    else fixed slope; <5 pairs → null (honest fallback to declared
    rates). Band = 2·SD/√n floored 100. r = (14d intake −
    maintenance)/3500×7; protein g/lb feeds §5 pf(); carbs surface on
    the card (no carb term in the model — documented). Live numbers
    2026-09-28: maintenance ~2430 ± 467 (energy_balance, 18 paired d),
    14d intake 1653 → r −1.55 lb/wk (vs observed −0.8: likely
    under-logging or maintenance overshoot; the recalibration window
    opens ~Nov 2 and will offset it).
  - SCOPING: nutrition r/P override applies to the CURRENT block ONLY
    (new sim2Run/MC `blockOverrides` param) — later blocks run the
    declared calendar ("phase declarations stay"; a global override
    ran the deficit r for the whole 2-yr horizon → bw collapse).
  - THE ONE LEVER: NUTRITION card (top of the section) — 7/14d kcal ·
    P · C averages, maintenance ± band (+ recal offset), implied rate,
    and a ±100 kcal/day what-if stepper (projection only; macros scale
    proportionally — documented approximation).
  - AUTO-RECALIBRATION (lib/services/forecast_calibration.dart, pure,
    14 tests): nightly REPLAY (the forecast tab is replace-all, so no
    stored-prediction diff) — re-run from 6 wk back anchored to
    actuals then, compare weekly predicted bw vs actual 7d-avg (band
    1.25 lb) and predicted INDEX vs observed weekly e1rm totals (band
    25 lb); persistent = last 3 checks all outside band → guardedRefit:
    capacity gains a,b × actual/predicted progression ratio CLAMPED
    0.5–1.5 (the ±50% drift guard; near-flat predicted slope refuses),
    bw rate error → maintenance offset clamped ±500 kcal. NON-cumulative
    (recomputed nightly from fitted). State + event log (last 8) in the
    NEW `forecast_meta` tab (key/value, REPLACE-ALL nightly);
    ForecastMetaStore (direct Sheets, 15-min cache) feeds the Plan tab's
    "model tracking: on / adjusted <date> (<what moved>)" line and the
    app applies the same scales/offset locally so app ≡ nightly.
  - Nightly writer (program_status_update.dart) runs the same pipeline
    (nutrition → replay → refit → sim) and writes `forecast` (same
    headers, now ~114 wks to the extended horizon) + `forecast_meta`.
    MCP get_coach_context forecast block gained `nutrition` sub-block +
    `model_tracking` + the single-trajectory note (worker DEPLOYED).
  - Wiring: plan_screen gained meals repo/view + ForecastMetaStore
    (home_screen passes dashMealsView + a store built beside WmStore).
    Tests: forecast_section_test REWRITTEN (11 — asserts the lever UI
    is GONE), nutrition_model_test 15, forecast_calibration_test 14;
    ledger-mcp +2 (132 total).
- **Recomp TRACKING layer (2026-09-28, coach/recomp-tracking-spec.md —
  canonical, user-authored)**: adherence INPUTS vs generated OUTCOMES.
  SCHEMAS (existing keys only — NO Rust/dylib change; engine's
  additive header merge adds columns, new tabs auto-create): strength
  `set_type` dropdown (warmup/heavy/hypertrophy/skill/rehab, optional,
  autofill:false; RIR = 10 − RPE convention documented on rpe — NO
  second field); NEW `calisthenics` view+input (skill dropdown,
  variation, sets/reps/hold_seconds, assistance, clean switch, rpe;
  skill quality NOT volume; dashboards entry domain, person-standing
  icon); weight `waist_in` (weekly navel); cardio
  `completed_intervals`; daily_notes recovery subjectives
  (sleep_hours/sleep_quality/fatigue/soreness/pain/readiness — §2.4
  amendment noted in the airledger intent-layers spec; pain OUTRANKS
  numbers). WEEKLY REVIEW: lib/services/recomp_review.dart (pure,
  16 tests) — daily nutrition adherence vs targets-IN-FORCE (block-0
  nulls → honest "no target"), set_type-aware productive sets/muscle
  (untagged legacy rows effort-inferred: RPE<6 = warmup, else counted;
  climbing overlap credited), avg RIR, heavy exposures (readings),
  V5+ climbing deriveds, calisthenics bests, 4x4 workload (speed ×
  incline) trend at comparable HR (±5 bpm), recovery aggregates, body
  7d avgs + waist, the 10-question coaching decision + markdown.
  Review weeks are MON-SUN (schedule shape), deliberately NOT the
  Saturday accounting week. tool/program_status_update.dart: Sundays
  (or --weekly) rewrite the `weekly_review` tab (8 weeks,
  newest-first: week_start/week_end/generated_at/markdown);
  --weekly-brief [--week=YYYY-MM-DD] prints one review;
  coach_nightly.sh injects it into SUNDAY briefings. MCP
  `get_weekly_review` (deployed) serves the tab. `nutrition.
  maintenance_kcal` in a future program version feeds Q2 (unset →
  "no data" until block 1 records it). HOME DASHBOARD: in the recomp
  phase the THIS WEEK strip becomes the spec's one-screen rows
  (BODY/NUTRITION/HYPERTROPHY/STRENGTH/SKILLS/CARDIO/RECOVERY, live
  weekly review over local rows incl. the new calisthenics +
  daily_notes sources; placeholders for waist/DEXA/recovery until
  data flows; detail sheet ends on the spec's closing question);
  other phases keep the driver checklist (test-pinned). Hidden until
  the phase flips (cut → effective key stays cut).
- **Sim dial audit + strip clarity (2026-09-29)**: sim2 dials realigned
  to the ACTUAL v13 routine (user: predictions must track the adjusted
  routine, 4x4 never changes) — cut D 4.5→4 (the Thu skill/arms day
  rides Q only; it was half-counted in both dials), reverse-block N
  3→4 (one wave top per lift every week; the RPE-7 cap is intensity,
  not count); Z=1 in EVERY block forever and K=2/kLim=1 (climbing
  blocks 3) verified already right. New §9.3 pins (sim2_model_test):
  det 1006.2 / cap 1023.7 / over 59 / MC 1004 / P(V8) 0.76; cut L 7.4
  vs 6.0, F peaks ~0.77 (was 1.04) so end-of-cut expressed 889 (was
  880); VO2 stays 53.4 — Z=1 holds absolute capacity, the score is
  bodyweight-driven, and the forecast VO2 card now says exactly that
  (workload-at-same-HR gains belong to the weekly review/tracking
  layer, explicitly not claimed by the model). Bulk preset pins
  1031.6/1030/0.39. Nightly forecast tab rewritten; MCP untouched
  (serves the tab). THIS WEEK strip clarity (user: "what's Q, H, C,
  B, S, B, T?"): NO single-letter compressions anywhere — driver
  ticks spell lifts out ("squat ✓ (heavy week)"), the
  hypertrophy_volume pill reads "N of M groups in the 8-12-set range"
  with a per-group under/in range/over list in the detail sheet
  (home_dashboard hypertrophyLines/plainName), heavy-single line and
  recomp rows spelled out (protein/carbs/fat, calisthenics, body
  fat, full lift names); dashboards.yaml labels now "muscle sets" /
  "bench days"; ban-list widget tests pin the cryptic forms out.
- **Cut-training revision (program.yaml v11, 2026-09-28 — user-approved,
  effective now)**: block-0 training REWRITTEN as a hypertrophy-
  maximizing deficit program; cut NUTRITION/WEIGHT targets UNCHANGED
  (protein stays 0.8-1.0 g/lb until Dec 14); v10 post-cut tail copied
  verbatim (Dec 14+ untouched). NEW `strength_wave_cut`: CALENDAR-
  anchored (anchor_monday 2026-09-28, ((weeks since anchor) mod 4)+1 —
  unlike the block-anchored post-cut wave) 4-week wave on ALL FOUR
  lifts — wk1 1x5@0.811 / wk2 1x4@0.837 / wk3 1x3@0.863 (pcts ARE
  chart[8][reps], the approved "81/84/86%") / wk4 deload 1x5@0.70 +
  non-top sets ×0.5 (min 1). TM = live working_max tab, never
  hard-coded; completion never moves the TM. NEW `backoff_rule`
  {target_rpe 8, hold_if_rpe_lte 8, drop_pct [2.5,5], purpose "prevent
  RPE drift, not normal fatigue"}; no AMRAPs. weekly_template_block_0
  rewritten verbatim from the approved schedule: Mon squat-top + BSS +
  bench 4x8@68%TM + laterals + triceps / Tue AM-4x4 + PM HARD climb,
  NO lifting (climb intensity SWAPPED vs old cut AND vs post-cut) /
  Wed bench-top + 3x6-8@72% + squat 3x8@65% + OHP 3x8-10@62% +
  pull-ups / Thu muscle-ups FIRST (skill) + dips + EZ curls (optional
  row/triceps stay prose — planner never plans optionals) / Fri
  DL-top + 2x4-6@75% + RDL 2x8-12 + bench 3x8-10@65% + PM LIGHT climb
  / Sat OHP-top + 3x6-8@72% + row + pull-ups + laterals + face pulls
  + ext rot / Sun rest. planned_alternation RETIRED (every lift tops
  weekly — driver (H)/(L) parity tags disappear). targets_block_0:
  bench_days 3 / squat 2 / press 2 / hypertrophy band [8,12] ACTIVE
  for the cut. All new-template movements already had
  exercise_muscle_map entries (dips = "Parallel Bar Triceps Dip") —
  no new credits. PLANNER plan_v5: planned items may carry `pct`
  (%TM — priced wm × min(pct, chart[policy-target-after-caps][reps]);
  caps (pain / post-drop / cut_late's 7 from Nov 16) always undercut;
  %TM rows NEVER fall back to reference e1rm); block-0 `reps: top` →
  strengthWaveCutFor (program_current.dart, CutWaveWeekSpec); cut
  deload halves non-top sets. Rx: buildPrescription gained `topPct`;
  week-plan blocks show "Top set (wave)" + the backoff_rule drift-
  guard annotation. WM: cut_early/cut_late policies VERBATIM —
  extraction stays rep-agnostic, so %TM volume-day tops (Wed squat,
  Fri bench) also produce readings and an easy pair can raise
  (accepted, documented in v11). DRIVERS (dashboards.yaml cut):
  dual_exposure (hyp_sets_min 2 — deadlift's 2x4-6; hyp_reps [4,12])
  + hypertrophy_volume [8,12] now ACTIVE in the cut; bench_frequency
  3; heavy_single_max_days RETIRED (wave tops are 3-5 reps — the
  ≤2-rep recency line would never refresh). REVIEW: recomp_review
  gained the fatigue-match readout (backoffComplianceOf — per
  day+main-lift consecutive productive pairs; RPE > 8.5 with next
  load held = flagged; missing RPE = unknown; renders in the Strength
  markdown section). SIM: cut dials recounted D 4.5 / N 4 / W 49
  (wave-avg of 55 normal / 30 deload; ext-rot "easy" excluded) — cut
  runs L 7.9 vs deficit cap 6.0, all 11 weeks over budget, F → ~1.0
  by Dec: end-of-cut capacity +6.5 but expressed −10 vs the old cut;
  full-horizon det 1003 (+4.5) / over-budget 59 / MC 1001, P(V8)
  0.73 (was 0.79 — fatigue-driven injury hazard, 2.6→2.9 wk); bulk
  preset shares the cut so its pins moved too (1029/1027/0.38 — no
  longer the original fit-report 1023/1022/0.45). MCP: tools.ts
  heavy-day detection accepts `reps: top` (+ fixed post-cut heavy-day
  map corrected to mon/tue/fri/sat), deployed; resolver slice shape
  unchanged, fixtures pin v11. NOT built (follow-ups): live next-set
  suggester (in-gym RPE-reactive backoff weights), double-progression
  prompts for accessories, wave-aware MCP prescriptions (TS §4 still
  prints 1/2/3-rep chart options).
- **Post-cut recomp program (v9, 2026-09-27, superseded by v10 above)**:
  coach/program.yaml v9
  integrates the user's `coach/post-cut-recomp-spec.md` (user-authored;
  where it conflicts with program-2026-27-source.md THE SPEC WINS).
  Post-cut (Dec 14+, blocks 1-7): NEW weekly template (Mon squat / Tue
  bench+limit-climb / Wed calisthenics / Thu 4x4 / Fri deadlift+
  volume-climb / Sat OHP+bench2 / Sun rest) with `planned` volume work
  the week planner auto-plans (weight_fill gained pct_by_reps[5]=0.80;
  wm path prices 5s off rpe_chart); DUAL exposure per lift — heavy 1-3
  @ RPE 7-8 (load_policies lifting_block retargeted 8.5-9 → 7.5-8,
  raise at ≤7; climbing_block UNFROZEN, raises need 2 consecutive ≤7;
  saturday_single retired) AND hypertrophy 3-8 @ RPE 7-9; FIRST-CLASS
  hypertrophy: `hypertrophy_targets` (8-12 sets/muscle/wk, ~10) +
  `exercise_muscle_map` (per-set fractional credits, prefix-matched
  names, per-climbing-session pulling credit — ALL credits are
  best-judgment defaults the user should review/edit); ABSOLUTE
  nutrition (protein 160-175 g/day, fat floor 55-65, carbs 225-300
  biased to training days); weight goes SOFT — advisory band 154-165 +
  conditioned `weight_rules` (flat scale = SUCCESS, never auto +100;
  154 is NOT the long-term target — glycogen-replete maintenance sits
  higher; maintenance = 7d-avg stable 2-3 wk); DEXA cadence 3-4 mo;
  climbing 2x differentiated (limit vs technique/volume, track V5+
  sends/onsights); calisthenics = skill list. Block-0 cut slice pinned
  IDENTICAL (targets_block_0 nulls the new keys). Resolvers expose
  protein_g_day/fat_g_day_min/carbs_g_day/hypertrophy_sets_per_muscle/
  bodyweight_band_advisory (program_current.dart + ledger-mcp
  program.ts, shared fixtures). Home recomp drivers (week_drivers.dart):
  `dual_exposure` (heavy reading + ≥3 hyp sets per lift) +
  `hypertrophy_volume` (per-muscle weekly sets vs the 8-12 band, over
  = red) + absolute `protein_floor` (floor_g 160) + bike_4x4; recomp
  weight_hold eigenvector softened ([-0.1,0.25], act at ±0.5). Sim2
  v9 baseline N=4/W=30: deterministic 988 / over-budget 38 / MC 986,
  P(V8) 0.80; bulk preset restores the bulk template and still pins
  1023/1022/0.45 (test/sim2_model_test.dart).
- **Video-attach + AI RPE (2026-09-28)**: `widget: video` end-to-end
  (Rust `WidgetType::Video` + all three Dart mirrors, switch precedent;
  dylib rebuilt + strings-checked). strength gained `video_url`
  (widget video, autofill:false — a carried-over video is fabricated
  data) + `video_media_id` (editable:false); sibling-dim CONVENTION
  `<field minus "_url">_media_id` (video_rpe.dart mediaIdFieldFor), no
  new schema key beyond the widget. Attach = Google Photos PICKER API
  (Library API's third-party media access died 2025-03-31; picker is
  the sanctioned path) behind injectable `PhotosPickerGateway`
  (GmailGateway pattern; scope photospicker.mediaitems.readonly ONLY;
  google_sign_in 7.x init shared via google_signin_bootstrap.dart —
  SAME web client id as kaya_gmail): sessions.create → VIEW-intent
  pickerUri → poll until mediaItemsSet (pollingConfig, 5-min cap) →
  first VIDEO of mediaItems.list. Picked items have NO productUrl —
  video_url stores the CONSTRUCTED deep link
  photos.google.com/lr/photo/<persistent-id> (Library-productUrl
  shape; verify it opens on device). RPE estimate fires AT ATTACH TIME
  (the baseUrl dies ~60 min post-pick): `=dv` download → ≤14 evenly
  spaced frames (4% end inset, ≥100 ms spacing) via a dependency-free
  MediaMetadataRetriever channel in MainActivity
  (`com.robertyi.fitness/video_frames`, services/video_frames.dart —
  deliberately NOT the video_thumbnail plugin: same Android API, no
  new version pin) → `LlmClient.completeVision` (Anthropic-only,
  images-then-text, max_tokens 1024; visionModelName() prefers
  `sonnet`) with exercise/load/set-intent + recent same-lift RPE lines
  as calibration → strict-JSON parse (rpe∈[1,10] or honest null;
  garbage throws — never a fabricated number). PROPOSE-ONLY: the chip
  "AI estimate: ~8.5 (8–9) — tap to accept" under the video field is
  the ONLY path into rpe (still user-editable after; nothing flows to
  WM/review until the user saves an rpe). Estimates persist per media
  id (shared_preferences, edit-reopen safe); meta `video_rpe_log`
  (cap 20) records estimate → `final_rpe` at save (accepted vs
  overrode) and renders into CoachBrain's system prompt as a
  calibration section. That meta is DEVICE-LOCAL — the Mac nightly /
  weekly-review tabs do NOT see it (deliberate minimal shape; promote
  to a sheet tab if the coach needs it offline).
- **Coach** (the big feature, v3 architecture):
  - `coach_chat` synced view rendered ONLY as chat: pinned tinted
    Coach row (unread accent via meta `coach_chat_last_read_ts`) +
    `coach_chat_screen.dart`.
  - **Interactive replies: IN-APP via API credits** — CoachBrain on the
    ChatRunner tool loop (streaming Anthropic, max_tokens 4096; context
    = coach/*.md from GitHub (1h cache) + 28-day local ledger dump +
    last 40 thread messages). Tools: read_program_day / propose_schedule
    (TEMPLATE RETIRE 2026-09-30, Phase C — see below). Proposals land as
    `kind=proposal` coach_chat rows
    (JSON in `text`, no schema change); the chat renders a card —
    Schedule writes PlanStore + opens the timeline with the entries
    highlighted (initialDate/highlightKeys params), Undo removes them;
    status + localIds are device-local (`coach_proposal:<rowId>`).
    routine.md carries the Monday press anchor + skipped-lift carryover
    rule + deficit consequences (2026-09-13). Note: LlmClient (post-log
    hooks) still hardcodes max_tokens 512; the coach no longer uses it.
  - **Nightly briefing 23:30**: Mac launchd `com.robertyi.airledger-coach`
    → `tool/coach_nightly.sh` → `claude -p` (user's Max plan) →
    `tool/coach_msg.dart post`. Idempotent per planning target
    (before noon = today, else tomorrow). Logs
    ~/.config/airledger/coach/logs/. The Mac REPLY relay is retired.
  - **MCP server** (`~/repos/ledger-mcp`, worker ledger-mcp): tools
    get_recent_data/get_coach_context/add_daily_note/log_rows/
    post_coach_message for the Claude app via custom connector; URL =
    workers.dev + token at ~/.config/airledger/mcp_token. Deployed +
    verified; user may or may not have added the connector.
  - Coach context docs (Claude-editable): `~/repos/airledger-fitness/
    coach/{goals,routine,metrics,PROMPT}.md` — goals: CUT active;
    routine.md is a DEPRECATED readable fallback (program.yaml `routine:`
    is authoritative; templates retired 2026-09-30).
- **Whoop activity layer (2026-10-01, Part 1; spec/plan in
  docs/superpowers/{specs,plans}/2026-10-01-whoop-activity-layer*)**:
  Whoop is the source of truth that a session HAPPENED (+ strain); Kaya
  enriches climbing with grades when an export lands (~weekly, rate-
  limited); manual logs carry set detail.
  - LOCAL TIME FIX: whoop_api.dart transforms use each record's
    `timezone_offset` (`whoopOffset`/`_wall`) — the raw UTC date put
    evening PT sessions on the next day. Recovery keys on its sleep_id's
    local wake day. Recovery pull now unwinds stale days via
    `deleted_dates` (`whoopStaleDays`, +2-day window margin, pending/
    re-scoring sleeps excluded, empty-fetch guard); workout deletion diff
    got the same +2-day margin (`whoopStaleWorkoutIds`).
  - `lib/services/whoop_activity.dart` = THE classifier (kind climb/run/
    lift/walk/other; stair/machine never climb), `isZone2Run`,
    `isUnlogged` (cardio rows count), `climbDaysUnion` (Kaya day K folds
    into a Whoop climb on K-1 — Kaya export date may be UTC),
    `creditClimbItems`. MIRRORED by ledger-mcp `kindOf` — edit BOTH.
  - Consumers: goals climbing = Whoop ∪ Kaya distinct days; new optional
    `zone2_run` goal (dashboards.yaml, Whoop run ≥20 min, avg HR ≤75% of
    meta user_max_hr) + generic `optional:` → `GoalStatus.optional`
    ("Nice to have", never red); Today program card ticks the climb item
    from Whoop ("strain N.N"); day synthesis ACTIVITY line (cache v4);
    CoachBrain "Activity (Whoop, last 14 days)" section with [unlogged]
    flags; MCP workouts_recent entries carry kind + avg_hr (deployed).
  - program.yaml v15: cut Sunday morning = optional easy zone-2 run prose
    (never planned; Program screen still shows Sunday "Rest" — daySummary
    keys on keywords). daily_notes form hides sleep_hours/sleep_quality/
    readiness (`editable: false`; Whoop owns them; data intact).
  - USER ONE-TIME: Integrations → Whoop (sleep + recovery) ⋮ → Full
    reconcile to re-date existing rows.
- **Template retire — FULL (2026-09-30, Phase C; user-approved)**: the
  workout-template concept is gone everywhere. WHY: program.yaml v12+
  `routine:` (base week + phase_overrides) is the single source of the
  weekly structure — the app resolves it into a "program slice" +
  `buildWeekPlannedEntries`, making the static `views/*.template.yml`
  files (13) redundant and drift-prone.
  - FITNESS: all 13 `views/*.template.yml` DELETED (pushed). PROMPT.md /
    routine.md / README.md rewritten to point at the program slice /
    `routine:` (routine.md kept as a deprecated fallback; template names
    in its body are historical prose only).
  - LEDGER: deleted template_loader.dart, template_interpolator.dart,
    pinned_templates.dart, template_vars_cache.dart, models/template.dart,
    templates_screen.dart, template_vars_dialog.dart. coach_tools.dart
    dropped list_templates/read_template; ADDED `read_program_day` (pulls
    a day's PRESCRIBED rows from the program via buildWeekPlannedEntries —
    CoachBrain builds the resolver from program.yaml; strength-only, no
    WM-tab read so main-lift loads may be absent — the coach fills
    numbers from the ledger dump); propose_schedule now takes `group`
    (legacy `template` key still accepted for the timeline group label —
    proposal→PlanStore→highlight flow UNCHANGED). chat_tools.dart dropped
    list_templates/read_template/apply_template (add_planned_entry stays
    as the template-free stage path). timeline_screen.dart: removed the
    recipe "production strip" + fullscreen recipe screen + the Templates
    app-bar action; the repeat_group BATCH banner (Stop & finish) stays,
    now gated only on `repeatGroup != null`. The planned-group "Log all"
    (WeekPlanner.templateLabel = 'program: week plan') is UNCHANGED — it
    keys on PlannedEntry.templateName (a plain group-label string, never
    coupled to template FILES) so program-planned + coach-proposal groups
    still log-all/delete-all.
  - MCP: no list/read_template TOOLS existed; get_coach_context's `views`
    list was mis-filtering `.template.yml` (would go empty on delete) →
    repointed to `.view.yml` (the real views). coach_nightly.sh /
    coach_relay.sh dropped the `views/*.template.yml` dump (program slice
    covers the day). Tests: coach_tools +4, mcp coach_context/wm_tools
    mocks → `.view.yml`; all green (ledger baseline 27 analyze / 7 known
    failures held; mcp 143/143).
- **App IA redesign P1+P2+P3 — COMPLETE (2026-09-21)**: spec = airledger
  docs/superpowers/specs/2026-09-22-app-ia-redesign-spec.md. Presentation
  config `app/dashboards.yaml` in airledger-fitness (ENGINE-FREE —
  fetched via GitHub, shared 1 h DocCache, pull-to-refresh bust; NO
  dylib/schema-mirror work ever): domains strength/weight/cardio/
  daily_notes (entry) + climbing/meals (integration), each views/icon/
  metrics (+ `list_fields`, `goal_band_per_lb` since P3 — parser skips
  malformed entries, never throws). Home: Ledgers expandable → LOG
  (entry domains + any unclaimed views) and CONNECTED (integration)
  sections; missing/bad config falls back to the old Ledgers tile
  (never breaks). Domain rows open `domain_screen.dart`: dashboard
  header (domain_metrics.dart pure engine — ALL ten built-ins live:
  pl_total / e1rm_reference / all_time_best_weight / bw_series w/ 154
  goal line / bf_series / kcal_series / protein_series (0.8–1.0 g/lb ×
  current 7d-avg bw as a SHADED BAND — meals gets the weight view via
  DomainScreen.weightView passed from home) / grade_pyramid (MetricBars
  horizontal bars, numeric v-grades desc then vIntro/vB tail, routes
  counted in a note) / session_frequency (sessions per ISO week, 12 wks
  zero-filled) / hr_4x4_series (max HR per session day)). These
  dashboards SUPERSEDED the old ".app.yml Apps" paradigm — the home
  Apps tile, apps_screen/app_viewer_screen, AppRuntime/AppLoader/AppDef,
  assets/apps wiring, and airledger-fitness apps/ were all removed
  2026-09-21 (AnalyticsEngine + LocalDb stay — chat run_query + weight
  series use them). Entry domains:
  header over the normal timeline via TimelineScreen's `header` slot.
  Integration domains: `_DomainRecordsScreen` — read-friendly list
  (header scrolls as item 0, date-grouped one-line records via pure
  services/domain_records.dart, newest first, lazy builder for
  climbing's ~1.4k rows); the classic read-only timeline (forceReadOnly)
  stays behind the app-bar calendar icon, headerless there by design.
- **Plan-then-log**: PlanStore (device-local) planned entries; one-tap
  Log-now stamps at press time; template group headers have "Log all".
  The coach does NOT write rows (v1 draft-rows pattern was removed).
- **daily_notes** view: free-form journal, one row/day by convention.
- **Form UX**: required-field misses show floating red snackbar +
  field highlights (fixed snackbars hide behind the keyboard); cardio
  `type` renders first.
- **Switch widget + equipment flags** (2026-09-21): `widget: switch`
  is a tri-state NULLABLE bool end-to-end (Rust `WidgetType::Switch`,
  Dart `WidgetType.switch_`, `_SwitchFieldWidget`). UX contract: null
  renders a dimmed "Not set", toggling sets an explicit true/false, a
  × suffix clears back to blank — blank is NEVER coerced to false.
  boolean dims with no widget now default to switch. strength gained
  boolean dims paused/belted/wrist_wraps/knee_sleeves (sheet columns
  `Paused`/`Belted`/`Wrist Wraps`/`Knee Sleeves`), gated per exercise
  via `show_when: { exercise: { in: [...] } }` (fully supported
  through the engine — no new key was needed): paused = bench+squat;
  belted = squat+deadlift (user never belts bench/ohp — the dim exists
  on every row, the form just hides it there); wrist_wraps =
  bench+OHP+military press; knee_sleeves = squat+dl. All four are
  `autofill: false` (carrying gear flags over would fabricate data).
  WM variant resolution (`parseVariant` named params via
  `StrengthRow.paused/belted`) PREFERS the structured flags over notes
  keywords when non-null (bench paused=false ⇒ touch_and_go); blank
  falls back to legacy notes parsing unchanged. Historical backfill:
  `tool/migrate_equipment.dart` (idempotent, dry-run default,
  --confirm writes the new columns only) applied 2026-09-21 — Belted
  on squat/dl: 130 explicit-true + 75 explicit-false from notes, 669
  inferred-true (day-top set, effort ≥ .93 vs the 42-day reference),
  111 inferred-false (effort ≤ .80 + ≥2 strong days within ±3 wks);
  Paused on bench from notes only (37 true / 16 false); ~5.3k
  candidate rows left honestly blank; wraps/sleeves never backfilled.
  strength exercise options trimmed to a curated ~37 (mains first,
  then live-sheet frequency, recent-year bias).

## Dev gotchas (hard-won)

- `import 'package:jinja/jinja.dart' hide Template;` (name clash);
  jinja 0.6.6 `round`/`int` filters broken — TemplateInterpolator
  registers a custom `round`.
- Sheets: `values.append` at A1 eats the header row if A1 is empty —
  use explicit A2 ranges in tools; API trims trailing empty cells on
  read; `CellCodec.encode` returns Object (nums stay nums; don't
  toString); valueInputOption RAW everywhere.
- Assets (schemas) need full rebuild — hot reload won't pick them up;
  no dart:io File() on asset paths.
- Don't run `flutter create` or `flutter pub upgrade`; don't leave
  debugPrints; scripts in tool/ start with
  `// ignore_for_file: avoid_print` and run via `dart run tool/x.dart`.
- Commits: conventional style, trailer
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; per-task
  commits are the norm in all repos (user approved).
- **Sheets round-trip stability is a sync invariant** (the 2026-09-21
  429 push storm): the engine pushes with USER_ENTERED, so Sheets
  PARSES what we write — ISO-T datetimes become native datetime cells
  and pull back SPACE-separated ("2026-09-16 10:00:00"); numbers
  reshape (Float(26.0) → "26" → Int(26)). Anything decode can't map
  back to the pushed value corrupts the local row via TakeRemote, and
  if an ingest source owns that field it re-dirties + re-pushes every
  cycle → per-row writes → 429 forever. Engine-side guards (2026-09-21):
  parse_datetime accepts space forms, CellValue::equivalent /
  records_equivalent (Int==Float, missing-key==Null) in ingest + merge,
  sync updates batched via values:batchUpdate, 429s retried with
  Retry-After-aware capped backoff. If you add a new dimension TYPE or
  wire format, extend `sync_engine.rs::SheetsFaithfulRemote` and the
  steady-state test FIRST.

## Open follow-ups

- Whoop activity Part 2 (NOT designed yet): missed-exercise detection +
  carryover/rescheduling into the following days; strain-based load
  modulation. Separate spec.
- Video-attach + AI RPE (2026-09-28): USER one-time GCP setup before
  the attach button goes live — console (ryi-data-entry): enable the
  "Google Photos Picker API"; add scope
  photospicker.mediaitems.readonly to the OAuth consent screen (testing
  mode + existing test user suffices); the SAME OAuth clients as
  kaya_gmail work (Android package+SHA-1 + the Web client id in
  config.yml integrations.kaya_gmail.server_client_id) — which is
  ITSELF still pending, so both features light up together. Until
  then the form renders "Attach video" disabled + hint. On-device
  verify wanted: the constructed photos.google.com/lr/photo/<id> link
  opens the right video; first end-to-end estimate quality.

- Cut revision (2026-09-28): NOT built — (1) live next-set suggester
  (in-gym: read the just-logged RPE, propose the next set's load per
  backoff_rule), (2) double-progression prompts (accessory at top of
  range at target RIR → suggest +load next week), (3) wave-aware MCP
  §4 prescriptions (ledger-mcp still prints 1/2/3-rep chart options —
  correct pricing, wrong reps on wave days). The weekly review's
  fatigue-match readout needs RPE logged on back-off sets to say
  anything (missing RPE = unknown). Sim W=49 extrapolates the b-slope
  (fitted ~W≈20) — same caveat as post-cut W=57; watch real block-0
  fatigue (model says F≈1.0 by Dec, all cut weeks over budget).
- Recomp tracking (2026-09-28): user should start TAGGING set_type on
  new strength rows (legacy rows stay effort-inferred), take the first
  weekly waist measurement, and log sleep/fatigue/soreness in daily
  notes — the review says "no data" honestly until then. The
  calisthenics tab auto-creates on the app's first engine sync after
  this install. No DEXA data source yet (dashboard shows "DEXA —" +
  latest scale bf). `nutrition.maintenance_kcal` gets recorded in a
  new program version at the end of block 1 — Q2 of the weekly
  decision is "no data" until then. 4x4 `completed_intervals` is
  session-level by convention (fill on the day's last row).
- Kaya (in-app Gmail flow, 2026-09-21 — supersedes the 2026-09-18
  CLI-only shape): climbing data is STILL never synced into the engine
  ledger; the `kaya_ascents` tab replace-all just moved in-app.
  `KayaGmailIntegration` (integrations/kaya_gmail.dart): Connect =
  Google sign-in (google_sign_in PINNED 7.2.0, Credential Manager era)
  requesting gmail.readonly ONLY, behind the injectable GmailGateway
  seam (D2 pattern); Sync = guided flow — dialog, launch Kaya
  (com.project9a.redpoint via android_intent_plus PINNED 6.1.0 +
  manifest `<queries>`), poll Gmail 20s×15 for an export email
  STRICTLY newer than sync-start (never re-imports yesterday's),
  download/base64url-decode CSV, parse via shared
  services/kaya_csv.dart, replace-all the tab (service-account path);
  card menu "Import latest export" = same import, 7d window, no
  Kaya launch. Meta integration_kaya_gmail_* (imported_at/count/
  msg_ms) drives the "imported <ago>" status. pull() = quiet 6h
  background check for exports newer than the last imported email.
  NOT YET CONFIGURED: needs `integrations.kaya_gmail.server_client_id`
  in the schemas repo config.yml — GCP console (ryi-data-entry):
  enable Gmail API; consent screen (external/testing: add each user
  as test user — gmail.readonly is restricted, unverified apps are
  test-users-only); OAuth client (1) Android: package
  com.robertyi.fitness + SHA-1 (release signs with debug keystore:
  `keytool -list -v -alias androiddebugkey -keystore
  ~/.android/debug.keystore -storepass android | grep SHA1`); OAuth
  client (2) Web application — THAT id is server_client_id (7.x
  Android requires the web id; Play Services finds the Android client
  by package+SHA-1). Until then the card shows the setup hint,
  button-less. `dart run tool/kaya_import.dart <csv> --confirm` still
  works (delegates to kaya_csv.dart). Dormant API-pull KayaIntegration
  (kaya.dart/kaya_api.dart) remains unused.
- **Read-only ledgers** (2026-09-18): input.yml `read_only: true`
  (parsed in Rust `src/schema/{overlay,view}.rs` + `src/parse/` AND
  all three Dart mirrors). Such views render under a "Read-only"
  home section, open a browse-only timeline backed by a DIRECT
  SheetsRepository read (network on open, nothing stored locally),
  and are excluded from ensureTable, SyncScheduler, and the Today
  strip — ensureTable on a foreign tab like kaya_ascents would
  rewrite its headers. Timeline gates every mutation affordance on
  view.readOnly.
- User: run Withings Full reconcile once (ghost 20.9 fix lands then).
- coach_apply-style row-writing exists only in git history (removed);
  "stage it from chat" could return as a CoachBrain tool.
- Timer "Connect HR" chip doesn't request BT permissions itself (pair
  via Integrations card first); HR reconnect loop has no cancel UI;
  fullscreen timer swallows auto-stamp snackbars.
- Whoop API integration (needs user dev-app registration).
- Macrofactor → meals: BUILT (2026-09-21, see feature state). User:
  enable Macrofactor's Health Connect export, tap Connect on the
  Integrations card (system sheet), confirm the first 90-day pull
  lands in meals with sane eaten_at wall-clock times.
- MCP worker's workers.dev subdomain is `ryime` (renamed from
  `airledger-mcp` 2026-09-13; old URLs are dead). Connector URL:
  `https://ledger-mcp.ryime.workers.dev/mcp/<token>`.
- Equipment-flags rollout ordering (2026-09-21): the airledger-fitness
  schema commit (paused/belted/wrist_wraps/knee_sleeves + trimmed
  options) is committed locally but the PUSH is gated on the new APK
  (switch-widget dylib) being installed — trap #2 in reverse: pushing
  first would sync switch-widget schemas into an app whose dylib drops
  the key. PENDING manual steps when the Pixel is next connected
  (the 2026-09-21 wait-for-device watcher was stopped without firing):
  (1) `adb -s 66260DLKX00010 install -r
  ~/repos/ledger/build/app/outputs/flutter-apk/app-release.apk` — the
  APK is already built with the new dylib + schemas (rebuild via
  brand.dart if anything changed since); then (2) `git push` in
  ~/repos/airledger-fitness. The sheet columns + backfilled data are
  ALREADY live (harmless to the old app — unknown columns are
  ignored).
- **Post-cut recomp year (program.yaml v10, 2026-09-27 — supersedes the
  v9/v8 recomp entries)**: the 2026-27 year runs the post-cut recomp
  per the user's `airledger-fitness/coach/post-cut-final-spec.md`
  (FINAL; canonical) from Dec 14 (see feature state). Follow-ups:
  - USER REVIEW WANTED: the `exercise_muscle_map` credits (incl. the
    per-climbing-session pulling credit back 3 / forearms 3 /
    biceps 1.5 / core 1, every per-exercise fraction, and the v10
    additions for the new accessories) are Claude's best-judgment
    defaults — correct them in program.yaml; the hypertrophy counters
    re-read on next sync. The climb-day assignment is now FIXED by the
    final spec (Tue = technique V3-V5, Fri = limit) — no longer
    swap-freely.
  - Wed HSPU + front-lever progressions are deliberately NOT planned
    as rows (the spec gives quality-set counts, no rep range — the
    planner never fabricates); pistol squat 3x3 IS planned. Add rows
    if the user settles rep prescriptions.
  - Sim W=57 is an extrapolation of the b-slope fitted around W≈20,
    and the v10 baseline runs L 7.4 vs cap 7.0 on normal lifting
    weeks (59 over-budget weeks flagged red) — the weekly Fri limit
    session is the tipping term. Watch real fatigue in block 1-2 and
    consider re-fitting once post-cut weeks accumulate.
  - User: book a DEXA for the week of Nov 2-8 (at ~157 lb); repeat
    every 3-4 months per the spec.
  - Daily-note gap: the one-line daily note (fingers, elbows, back,
    sleep) — daily_notes is still mostly empty; start it during the
    cut.
  - Waist tracking gap: the spec's PRIMARY fat gauge is a weekly
    navel-waist 7-day average and NO data source exists (no
    view/field). program.yaml v9 gauges + dashboards still say "not
    tracked yet"; the conditioned weight_rules (allow rise if waist
    stable etc.) can only run on judgment until a waist source lands —
    then wire a real eigenvector.
  - ~~Hypertrophy accessories PROSE-only~~ RESOLVED in v10: the final
    spec prescribes them concretely and the planner plans them
    (accessory rows get no weights — no main-lift reference).
  - meals dashboard `protein_series` still shades goal_band_per_lb
    0.8-1.0 (cut-correct). Post-cut the spec's target is ABSOLUTE
    160-175 g/day — the driver carries it; flip the meals metric to
    an absolute band (or ~1.02-1.11 per-lb) when the cut ends.
  - tool/sim2_horizon.dart CLI still carries the v8 dials (header
    note added); the harness (sim2_harness.dart) is authoritative.
  - User: confirm hangboard access at Belmont, or get one for home
    (20mm edge, add/remove load) — needed from block 2 (Jan 2027).
  - User: ask Glo to screen shoulders + elbows before block 2 (early
    January).
  - User: decide the outdoor trip or comp that closes block 4
    (June 2027).
