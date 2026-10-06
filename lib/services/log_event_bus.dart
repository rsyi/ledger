import 'dart:async';

import 'sheets_repository.dart' show Record;

/// What happened to the row.
enum LogEventKind { created, updated, deleted }

/// A ledger row change that just landed in the local ledger: a `create`
/// (a log), or an `update` / `delete` (an edit or removal — surfaces that
/// show logged work must refresh, but "Nice work" nudges must not fire).
class LogEvent {
  /// The view the row belongs to ('strength', 'meals', 'cardio', …).
  final String view;

  /// The record's values (for a delete: the row as it was).
  final Record record;

  final LogEventKind kind;

  const LogEvent(this.view, this.record, {this.kind = LogEventKind.created});

  bool get isCreate => kind == LogEventKind.created;
}

/// Process-global broadcast of ledger writes so features can react to
/// logging without editing the entry form. The connector publishes here
/// on every create, update and delete (2026-10-05: deletes/edits used to
/// be silent, so the Today program card + Week goals kept showing a
/// cleaned-up session's stale sets); listeners filter by [LogEvent.kind]
/// — the post-log notification driver reacts to creates only.
///
/// Deliberately NOT tied to SyncScheduler: writes flow through the engine
/// connector regardless of whether sync is configured, and a notification
/// nudge shouldn't depend on the sync singleton existing.
class LogEventBus {
  LogEventBus._();
  static final LogEventBus instance = LogEventBus._();

  final _controller = StreamController<LogEvent>.broadcast();

  /// Fired by the connector after a successful create / update / delete.
  void publish(LogEvent event) {
    if (_controller.hasListener) _controller.add(event);
  }

  /// Subscribe to log events.
  Stream<LogEvent> get stream => _controller.stream;
}
