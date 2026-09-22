# Sharing `config.yml` across oxy, airlayer, and ledger

**Principle.** Compatibility is maintained through the YAML schema, not
through code dependencies. Each tool parses the same `config.yml` shape —
same `type:` tags, same field names. No tool imports another's Rust/Dart
types.

This document captures the pattern airlayer already uses to stay compatible
with oxy, and prescribes that ledger follow the same pattern as we add
warehouse support beyond Google Sheets.

---

## The pattern, as implemented in airlayer

In `~/repos/airlayer/src/executor/mod.rs` airlayer declares its own
`DatabaseConnection` enum:

```rust
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum DatabaseConnection {
    #[cfg(feature = "exec-postgres")]
    Postgres(PostgresConnection),
    #[cfg(feature = "exec-mysql")]
    Mysql(MySqlConnection),
    #[cfg(feature = "exec-snowflake")]
    Snowflake(SnowflakeConnection),
    #[cfg(feature = "exec-bigquery")]
    Bigquery(BigQueryConnection),
    // ...etc — one variant per warehouse airlayer knows how to execute
}
```

Crucially:

1. **It does not import from oxy.** `airlayer`'s `Cargo.toml` has no
   `oxy = ...` dependency. The enum is independently declared.
2. **It mirrors oxy's serde tags exactly.** `#[serde(tag = "type")]` with
   `rename_all = "lowercase"` (or explicit `#[serde(rename = "...")]` per
   variant) matches oxy's discriminator. A `databases:` entry written for
   oxy parses correctly in airlayer too.
3. **Per-variant struct fields match oxy's fields.** `PostgresConnection`
   has the same `host`, `port`, `dbname`, etc. that oxy's `Postgres` does.
   Where airlayer needs only a subset, it reads only the subset — extra
   oxy-only fields deserialize into `_serde_other` or are ignored via
   `#[serde(default)]`.
4. **Feature-gated implementations.** `exec-postgres`, `exec-snowflake`,
   `exec-bigquery`, etc. let downstream consumers compile only the
   connectors they need. The compatibility schema is decoupled from the
   actual connector code.
5. **The shared artifact is `config.yml`, not a Rust crate.** A customer
   writes one `config.yml`. Oxy reads it for the analyst, airlayer reads
   it for execution, ledger reads it for CRUD. Three independent
   implementations, one contract.

When oxy adds a new warehouse (or a new field on an existing one), the
update propagates to airlayer (and to ledger) through the YAML, not
through a Cargo bump.

---

## Applying the pattern to ledger

Ledger today supports only Google Sheets. To expand to oxy's warehouse
list, the same principle applies: ledger declares a Dart `DatabaseConfig`
discriminated union that mirrors oxy's `DatabaseType`, with the same
discriminator and variant names. Ledger does **not** import oxy or
airlayer at the code level.

### Warehouse list (as of 2026-05-28, from `oxy-internal/crates/core/src/config/model.rs`)

| `type:` value         | Notes |
|-----------------------|-------|
| `bigquery`            | service-account JSON or key path |
| `postgres`            | host/port/user/password/db |
| `redshift`            | postgres-wire-compatible |
| `mysql`               | host/port/user/password/db |
| `snowflake`           | account + auth (key pair / OAuth / password) |
| `clickhouse`          | HTTP interface |
| `duckdb`              | local file or in-memory |
| `motherduck`          | hosted DuckDB |
| `airhouse`            | oxy's postgres-wire on duckdb dialect |
| `airhouse_managed`    | airhouse with oxy-managed credentials |
| `databricks`          | HTTP SQL endpoint |
| `domo`                | HTTP API |

Plus the special case ledger already has:

| `sheets`              | a Google Sheet by spreadsheet id |

`sheets` is not currently in oxy's enum (oxy is read-only / warehouse-side;
Sheets is more of a CRUD substrate). The pattern still applies: ledger
declares it as one variant of the same enum shape, and any tool that
wants to read it can.

### Dart `DatabaseConfig` (proposed shape)

