/// Single-value stale-while-revalidate cache (perf #8, 2026-10-12) for
/// the direct-Sheets stores on critical paths (WmStore, ForecastMetaStore,
/// ProjectionSnapshotStore):
///  - fresh (younger than [ttl]) → returned as-is, no network;
///  - STALE → last-good returned immediately + ONE background refresh;
///  - nothing cached / [invalidate]d / `force` → awaits the load;
///  - concurrent loads coalesce onto one in-flight request;
///  - a failed load returns last-good (null before the first success).
/// [invalidate] (after a write) bumps a generation so a load started
/// before the write never stores its pre-write result.
///
/// PERSISTED (perf batch 3, 2026-10-12): with a [SwrPersist] and
/// [DiskCache.instance] set, every successful load is written to disk
/// (JSON via [SwrPersist.encode]); the first [get] of a process with
/// nothing in memory serves the disk copy IMMEDIATELY and revalidates in
/// the background. A background revalidation whose encoded value differs
/// from what was served publishes [name] on [RevalidationBus].
library;

import 'dart:async';
import 'dart:convert';

import 'disk_cache.dart';
import 'perf.dart';
import 'revalidation_bus.dart';

/// How a [SwrCache] value persists: [key] must be unique per data
/// location (e.g. include the spreadsheet id); [encode] → JSON-able,
/// [decode] → value (throwing / null = no usable copy).
class SwrPersist<T> {
  const SwrPersist({
    required this.key,
    required this.encode,
    required this.decode,
  });
  final String key;
  final Object? Function(T value) encode;
  final T? Function(Object? json) decode;
}

class SwrCache<T extends Object> {
  SwrCache({
    required this.name,
    required this.ttl,
    DateTime Function()? now,
    this.persist,
  }) : _now = now ?? DateTime.now;

  /// Optional disk persistence (null = memory-only).
  final SwrPersist<T>? persist;

  /// Perf span/counter prefix.
  final String name;
  final Duration ttl;
  final DateTime Function() _now;

  T? _value;
  DateTime? _at;
  bool _invalid = false;
  int _gen = 0;
  Future<T?>? _inflight;
  bool _diskTried = false;
  Future<T?>? _diskRead;

  /// Encoded form of the value last served/stored (change detection +
  /// skip identical disk writes).
  String? _encoded;

  /// Last-good value (null before the first success).
  T? get value => _value;

  /// Whether a refresh is currently running (test hook).
  bool get refreshing => _inflight != null;

  Future<T?> get(Future<T> Function() load, {bool force = false}) {
    final v = _value;
    final at = _at;
    if (!force && !_invalid && v != null && at != null) {
      if (_now().difference(at) < ttl) {
        Perf.count('$name.hit');
      } else {
        Perf.count('$name.stale');
        unawaited(_refresh(load));
      }
      return Future.value(v);
    }
    if (!force && !_invalid && v == null) {
      final pendingDisk = _diskRead;
      if (pendingDisk != null) return pendingDisk;
      final p = persist;
      if (p != null && !_diskTried && DiskCache.instance != null) {
        _diskTried = true;
        return _fromDisk(p, DiskCache.instance!, load);
      }
    }
    return _refresh(load);
  }

  Future<T?> _fromDisk(
      SwrPersist<T> p, DiskCacheStore disk, Future<T> Function() load) {
    final gen = _gen;
    final f = () async {
      final saved = await Perf.span<({T value, DateTime at, String enc})?>(
        '$name.disk',
        () async {
          final raw = await disk.read('swr|${p.key}');
          if (raw == null) return null;
          try {
            final m = jsonDecode(raw) as Map<String, Object?>;
            final value = p.decode(m['value']);
            if (value == null) return null;
            final at = DateTime.tryParse(m['at']?.toString() ?? '') ??
                DateTime(2000);
            return (value: value, at: at, enc: jsonEncode(m['value']));
          } catch (_) {
            return null;
          }
        },
        metaOf: (s) => {'hit': s != null},
      );
      _diskRead = null;
      if (gen != _gen || saved == null || _value != null) {
        return _value ?? await _refresh(load);
      }
      _value = saved.value;
      _at = saved.at;
      _encoded = saved.enc;
      // Cold start: always revalidate once in the background.
      unawaited(_refresh(load));
      return saved.value;
    }();
    _diskRead = f;
    return f;
  }

  void _store(T r) {
    final p = persist;
    if (p == null) return;
    String enc;
    try {
      enc = jsonEncode(p.encode(r));
    } catch (_) {
      return;
    }
    final prev = _encoded;
    if (prev == enc) return;
    _encoded = enc;
    if (prev != null) {
      Perf.count('$name.changed');
      RevalidationBus.instance.publish(name);
    }
    final disk = DiskCache.instance;
    if (disk == null) return;
    unawaited(disk.write(
      'swr|${p.key}',
      '{"at":${jsonEncode(_now().toIso8601String())},"value":$enc}',
    ));
  }

  Future<T?> _refresh(Future<T> Function() load) {
    final pending = _inflight;
    if (pending != null) return pending;
    final gen = _gen;
    final f = Perf.span<T?>('$name.load', () async {
      try {
        final r = await load();
        if (gen == _gen) {
          _value = r;
          _at = _now();
          _invalid = false;
          _store(r);
        }
        return r;
      } catch (_) {
        return _value;
      }
    });
    _inflight = f;
    f.whenComplete(() {
      if (identical(_inflight, f)) _inflight = null;
    }).ignore();
    return f;
  }

  /// Marks the value invalid: the next [get] awaits a fresh load (the
  /// last-good value stays available as the failure fallback).
  void invalidate() {
    _invalid = true;
    _gen++;
    _inflight = null;
    _diskRead = null;
  }
}
