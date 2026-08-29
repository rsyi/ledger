import 'package:flutter/widgets.dart';

/// One connectable external source. Implementations own auth, pull,
/// transform, and reconcile; they funnel all writes through
/// `EngineLedgerRepository.ingest` and keep status/cursors in ledger
/// meta under `integration_<id>_*` keys, so the page and the engine
/// share one source of truth.
abstract class Integration {
  String get id; // 'withings'
  String get displayName; // 'Withings'
  String get targetDescription; // '→ weight'

  /// False when the build lacks credentials (e.g. .env placeholders);
  /// the card shows a setup hint instead of Connect.
  bool get isConfigured;

  Future<bool> get isConnected;

  /// One-line human status for the card: 'Not connected',
  /// 'Connected · last pulled 08:12 · 143 days synced',
  /// 'Reconnect needed', 'Error: …'.
  Future<String> get statusLine;

  /// Run the interactive auth flow.
  Future<void> connect(BuildContext context);

  /// Drop tokens + cursor so pulls stop. Provenance stays, so a later
  /// reconnect remains consistent with what was already ingested.
  Future<void> disconnect();

  /// Pull new data and ingest. [force] bypasses the per-source
  /// minimum interval; [fullReconcile] sweeps all history for
  /// deletions instead of the rolling window. Must never throw —
  /// failures land in the status meta and retry next trigger.
  Future<void> pull({bool force = false, bool fullReconcile = false});
}
