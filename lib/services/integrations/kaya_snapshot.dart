/// Kaya snapshot indicator — a read-only Integrations card.
///
/// The user's climbing data deliberately does NOT sync into the ledger:
/// it lives in the `kaya_ascents` sheet tab (written by the ledger
/// repo's tool/kaya_import.dart from Kaya's CSV export) purely so the
/// MCP worker can serve it to Claude. This integration exists to make
/// that state visible in the app — count + latest ascent straight from
/// the tab — not to move any data. `isConfigured` is false on purpose:
/// the card then renders with no Connect/Sync buttons at all.
library;

import 'package:flutter/widgets.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

import 'integration.dart';

const _kTab = 'kaya_ascents';
const _kStatusTtl = Duration(minutes: 10);

/// Renders the snapshot state from the raw tab rows (header + data).
/// Null/empty rows means the tab doesn't exist yet (never imported).
String kayaSnapshotStatus(List<List<Object?>>? rows) {
  if (rows == null || rows.isEmpty) {
    return 'No snapshot yet — Export Logbook in Kaya, then kaya_import';
  }
  final headers = rows.first.map((h) => '$h'.trim().toLowerCase()).toList();
  final dateCol = headers.indexOf('date');
  final count = rows.length - 1;
  String? latest;
  if (dateCol >= 0) {
    for (final r in rows.skip(1)) {
      final v = dateCol < r.length ? '${r[dateCol]}'.trim() : '';
      if (DateTime.tryParse(v) == null) continue;
      if (latest == null || v.compareTo(latest) > 0) latest = v;
    }
  }
  return [
    'Snapshot',
    '$count ascents',
    if (latest != null) 'latest $latest',
    'refresh: export in Kaya',
  ].join(' · ');
}

class KayaSnapshotIntegration implements Integration {
  KayaSnapshotIntegration({
    required this.spreadsheetId,
    required this.serviceAccountKeyJson,
  });

  final String spreadsheetId;
  final String serviceAccountKeyJson;

  String? _cachedStatus;
  DateTime? _cachedAt;

  @override
  String get id => 'kaya_snapshot';
  @override
  String get displayName => 'Kaya';
  @override
  String get targetDescription => '→ Claude (MCP snapshot)';

  /// False so the card is display-only: no Connect, no Sync, no menu.
  /// There is nothing to configure — the data flow runs outside the app.
  @override
  bool get isConfigured => false;

  @override
  Future<bool> get isConnected async => false;

  @override
  Future<String> get statusLine async {
    final at = _cachedAt;
    if (_cachedStatus != null &&
        at != null &&
        DateTime.now().difference(at) < _kStatusTtl) {
      return _cachedStatus!;
    }
    try {
      final client = await clientViaServiceAccount(
        ServiceAccountCredentials.fromJson(serviceAccountKeyJson),
        [sheets.SheetsApi.spreadsheetsReadonlyScope],
      );
      try {
        final api = sheets.SheetsApi(client);
        final resp =
            await api.spreadsheets.values.get(spreadsheetId, "'$_kTab'");
        _cachedStatus = kayaSnapshotStatus(resp.values);
      } finally {
        client.close();
      }
    } catch (e) {
      // A 400 means the tab doesn't exist (never imported); anything
      // else is a transient fetch problem — show it, don't cache it.
      final s = '$e';
      if (s.contains('Unable to parse range')) {
        _cachedStatus = kayaSnapshotStatus(null);
      } else {
        return 'Snapshot status unavailable: $e';
      }
    }
    _cachedAt = DateTime.now();
    return _cachedStatus!;
  }

  @override
  Map<String, Future<void> Function(BuildContext)> get extraMenuActions =>
      const {};

  @override
  Future<void> connect(BuildContext context) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> pull({bool force = false, bool fullReconcile = false}) async {}
}
