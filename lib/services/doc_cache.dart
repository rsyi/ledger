/// Process-wide TTL cache for GitHub-fetched config/docs — the fetch+
/// cache pattern [ProgramProvider] used privately, extracted so the
/// domain-dashboard config loader shares it instead of growing a third
/// copy (CoachBrain keeps its own map for coach/*.md).
///
/// Keyed by repo path. Fetch errors are swallowed into null (callers
/// must degrade gracefully); a successful fetch refreshes the entry.
library;

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

  /// Clears every cached doc — pull-to-refresh bust + test hook.
  static void clear() => _cache.clear();

  /// Returns the cached content for [path] when fresher than [ttl],
  /// otherwise fetches via [fetchDoc]. Null when the doc is missing or
  /// the fetch failed AND nothing usable is cached (a stale entry is
  /// deliberately NOT served — matches the extracted behavior).
  static Future<String?> fetch(
    String path,
    DocFetcher fetchDoc, {
    DateTime Function() now = DateTime.now,
  }) async {
    final at = now();
    final cached = _cache[path];
    if (cached != null && at.difference(cached.at) < ttl) {
      return cached.content;
    }
    String? raw;
    try {
      raw = await fetchDoc(path);
    } catch (_) {
      raw = null;
    }
    if (raw != null) _cache[path] = (at: at, content: raw);
    return raw;
  }
}
