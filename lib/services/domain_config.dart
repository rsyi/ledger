/// Domain-dashboard presentation config — the app-IA redesign's declared
/// layer (spec: airledger docs/superpowers/specs/
/// 2026-09-22-app-ia-redesign-spec.md).
///
/// `app/dashboards.yaml` in the schemas repo groups views into DOMAINS,
/// each with a paradigm (`entry` → home LOG section, full timeline;
/// `integration` → CONNECTED section, read-only timeline), an icon, and
/// a metrics list for the domain screen's dashboard header.
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
  /// bw_series, bf_series, kcal_series, protein_series, grade_pyramid,
  /// session_frequency, hr_4x4_series). Ids the metric engine doesn't
  /// know render as a placeholder, never an error.
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

  /// Main-lift filter for per-lift strength metrics.
  final List<String> lifts;

  const MetricConfig({
    required this.id,
    this.kind = MetricKind.stat,
    this.label,
    this.unit,
    this.goal,
    this.goalNote,
    this.lifts = const [],
  });
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

  const DomainConfig({
    required this.name,
    required this.paradigm,
    required this.views,
    this.icon,
    this.metrics = const [],
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
        lifts: lifts is List
            ? [for (final l in lifts) l.toString()]
            : const [],
      ),
    );
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
