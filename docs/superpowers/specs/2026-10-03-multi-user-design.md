# Multi-user Ledger — design (2026-10-03)

Goal (user): "I want other people to be able to use this app so make it
modular enough that the program is codified in the github repo, and within
the app you can authenticate against a github repo to add the
configuration (or add the ability to save the configuration within google
drive)."

Audience (user-chosen): a few friends, sideloaded APK → Google OAuth stays
in TESTING mode (≤100 test users, no verification). Defaults chosen by
Claude (user said "continue"): GitHub config first, Drive second behind the
same interface; coach = in-app with the user's own Anthropic key; data =
the user's own Google Sheet via their Google sign-in. The owner's
(Robert's) build keeps baked-in config and works unchanged.

## Today (what's hard-wired)

brand.dart bakes ledger.yaml/config.yml + .env secrets (service-account
JSON, GitHub token, Anthropic key, spreadsheet id, integration client ids)
into the APK. SchemaSync / ProgramProvider / DomainConfigProvider / coach
docs fetch from a fixed GitHub repo with a baked token. The Rust engine
syncs Sheets with the service account. Nightly coach (launchd on the Mac)
and the MCP worker are single-tenant.

## Sub-projects (build in order)

1. **Config source abstraction** — `ConfigSource` (list/read/write files,
   identity, display name) with `GitHubConfigSource` (OAuth device flow or
   fine-grained PAT entry; repo + branch + path picker; token in secure
   storage) and later `DriveConfigSource`. Every config reader (SchemaSync,
   ProgramProvider fetcher, DomainConfigProvider, coach docs, app_settings
   default) goes through the active source. Baked GitHub config = a
   preconfigured source (owner build).
2. **Per-user Google identity for data** — Google sign-in (Sheets +
   drive.file scopes) replaces the service account for users without a
   baked key: Dart Sheets paths (WmStore, ForecastMetaStore, readOnly repo,
   app_settings, projection store…) take an auth-client provider; the Rust
   engine gains bearer-token auth (refreshing token passed in from Dart via
   FFI) — engine change ⇒ dylib rebuild (CLAUDE.md trap #1). "Create my
   spreadsheet" creates a workbook in the user's Drive and records its id
   in settings; existing id can be pasted/picked.
3. **Template config** — a public template repo (e.g. rsyi/ledger-template)
   derived from airledger-fitness with personal data removed: generic views
   (strength, cardio, weight, meals, daily_notes, calisthenics, recovery,
   whoop_workouts, program_moves), a starter program.yaml (generic 4-day
   template with the same schema), phase.yaml, dashboards.yaml, coach
   prompts, README explaining how to edit. Drive source seeds a folder from
   the same template (bundled in the APK as a fallback).
4. **Onboarding + Settings** — first launch without baked config:
   welcome → Google sign-in → choose config source (GitHub: sign in + pick
   repo or "use the template"; Drive: create Ledger folder from template)
   → spreadsheet (create/pick) → optional: Anthropic key, integrations.
   Settings screen gains Account, Config source, Spreadsheet, Coach key,
   Week start (exists), Integrations (exists). Secrets in secure storage.
5. **Per-user integrations + coach** — integrations read client ids from
   config/settings, not .env; Whoop/Withings need the user's own developer
   app credentials OR the owner's client id with the friend added as a
   test user (document both); Kaya/Gmail via the same Google sign-in.
   Coach features gated on a key being present. Nightly briefing + MCP:
   documented "advanced: self-host" (out of scope).
6. **Drive config source** — `DriveConfigSource` over drive.file
   (app-created folder), same interface; config edits from the app write
   back (append-only program versions still apply).

Each sub-project: spec section above → plan → TDD implementation → owner
build regression check (Robert's baked config path must keep working).
