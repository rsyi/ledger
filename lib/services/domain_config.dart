/// Domain-dashboard presentation config — the app-IA redesign's declared
/// layer (spec: airledger docs/superpowers/specs/
/// 2026-09-22-app-ia-redesign-spec.md).
///
/// `app/dashboards.yaml` in the schemas repo groups views into DOMAINS,
/// each with a paradigm (`entry` → home LOG section, full timeline;
/// `integration` → CONNECTED section, read-friendly record list with
/// the read-only timeline a calendar-icon away), an icon, a metrics
/// list for the domain screen's Trends mode, an optional `headline`
/// (metric ids for the one-line strip atop the records mode), and
/// optional `list_fields` (the record list's salient columns).
///
/// ENGINE-FREE by design (adaptation decision 1): fetched straight from
/// GitHub through the shared [DocCache] (1 h TTL, pull-to-refresh bust)
/// and parsed here in Dart only — no Rust schema keys, no dylib rebuild,
/// no trap #1. Missing or malformed config MUST degrade to null so the
/// home screen falls back to the flat Ledgers section — a bad push can
/// never break the app.
library;

import 'package:yaml/yaml.dart';

import 'display_names.dart';
import 'doc_cache.dart';

/// Repo path of the presentation config.
const kDashboardsPath = 'app/dashboards.yaml';

/// How a domain behaves in the UI. Unknown paradigm strings parse to
/// [entry] (the safe default — nothing loses affordances by accident;
/// an unrecognized future paradigm still renders usable).
enum DomainParadigm { entry, integration }

/// Metric display kinds from the spec vocabulary. Unknown kinds parse
/// to [stat] — the metric engine keys off [MetricConfig.id] anyway.
enum MetricKind { stat, best, series }

/// One dashboard-header metric declaration.
class MetricConfig {
  /// Built-in id (pl_total, e1rm_reference, recent_e1rm_rpe,
  /// all_time_best_weight, wilks, wilks_series, bw_series, bf_series,
  /// kcal_series, protein_series, grade_pyramid, session_frequency,
  /// hr_4x4_series).
  /// Ids the metric engine doesn't know render as a placeholder, never
  /// an error.
  final String id;
  final MetricKind kind;
  final String? label;
  final String? unit;

  /// Target value (chart target line / stat reference). Null either
  /// means "explicitly no goal" (yaml `goal: null`) or the key was
  /// absent — the UI treats both as "no goal".
  final double? goal;

  /// Human context for the goal when it isn't a bare number.
  final String? goalNote;

  /// Bodyweight-relative goal band (yaml `goal_band_per_lb: [0.8, 1.0]`)
  /// — the metric engine scales it by the current 7-day-avg bodyweight
  /// and the chart shades the range (protein_series). Normalized so
  /// low <= high; null when absent or malformed.
  final ({double low, double high})? goalBandPerLb;

  /// Main-lift filter for per-lift strength metrics.
  final List<String> lifts;

  /// Series window start (yaml `from: "2026-09-21"`): clip the series
  /// to days on/after this date, and — for wilks_series — anchor the
  /// dashed reference line to the metric's value AS OF this date (the
  /// stability target for "hold through the cut"). Null when absent or
  /// unparseable.
  final DateTime? from;

  /// Acceptable-drop floor (yaml `floor_pct: 2.5`), percent BELOW the
  /// `from`-anchored reference: the chart draws a second dashed line at
  /// reference × (1 − floor_pct/100) — the "act if you sink under this"
  /// line (wilks_series during the cut). Null when absent or malformed
  /// (back-compat: older configs simply get no floor line).
  final double? floorPct;

  /// Default plot window in YEARS (yaml `window_years: 4`) — since the
  /// range selectors (2026-09-22) this seeds the chart's DEFAULT range
  /// chip ('4Y') on a full-history monthly series instead of clipping
  /// the computed data; the user can still widen to All. User-tunable
  /// from dashboards.yaml; null / absent / non-positive → default All.
  final int? windowYears;

  const MetricConfig({
    required this.id,
    this.kind = MetricKind.stat,
    this.label,
    this.unit,
    this.goal,
    this.goalNote,
    this.goalBandPerLb,
    this.lifts = const [],
    this.from,
    this.floorPct,
    this.windowYears,
  });
}