```dart
sealed class DatabaseConfig {
  final String name;
  const DatabaseConfig({required this.name});

  static DatabaseConfig fromYaml(Map<String, dynamic> json) {
    final type = json['type'] as String;
    final name = json['name'] as String;
    return switch (type) {
      'sheets'     => SheetsConfig.fromJson(name, json),
      'bigquery'   => BigQueryConfig.fromJson(name, json),
      'postgres'   => PostgresConfig.fromJson(name, json),
      'snowflake'  => SnowflakeConfig.fromJson(name, json),
      'clickhouse' => ClickHouseConfig.fromJson(name, json),
      // ...etc
      _ => UnsupportedConfig(name: name, type: type, raw: json),
    };
  }
}

class PostgresConfig extends DatabaseConfig { /* host, port, ... */ }
class BigQueryConfig extends DatabaseConfig { /* key_path, project, ... */ }
// ...
class UnsupportedConfig extends DatabaseConfig {
  final String type;
  final Map<String, dynamic> raw;
  // Parses successfully but cannot connect — surfaces a clear "warehouse
  // type X is not supported by this build of ledger" at use time.
}
```

`UnsupportedConfig` is the same trick airlayer uses with feature flags:
the schema parses unconditionally, but only the variants whose connector
is compiled in are usable. This keeps the YAML contract intact even when
a given build can't actually connect.

### Per-view routing

Each `view.yml` already has a `datasource:` field. The contract is:
`datasource:` matches a `name:` in the `databases:` array of the shared
`config.yml`. Ledger looks up the named entry, instantiates the
appropriate `DatabaseConnector`, and runs CRUD through it.

```yaml
# inventory.view.yml
name: inventory
datasource: clickhouse   # → resolves to databases[?(name=clickhouse)]
table: restaurant_analytics___inventory
```

Today, `datasource` is parsed but unused; SheetsRepository is hardcoded.
The first implementation step is making `datasource` actually route.

---

## Repo layout (proposed)

The customer holds one repo per business. Inside, oxy and ledger live as
sibling concerns sharing `config.yml`:

```
~/customer-repos/pokehouse/pokehouse-oxy/
  oxy/
    config.yml          # databases + models — read by oxy + airlayer + ledger
    semantics.yml       # semantic layer (read by oxy + airlayer)
    *.app.yml           # oxy apps (analyst-facing)
    workflows/
  ledger/
    ledger.yaml         # branding (app_name, icon, package_id) — ledger-only
    views/*.view.yml    # CRUD forms (each names a datasource from config.yml)
    templates/*/*.yml   # planned-entry presets
```

`ledger.yaml` does *not* point at the shared config explicitly. The
canonical layout makes pure walk-up sufficient (see below).

```yaml
app_name: "Poke House Inventory"
package_id: com.robertyi.pokehouse
icon: assets/icon.png

# Optional: which database from config.yml to use when a view doesn't
# specify `datasource:`. Today's sheets-only views work unchanged
# (datasource defaults to a baked-in sheets connection).
default_database: clickhouse
```

The `brand.dart` CLI grows a small responsibility: when it syncs assets,
it walks up from `ledger.yaml`'s directory to discover `config.yml`, then
copies it into `assets/config.yml` so the bundled APK has everything it
needs at runtime.

### Config discovery (mirrors airlayer exactly)

Airlayer walks up from `cwd` looking for `config.yml`
(`~/repos/airlayer/src/cli/mod.rs:find_project_root`). One path per
ancestor level, stop at filesystem root.

Ledger uses the **same** logic — single-path walk-up, no extensions.
Implementation at `lib/services/oxy_config_discovery.dart`:

```dart
OxyConfigLocation? findOxyConfig({required String from}) {
  var dir = Directory(p.absolute(from));
  while (true) {
    final candidate = File(p.join(dir.path, 'config.yml'));
    if (candidate.existsSync()) {
      return OxyConfigLocation(configPath: candidate.path, projectRoot: dir.path);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}
```

For this to find the shared config, the canonical layout puts
`config.yml` at the **customer-repo root** (not inside an `oxy/`
subdir). Both `oxy/` and `ledger/` then walk up one level and discover
it.

#### Migrating legacy pokehouse-oxy layout

Today `~/customer-repos/pokehouse/pokehouse-oxy/oxy/config.yml` lives
inside the `oxy/` subdir. One-time move to the canonical location:

