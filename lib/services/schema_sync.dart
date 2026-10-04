// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'config_source/config_source.dart';

/// Fetches view/template/app YAML files from the active [ConfigSource]
/// (the schemas repo — baked or user-connected) and writes
/// them to a local cache dir. The schema/template/app loaders prefer
/// this cache when present (else fall back to bundled assets), so a
/// PR merged on GitHub takes effect on the next app launch — no rebuild.
///
/// Scope: pulls every file under `<github.viewsPath>` in the repo at
/// `default_branch`. Subdirectories aren't recursed (we don't have any
/// yet); flatten if/when needed.
class SchemaSync {
  final ConfigSource source;
  static const _cacheDirName = 'synced_schemas';

  /// Resolves the platform's app docs dir. Swappable so unit tests (which
  /// have no plugin registry) can point the cache at a temp dir.
  static Future<Directory> Function() docsDir =
      getApplicationDocumentsDirectory;

  /// Name of the marker file (inside the cache dir) holding the signature
  /// of the last successful sync. Not a `.yml`, so the loaders skip it.
  static const _sigFileName = '.sig';

  SchemaSync(this.source);

  /// A cheap fingerprint of the repo's current schema state: the sorted
  /// list of `<name>:<blob-sha>` for every `.yml` under viewsPath, hashed
  /// down to one string. GitHub's contents listing returns each file's
  /// git blob sha (which changes iff its content changes), so this is a
  /// SINGLE API call — no file bodies downloaded. The poller compares it
  /// against [cachedSignature] and only does a full [refresh] on a diff.
  /// Returns null on any network/API error (caller treats as "unknown,
  /// try again next tick").
  Future<String?> remoteSignature() => source.signature(source.viewsPath);

  /// The signature recorded by the last successful [refresh], or null if
  /// the cache has never been written (or predates signature tracking).
  static Future<String?> cachedSignature() async {
    final d = await cacheDir();
    if (d == null) return null;
    final f = File(p.join(d.path, _sigFileName));
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  }

  /// Resolves the cache dir path. Public so loaders can read from it.
  /// Returns null if the platform's app docs dir isn't available (test
  /// environments). Always-creates the dir on a hit.
  static Future<Directory?> cacheDir() async {
    try {
      final base = await docsDir();
      final d = Directory(p.join(base.path, _cacheDirName));
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  /// True if the cache has at least one .view.yml file. Loaders use this
  /// as the "should I read from cache?" gate.
  static Future<bool> hasCachedSchemas() async {
    final d = await cacheDir();
    if (d == null) return false;
    final views = d.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.view.yml'),
        );
    return views.isNotEmpty;
  }

  /// The refresh currently in flight, if any. Concurrent callers (the
  /// background poller, the manual sync button, a double-tap of it) share
  /// one fetch instead of racing over the tmp dir — two interleaved
  /// refreshes used to wipe each other's half-written tmp dir and could
  /// swap in a cache missing files while recording a complete signature,
  /// which made the poller believe it was current forever.
  static Future<SchemaSyncResult>? _inFlight;

  /// Pulls every .yml file under viewsPath from the configured repo at
  /// default_branch, writes to the cache dir, and returns a small summary
  /// (counts + first error if any). Atomic: writes go to a tmp dir first
  /// and the swap only happens when EVERY listed file was fetched — on any
  /// failure the previous cache (and its signature) survives untouched. A
  /// stale complete cache beats a fresh partial one; the poller retries on
  /// the next tick. If a refresh is already in flight, returns its future.
  Future<SchemaSyncResult> refresh() {
    final pending = _inFlight;
    if (pending != null) return pending;
    final run = _refresh().whenComplete(() => _inFlight = null);
    _inFlight = run;
    return run;
  }

  Future<SchemaSyncResult> _refresh() async {
    final base = await docsDir();
    final finalDir = Directory(p.join(base.path, _cacheDirName));
    final tmpDir = Directory(p.join(base.path, '${_cacheDirName}_tmp'));
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    tmpDir.createSync(recursive: true);

    var fetched = 0;
    var skipped = 0;
    String? error;
    final sigParts = <String>[];

    try {
      final entries = await source.listDir(source.viewsPath);
      for (final e in entries) {
        if (!e.isFile || !e.path.endsWith('.yml')) {
          skipped++;
          continue;
        }
        final file = await source.readFile(e.path);
        if (file == null) {
          // Listed but 404 on read — a push raced this refresh (file
          // renamed/deleted) or an API blip. Swapping in a cache missing
          // this file would silently drop its view from the app, so treat
          // it as a failed refresh and keep the old cache.
          throw StateError('${e.path} listed but not readable (404)');
        }
        final out = File(p.join(tmpDir.path, e.name));
        out.writeAsStringSync(file.content);
        sigParts.add('${e.name}:${e.version ?? ''}');
        fetched++;
      }
    } catch (e) {
      error = e.toString();
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      return SchemaSyncResult(
        fetched: 0,
        skipped: skipped,
        error: error,
        when: DateTime.now(),
      );
    }

    // Record the signature of this fetch so the poller can detect future
    // changes without re-downloading. Matches remoteSignature()'s format.
    sigParts.sort();
    final signature = sigParts.join('|');
    File(p.join(tmpDir.path, _sigFileName)).writeAsStringSync(signature);

    // Swap tmp → final atomically (delete + rename).
    if (finalDir.existsSync()) finalDir.deleteSync(recursive: true);
    tmpDir.renameSync(finalDir.path);

    return SchemaSyncResult(
      fetched: fetched,
      skipped: skipped,
      error: null,
      when: DateTime.now(),
      signature: signature,
    );
  }

  /// Brings the cache up to date with the remote (refreshing only when
  /// their signatures differ) and returns the signature of whatever the
  /// cache holds afterwards. Falls back to the current cached signature
  /// when the remote is unreachable or the refresh fails — the caller can
  /// still compare it against what the UI was built from and catch up to
  /// the cache without the network. Null only when the cache has never
  /// been written and no refresh succeeded.
  Future<String?> ensureFresh() async {
    final cached = await cachedSignature();
    final remote = await remoteSignature();
    if (remote == null || remote == cached) return cached;
    final result = await refresh();
    return result.ok ? result.signature : cached;
  }

  /// Drops the cache (forces loaders to read bundled assets again).
  /// Useful for debugging or if a sync produced a bad cache.
  static Future<void> clearCache() async {
    final d = await cacheDir();
    if (d == null) return;
    if (d.existsSync()) d.deleteSync(recursive: true);
  }
}

class SchemaSyncResult {
  final int fetched;
  final int skipped;
  final String? error;
  final DateTime when;

  /// Signature of the synced state (null on error). The poller stores this
  /// to skip redundant refreshes until the repo changes again.
  final String? signature;

  SchemaSyncResult({
    required this.fetched,
    required this.skipped,
    required this.error,
    required this.when,
    this.signature,
  });

  bool get ok => error == null;
}
