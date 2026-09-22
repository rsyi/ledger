/// Domain-dashboard presentation config — the app-IA redesign's declared
/// layer (spec: airledger docs/superpowers/specs/
/// 2026-09-22-app-ia-redesign-spec.md).
///
/// `app/dashboards.yaml` in the schemas repo groups views into DOMAINS,
/// each with a paradigm (`entry` → home LOG section, full timeline;
/// `integration` → CONNECTED section, read-friendly record list with
/// the read-only timeline a calendar-icon away), an icon, a metrics
/// list for the domain screen's dashboard header, and optional
/// `list_fields` (the record list's salient columns).
///
/// ENGINE-FREE by design (adaptation decision 1): fetched straight from
/// GitHub through the shared [DocCache] (1 h TTL, pull-to-refresh bust)
/// and parsed here in Dart only — no Rust schema keys, no dylib rebuild,
/// no trap #1. Missing or malformed config MUST degrade to null so the
/// home screen falls back to the flat Ledgers section — a bad push can
/// never break the app.
library;

import 'package:yaml/yaml.dart';

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
  /// Built-in id (pl_total, e1rm_reference, all_time_best_weight,
  /// wilks, wilks_series, bw_series, bf_series, kcal_series,
  /// protein_series, grade_pyramid, session_frequency, hr_4x4_series).
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
  final DomainParadigm paradigm;

  /// View names — the FIRST backs the domain screen's timeline body.
  final List<String> views;

  /// Lucide icon name (same vocabulary as input.yml icons).
  final String? icon;

  final List<MetricConfig> metrics;

  /// Salient columns for the read-friendly record list. Empty → the UI
  /// falls back to the view's `list_display`.
  final List<DomainListField> listFields;

  const DomainConfig({
    required this.name,
    required this.paradigm,
    required this.views,
    this.icon,
    this.metrics = const [],
    this.listFields = const [],
  });

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
        paradigm: d['paradigm']?.toString() == 'integration'
            ? DomainParadigm.integration
            : DomainParadigm.entry,
        views: views,
        icon: d['icon']?.toString(),
        metrics: _parseMetrics(d['metrics']),
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
      ),
    );
  }
  return out;
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
}