```sh
cd ~/customer-repos/pokehouse/pokehouse-oxy
mv oxy/config.yml ./config.yml
```

Oxy keeps working unchanged — it just walks up one more level from
`oxy/` to find the config. No code change required, and ledger can
plug in as a sibling.

### Why monorepo (oxy/ + ledger/ siblings)

- One git history, one PR review, one source of truth.
- Schema changes that affect both (a new column in a clickhouse table that
  shows up in both an oxy semantic measure and a ledger view) land in one
  commit.
- The shared `config.yml` has only one canonical location.
- `ledger.yaml` becomes a small overlay rather than a full configuration.

The alternative — two repos (`pokehouse-oxy/`, `pokehouse-ledger/`) —
requires either path-traversal references or a publish/consume pattern,
both of which add friction for a single-developer setup.

---

## Implementation phases

This doc captures the principle; here's the order to expand ledger
toward full warehouse support.

### Phase 1 — parse the contract  ✅ shipped

- `DatabaseConfig` sealed class
  (`lib/models/database_config.dart`) mirrors oxy's `DatabaseType` tags.
  Variants: `sheets`, `postgres`, `redshift`, `airhouse`,
  `airhouse_managed`, `bigquery`, `snowflake`, `clickhouse`, `mysql`,
  `duckdb`, `motherduck`, `databricks`, `domo`. Unknown `type:` values
  fall into `UnknownConfig` (parses cleanly, throws at use).
- `WarehouseConnector` interface
  (`lib/services/warehouse_connector.dart`) — five methods:
  `ensureTable`, `list`, `create`, `update`, `delete`.
- `SheetsRepository` implements `WarehouseConnector` directly. No other
  concrete connectors yet — every other variant resolves to
  `UnimplementedConnector`, which throws clear errors at use time.
- `ConnectorRegistry`
  (`lib/services/connector_registry.dart`) — given a list of
  `DatabaseConfig`s + the bundled sheets repo, returns the right
  connector for each view's `datasource:`. Bundled sheets is the
  fallback.
- Bootstrap builds the registry; `ensureTable` is called per view at
  startup through the registry.

### Phase 2 — wire config.yml discovery into the build  (next)

- `brand.dart` walks up from `ledger.yaml` to find `config.yml` (via
  `oxy_config_discovery.dart`).
- The discovered `config.yml` is copied into `assets/config.yaml`,
  replacing the legacy single-`spreadsheet_id:` shape.
- `AppConfig` parses `databases:` from the bundled config; the bootstrap
  passes that list into `ConnectorRegistry.build`.
- After this phase, `datasource:` references in `.view.yml` files are
  actually routed.

### Phase 3 — first non-sheets concrete connector

- Postgres first (covers `postgres`, `redshift`, `airhouse` since they
  share the wire protocol). Pure-Dart `postgres ^3.x` package.
- Generic SQL CRUD: `INSERT … VALUES (…) RETURNING *`, `UPDATE … WHERE
  id = ?`, `DELETE … WHERE id = ?`, `SELECT * FROM … [WHERE date = ?]`.
- Validates the abstraction. Likely reveals shape mismatches between
  sheets-style CRUD and SQL-style CRUD (sheets has trailing empty cell
  trimming; SQL is exact-arity).

### Phase 4 — long tail via airlayer FFI

- Snowflake, Databricks, Domo, MotherDuck, etc. don't have great Dart
  clients. Route their CRUD through airlayer (which already has all the
  connector code as Rust crates).
- Adds a write-side to airlayer's FFI (currently read-only). One
  `execute_dml(config, sql)` call that returns affected rows. Ledger
  generates the SQL; airlayer does the connection + transport.
- Mirrors how ledger already uses airlayer for analytics — airlayer
  becomes the universal warehouse client and ledger stays pure Dart.

### Phase 5 — `airhouse_managed` and OAuth

- `airhouse_managed` (per-user credentials managed by oxy) requires a
  ledger ↔ oxy auth dance. Deferred until the rest is settled. Ledger
  starts with explicit credentials in `config.yml` or env-var lookups.

---

## What stays out of scope

Things this principle deliberately does *not* prescribe:

- **No oxy-core as a code dep.** Ledger never imports oxy's Rust types,
  even indirectly through airlayer. The contract is YAML.
