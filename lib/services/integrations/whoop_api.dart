/// Whoop API → `recovery` view (objective sleep + recovery) integration.
///
/// DISTINCT from the BLE live-HR `WhoopIntegration` in whoop.dart — that
/// one streams the Heart Rate Broadcast (0x180D) during workouts and
/// writes zone stamps. THIS one is a background-pull (Withings pattern):
/// OAuth2 authorization-code against the Whoop developer API, tokens in
/// secure storage with a refresh flow, and a rolling-window pull that
/// maps each night's sleep + each day's recovery onto its OWN `recovery`
/// view (one row/day, match-by-date ingest), OWNING all the objective
/// device fields (sleep_hours / sleep_performance_pct /
/// sleep_efficiency_pct / sleep_consistency_pct / recovery_score /
/// hrv_ms / resting_hr / respiratory_rate) while leaving the free-text
/// `notes` to the user (fill-if-blank).
///
/// HISTORY (2026-09-30): this integration used to write into daily_notes,
/// bucketing sleep% → sleep_quality 1-5 and recovery% → readiness 1-5.
/// Per the user directive ("Whoop sleep/recovery should be its own sheet
/// like climbing/weight/meals"), it now owns a first-class `recovery`
/// sheet and stores the RAW %/scores (richer + honest); daily_notes keeps
/// its MANUAL recovery subjectives for hand-journaling. Any sleep values
/// the OLD build left in daily_notes are harmless leftovers — not
/// migrated, and no longer touched here.
library;

import 'dart:convert';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../app_config.dart' show WhoopApiConfig;
import '../../ui/oauth_webview_screen.dart';
import 'integration.dart';

const _kAuthorizeUrl = 'https://api.prod.whoop.com/oauth/oauth2/auth';
const _kTokenUrl = 'https://api.prod.whoop.com/oauth/oauth2/token';
const _kSleepUrl = 'https://api.prod.whoop.com/developer/v2/activity/sleep';
const _kRecoveryUrl = 'https://api.prod.whoop.com/developer/v2/recovery';
const _kRedirectUri = 'ledger://oauth/whoop';
// offline → refresh token; read scopes for the three record types.
const _kScope = 'read:sleep read:recovery read:cycles offline';

const _kMinPullInterval = Duration(hours: 6);
const _kFirstPullWindow = Duration(days: 30);
const _kRollingWindow = Duration(days: 14);

// ---------------------------------------------------------------------------
// Pure transforms (TDD'd in test/whoop_api_transform_test.dart).
// ---------------------------------------------------------------------------

/// Transform Whoop v2 sleep records into partial `recovery` ingest
/// records keyed on the WAKE date (the sleep `end`'s local day). Naps
/// and score-less (in-progress / pending) records are skipped. One row
/// per wake-date; the latest-ending night wins a collision.
///
/// Record shape (v2 /activity/sleep): {id, nap: bool, start, end,
/// score: {sleep_performance_percentage, sleep_efficiency_percentage,
/// sleep_consistency_percentage, respiratory_rate, stage_summary:
/// {total_in_bed_time_milli, total_awake_time_milli}}}. Sleep-hours =
/// (in-bed − awake) ms → hours, 1dp. All %/scores stored RAW.
List<Map<String, dynamic>> whoopSleepToRecovery(List<dynamic> records) {
  final byDay = <String, Map<String, dynamic>>{};
  final endByDay = <String, int>{};
  for (final s in records) {
    if (s is! Map) continue;
    if (s['nap'] == true) continue;
    final score = s['score'];
    if (score is! Map) continue; // no score → in-progress / pending
    final endStr = s['end'] as String?;
    if (endStr == null) continue;
    final end = DateTime.tryParse(endStr);
    if (end == null) continue;
    // Trust the timestamp's own date portion as the wake day (Whoop
    // stamps in UTC; converting to the device's local zone would shove
    // an early-morning wake back a calendar day — the Kaya Z-suffix
    // convention). Compare instants via the parsed ms for latest-wins.
    final day = _isoDate(end.toUtc());
    final endMs = end.millisecondsSinceEpoch;
    final existing = endByDay[day];
    if (existing != null && existing >= endMs) continue; // latest wins

    final stage = score['stage_summary'];
    double? hours;
    if (stage is Map) {
      final inBed = (stage['total_in_bed_time_milli'] as num?)?.toDouble();
      final awake =
          (stage['total_awake_time_milli'] as num?)?.toDouble() ?? 0;
      if (inBed != null) {
        hours = _round1((inBed - awake) / 3600000.0);
      }
    }

    final rec = <String, dynamic>{
      'date': {'kind': 'date', 'value': day},
      if (hours != null) 'sleep_hours': _float(hours),
      ..._num(score, 'sleep_performance_percentage', 'sleep_performance_pct'),
      ..._num(score, 'sleep_efficiency_percentage', 'sleep_efficiency_pct'),
      ..._num(score, 'sleep_consistency_percentage', 'sleep_consistency_pct'),
      // Whoop attaches respiratory_rate to the sleep score.
      ..._num(score, 'respiratory_rate', 'respiratory_rate'),
    };
    byDay[day] = rec;
    endByDay[day] = endMs;
  }
  final days = byDay.keys.toList()..sort();
  return [for (final d in days) byDay[d]!];
}

