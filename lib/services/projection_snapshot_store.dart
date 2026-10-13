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

import 'google_auth/sheets_auth.dart';
import 'swr_cache.dart';

import 'projection_snapshot.dart';

class ProjectionSnapshotStore {
  ProjectionSnapshotStore({
    required this.spreadsheetId,
    required SheetsAuth this.auth,
  }) : _fixed = null;

  /// In-memory store (tests / offline fixtures): [load] returns
  /// [snapshots] and never touches the network.
  ProjectionSnapshotStore.memory(List<ProjectionSnapshot> snapshots)
    : spreadsheetId = '',
      auth = null,
      _fixed = snapshots;

  final List<ProjectionSnapshot>? _fixed;

  final String spreadsheetId;

  /// Service account (owner build) or the user's Google token; null only
  /// for the in-memory store.
  final SheetsAuth? auth;

  /// Snapshots change at most once per block — a long cache is safe.
  static const cacheTtl = Duration(minutes: 30);

  /// Raw tab cells (persisted — perf batch 3) + the parsed snapshots.
  late final SwrCache<
      ({List<List<Object?>> raw, List<ProjectionSnapshot> parsed})> _cache =
      SwrCache(
    name: 'projection_store',
    ttl: cacheTtl,
    persist: SwrPersist(
      key: 'projection_store|$spreadsheetId',
      encode: (v) => v.raw,
      decode: (j) {
        final raw = [
          for (final r in (j as List)) (r as List).cast<Object?>(),
        ];
        return (raw: raw, parsed: parseProjectionSnapshots(raw));
      },
    ),
  );

  /// STALE-WHILE-REVALIDATE (perf #8): fresh → cached; stale → last-good
  /// immediately + one background refresh; [force] awaits fresh. Every
  /// failure degrades to the cached copy or null.
  Future<List<ProjectionSnapshot>?> load({bool force = false}) async {
    if (_fixed != null) return _fixed;
    return (await _cache.get(_fetch, force: force))?.parsed;
  }

  Future<({List<List<Object?>> raw, List<ProjectionSnapshot> parsed})>
      _fetch() async {
    final client = await auth!.client(readOnly: true);
    try {
      final api = sheets.SheetsApi(client);
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        "'$projectionSnapshotsTabName'",
      );
      final raw = [
        for (final r in resp.values ?? const <List<Object?>>[])
          r.cast<Object?>(),
      ];
      return (raw: raw, parsed: parseProjectionSnapshots(raw));
    } finally {
      client.close();
    }
  }
}