/// One entry of a domain's `list_fields:` — a salient column for the
/// read-friendly record list (integration domains). Yaml accepts a bare
/// string (`grade`) or a map (`{ field: calories, unit: kcal }`).
class DomainListField {
  final String field;

  /// Appended after numeric values ("222 kcal").
  final String? unit;

  const DomainListField({required this.field, this.unit});
}

/// One domain: a home row + a domain screen.
class DomainConfig {
  final String name;

  /// Human display name (yaml `label: Daily notes`). Null → the
  /// humanized [name] (see [displayName]).
  final String? label;

  /// Short Log-list subtitle (yaml `description:`). Null → the primary
  /// view's description, cut to its first clause.
  final String? description;
  final DomainParadigm paradigm;

  /// View names — the FIRST backs the domain screen's timeline body.
  final List<String> views;

  /// Lucide icon name (same vocabulary as input.yml icons).
  final String? icon;

  final List<MetricConfig> metrics;

  /// Metric ids for the compact headline strip atop the domain screen's
  /// default (records) mode — yaml `headline: [wilks, pl_total]`. Ids
  /// must reference entries in [metrics]; unknown ids are skipped at
  /// display time. Empty → the UI picks sensible defaults (stat-kind
  /// metrics first). See headlineConfigs in domain_metrics.dart.
  final List<String> headline;

  /// Salient columns for the read-friendly record list. Empty → the UI
  /// falls back to the view's `list_display`.
  final List<DomainListField> listFields;

  const DomainConfig({
    required this.name,
    this.label,
    this.description,
    required this.paradigm,
    required this.views,
    this.icon,
    this.metrics = const [],
    this.headline = const [],
    this.listFields = const [],
  });

  /// What the UI shows: the declared `label`, else `daily_notes` →
  /// "Daily notes".
  String get displayName {
    final l = label?.trim();
    return l == null || l.isEmpty ? viewLabel(name) : l;
  }

  /// The view backing the domain screen's timeline.
  String? get primaryView => views.isEmpty ? null : views.first;
}

/// Parses dashboards.yaml content. Returns null when the document is
/// not parseable as the expected shape (malformed yaml, no `domains:`
/// list) — the caller falls back to the flat Ledgers section. Individual
/// bad entries are SKIPPED, not fatal: one typo'd domain must not take
/// down the rest.
List<DomainConfig>? parseDomainConfigs(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  Object? doc;
  try {
    doc = loadYaml(raw);
  } catch (_) {
    return null;
  }
  if (doc is! Map) return null;
  final domains = doc['domains'];
  if (domains is! List) return null;
  final out = <DomainConfig>[];
  for (final d in domains) {
    if (d is! Map) continue;
    final name = d['name']?.toString().trim() ?? '';
    final viewsRaw = d['views'];
    final views = viewsRaw is List
        ? [
            for (final v in viewsRaw)
              if (v != null && v.toString().trim().isNotEmpty)
                v.toString().trim(),
          ]
        : const <String>[];
    // A domain without a name or without at least one view is unusable
    // (no row label / no screen to open) — skip it.
    if (name.isEmpty || views.isEmpty) continue;
    out.add(
      DomainConfig(
        name: name,
        label: d['label']?.toString(),
        description: d['description']?.toString(),
        paradigm: d['paradigm']?.toString() == 'integration'
            ? DomainParadigm.integration
            : DomainParadigm.entry,
        views: views,
        icon: d['icon']?.toString(),
        metrics: _parseMetrics(d['metrics']),
        headline: _parseHeadline(d['headline']),
        listFields: _parseListFields(d['list_fields']),
      ),
    );
  }
  return out;
}

List<MetricConfig> _parseMetrics(Object? raw) {
  if (raw is! List) return const [];
  final out = <MetricConfig>[];
  for (final m in raw) {
    if (m is! Map) continue;
    final id = m['id']?.toString().trim() ?? '';
    if (id.isEmpty) continue;
    final goal = m['goal'];
    final floorPct = m['floor_pct'];
    final windowYears = m['window_years'];
    final lifts = m['lifts'];
    out.add(
      MetricConfig(
        id: id,
        kind: switch (m['kind']?.toString()) {
          'best' => MetricKind.best,
          'series' => MetricKind.series,
          _ => MetricKind.stat,
        },
        label: m['label']?.toString(),
        unit: m['unit']?.toString(),
        goal: goal is num ? goal.toDouble() : null,
        goalNote: m['goal_note']?.toString(),
        goalBandPerLb: _parseBand(m['goal_band_per_lb']),
        lifts: lifts is List
            ? [for (final l in lifts) l.toString()]
            : const [],
        from: DateTime.tryParse(m['from']?.toString() ?? ''),
        floorPct: floorPct is num ? floorPct.toDouble() : null,
        windowYears: windowYears is num && windowYears > 0
            ? windowYears.toInt()
            : null,
      ),
    );
  }
  return out;
}

