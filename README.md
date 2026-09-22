<p align="center"><img src="assets/readme-banner.png" alt="Airledger"/></p>

# airledger

Schema-driven mobile CRUD app. The **input layer** of the air* stack
(alongside [airlayer](https://github.com/oxy-hq/airlayer) and oxy).
Declare a tracker in YAML, get a working Android app with auto-generated
forms, a date-filtered timeline, and warehouse persistence — no
per-tracker code.

Schemas live alongside an [oxy](https://github.com/oxy-hq/oxy-internal)
project in a customer repo, sharing the same `config.yml` for warehouse
connections. One customer repo, two consumers. See
[`docs/oxy-compatibility.md`](./docs/oxy-compatibility.md) for the
principle.

## What's in the box

### Form & timeline (per view)

- **Auto-generated entry forms** from `view.yml` — text / number / date /
  datetime / dropdown / autocomplete / longtext widgets, plus a
  `now_button` helper for time-of-day fields
- **Date-filtered timeline** with swipe-to-delete, long-press
  multi-select for bulk delete, and a "remove whole group" action on
  template headers
- **Polymorphic records** via `show_when:` — one tab can hold treadmill
  and stairmaster sets, form shows only relevant fields per row's type
- **Plan-then-log workflow**: templates create local-only "planned"
  rows; a single tap stamps the time and commits to the warehouse. The
  logged row stays under its template header so you see your progress
  (`5 / 13`) without losing the session structure
- **Optimistic CRUD** — the UI updates immediately, the network call
  runs in the background, snackbar + re-sync on failure
- **New rows insert at the top** (newest-first) instead of appending

### Templates

- **Jinja-templated presets** with per-template variable caching (set
  your `top_single` once, it pre-fills next session) — registers a
  custom `round` filter so float→int math works around dart jinja
- **Live preview** in the apply dialog — see every rendered entry with
  computed weights before committing
- **Group attribution in the timeline** — rows from the same template
  apply stay clustered under a header; the whole group can be removed
  in one tap
- **Pin** frequently-used templates to the top of the list, per view

### Branding & deployment

- **`tool/brand.dart`** is the build CLI. Reads a per-schemas-repo
  `ledger.yaml` and produces a custom-branded APK — launcher label,
  launcher icon, package id all come from the config. Two schemas
  repos → two side-by-side installs on one phone, one codebase
- **One command, full chain** — patches `strings.xml`, regenerates
  launcher icons via `flutter_launcher_icons`, syncs assets, runs
  `flutter build apk --release`, `adb install`, and `adb shell monkey`
- **Auto-clean only when switching apps** — back-to-back builds against
  the same brand stay fast (~20s incremental); changing `package_id`
  triggers a `flutter clean`
- **In-app AppBar title** reads the OS-level app label via
  `package_info_plus`, so `app_name:` in `ledger.yaml` drives both the
  launcher chip and the in-app header (single source of truth)

### Runtime config

- **In-app Settings** for overriding the bundled spreadsheet id and
  configuring a GitHub repo for live schema refresh
- **Remote schema sync** — pull `.view.yml` and template files from a
  configured GitHub repo into the app's docs cache. Schema-only edits
  land without rebuilding the APK
- **Loaders prefer the cache** — `SchemaLoader` / `TemplateLoader` use
  the synced cache when present, falling back to bundled assets when
  not

### Analytics

- **Local SQLite cache** synced from the warehouse for analytics queries
- **[airlayer](https://github.com/oxy-hq/airlayer) FFI bindings** for
  semantic-layer SQL compilation
- **`fl_chart` line charts** with pan, pinch, and zoom

### Theme

- Dark mode default, palette inspired by oxy / shadcn / Vercel — near-
  black surface, near-white primary for buttons + FAB, brand accent
  reserved for focus rings and selection states. Hairline borders, flat
  surfaces, tightened type scale

## Repo layout (the customer side)

Schemas live inside an oxy customer repo, sharing `config.yml` at the
project root:

```
<customer>-oxy/
  config.yml          <- shared with oxy and airlayer
  oxy/                <- semantic layer, oxy apps, workflows
  ledger/             <- ledger schemas
    ledger.yaml       <- branding (app_name, package_id, icon)
    views/*.view.yml  <- CRUD forms
    templates/*/*.yml <- planned-entry presets
    assets/icon.png   <- launcher icon source (1024×1024)
```

Standalone schemas repos (no oxy sibling) also work — they keep their
own `ledger.yaml` and skip the shared `config.yml`. Useful for personal
trackers without an analytics layer.

## Setup

One-time on a new machine:

1. Install Flutter 3.44+ and the Android SDK.
2. Place a Google Cloud service-account key at
   `~/.config/airledger/service-account.json` (for Sheets-backed views).
   The SA needs `Editor` access on the target workbook.
3. Create `~/.config/airledger/config.yaml` with a default spreadsheet id:
   ```yaml
   spreadsheet_id: <your default spreadsheet id>
   ```
4. Have a customer repo (or standalone schemas repo) with
   `<repo>/ledger.yaml` (or `<repo>/ledger/ledger.yaml`):
   ```yaml
   app_name: "My Tracker"
   package_id: com.you.mytracker
   icon: assets/icon.png         # optional
   adb_device: <serial>          # optional default device
   ```
5. Build + install + launch:
   ```sh
   dart run ~/repos/airledger/tool/brand.dart \
     --config /path/to/ledger.yaml
   ```

## Iterating

After a schema edit:

```sh
dart run ~/repos/airledger/tool/brand.dart --config /path/to/ledger.yaml
```

For schemas-only changes (no APK rebuild needed): configure the GitHub
repo in **Settings → Schemas**, then tap **Refresh schemas**. The app
pulls latest YAMLs into its local cache and reloads on next open.

For a quick standalone build (no branding):

```sh
./tool/sync_assets.sh
flutter build apk --release
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk
adb -s <serial> shell monkey -p com.robertyi.ledger \
  -c android.intent.category.LAUNCHER 1
```

## Helper tools

In `tool/`:

- **brand.dart** — the canonical build CLI. Custom-brands the APK from
  a `ledger.yaml`, then builds + installs + launches.
- **sync_assets.sh** — copies schemas, templates, apps, service-account
  key, and config into `assets/` so they're bundled into the APK. Used
  internally by `brand.dart`; honors `SCHEMAS_SRC` / `TEMPLATES_SRC` /
  `APPS_SRC` env-var overrides.
- **sheets_check.dart** — end-to-end smoke test (ensure-tab → create
  probe → list → delete).
- **check_schema.dart `<path>`** — parse a `.view.yml` and print what the
  parser saw (dimensions, plannable, samples count). Handy for catching
  YAML typos.
- **list_tabs.dart `<spreadsheet_id>`** — list tab names + gids.
- **dump_sheet.dart `<id> <tab> [last_n]`** — dump rows from a sheet.
- **dump_exercises.dart `<id> <tab> <column>`** — distinct values in a
  column, sorted by frequency.
- **consolidate_exercises.dart** — group exercise variants by word-set,
  produce a canonical-name list and a merge map.
- **migrate_{strength,cardio,inventory}.dart `--confirm`** — destructive
  bulk-imports from legacy sources.
- **fix_cell_types.dart `<id> <view> [--confirm]`** — coerces stringy
  numbers / booleans to native cell types (clears the leading-quote
  display in Sheets). Dry-runs by default.
- **reorder_sheet.dart `<id> <tab> [--confirm]`** — sorts rows by date
  desc / time asc. Run on demand; the live app already inserts at the
  top.
- **rebuild_headers.dart `<id> <view> [--confirm]`** — recovery: rewrites
  the header row from the schema and re-aligns data underneath. Use
  after a `values.append` overwrites the header (see CLAUDE.md
  gotcha #9).

## Where things live

```
lib/
  main.dart                 LedgerApp + theme (oxy-inspired dark palette)
  models/
    view_schema.dart        ViewSchema, Dimension, InputSpec, Plannable, ...
    template.dart           Template + TemplateVariable
    planned_entry.dart      Local plan row (pre-log), template-attribution-aware
  services/
    schema_parser.dart      Pure-Dart YAML → ViewSchema
    schema_loader.dart      Loads views (cache > bundled assets)
    sheets_repository.dart  CRUD over Google Sheets (insert-at-top, ...)
    cell_codec.dart         Typed Dart ↔ string for sheet cells
    derive.dart             Runs `derive:` specs (weekday, iso_date, ...)
    log_now.dart            Stamps current time per LogFormat
    template_loader.dart    Loads templates (cache > bundled assets)
    template_interpolator.dart  Jinja2 render with custom `round` filter
    template_vars_cache.dart    shared_preferences-backed last-used values
    plan_store.dart         shared_preferences-backed local PlannedEntry CRUD
    list_display_render.dart    list_display interpolation for tiles + preview
    pinned_templates.dart   shared_preferences-backed pinned-template set
    settings_store.dart     shared_preferences-backed runtime settings
    remote_sync.dart        GitHub Contents API → docs cache for schemas
    oxy_config_discovery.dart   walk-up config.yml discovery (airlayer pattern)
    analytics_engine.dart   airlayer FFI + sqflite for analytics queries
    local_db.dart           sqflite cache synced from the warehouse
  ui/
    home_screen.dart        Lists views, AppBar reads OS app label
    timeline_screen.dart    Merged timeline (logged + planned + template grouping)
    form_screen.dart        Auto-generated form (also Plan mode)
    templates_screen.dart   Pin + apply with live preview
    template_vars_dialog.dart   Per-template input prompt + live preview
    settings_screen.dart    Database + GitHub config
    widgets/field_widgets.dart  buildFieldWidget dispatch
assets/                     auto-populated by tool/sync_assets.sh
docs/
  oxy-compatibility.md      principle for sharing config.yml with oxy / airlayer
tool/                       Dart + bash scripts (see above)
```

## Pointers

- **[CLAUDE.md](./CLAUDE.md)** — operator's guide: architectural notes,
  build loop details, gotchas list (read before non-trivial changes).
- **[docs/oxy-compatibility.md](./docs/oxy-compatibility.md)** —
  multi-tool config sharing principle (oxy / airlayer / ledger).
- **[airlayer](https://github.com/oxy-hq/airlayer)** — the semantic
  engine ledger uses for analytics SQL compilation.
- **[oxy-internal](https://github.com/oxy-hq/oxy-internal)** — the
  upstream semantic layer / analyst tooling whose `config.yml` shape we
  conform to.
