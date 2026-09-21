/// Macrofactor → meals integration (via Android Health Connect).
///
/// Macrofactor has no API; it exports nutrition records to Health
/// Connect, which this integration reads through the injectable
/// [HealthConnectGateway] seam (real adapter:
/// `health_connect_gateway.dart`). Row-grained kaya pattern: one meals
/// row per HC nutrition record, ingested in match_field mode keyed on
/// `hc_id` (the HC record uuid), so re-pulls are idempotent and
/// hand-entered meals rows (blank hc_id) are invisible to the batch.
///
/// Windows: HC retains limited pre-grant history (reads reach at most
/// ~30 days before the permission grant), so the first pull sweeps 90
/// days (returns whatever HC allows) and later pulls reconcile a
/// rolling 14-day window. Deletions are diffed within the window only:
/// known ids (meta map hc_id → day) whose day falls inside the window
/// but that HC no longer returns become `deleted_ids`. The diff keys
/// on RAW wire uuids, never transform output, so a parse regression
/// reads as "row not updated", never "row deleted"; an empty fetch
/// against non-empty in-window baseline refuses to mass-delete unless
/// the user explicitly runs Full reconcile.
///
/// No source-app filter: whatever writes nutrition into HC lands in
/// meals. In practice Macrofactor is the only nutrition writer on this
/// device; filtering by package id would silently break on a
/// Macrofactor rename.
library;

import 'dart:convert';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/material.dart';

import 'health_connect_gateway.dart';
import 'integration.dart';

/// HC meal-type wire strings (health plugin constants) → meals
/// dropdown values. UNKNOWN and anything unrecognized is omitted.
const _kMealTypes = {
  'BREAKFAST': 'breakfast',
  'LUNCH': 'lunch',
  'DINNER': 'dinner',
  'SNACK': 'snack',
};

/// Transform gateway nutrition maps into engine ingest records tagged
/// with kind metadata. Malformed points (non-map, missing/empty uuid,
/// unparseable date_from) are silently dropped; wrong-typed fields
/// within an otherwise-valid point are omitted rather than crashing.
/// Duplicate uuids keep the first point (deterministic; ingest is
/// keyed by hc_id so later duplicates would be no-op updates anyway).
List<Map<String, dynamic>> hcNutritionToRecords(List<dynamic> points) {
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final raw in points) {
    if (raw is! Map) continue;
    final uuid = raw['uuid'];
    if (uuid == null) continue;
    final idStr = uuid.toString();
    if (idStr.isEmpty) continue;
    if (!seen.add(idStr)) continue;
    final eatenAt = hcDatetime(raw['date_from']);
    if (eatenAt == null) continue;

    final rec = <String, dynamic>{
      'hc_id': _str(idStr),
      'eaten_at': {'kind': 'date_time', 'value': eatenAt},
    };

    final mealTypeRaw = raw['meal_type'];
    final mealType =
        mealTypeRaw is String ? _kMealTypes[mealTypeRaw] : null;
    if (mealType != null) rec['meal_type'] = _str(mealType);

    // meal (the list title) is fill-if-blank: named foods use the HC
    // name; Macrofactor's unnamed exports fall back to a labeled slot
    // so the row is still legible. Users can rename without the source
    // stomping the edit.
    final nameRaw = raw['name'];
    final name = nameRaw is String && nameRaw.isNotEmpty ? nameRaw : null;
    rec['meal'] = _str(name ??
        (mealType != null ? 'Macrofactor $mealType' : 'Macrofactor entry'));

    // Macro columns (owned). Omit-don't-clear on wire drift: absent or
    // wrong-typed values are simply not emitted (no exclusive-pair
    // semantics here, unlike kaya's gym/location).
    void macro(String field, dynamic v) {
      if (v is num) {
        rec[field] = {'kind': 'float', 'value': _round1(v.toDouble())};
      }
    }

    macro('calories', raw['calories']);
    macro('protein_g', raw['protein']);
    macro('carbs_g', raw['carbs']);
    macro('fat_g', raw['fat']);

    result.add(rec);
  }
  return result;
}

/// Uuids of every point HC RETURNED, independent of whether the
/// transform could produce a record for it. The reconcile diff must
/// use this — never the transformed records — so a parse regression
/// reads as "row not updated", never "row deleted".
Set<String> hcFetchedIds(List<dynamic> points) {
  final result = <String>{};
  for (final raw in points) {
    if (raw is! Map) continue;
    final uuid = raw['uuid'];
    if (uuid == null) continue;
    final idStr = uuid.toString();
    if (idStr.isEmpty) continue;
    result.add(idStr);
  }
  return result;
}