/// Transform Whoop v2 recovery records into a day → objective-fields map,
/// keyed on the recovery's `created_at` local day. Score-less records are
/// skipped. Later `created_at` wins a same-day collision. Fields:
/// recovery_score, hrv_ms (hrv_rmssd_milli), resting_hr
/// (resting_heart_rate).
Map<String, Map<String, dynamic>> whoopRecoveryFields(List<dynamic> records) {
  final out = <String, Map<String, dynamic>>{};
  final atByDay = <String, int>{};
  for (final r in records) {
    if (r is! Map) continue;
    final score = r['score'];
    if (score is! Map) continue;
    if (score['recovery_score'] == null) continue;
    final createdStr = (r['created_at'] ?? r['updated_at']) as String?;
    if (createdStr == null) continue;
    final created = DateTime.tryParse(createdStr);
    if (created == null) continue;
    final ms = created.millisecondsSinceEpoch;
    final day = _isoDate(created.toUtc());
    final existing = atByDay[day];
    if (existing != null && existing >= ms) continue;
    out[day] = <String, dynamic>{
      ..._num(score, 'recovery_score', 'recovery_score'),
      ..._num(score, 'hrv_rmssd_milli', 'hrv_ms'),
      ..._num(score, 'resting_heart_rate', 'resting_hr'),
    };
    atByDay[day] = ms;
  }
  return out;
}

/// Fold the recovery-by-day fields into the sleep records (matched on the
/// same `recovery` date), producing the final ingest record list. A
/// recovery day with no matching sleep still yields a row (recovery
/// fields only). Output sorted by date.
List<Map<String, dynamic>> whoopMergeRecovery({
  required List<Map<String, dynamic>> sleep,
  required Map<String, Map<String, dynamic>> recovery,
}) {
  final byDay = <String, Map<String, dynamic>>{};
  for (final s in sleep) {
    final day = ((s['date'] as Map)['value']) as String;
    byDay[day] = Map<String, dynamic>.from(s);
  }
  recovery.forEach((day, fields) {
    final rec = byDay.putIfAbsent(
        day, () => {'date': {'kind': 'date', 'value': day}});
    rec.addAll(fields);
  });
  final days = byDay.keys.toList()..sort();
  return [for (final d in days) byDay[d]!];
}

/// Read a numeric field off a Whoop `score` map under [srcKey] and emit
/// it (as an engine float cell) under [dstKey]. Absent/non-numeric →
/// nothing (omit-don't-clear).
Map<String, dynamic> _num(Map score, String srcKey, String dstKey) {
  final v = score[srcKey];
  if (v is num) return {dstKey: _float(v.toDouble())};
  return const {};
}

Map<String, dynamic> _float(double v) => {'kind': 'float', 'value': v};

double _round1(double v) => (v * 10).roundToDouble() / 10;

String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------------------
// Integration.
// ---------------------------------------------------------------------------

class WhoopApiIntegration implements Integration {
  WhoopApiIntegration({
    required this.config,
    required this.repo,
    required this.recoveryViewJson,
  });

  final WhoopApiConfig? config;
  final EngineLedgerRepository repo;