/// `headline: [id, id]` — bare metric-id strings; blanks skipped.
/// Anything that isn't a list degrades to empty (default headline).
List<String> _parseHeadline(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final id in raw)
      if (id != null && id.toString().trim().isNotEmpty) id.toString().trim(),
  ];
}

/// `goal_band_per_lb: [low, high]` → normalized record. Anything that
/// isn't a two-number list degrades to null (no band).
({double low, double high})? _parseBand(Object? raw) {
  if (raw is! List || raw.length != 2) return null;
  final a = raw[0];
  final b = raw[1];
  if (a is! num || b is! num) return null;
  final lo = a.toDouble();
  final hi = b.toDouble();
  return lo <= hi ? (low: lo, high: hi) : (low: hi, high: lo);
}

/// The home STRENGTH card's "last bulk" window — dashboards.yaml's
/// top-level `last_bulk:` section (2026-09-22, user: "show my numbers
/// from my last bulk"):
///
/// ```yaml
/// last_bulk:
///   start: "2025-02-05"   # derived from the weigh-in trough
///   end: "2025-10-06"     # the declared cut (phase.yaml v1)
///   label: "2025 bulk"
/// ```
///
/// The card shows the heaviest weight ACTUALLY lifted per lift inside
/// [start, end]. `start` is derived (services/bulk_window.dart — the
/// 7-day-avg weigh-in trough before the run-up) but lives here
/// EXPLICITLY so the user can edit it. Back-compat by construction:
/// absent section, unparseable dates, or start ≥ end → null, and the
/// card simply omits the column.
({DateTime start, DateTime end, String label})? parseLastBulkWindow(
  String? raw,
) {
  if (raw == null || raw.trim().isEmpty) return null;
  Object? doc;
  try {
    doc = loadYaml(raw);
  } catch (_) {
    return null;
  }
  if (doc is! Map) return null;
  final section = doc['last_bulk'];
  if (section is! Map) return null;
  final start = DateTime.tryParse(section['start']?.toString() ?? '');
  final end = DateTime.tryParse(section['end']?.toString() ?? '');
  if (start == null || end == null || !start.isBefore(end)) return null;
  final label = section['label']?.toString().trim() ?? '';
  return (start: start, end: end, label: label.isEmpty ? 'last bulk' : label);
}

/// `list_fields:` entries — bare string, or map with `field` (+ `unit`).
/// Blank / field-less entries are skipped.
List<DomainListField> _parseListFields(Object? raw) {
  if (raw is! List) return const [];
  final out = <DomainListField>[];
  for (final f in raw) {
    if (f is Map) {
      final field = f['field']?.toString().trim() ?? '';
      if (field.isEmpty) continue;
      out.add(DomainListField(field: field, unit: f['unit']?.toString()));
    } else {
      final field = f?.toString().trim() ?? '';
      if (field.isEmpty) continue;
      out.add(DomainListField(field: field));
    }
  }
  return out;
}

/// Fetch + parse with the shared 1 h [DocCache]. Null on missing/bad
/// config (home falls back to the Ledgers section).
class DomainConfigProvider {
  final DocFetcher fetchDoc;

  /// Injectable clock — tests pass a fixed value.
  final DateTime Function() now;

  DomainConfigProvider(this.fetchDoc, {this.now = DateTime.now});

  /// Pull-to-refresh bust. Clears the shared [DocCache] (also busting
  /// the program/phase docs — they refresh together by design).
  static void clearCache() => DocCache.clear();

  Future<List<DomainConfig>?> load() async =>
      parseDomainConfigs(await DocCache.fetch(kDashboardsPath, fetchDoc, now: now));

  /// The raw file, for parsers beyond the domain list (the home hero's
  /// `phases:` eigenvectors — services/phase_eigenvectors.dart). Same
  /// shared cache entry as [load].
  Future<String?> loadRaw() =>
      DocCache.fetch(kDashboardsPath, fetchDoc, now: now);
}
