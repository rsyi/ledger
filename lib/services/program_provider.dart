/// Reusable intent-file provider — fetches and parses coach/program.yaml,
/// coach/phase.yaml, and coach/strategy.yaml with a 1 h static cache.
///
/// Extracted from [CoachBrain._programSliceSection] so both the coach
/// prompt builder and the week-plan screen share the same fetch/cache logic
/// without duplicating code.
library;

import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:yaml/yaml.dart';

import 'coach_brain.dart' show CoachDocFetcher;
import 'doc_cache.dart';
import 'intent_docs.dart';
import 'perf.dart';

export 'intent_docs.dart';

/// Fetches and parses the three intent YAML files ([program], [phase],
/// [strategy]) from the coach repo, using the same 1 h static cache that
/// [CoachBrain] uses for its doc files.
///
/// Construct one, call [load], await the result.
class ProgramProvider {
  /// The fetcher to use — the active config source's
  /// `ConfigSource.docFetcher` (config_source/config_source.dart).
  final CoachDocFetcher fetchDoc;

  /// Injectable clock — defaults to [DateTime.now]. Tests pass a fixed value.
  final DateTime Function() now;

  /// TTL shared with CoachBrain so both components agree on freshness.
  static const cacheTtl = DocCache.ttl;

  /// Test hook + pull-to-refresh bust — clears the shared [DocCache]
  /// (which also busts the domain-dashboard config; the two refresh
  /// together by design).
  /// Busts the RAW docs only; the parsed cache below is keyed on the raw
  /// content, so it self-invalidates when a refetch returns new text.
  static void clearCache() => DocCache.clear();

  /// Parsed-doc cache (perf #1): path → (raw text, parsed map). A load
  /// whose fetched text is identical (`identical` or `==`) to the cached
  /// raw reuses the parsed map — program.yaml (~476 KB) is parsed ONCE
  /// per content change instead of on every load. Parsed maps are deep
  /// PLAIN + UNMODIFIABLE collections (YAML nodes were immutable too).
  static final Map<String, ({String raw, Map<Object?, Object?>? parsed})>
      _parsed = {};
  static final Map<String, ({String raw, Future<Map<Object?, Object?>?> f})>
      _parsing = {};

  /// Number of real YAML parses performed (test hook).
  static int debugParseCount = 0;

  /// Test hook — drops the parsed cache too.
  static void debugClearParsed() {
    _parsed.clear();
    _parsing.clear();
    debugParseCount = 0;
  }

  /// Docs at or above this size parse on a worker isolate
  /// ([Isolate.run]); smaller ones (phase/strategy) parse inline. Under
  /// `flutter test` everything parses inline — a real isolate never
  /// completes inside a widget test's fake-async zone.
  static int isolateThresholdBytes =
      Platform.environment.containsKey('FLUTTER_TEST') ? 1 << 62 : 32 * 1024;

  static Future<Map<Object?, Object?>?> _parse(String path, String raw) {
    final hit = _parsed[path];
    if (hit != null && (identical(hit.raw, raw) || hit.raw == raw)) {
      Perf.count('program.parse.hit', meta: {'path': path});
      return Future.value(hit.parsed);
    }
    final running = _parsing[path];
    if (running != null && (identical(running.raw, raw) || running.raw == raw)) {
      return running.f;
    }
    final big = raw.length >= isolateThresholdBytes;
    final f = Perf.span<Map<Object?, Object?>?>(
      'program.parse',
      () => big ? Isolate.run(() => parsePlainYamlMap(raw)) : parsePlainYamlMap(raw),
      meta: {'path': path, 'bytes': raw.length, 'isolate': big},
    ).then((parsed) {
      debugParseCount++;
      _parsed[path] = (raw: raw, parsed: parsed);
      if (identical(_parsing[path]?.raw, raw)) _parsing.remove(path);
      return parsed;
    });
    _parsing[path] = (raw: raw, f: f);
    return f;
  }


  ProgramProvider(this.fetchDoc, {this.now = DateTime.now});

  /// Fetches all three files (hitting cache when fresh) and returns the
  /// parsed maps. Any parse error or 404 silently sets the corresponding
  /// field to null — callers must handle absent docs.
  Future<IntentDocs> load() => Perf.span('program.load', _load);

  Future<IntentDocs> _load() async {
    const paths = [
      'coach/program.yaml',
      'coach/phase.yaml',
      'coach/strategy.yaml',
    ];
    final raws = await Perf.span(
        'program.fetch',
        () => Future.wait(
            [for (final p in paths) DocCache.fetch(p, fetchDoc, now: now)]));
    final parsed = await Future.wait([
      for (var i = 0; i < paths.length; i++)
        raws[i] == null ? Future.value(null) : _parse(paths[i], raws[i]!),
    ]);
    return (
      program: parsed[0],
      phase: parsed[1],
      strategy: parsed[2],
    );
  }
}

/// Parses [raw] YAML into a deep PLAIN, unmodifiable map (sendable across
/// isolates — YamlMap/YamlList are not cheap to send and carry spans).
/// Null when the doc is not a map or fails to parse. Top-level so
/// [Isolate.run] can ship it.
Map<Object?, Object?>? parsePlainYamlMap(String raw) {
  try {
    final y = loadYaml(raw);
    return y is Map ? _plain(y) as Map<Object?, Object?> : null;
  } catch (_) {
    return null;
  }
}

Object? _plain(Object? v) {
  if (v is Map) {
    return Map<Object?, Object?>.unmodifiable(
        {for (final e in v.entries) _plain(e.key): _plain(e.value)});
  }
  if (v is List) return List<Object?>.unmodifiable(v.map(_plain));
  return v;
}
