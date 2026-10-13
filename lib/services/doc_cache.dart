/// Process-wide TTL cache for GitHub-fetched config/docs — the fetch+
/// cache pattern [ProgramProvider] used privately, extracted so the
/// domain-dashboard config loader shares it instead of growing a third
/// copy (CoachBrain keeps its own map for coach/*.md).
///
/// Keyed by repo path. Fetch errors are swallowed into null (callers
/// must degrade gracefully); a successful fetch refreshes the entry.
///
/// PERSISTED (perf batch 3, 2026-10-12): with [DiskCache.instance] set
/// and a [diskScope] (the active config source id), every successful
/// fetch writes `{content, sha, fetchedAt}` to disk; the FIRST access to
/// a path in a process (cold start) serves that last-good copy
/// immediately and revalidates in the background. A revalidation that
/// returns DIFFERENT content updates memory + disk and publishes
/// `doc:<path>` on [RevalidationBus] (HomeScreen re-loads its cards).
/// [clear] (pull-to-refresh) never re-serves disk: the next fetch awaits
/// the network (disk is only the offline fallback then).
library;

import 'dart:async';
import 'dart:convert';

import 'disk_cache.dart';
import 'perf.dart';
import 'revalidation_bus.dart';

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

  /// In-flight cold-start disk reads per path (concurrent first callers
  /// share one read).
  static final Map<String, Future<String?>> _diskInflight = {};

  /// `scope|path` already offered the disk copy this process.
  static final Set<String> _diskTried = {};

  /// `scope|path` → sha of the copy known to be on disk (skip rewrites).
  static final Map<String, String> _diskSha = {};

  /// Bumped by [clear] so a fetch started before a bust never
  /// repopulates the cache with pre-bust content.
  static int _gen = 0;

  /// The disk namespace — the active config source's id (set by
  /// ConfigSourceRegistry). Null → no persistence (a doc from one source
  /// must never paint under another).
  static String? diskScope;

  /// Clears every cached doc — pull-to-refresh bust + test hook. Disk
  /// copies stay (offline fallback) but are not re-served first.
  static void clear() {
    _cache.clear();
    _inflight.clear();
    _diskInflight.clear();
    _gen++;
  }

  /// Test hook: simulates a process restart (memory gone, disk kept).
  static void debugColdStart() {
    clear();
    _diskTried.clear();
    _diskSha.clear();
  }

  /// STALE-WHILE-REVALIDATE (perf #8, 2026-10-12): a fresh entry
  /// (younger than [ttl]) is returned as-is; a STALE entry is returned
  /// immediately (last-good) while ONE background fetch refreshes it;
  /// with nothing cached the call awaits the (coalesced) fetch — or, on
  /// the first access of a cold start, serves the DISK copy and
  /// revalidates in the background. Null only when the doc is missing /
  /// the fetch failed AND no copy exists. A failed refresh keeps the
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
    final diskPending = _diskInflight[path];
    if (diskPending != null) return diskPending;
    final disk = DiskCache.instance;
    final scope = diskScope;
    if (disk != null && scope != null && _diskTried.add('$scope|$path')) {
      return _fromDisk(path, fetchDoc, at, disk, scope);
    }
    return _refresh(path, fetchDoc, at);
  }

  static String _diskKey(String scope, String path) => 'doc|$scope|$path';

  static Future<({String content, DateTime at})?> _readDisk(
      DiskCacheStore disk, String scope, String path) async {
    final raw = await disk.read(_diskKey(scope, path));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, Object?>;
      final content = m['content'] as String;
      final at = DateTime.tryParse(m['fetchedAt']?.toString() ?? '');
      final sha = m['sha']?.toString();
      if (sha != null) _diskSha['$scope|$path'] = sha;
      // Unknown age → treat as stale (revalidated anyway).
      return (content: content, at: at ?? DateTime(2000));
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _fromDisk(String path, DocFetcher fetchDoc,
      DateTime at, DiskCacheStore disk, String scope) {
    final gen = _gen;
    final f = () async {
      final saved = await Perf.span(
        'doc_cache.disk',
        () => _readDisk(disk, scope, path),
        meta: {'path': path},
        metaOf: (s) => {'hit': s != null},
      );
      _diskInflight.remove(path);
      if (gen != _gen || saved == null) {
        Perf.count('doc_cache.disk_miss', meta: {'path': path});
        return _refresh(path, fetchDoc, at);
      }
      Perf.count('doc_cache.disk_hit', meta: {'path': path});
      _cache[path] ??= (at: saved.at, content: saved.content);
      // Cold start: always revalidate once in the background.
      unawaited(_refresh(path, fetchDoc, at));
      return saved.content;
    }();
    _diskInflight[path] = f;
    return f;
  }

  static void _persist(String path, String content, DateTime at) {
    final disk = DiskCache.instance;
    final scope = diskScope;
    if (disk == null || scope == null) return;
    final sha = fnv1a64Hex(content);
    final k = '$scope|$path';
    if (_diskSha[k] == sha) return;
    _diskSha[k] = sha;
    unawaited(Perf.span(
      'doc_cache.disk_write',
      () => disk.write(
          _diskKey(scope, path),
          jsonEncode({
            'path': path,
            'sha': sha,
            'fetchedAt': at.toIso8601String(),
            'content': content,
          })),
      meta: {'path': path, 'bytes': content.length},
    ));
  }

  static Future<String?> _refresh(
      String path, DocFetcher fetchDoc, DateTime at) {
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
        final prev = _cache[path]?.content;
        _cache[path] = (at: at, content: raw);
        _persist(path, raw, at);
        if (prev != null && prev != raw) {
          Perf.count('doc_cache.changed', meta: {'path': path});
          RevalidationBus.instance.publish('doc:$path');
        }
        return raw;
      }
      final last = _cache[path]?.content;
      if (last != null) return last;
      // Offline with nothing in memory: the disk copy is still last-good.
      final disk = DiskCache.instance;
      final scope = diskScope;
      if (disk == null || scope == null) return null;
      final saved = await _readDisk(disk, scope, path);
      if (saved == null || gen != _gen) return saved?.content;
      _cache[path] ??= (at: saved.at, content: saved.content);
      return saved.content;
    }, meta: {'path': path});
    _inflight[path] = f;
    f.whenComplete(() {
      if (identical(_inflight[path], f)) _inflight.remove(path);
    }).ignore();
    return f;
  }
}
