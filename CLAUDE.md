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
— syncs schemas→assets, builds, installs, launches. Manual:
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
   .../jniLibs/arm64-v8a/libairledger_engine.so | grep <new_key>`.
2. **Push airledger-fitness after schema edits** — SchemaSync pulls
   `views/` from GitHub every ~5 min and PREFERS the synced copy; an
   unpushed edit gets reverted on device.

Schema additions go in BOTH places: Rust (`src/schema/`, `src/parse/`,
round-trip tests) and Dart mirrors (`lib/models/view_schema.dart`,
`lib/services/input_parser.dart`, `lib/services/engine_schema_adapter.dart`).

## Current feature state (all live on device as of 2026-09-13)

- **Sync/store**: engine SQLite is source of truth; Sheets is the
  mirror. Ingest primitive: match-by-date, owned vs fill-if-blank
  (fill-if-blank SELF-CORRECTS the source's own unedited values via
  provenance — 2026-09-13), provenance merge on update, deleted_dates
  unwind. Main workbook 1C1rS…; cardio tab is literally named `4x4`.
- **Withings → weight**: OAuth in-app WebView only (Custom Tabs break
  custom-scheme redirects). Reconcile re-ingests window values +
  day-set deletions. Known data issue: user should run one Full
  reconcile to fix a ghost 20.9 lb entry (2026-08-29).
- **Whoop live HR**: BLE Heart Rate Broadcast (0x180D) →
  `HeartRateService` → timer widget: live BPM badge, auto-stamps
  zone4/zone5 at ladders' `hr_pct` % of meta `user_max_hr`, writes
  max_hr on Stop, wakelock. Pairing card on Integrations; max HR
  editable via card menu + tapping the BPM chip. Whoop API (for real
  max HR / recovery) would need user-created dev-app OAuth creds.
- **Coach** (the big feature, v3 architecture):
  - `coach_chat` synced view rendered ONLY as chat: pinned tinted
    Coach row (unread accent via meta `coach_chat_last_read_ts`) +
    `coach_chat_screen.dart`.
  - **Interactive replies: IN-APP via API credits** —
    `lib/services/coach_brain.dart` (LlmClient `sonnet` from
    assets/config.yaml; context = coach/*.md from GitHub (1h cache) +
    28-day local ledger dump + last 40 chat messages). Note:
    LlmClient hardcodes max_tokens 512.
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
- **Plan-then-log**: PlanStore (device-local) planned entries; one-tap
  Log-now stamps at press time; template group headers have "Log all".
  The coach does NOT write rows (v1 draft-rows pattern was removed).
- **daily_notes** view: free-form journal, one row/day by convention.
- **Form UX**: required-field misses show floating red snackbar +
  field highlights (fixed snackbars hide behind the keyboard); cardio
  `type` renders first.

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

## Open follow-ups

- User: run Withings Full reconcile once (ghost 20.9 fix lands then).
- coach_apply-style row-writing exists only in git history (removed);
  "stage it from chat" could return as a CoachBrain tool.
- Timer "Connect HR" chip doesn't request BT permissions itself (pair
  via Integrations card first); HR reconnect loop has no cancel UI;
  fullscreen timer swallows auto-stamp snackbars.
- Whoop API integration (needs user dev-app registration).
- Macrofactor via Health Connect → meals: still queued.
- MCP worker's workers.dev subdomain is `airledger-mcp` (account-wide,
  cosmetic; renameable in CF dash but changes the connector URL).
