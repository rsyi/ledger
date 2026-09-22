/// Reusable intent-file provider — fetches and parses coach/program.yaml,
/// coach/phase.yaml, and coach/strategy.yaml with a 1 h static cache.
///
/// Extracted from [CoachBrain._programSliceSection] so both the coach
/// prompt builder and the week-plan screen share the same fetch/cache logic
/// without duplicating code.
library;

import 'package:yaml/yaml.dart';

import 'coach_brain.dart' show CoachDocFetcher;
import 'doc_cache.dart';

/// Parsed trio of intent YAML files. All three fields are nullable: the
/// caller should handle missing/malformed docs gracefully.
typedef IntentDocs = ({
  Map<Object?, Object?>? program,
  Map<Object?, Object?>? phase,
  Map<Object?, Object?>? strategy,
});

/// Fetches and parses the three intent YAML files ([program], [phase],
/// [strategy]) from the coach repo, using the same 1 h static cache that
/// [CoachBrain] uses for its doc files.
///
/// Construct one, call [load], await the result.
class ProgramProvider {
  /// The fetcher to use (e.g. [CoachBrain.githubFetcher]).
  final CoachDocFetcher fetchDoc;

  /// Injectable clock — defaults to [DateTime.now]. Tests pass a fixed value.
  final DateTime Function() now;

  /// TTL shared with CoachBrain so both components agree on freshness.
  static const cacheTtl = DocCache.ttl;

  /// Test hook + pull-to-refresh bust — clears the shared [DocCache]
  /// (which also busts the domain-dashboard config; the two refresh
  /// together by design).
  static void clearCache() => DocCache.clear();

  ProgramProvider(this.fetchDoc, {this.now = DateTime.now});

  /// Fetches all three files (hitting cache when fresh) and returns the
  /// parsed maps. Any parse error or 404 silently sets the corresponding
  /// field to null — callers must handle absent docs.
  Future<IntentDocs> load() async {
    final paths = [
      'coach/program.yaml',
      'coach/phase.yaml',
      'coach/strategy.yaml',
    ];
    final parsed = <String, Map<Object?, Object?>?>{};
    for (final path in paths) {
      final raw = await DocCache.fetch(path, fetchDoc, now: now);
      if (raw == null) {
        parsed[path] = null;
      } else {
        try {
          final y = loadYaml(raw);
          parsed[path] = y is Map ? Map<Object?, Object?>.from(y) : null;
        } catch (_) {
          parsed[path] = null;
        }
      }
    }
    return (
      program: parsed['coach/program.yaml'],
      phase: parsed['coach/phase.yaml'],
      strategy: parsed['coach/strategy.yaml'],
    );
  }
}