- **No oxy server in the loop for CRUD.** Ledger talks to the warehouse
  (possibly via airlayer FFI), not to an oxy backend.
- **No schema generation from oxy.** Ledger's `.view.yml` files are
  authored by hand. We do not auto-generate forms from oxy's semantic
  layer. (We may add a tool that *suggests* a view from a semantic
  entity, but the suggestion is materialized as a hand-edited file.)

---

## Open questions

- **Default warehouse for sheets-only existing setups.** When a view has
  no `datasource:`, what's the right fallback — the bundled sheets
  config, the first entry of `config.yml`, or an explicit
  `default_database:` in `ledger.yaml`? Recommend `default_database:`
  in `ledger.yaml`, falling back to sheets when neither is set.
- **Credential storage on mobile.** `config.yml` may contain service
  account JSON or password references via env vars. On a mobile device
  there are no env vars. Options: (a) keep secrets in `config.yml` and
  rely on Android app-private storage; (b) bake secrets in at build time
  via `brand.dart`; (c) prompt the user once at first launch and store
  in Android Keystore. Lean toward (b) for v1 — secrets land in the APK
  alongside the schemas, no runtime prompts.
- **OAuth flows on mobile.** For warehouses that need OAuth (snowflake,
  databricks SSO), this is the same problem the web target hits.
  Probably needs a v2 pass with `flutter_appauth` or similar.

## File-pairing convention

Ledger uses oxy's basename-pairing convention for sidecar files, with
the same caveat oxy applies: **the basename is a human-readable
convention; `target:` is the authoritative pointer.** Example from oxy
(`pokehouse-oxy/oxy/tests/restaurant_analyst.operations.test.yml`):

```yaml
name: "Restaurant operations"
target: restaurant_analyst.agent.yml   # ← authoritative pointer
```

The filename `restaurant_analyst.operations.test.yml` shares its basename
prefix with `restaurant_analyst.agent.yml`, but tools route via `target:`,
not by filename inspection. Renaming a file doesn't break the link.

Applied to ledger:

```
views/
  strength.view.yml                              # semantic-layer parent
  strength.input.yml                             # input overlay
  strength.cut_deadlift_heavy.template.yml       # template
  strength.cut_squat_heavy.template.yml
  sauces.view.yml
  sauces.input.yml
  sauces.sriracha_aioli.template.yml
```

Each sidecar carries `target: <parent>.view.yml`:

```yaml
# strength.input.yml
target: strength.view.yml
date_field: date
plannable: { log_field: start_time, log_format: time_string }
dimensions: { ... }
```

```yaml
# strength.cut_deadlift_heavy.template.yml
target: strength.view.yml
name: "Cut · Deadlift (heavy)"
variables: [ ... ]
entries: [ ... ]
```

The loader validates that `target:` resolves to a known `.view.yml` and
that the basename pairing matches. If a template's `target:` doesn't
match the view it's being loaded under (e.g. someone copied a file and
forgot to update the field), parsing fails loud.



- **Two-separate-repos.** We do not support `<customer>-oxy/` and
  `<customer>-ledger/` as separate sibling repos with cross-references.
  One customer = one repo. If you have two, merge them (cheap with
  `git subtree`).
- **Config in a `oxy/` subdir.** Mirroring airlayer's discovery means
  config.yml lives at the project root. We don't extend the walk-up to
  also peek into `./oxy/`. Legacy customers with config nested under
  `oxy/` should run the one-line `mv` shown above.
- **Symlinks for sharing.** Workable in principle, but it's load-bearing
  filesystem magic that doesn't survive a fresh git clone cleanly. Better
  to keep config.yml at the canonical location everyone walks up to.

---

## See also

- `~/repos/airlayer/PHILOSOPHY.md` — the parent principle airlayer
  inherited from oxy (semantic layer as contract).
- `~/repos/airlayer/src/executor/mod.rs` — the actual airlayer
  `DatabaseConnection` enum that this doc points to as the reference
  implementation.
- `~/repos/oxy-internal/crates/core/src/config/model.rs` — the canonical
  oxy `DatabaseType` definition.
- This repo's `CLAUDE.md` — the operating guide; links here from the
  "Pointers" section.
