/// App-side reader for the nightly `forecast_meta` tab (forecast
/// recalibration state — see forecast_calibration.dart). Direct Sheets
/// read, same service-account pattern as WmStore: the tab has no
/// ViewSchema and lives outside the engine ledger. Read-only in-app —
/// only tool/program_status_update.dart writes it (REPLACE-ALL
/// nightly). Cached briefly; every failure degrades to the cached copy
/// or null (the Plan tab then shows "model tracking: on" with no
/// adjustment applied — the honest default).
library;

import 'package:googleapis/sheets/v4.dart' as sheets;

import 'google_auth/sheets_auth.dart';
import 'swr_cache.dart';

import 'forecast_calibration.dart';

class ForecastMetaStore {
  ForecastMetaStore({required this.spreadsheetId, required this.auth});

  final String spreadsheetId;

  /// Service account (owner build) or the user's Google token.
  final SheetsAuth auth;

  static const cacheTtl = Duration(minutes: 15);

  final SwrCache<ForecastMeta> _cache = SwrCache(
    name: 'forecast_meta',
    ttl: cacheTtl,
  );

  /// STALE-WHILE-REVALIDATE (perf #8): fresh → cached; stale → last-good
  /// immediately + one background refresh; [force] awaits fresh. Every
  /// failure degrades to the cached copy or null.
  Future<ForecastMeta?> load({bool force = false}) async {
    return _cache.get(_fetch, force: force);
  }

  Future<ForecastMeta> _fetch() async {
    final client = await auth.client(readOnly: true);
    try {
      final api = sheets.SheetsApi(client);
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        "'$forecastMetaTabName'",
      );
      final meta = ForecastMeta.fromTab(resp.values ?? const []);
      return meta;
    } finally {
      client.close();
    }
  }
}
