import 'dart:async';

import 'sheets_repository.dart' show Record;

/// A logged row (a `create`) that just landed in the local ledger.
class LogEvent {
  /// The view the row belongs to ('strength', 'meals', 'cardio', …).
  final String view;

  /// The created record's values.
  final Record record;

  const LogEvent(this.view, this.record);
}

/// Process-global broadcast of ledger `create`s so features can react to
/// logging without editing the entry form. The connector publishes here
/// on every create; listeners (the post-log notification driver) debounce
/// and compose their own summaries.
///
/// Deliberately NOT tied to SyncScheduler: writes flow through the engine
/// connector regardless of whether sync is configured, and a notification
/// nudge shouldn't depend on the sync singleton existing.
class LogEventBus {
  LogEventBus._();
  static final LogEventBus instance = LogEventBus._();

  final _controller = StreamController<LogEvent>.broadcast();

  /// Fired by the connector after a successful `create`.
  void publish(LogEvent event) {
    if (_controller.hasListener) _controller.add(event);
  }

  /// Subscribe to log events.
  Stream<LogEvent> get stream => _controller.stream;
}
