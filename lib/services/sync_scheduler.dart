/// Background sync driver for the local-first ledger.
///
/// Triggers a sync when:
///  - the app starts (after bootstrap),
///  - the app returns to the foreground,
///  - ~5 s after any local write (debounced),
///  - connectivity appears while local changes are pending.
///
/// Every trigger is gated by the `Sync on Wi-Fi only` setting
/// (default ON): with it on, cellular-only connectivity means the
/// sync is skipped and retried at the next trigger. A manual
/// "Sync now" bypasses the gate — explicit user intent.
///
/// One sync at a time; triggers during a running sync are dropped
/// (the running sync already covers their changes, and dirty rows
/// survive failures for the next round).
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_ledger_connector.dart';

class SyncScheduler with WidgetsBindingObserver {
  SyncScheduler._(this._ledger, this._viewsJson, this._prefs);

  /// Singleton, set by [init]. Null when local-first is disabled.
  static SyncScheduler? instance;

  static const _wifiOnlyKey = 'sync_on_wifi_only';
  static const _debounceDelay = Duration(seconds: 5);

  final EngineLedgerConnector _ledger;
  final List<Map<String, dynamic>> _viewsJson;
  final SharedPreferences _prefs;

  /// Observable sync state for the status button.
  final ValueNotifier<bool> syncing = ValueNotifier(false);
  final ValueNotifier<int> pending = ValueNotifier(0);
  final ValueNotifier<DateTime?> lastSync = ValueNotifier(null);
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  Timer? _debounce;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  bool get wifiOnly => _prefs.getBool(_wifiOnlyKey) ?? true;

  Future<void> setWifiOnly(bool value) async {
    await _prefs.setBool(_wifiOnlyKey, value);
    if (!value) maybeSync(); // gate just loosened — try now
  }

  /// Build + register the singleton and fire the app-start sync.
  static Future<SyncScheduler> init({
    required EngineLedgerConnector ledger,
    required List<Map<String, dynamic>> viewsJson,
  }) async {
    // Re-init (hot reload / manual refresh): tear the old one down.
    instance?.dispose();
    final prefs = await SharedPreferences.getInstance();
    final s = SyncScheduler._(ledger, viewsJson, prefs);
    WidgetsBinding.instance.addObserver(s);
    s._connSub = Connectivity()
        .onConnectivityChanged
        .listen(s._onConnectivityChanged);
    instance = s;
    await s.refreshPending();
    s.maybeSync(); // app-start trigger (fire and forget)
    return s;
  }

  void dispose() {
    _debounce?.cancel();
    _connSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (identical(instance, this)) instance = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) maybeSync();
  }

  /// Called by the connector after every create/update/delete.
  void onLocalWrite() {
    refreshPending();
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, maybeSync);
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (pending.value > 0 && _allowedBy(results)) maybeSync();
  }

  Future<void> refreshPending() async {
    try {
      pending.value = await _ledger.repo.pending();
    } catch (_) {/* store errors surface on the next real op */}
  }

  bool _allowedBy(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.none)) return false;
    if (!wifiOnly) return true;
    return results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
  }

  /// Run a sync if the connectivity gate allows. [manual] bypasses
  /// the wifi-only gate. No-op while a sync is already running.
  Future<void> maybeSync({bool manual = false}) async {
    if (syncing.value) return;
    if (!manual) {
      final results = await Connectivity().checkConnectivity();
      if (!_allowedBy(results)) return;
    }
    syncing.value = true;
    try {
      final results = await _ledger.repo.sync(_viewsJson);
      final errors = results
          .map((r) => r['error'])
          .whereType<String>()
          .toList();
      lastError.value = errors.isEmpty ? null : errors.join('; ');
      lastSync.value = DateTime.now();
    } catch (e) {
      // Input-shape / transport-level failure: keep dirty rows, note
      // the error, retry at the next trigger.
      lastError.value = e.toString();
    } finally {
      syncing.value = false;
      await refreshPending();
    }
  }
}