  /// Engine JSON of the `recovery` view (with date_field applied).
  final Map<String, dynamic> recoveryViewJson;

  static const _storage = FlutterSecureStorage();
  static const _kAccess = 'whoop_api_access';
  static const _kRefresh = 'whoop_api_refresh';
  static const _kExpiry = 'whoop_api_expiry';

  // Ledger-meta keys (shared source of truth with the page).
  static const _kLastPull = 'integration_whoop_api_last_pull';
  static const _kStatus = 'integration_whoop_api_status';
  static const _kError = 'integration_whoop_api_error';
  static const _kDays = 'integration_whoop_api_days';

  // All objective device fields are owned; the free-text note stays
  // user-owned (fill-if-blank).
  static const _ownedFields = [
    'sleep_hours',
    'sleep_performance_pct',
    'sleep_efficiency_pct',
    'sleep_consistency_pct',
    'recovery_score',
    'hrv_ms',
    'resting_hr',
    'respiratory_rate',
  ];

  @override
  String get id => 'whoop_api';
  @override
  String get displayName => 'Whoop (sleep + recovery)';
  @override
  String get targetDescription => '→ recovery';
  @override
  bool get isConfigured => config?.isConfigured ?? false;

  @override
  Future<bool> get isConnected async =>
      (await _storage.read(key: _kRefresh)) != null;

  @override
  Future<String> get statusLine async {
    if (!isConfigured) {
      return 'Set WHOOP_CLIENT_ID / _SECRET in .env and rebrand';
    }
    if (!await isConnected) return 'Not connected';
    final status = await repo.metaGet(_kStatus);
    if (status == 'reconnect') return 'Reconnect needed';
    if (status == 'error') {
      final e = await repo.metaGet(_kError) ?? 'unknown';
      return 'Error: $e';
    }
    final last = await repo.metaGet(_kLastPull);
    final nights = _decodeDays(await repo.metaGet(_kDays)).length;
    final when = last == null
        ? 'never'
        : DateTime.tryParse(last)?.toLocal().toString().substring(11, 16) ??
            last;
    return 'Connected · last pulled $when · $nights night(s) synced';
  }

  @override
  Map<String, Future<void> Function(BuildContext)> get extraMenuActions =>
      const {};

