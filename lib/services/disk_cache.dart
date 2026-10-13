/// Tiny persistent key → text store for LAST-GOOD snapshots (perf batch
/// 3, 2026-10-12): DocCache (GitHub-fetched program/phase/strategy/
/// dashboards docs) and the direct-Sheets SwrCache stores (WmStore,
/// ForecastMetaStore, ProjectionSnapshotStore) write their last good
/// value here so a COLD start paints from disk instead of waiting on
/// the network (~0.4–0.8 s per doc, ~2 s for the WM tabs on device).
///
/// [DiskCache.instance] is null by default (tests, CLI tools) → callers
/// stay memory-only. The app wires [FileDiskCacheStore] over the app
/// support dir in main(). Every IO failure degrades to "no copy" —
/// never throws to callers. One file per key (FNV-1a-64 hex name).
library;

import 'dart:async';
import 'dart:io';

abstract class DiskCacheStore {
  /// The stored text, or null (missing / unreadable).
  Future<String?> read(String key);

  /// Best-effort write (errors swallowed).
  Future<void> write(String key, String value);
}

class DiskCache {
  DiskCache._();

  /// The process store; null = persistence off.
  static DiskCacheStore? instance;
}

/// FNV-1a 64-bit hex of [s] — stable file names + cheap content tags.
/// (Dart ints are 64-bit; the multiply wraps.)
String fnv1a64Hex(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h ^= c;
    h *= 0x100000001b3;
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// One file per key under [dir] (`<fnv(key)>.txt`); the key itself is
/// the first line so a hash collision reads as a miss, never as another
/// key's data. Writes go to a temp file + rename (atomic on Android).
class FileDiskCacheStore implements DiskCacheStore {
  FileDiskCacheStore(this._dir);

  final Future<Directory> _dir;

  Future<File> _file(String key) async {
    final d = await _dir;
    return File('${d.path}/${fnv1a64Hex(key)}.txt');
  }

  @override
  Future<String?> read(String key) async {
    try {
      final f = await _file(key);
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      final nl = text.indexOf('\n');
      if (nl < 0 || text.substring(0, nl) != key) return null;
      return text.substring(nl + 1);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final f = await _file(key);
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString('$key\n$value', flush: true);
      await tmp.rename(f.path);
    } catch (_) {/* best-effort */}
  }
}

/// In-memory store (tests).
class MemoryDiskCacheStore implements DiskCacheStore {
  final Map<String, String> entries = {};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async =>
      entries[key] = value;
}
