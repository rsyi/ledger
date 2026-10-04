/// App-side holder for the synced settings (`app_settings` tab —
/// app_settings_tab.dart). The week start resolves through
/// [effectiveWeekStart] everywhere in the app: the synced setting, else
/// program.yaml's `week_start`, else Monday (week_start.dart).
///
/// Offline-first: the last value read/written is cached in
/// SharedPreferences and loaded at bootstrap BEFORE anything plans a
/// week; [refresh] then re-reads the tab in the background and notifies
/// [weekStartSetting] listeners (home screen → re-plan + rebuild) when
/// it changed elsewhere (another device, a tool run).
library;

import 'package:flutter/foundation.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings_tab.dart';
import 'google_auth/sheets_auth.dart';
import 'program_current.dart' show currentVersion;
import 'week_start.dart';

class AppSettings {
  AppSettings._();

  /// The synced week-start setting's RAW value ('saturday'), or null when
  /// unset. Process-wide: every week computation reads it through
  /// [effectiveWeekStart].
  static final weekStartSetting = ValueNotifier<String?>(null);

  static const _prefsKey = 'app_settings.week_start';

  static String? _spreadsheetId;
  static SheetsAuth? _auth;

  /// Wires the Sheets backing store (bootstrap) and loads the cached
  /// value. Never throws.
  static Future<void> init({
    required String spreadsheetId,
    required SheetsAuth auth,
  }) async {
    _spreadsheetId = spreadsheetId;
    _auth = auth;
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefsKey);
      if (v != null && v.isNotEmpty) weekStartSetting.value = v;
    } catch (_) {/* no cache: program default until refresh */}
  }

  static Future<T> _withApi<T>(
      Future<T> Function(sheets.SheetsApi api, String id) fn) async {
    final id = _spreadsheetId, auth = _auth;
    if (id == null || id.isEmpty || auth == null) {
      throw StateError('AppSettings not initialized');
    }
    return auth.withApi((api) => fn(api, id));
  }

  static Future<void> _cache(String? v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (v == null || v.isEmpty) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, v);
      }
    } catch (_) {}
  }

  /// Re-reads the tab; updates (and notifies) when the value changed.
  /// Returns whether it changed. Offline/missing tab → false, the cached
  /// value stays.
  static Future<bool> refresh() async {
    try {
      final all = await _withApi((api, id) => readAppSettings(api, id));
      final raw = all[weekStartSettingKey];
      final v = raw == null || raw.isEmpty ? null : raw;
      if (v == weekStartSetting.value) return false;
      await _cache(v);
      weekStartSetting.value = v;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Writes the week start ([day] = `DateTime.monday..sunday`) to the
  /// synced tab, then caches + notifies. Throws on a failed write (the
  /// Settings screen reports it; nothing changes locally).
  static Future<void> setWeekStart(int day) async {
    final v = weekdayKey(day);
    final w = debugWriter;
    if (w != null) {
      await w(weekStartSettingKey, v);
    } else {
      await _withApi(
          (api, id) => writeAppSetting(api, id, weekStartSettingKey, v));
    }
    await _cache(v);
    weekStartSetting.value = v;
  }

  /// Test seam: replaces the Sheets write in [setWeekStart].
  @visibleForTesting
  static Future<void> Function(String key, String value)? debugWriter;

  /// Test seam: sets the in-memory value without IO.
  @visibleForTesting
  static void debugSet(String? v) => weekStartSetting.value = v;
}

/// The program default seen last (`week_start` of the last non-null
/// program passed to [effectiveWeekStart]) — so a caller with no program
/// at hand (coach chat undo, the proposal card) still honors it.
Map<Object?, Object?>? _lastProgramVersion;

/// Test seam: forgets the last-seen program default.
@visibleForTesting
void debugForgetProgramDefault() => _lastProgramVersion = null;

/// The effective week start for [program] (its current version's
/// `week_start` is the default; null program → the last one seen) +
/// where it came from.
({int day, WeekStartSource source}) effectiveWeekStart(
    Map<Object?, Object?>? program) {
  final v = currentVersion(program);
  if (v != null) _lastProgramVersion = {'week_start': v['week_start']};
  return resolveWeekStart(
    setting: AppSettings.weekStartSetting.value,
    programVersion: v ?? _lastProgramVersion,
  );
}

/// [effectiveWeekStart]'s day.
int effectiveWeekStartDay(Map<Object?, Object?>? program) =>
    effectiveWeekStart(program).day;
