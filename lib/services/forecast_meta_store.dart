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
import 'package:googleapis_auth/auth_io.dart';

import 'forecast_calibration.dart';

class ForecastMetaStore {
  ForecastMetaStore({
    required this.spreadsheetId,
    required this.serviceAccountKeyJson,
  });

  final String spreadsheetId;
  final String serviceAccountKeyJson;

  static const cacheTtl = Duration(minutes: 15);

  ForecastMeta? _cached;
  DateTime? _cachedAt;

  Future<ForecastMeta?> load({bool force = false}) async {
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
          "'$forecastMetaTabName'",
        );
        final meta = ForecastMeta.fromTab(resp.values ?? const []);
        _cached = meta;
        _cachedAt = DateTime.now();
        return meta;
      } finally {
        client.close();
      }
    } catch (_) {
      // Missing tab / offline: cached copy if any, else null.
      return _cached;
    }
  }
}
