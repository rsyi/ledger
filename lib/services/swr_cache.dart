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
library;

import 'dart:async';

import 'perf.dart';

class SwrCache<T extends Object> {
  SwrCache({required this.name, required this.ttl, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// Perf span/counter prefix.
  final String name;
  final Duration ttl;
  final DateTime Function() _now;

  T? _value;
  DateTime? _at;
  bool _invalid = false;
  int _gen = 0;
  Future<T?>? _inflight;

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
    return _refresh(load);
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
  }
}
