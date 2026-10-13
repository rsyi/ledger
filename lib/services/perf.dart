/// Lightweight perf instrumentation — debug/profile only, no behaviour
/// change. [Perf.span] times an async (or sync) unit of work, emits a
/// DevTools timeline task, logs via `developer.log` (name `perf`) when
/// logging is on, and keeps rolling per-name counters ([Perf.stats]).
///
/// Logging is ON in debug + profile builds, or in release with
/// `--dart-define=PERF_LOG=true`. In a plain release build [span] is a
/// thin pass-through (one Stopwatch + a map update for the counters).
///
/// FLUTTER-FREE on purpose (pure services + `dart run` tools import it);
/// the >16 ms frame logger lives in perf_frames.dart.
library;

import 'dart:async';
import 'dart:developer' as developer;

// Same definitions as package:flutter/foundation's constants, inlined so
// this file stays Flutter-free.
const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');
const bool kPerfProfileMode = bool.fromEnvironment('dart.vm.profile');
const bool _kDebugMode = !_kReleaseMode && !kPerfProfileMode;

/// Rolling counters for one span name.
class PerfStat {
  int count = 0;
  int totalMicros = 0;
  int maxMicros = 0;
  int lastMicros = 0;

  void add(int micros) {
    count++;
    totalMicros += micros;
    lastMicros = micros;
    if (micros > maxMicros) maxMicros = micros;
  }

  double get avgMs => count == 0 ? 0 : totalMicros / count / 1000;

  @override
  String toString() => 'n=$count avg=${avgMs.toStringAsFixed(1)}ms '
      'max=${(maxMicros / 1000).toStringAsFixed(1)}ms';
}

class Perf {
  Perf._();

  static const bool forceLog = bool.fromEnvironment('PERF_LOG');

  /// Whether spans/frames log. Tests may flip it.
  static bool enabled = kPerfProfileMode || _kDebugMode || forceLog;

  static final Map<String, PerfStat> _stats = {};

  /// Snapshot of the rolling counters, keyed by span name.
  static Map<String, PerfStat> get stats => Map.unmodifiable(_stats);

  /// Test hook.
  static void reset() => _stats.clear();

  /// Records an externally-timed sample (e.g. a cache hit counter).
  static void count(String name, {Map<String, Object?>? meta}) {
    (_stats[name] ??= PerfStat()).add(0);
    if (enabled) _log(name, 0, meta);
  }

  /// Times [fn] (sync or async). [meta] is logged with the span; a
  /// [metaOf] callback can derive extra fields from the result (row
  /// counts etc.) — it never runs when logging is off.
  static Future<T> span<T>(
    String name,
    FutureOr<T> Function() fn, {
    Map<String, Object?>? meta,
    Map<String, Object?> Function(T result)? metaOf,
  }) async {
    final task = enabled ? (developer.TimelineTask()..start(name)) : null;
    final sw = Stopwatch()..start();
    try {
      final r = await fn();
      _finish(name, sw, task, meta, metaOf == null ? null : () => metaOf(r));
      return r;
    } catch (_) {
      _finish(name, sw, task, {...?meta, 'error': true}, null);
      rethrow;
    }
  }

  /// Sync twin of [span] for pure CPU work.
  static T spanSync<T>(
    String name,
    T Function() fn, {
    Map<String, Object?>? meta,
  }) {
    final task = enabled ? (developer.TimelineTask()..start(name)) : null;
    final sw = Stopwatch()..start();
    try {
      return fn();
    } finally {
      _finish(name, sw, task, meta, null);
    }
  }

  static void _finish(
    String name,
    Stopwatch sw,
    developer.TimelineTask? task,
    Map<String, Object?>? meta,
    Map<String, Object?> Function()? lateMeta,
  ) {
    sw.stop();
    final us = sw.elapsedMicroseconds;
    (_stats[name] ??= PerfStat()).add(us);
    if (task == null) return;
    Map<String, Object?>? all = meta;
    if (lateMeta != null) {
      try {
        all = {...?meta, ...lateMeta()};
      } catch (_) {}
    }
    task.finish(arguments: all);
    _log(name, us, all);
  }

  static void _log(String name, int us, Map<String, Object?>? meta) {
    final m = meta == null || meta.isEmpty
        ? ''
        : ' ${meta.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    final line = '$name ${(us / 1000).toStringAsFixed(1)}ms$m';
    // developer.log never reaches logcat in a release build; with the
    // explicit PERF_LOG define, print so `adb logcat -s flutter` sees it.
    if (forceLog) {
      // ignore: avoid_print
      print('[perf] $line');
    } else {
      developer.log(line, name: 'perf');
    }
  }

  /// Records one sample from an external timer (frame timings).
  static void record(String name, int micros) =>
      (_stats[name] ??= PerfStat()).add(micros);
}
