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

## Current feature state (all live on device as of 2026-09-17)

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
- **Coach** (the big feature, v3 architecture):
  - `coach_chat` synced view rendered ONLY as chat: pinned tinted
    Coach row (unread accent via meta `coach_chat_last_read_ts`) +
    `coach_chat_screen.dart`.
  - **Interactive replies: IN-APP via API credits** — CoachBrain on the
    ChatRunner tool loop (streaming Anthropic, max_tokens 4096; context
    = coach/*.md from GitHub (1h cache) + 28-day local ledger dump +
    last 40 thread messages). Tools: list_templates / read_template /
    propose_schedule. Proposals land as `kind=proposal` coach_chat rows
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
    routine: weekly rules ↔ template names (heavy squat/deadlift
    alternation etc.).
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
- **Recomposition year (2026-09-26, program.yaml v8)**: the 2026-27
  year runs the RECOMP variant from Dec 14, not the bulk — maintenance
  food, band 152-162 (hold 158-161, cap 165), rate 0..+0.15 (alarm 0.3
  ×2wk), protein 1.0-1.1 ×4 feedings; blocks/training week/loads
  unchanged; WEIGHT_FLAT retired (flat scale is the plan); bulk
  numbers preserved under `inactive_bulk_variant` + the sim's "Bulk
  plan (inactive)" preset. Source doc:
  airledger-fitness/coach/program-2026-27-source.md. Follow-ups from
  it:
  - User: book a DEXA for the week of Nov 2-8 (at ~157 lb); repeat
    every 16 weeks (late Apr / mid Aug / early Dec 2027).
  - Daily-note gap: the one-line daily note (fingers, elbows, back,
    sleep) is the doc's fifth tracked number and daily_notes is
    still mostly empty — start it during the cut.
  - Waist tracking gap: the recomp fat gauge is a weekly navel-waist
    7-day average and NO data source exists (no view/field). The app
    surfaces "waist gauge: not tracked yet" via program.yaml v8
    gauges + the dashboards recomp comment; needs a waist view or a
    weight-view field, then a real eigenvector.
  - User: confirm hangboard access at Belmont, or get one for home
    (20mm edge, add/remove load) — needed from block 2 (Jan 2027).
  - User: ask Glo to screen shoulders + elbows before block 2 (early
    January).
  - User: decide the outdoor trip or comp that closes block 4
    (June 2027).
