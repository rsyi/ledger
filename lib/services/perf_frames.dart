/// Flutter half of the perf instrumentation (perf.dart stays
/// Flutter-free): logs frames whose build or raster time exceeds 16 ms.
library;

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'perf.dart';

bool _installed = false;

/// Profile builds (or `--dart-define=PERF_LOG=true`) only — debug frame
/// times are meaningless. Idempotent; call after
/// `WidgetsFlutterBinding.ensureInitialized()`.
void installPerfFrameTimings() {
  if (_installed || !(kProfileMode || Perf.forceLog)) return;
  _installed = true;
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      final b = t.buildDuration.inMicroseconds;
      final r = t.rasterDuration.inMicroseconds;
      if (b > 16000 || r > 16000) {
        Perf.record('frame.jank', b > r ? b : r);
        developer.log(
            'jank frame build=${(b / 1000).toStringAsFixed(1)}ms '
            'raster=${(r / 1000).toStringAsFixed(1)}ms',
            name: 'perf');
      }
    }
  });
}
