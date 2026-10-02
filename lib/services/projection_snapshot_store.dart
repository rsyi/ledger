/// App-side reader for the nightly APPEND-ONLY `projection_snapshots`
/// tab (frozen phase projections — projection_snapshot.dart). Direct
/// Sheets read, same service-account pattern + cache as
/// ForecastMetaStore: the tab has no ViewSchema and lives outside the
/// engine ledger. Read-only in-app — only tool/program_status_update.dart
/// appends to it. Every failure degrades to the cached copy or null (the
/// pages then show the live model line labelled "no frozen projection
/// yet").
library;

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

import 'projection_snapshot.dart';

class ProjectionSnapshotStore {
  ProjectionSnapshotStore({
    required this.spreadsheetId,
    required this.serviceAccountKeyJson,
  }) : _fixed = null;

  /// In-memory store (tests / offline fixtures): [load] returns
  /// [snapshots] and never touches the network.
  ProjectionSnapshotStore.memory(List<ProjectionSnapshot> snapshots)
    : spreadsheetId = '',
      serviceAccountKeyJson = '',
      _fixed = snapshots;

  final List<ProjectionSnapshot>? _fixed;

  final String spreadsheetId;
  final String serviceAccountKeyJson;

  /// Snapshots change at most once per block — a long cache is safe.
  static const cacheTtl = Duration(minutes: 30);

  List<ProjectionSnapshot>? _cached;
  DateTime? _cachedAt;

  Future<List<ProjectionSnapshot>?> load({bool force = false}) async {
    if (_fixed != null) return _fixed;
    final at = _cachedAt;
    if (!force &&
        _cached != null &&
        at != null &&
        DateTime.now().difference(at) < cacheTtl) {
      return _cached;
    }
    try {
      final client = await clientViaServiceAccount(
        ServiceAccountCredentials.fromJson(serviceAccountKeyJson),
        [sheets.SheetsApi.spreadsheetsReadonlyScope],
      );
      try {
        final api = sheets.SheetsApi(client);
        final resp = await api.spreadsheets.values.get(
          spreadsheetId,
          "'$projectionSnapshotsTabName'",
        );
        final out = parseProjectionSnapshots(resp.values ?? const []);
        _cached = out;
        _cachedAt = DateTime.now();
        return out;
      } finally {
        client.close();
      }
    } catch (_) {
      // Missing tab / offline: cached copy if any, else null.
      return _cached;
    }
  }
}