/// Format a nutrition timestamp as the engine's naive-datetime string
/// (`yyyy-mm-ddThh:mm:ss`), or null if the value can't be interpreted.
/// Components are preserved as-is — no timezone conversion. The real
/// gateway hands over local DateTimes (plugin decodes epoch millis to
/// local), so the wall-clock meal time lands in `eaten_at`.
String? hcDatetime(dynamic v) {
  DateTime? dt;
  if (v is DateTime) dt = v;
  if (v is String) dt = DateTime.tryParse(v);
  if (dt == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-'
      '${two(dt.day)}T${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

/// Known ids whose recorded day falls inside the read window — the
/// only ids the deletion diff may consider (HC was never asked about
/// anything older). [dayById] is the meta map hc_id → `yyyy-mm-dd`;
/// ISO day strings compare correctly as plain strings.
Set<String> hcKnownIdsInWindow(
  Map<String, String> dayById, {
  required String windowStartDay,
}) {
  return {
    for (final e in dayById.entries)
      if (e.value.compareTo(windowStartDay) >= 0) e.key,
  };
}

/// Ids the ledger credits to Macrofactor that HC no longer returns for
/// the window — the `deleted_ids` for a reconcile batch. Sorted.
List<String> hcDeletedIds({
  required Set<String> fetchedIds,
  required Set<String> knownIdsInWindow,
}) {
  return (knownIdsInWindow.difference(fetchedIds).toList())..sort();
}

Map<String, dynamic> _str(String v) => {'kind': 'string', 'value': v};

double _round1(double v) => (v * 10).roundToDouble() / 10;

// ---------------------------------------------------------------------------
// Pull-loop constants
// ---------------------------------------------------------------------------

const _kMinPullInterval = Duration(hours: 6);
const _kFirstPullWindow = Duration(days: 90);
const _kReconcileWindow = Duration(days: 14);

// ---------------------------------------------------------------------------
// MacrofactorIntegration
// ---------------------------------------------------------------------------

class MacrofactorIntegration implements Integration {
  /// No app-level secrets (Health Connect grants are device-local
  /// system state), so [isConfigured] is always true — the card is
  /// always live. "Connected" is a ledger-meta flag set after a
  /// successful permission grant; pull() re-verifies the grant and
  /// degrades to 'reconnect' status if the user revoked it in HC.
  MacrofactorIntegration({
    required this.repo,
    required this.mealsViewJson,
    HealthConnectGateway? gateway,
  }) : gateway = gateway ?? HealthPluginGateway();

  final EngineLedgerRepository repo;

  /// Engine JSON of the meals view (with date_field applied).
  final Map<String, dynamic> mealsViewJson;

  final HealthConnectGateway gateway;

  // Ledger-meta keys (shared source of truth with the card).
  static const _kConnected = 'integration_macrofactor_connected';
  static const _kLastPull = 'integration_macrofactor_last_pull';
  static const _kStatus = 'integration_macrofactor_status';
  static const _kError = 'integration_macrofactor_error';

  /// JSON map hc_id → `yyyy-mm-dd` (day of the record). The day is
  /// what scopes the deletion diff to the read window.
  static const _kIdDays = 'integration_macrofactor_id_days';

  @override
  String get id => 'macrofactor';
  @override
  String get displayName => 'Macrofactor';
  @override
  String get targetDescription => '→ meals (via Health Connect)';
  @override
  bool get isConfigured => true;

  @override
  Future<bool> get isConnected async =>
      (await repo.metaGet(_kConnected)) == 'true';

  @override
  Future<String> get statusLine async {
    if (!await isConnected) return 'Not connected';
    final status = await repo.metaGet(_kStatus);
    if (status == 'reconnect') return 'Reconnect needed';
    if (status == 'error') {
      final e = await repo.metaGet(_kError) ?? 'unknown';
      return 'Error: $e';
    }
    final last = await repo.metaGet(_kLastPull);
    final count = _decodeIdDays(await repo.metaGet(_kIdDays)).length;
    final when = last == null
        ? 'never'
        : DateTime.tryParse(last)?.toLocal().toString().substring(11, 16) ??
            last;
    return 'Connected · last pulled $when · $count meal(s) synced';
  }

  @override
  Map<String, Future<void> Function(BuildContext)> get extraMenuActions =>
      const {};

  @override
  Future<void> connect(BuildContext context) async {
    final availability = await gateway.availability();
    if (availability != HcAvailability.available) {
      if (!context.mounted) return;
      final install = availability == HcAvailability.needsInstall;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Health Connect required'),
          content: Text(install
              ? 'Health Connect needs to be installed or updated before '
                  'Macrofactor data can be read. Install it, enable '
                  'Macrofactor’s Health Connect export, then connect '
                  'again.'
              : 'Health Connect is not available on this device.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Close'),
            ),
            if (install)
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Install'),
              ),
          ],
        ),
      );
      if (proceed == true) await gateway.installHealthConnect();
      return;
    }

    // System permission sheet (READ nutrition).
    final granted = await gateway.requestNutritionPermission();
    if (!granted) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nutrition access was not granted.'),
        ));
      }
      return;
    }

    await repo.metaSet(_kConnected, 'true');
    await repo.metaSet(_kStatus, 'ok');
    // First pull = 90-day backfill; don't block the UI on it.
    // ignore: unawaited_futures
    pull(force: true);
  }

  @override
  Future<void> disconnect() async {
    // The HC grant itself stays (it's system state the user manages in
    // Health Connect; revokePermissions() would drop ALL of this app's
    // HC grants). We just stop pulling.
    await repo.metaSet(_kConnected, '');
    await repo.metaSet(_kStatus, '');
    await repo.metaSet(_kError, '');
    // _kIdDays intentionally kept: reconnect stays consistent with the
    // provenance the engine still holds (mirrors Withings _kDays).
  }

  @override
  Future<void> pull({bool force = false, bool fullReconcile = false}) async {
    if (!await isConnected) return;
    try {
      if (!force) {
        final last = await repo.metaGet(_kLastPull);
        final lastAt = last == null ? null : DateTime.tryParse(last);
        if (lastAt != null &&
            DateTime.now().difference(lastAt) < _kMinPullInterval) {
          return;
        }
      }

      // Grant can be revoked from the Health Connect app at any time;
      // surface that as the reconnect state rather than a read error.
      if (!await gateway.hasNutritionPermission()) {
        await repo.metaSet(_kStatus, 'reconnect');
        return;
      }

      // ----------------------------------------------------------------
      // 1. Read the window. First pull sweeps 90 days (HC caps what it
      //    returns pre-grant); steady state reconciles a rolling 14
      //    days. End is padded a day so timezone edges never clip
      //    tonight's dinner.
      // ----------------------------------------------------------------
      final knownIdDays = _decodeIdDays(await repo.metaGet(_kIdDays));
      final firstPull =
          knownIdDays.isEmpty && await repo.metaGet(_kLastPull) == null;
      final now = DateTime.now();
      final windowStart = fullReconcile
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : now.subtract(
              firstPull ? _kFirstPullWindow : _kReconcileWindow);
      final points = await gateway.readNutrition(
          windowStart, now.add(const Duration(days: 1)));

      // ----------------------------------------------------------------
      // 2. Transform. fetchedIds uses RAW uuids, never derived from
      //    records, so a parse regression reads as "row not updated",
      //    never "row deleted".
      // ----------------------------------------------------------------
      final records = hcNutritionToRecords(points);
      final fetchedIds = hcFetchedIds(points);

      // ----------------------------------------------------------------
      // 3. Mass-drift guards.
      // ----------------------------------------------------------------
      // 3a. Points present but transform produced nothing → wire format
      //     changed; abort rather than mass-deleting rows.
      if (points.isNotEmpty && records.isEmpty) {
        await repo.metaSet(_kStatus, 'error');
        await repo.metaSet(
          _kError,
          'macrofactor: transform produced no records from '
          '${points.length} nutrition points (wire drift?)',
        );
        return;
      }

      final knownInWindow = hcKnownIdsInWindow(
        knownIdDays,
        windowStartDay: _isoDay(windowStart),
      );

      // 3b. HC returned nothing for a window we believe has rows —
      //     refuse mass-delete unless the user explicitly ran Full
      //     reconcile (the sanctioned path for a genuinely emptied log).
      if (!fullReconcile && fetchedIds.isEmpty && knownInWindow.isNotEmpty) {
        await repo.metaSet(_kStatus, 'error');
        await repo.metaSet(
          _kError,
          'macrofactor: Health Connect returned no nutrition for the '
          'window but ${knownInWindow.length} record(s) are known locally '
          '— refusing to mass-delete (run Full reconcile to force)',
        );
        return;
      }

      // ----------------------------------------------------------------
      // 4. Compute deletions and ingest.
      // ----------------------------------------------------------------
      final deleted = hcDeletedIds(
        fetchedIds: fetchedIds,
        knownIdsInWindow: knownInWindow,
      );

      if (records.isNotEmpty || deleted.isNotEmpty) {
        await repo.ingest(mealsViewJson, {
          'source': 'macrofactor',
          'match_field': 'hc_id',
          'owned_fields': [
            'hc_id',
            'eaten_at',
            'meal_type',
            'calories',
            'protein_g',
            'carbs_g',
            'fat_g',
          ],
          'fill_if_blank_fields': ['meal', 'notes'],
          'records': records,
          'deleted_ids': deleted,
        });
        for (final r in records) {
          final id = ((r['hc_id'] as Map)['value']) as String;
          final dt = ((r['eaten_at'] as Map)['value']) as String;
          knownIdDays[id] = dt.substring(0, 10);
        }
        for (final id in deleted) {
          knownIdDays.remove(id);
        }
        await repo.metaSet(_kIdDays, jsonEncode(knownIdDays));
      }

      await repo.metaSet(_kLastPull, DateTime.now().toIso8601String());
      await repo.metaSet(_kStatus, 'ok');
      await repo.metaSet(_kError, '');
    } catch (e) {
      await repo.metaSet(_kStatus, 'error');
      await repo.metaSet(_kError, e.toString());
    }
  }

  // ------------------------------------------------------ internals

  Map<String, String> _decodeIdDays(String? json) {
    if (json == null || json.isEmpty) return <String, String>{};
    final decoded = jsonDecode(json);
    return decoded is Map
        ? decoded.map((k, v) => MapEntry(k.toString(), v.toString()))
        : <String, String>{};
  }

  String _isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
