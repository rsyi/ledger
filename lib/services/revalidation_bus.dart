/// Process-wide "a background revalidation CHANGED cached content"
/// signal (perf batch 3, 2026-10-12). DocCache + SwrCache serve last-good
/// copies (memory or disk) immediately and refresh in the background;
/// when that refresh returns DIFFERENT content they publish here so the
/// screens that already rendered the old copy re-load (HomeScreen
/// listens, debounced). Unchanged revalidations never publish.
///
/// Event names: `doc:<repo path>` for DocCache, the SwrCache `name`
/// (wm_store / forecast_meta / projection_store) for stores. Pure Dart.
library;

import 'dart:async';

class RevalidationBus {
  RevalidationBus._();
  static final RevalidationBus instance = RevalidationBus._();

  final _controller = StreamController<String>.broadcast(sync: false);

  /// Monotonic count of published changes.
  int get version => _version;
  int _version = 0;

  Stream<String> get stream => _controller.stream;

  void publish(String what) {
    _version++;
    _controller.add(what);
  }
}