  @override
  Future<void> connect(BuildContext context) async {
    final cfg = config;
    if (cfg == null || !cfg.isConfigured) return;
    final state = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final url = Uri.parse(_kAuthorizeUrl).replace(queryParameters: {
      'response_type': 'code',
      'client_id': cfg.clientId,
      'scope': _kScope,
      'redirect_uri': _kRedirectUri,
      'state': state,
    });
    // In-app WebView, not a Custom Tab: intercept the custom-scheme
    // callback navigation ourselves (Withings pattern).
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => OAuthWebViewScreen(
          title: 'Connect Whoop',
          authorizeUrl: url,
          callbackScheme: 'ledger',
        ),
      ),
    );
    if (result == null) return; // user backed out
    final back = Uri.parse(result);
    if (back.queryParameters['state'] != state) {
      throw StateError('whoop oauth: state mismatch');
    }
    final code = back.queryParameters['code'];
    if (code == null) {
      throw StateError('whoop oauth: no code in callback');
    }
    final body = await _tokenRequest({
      'grant_type': 'authorization_code',
      'client_id': cfg.clientId,
      'client_secret': cfg.clientSecret,
      'code': code,
      'redirect_uri': _kRedirectUri,
    });
    await _storeTokens(body);
    await repo.metaSet(_kStatus, 'ok');
    // First pull = 30-day backfill; don't block the UI on it.
    // ignore: unawaited_futures
    pull(force: true);
  }

  @override
  Future<void> disconnect() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kExpiry);
    await repo.metaSet(_kStatus, '');
    await repo.metaSet(_kError, '');
    // _kDays intentionally kept: reconnect stays consistent with the
    // provenance the engine still holds.
  }

  @override
  Future<void> pull({bool force = false, bool fullReconcile = false}) async {
    if (!isConfigured || !await isConnected) return;
    try {
      if (!force) {
        final last = await repo.metaGet(_kLastPull);
        final lastAt = last == null ? null : DateTime.tryParse(last);
        if (lastAt != null &&
            DateTime.now().difference(lastAt) < _kMinPullInterval) {
          return;
        }
      }
      final token = await _freshAccessToken();
      if (token == null) return; // reconnect status already set

      // Window: first pull (no days yet) sweeps 30d, then rolling 14d.
      final now = DateTime.now();
      final known = _decodeDays(await repo.metaGet(_kDays));
      final window = (force && known.isEmpty) || fullReconcile
          ? _kFirstPullWindow
          : _kRollingWindow;
      final start = now.subtract(window).toUtc().toIso8601String();
      final end = now.toUtc().toIso8601String();

      final sleepRecs = await _getAll(_kSleepUrl, token, start, end);
      final recoveryRecs = await _getAll(_kRecoveryUrl, token, start, end);

      final records = whoopMergeRecovery(
        sleep: whoopSleepToRecovery(sleepRecs),
        recovery: whoopRecoveryFields(recoveryRecs),
      );

      if (records.isNotEmpty) {
        // match-by-date (no match_field) — one recovery row per day.
        // notes stays fill-if-blank so a manual note is never
        // overwritten by an empty Whoop pull.
        await repo.ingest(recoveryViewJson, {
          'source': 'whoop_api',
          'owned_fields': _ownedFields,
          'fill_if_blank_fields': const ['notes'],
          'records': records,
        });
        for (final r in records) {
          known.add(((r['date'] as Map)['value']) as String);
        }
        await repo.metaSet(_kDays, jsonEncode(known.toList()..sort()));
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

  Set<String> _decodeDays(String? json) {
    if (json == null || json.isEmpty) return <String>{};
    final decoded = jsonDecode(json);
    return decoded is List ? decoded.cast<String>().toSet() : <String>{};
  }

  /// Whoop v2 collections paginate via `next_token`; walk to exhaustion
  /// (windows are ≤30d so this is a handful of pages at most).
  Future<List<dynamic>> _getAll(
      String base, String token, String start, String end) async {
    final out = <dynamic>[];
    String? next;
    do {
      final params = <String, String>{
        'start': start,
        'end': end,
        'limit': '25',
      };
      if (next != null) params['nextToken'] = next;
      final url = Uri.parse(base).replace(queryParameters: params);
      final resp = await http.get(url, headers: {
        'Authorization': 'Bearer $token',
      });
      if (resp.statusCode != 200) {
        throw StateError('whoop $base: ${resp.statusCode} ${resp.body}');
      }
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final records = decoded['records'];
      if (records is List) out.addAll(records);
      next = decoded['next_token'] as String?;
    } while (next != null && next.isNotEmpty);
    return out;
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> form) async {
    final resp = await http.post(
      Uri.parse(_kTokenUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: form,
    );
    if (resp.statusCode != 200) {
      throw StateError('whoop token: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> _storeTokens(Map<String, dynamic> body) async {
    await _storage.write(key: _kAccess, value: body['access_token'] as String);
    final refresh = body['refresh_token'];
    if (refresh is String) {
      await _storage.write(key: _kRefresh, value: refresh);
    }
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 3600;
    await _storage.write(
      key: _kExpiry,
      value: DateTime.now()
          .add(Duration(seconds: expiresIn))
          .toIso8601String(),
    );
  }

  Future<String?> _freshAccessToken() async {
    final expiry = await _storage.read(key: _kExpiry);
    final access = await _storage.read(key: _kAccess);
    final expiresAt = expiry == null ? null : DateTime.tryParse(expiry);
    if (access != null &&
        expiresAt != null &&
        expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return access;
    }
    final refresh = await _storage.read(key: _kRefresh);
    final cfg = config;
    if (refresh == null || cfg == null) return null;
    try {
      final body = await _tokenRequest({
        'grant_type': 'refresh_token',
        'client_id': cfg.clientId,
        'client_secret': cfg.clientSecret,
        'refresh_token': refresh,
        'scope': _kScope,
      });
      await _storeTokens(body);
      return body['access_token'] as String;
    } catch (_) {
      await repo.metaSet(_kStatus, 'reconnect');
      return null;
    }
  }
}
