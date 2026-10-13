/// Process-wide TTL cache for GitHub-fetched config/docs — the fetch+
/// cache pattern [ProgramProvider] used privately, extracted so the
/// domain-dashboard config loader shares it instead of growing a third
/// copy (CoachBrain keeps its own map for coach/*.md).
///
/// Keyed by repo path. Fetch errors are swallowed into null (callers
/// must degrade gracefully); a successful fetch refreshes the entry.
library;

import 'dart:async';

import 'perf.dart';

/// Fetches one repo file's content; null when missing. Signature-
/// compatible with coach_brain's CoachDocFetcher (kept separate so pure
/// consumers — domain_config/domain_metrics, CLI tools — don't drag the
/// coach's Flutter imports).
typedef DocFetcher = Future<String?> Function(String path);

class DocCache {
  DocCache._();

  /// TTL shared by every consumer so they agree on freshness.
  static const ttl = Duration(hours: 1);

  static final Map<String, ({DateTime at, String content})> _cache = {};

  /// In-flight fetches per path — concurrent callers share one request.
  static final Map<String, Future<String?>> _inflight = {};

  /// Bumped by [clear] so a fetch started before a bust never
  /// repopulates the cache with pre-bust content.
  static int _gen = 0;

  /// Clears every cached doc — pull-to-refresh bust + test hook.
  static void clear() {
    _cache.clear();
    _inflight.clear();
    _gen++;
  }

  /// STALE-WHILE-REVALIDATE (perf #8, 2026-10-12): a fresh entry
  /// (younger than [ttl]) is returned as-is; a STALE entry is returned
  /// immediately (last-good) while ONE background fetch refreshes it;
  /// with nothing cached the call awaits the (coalesced) fetch. Null
  /// only when the doc is missing / the fetch failed AND nothing was
  /// ever cached since the last [clear]. A failed refresh keeps the
  /// last-good entry.
  static Future<String?> fetch(
    String path,
    DocFetcher fetchDoc, {
    DateTime Function() now = DateTime.now,
  }) {
    final at = now();
    final cached = _cache[path];
    if (cached != null) {
      if (at.difference(cached.at) < ttl) {
        Perf.count('doc_cache.hit', meta: {'path': path});
      } else {
        Perf.count('doc_cache.stale', meta: {'path': path});
        unawaited(_refresh(path, fetchDoc, at));
      }
      return Future.value(cached.content);
    }
    return _refresh(path, fetchDoc, at);
  }

  static Future<String?> _refresh(String path, DocFetcher fetchDoc, DateTime at) {
    final pending = _inflight[path];
    if (pending != null) return pending;
    final gen = _gen;
    final f = Perf.span('doc_cache.miss', () async {
      String? raw;
      try {
        raw = await fetchDoc(path);
      } catch (_) {
        raw = null;
      }
      if (gen != _gen) return raw;
      if (raw != null) {
        _cache[path] = (at: at, content: raw);
        return raw;
      }
      return _cache[path]?.content;
    }, meta: {'path': path});
    _inflight[path] = f;
    f.whenComplete(() {
      if (identical(_inflight[path], f)) _inflight.remove(path);
    }).ignore();
    return f;
  }
}
