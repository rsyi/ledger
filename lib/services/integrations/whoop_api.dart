/// Whoop API → daily_notes (sleep + recovery) integration.
///
/// DISTINCT from the BLE live-HR `WhoopIntegration` in whoop.dart — that
/// one streams the Heart Rate Broadcast (0x180D) during workouts and
/// writes zone stamps. THIS one is a background-pull (Withings pattern):
/// OAuth2 authorization-code against the Whoop developer API, tokens in
/// secure storage with a refresh flow, and a rolling-window pull that
/// maps each night's sleep + each day's recovery onto the daily_notes
/// view (one row/day, match-by-date ingest), OWNING sleep_hours /
/// sleep_quality / readiness while leaving the free-text note to the
/// user (fill-if-blank).
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

/// Map a Whoop sleep-performance percentage (0-100) to the daily_notes
/// 1-5 sleep_quality scale (5 = best). 20-wide bands, top-anchored so a
/// ~90% night reads a clean 5:
///   >=90 → 5 · >=75 → 4 · >=60 → 3 · >=45 → 2 · else → 1.
int whoopSleepQuality(num pct) {
  if (pct >= 90) return 5;
  if (pct >= 75) return 4;
  if (pct >= 60) return 3;
  if (pct >= 45) return 2;
  return 1;
}

/// Map a Whoop recovery score (0-100) to the daily_notes 1-5 readiness
/// scale (5 = fully ready). Whoop's own colour bands are green >=67 /
/// yellow 34-66 / red <34; we spread that to five buckets:
///   >=80 → 5 · >=67 → 4 · >=60 → 3 · >=40 → 2 · else → 1.
/// (Pins from the transform test: 82 → 5, 40 → 2.)
int whoopReadiness(num pct) {
  if (pct >= 80) return 5;
  if (pct >= 67) return 4;
  if (pct >= 60) return 3;
  if (pct >= 40) return 2;
  return 1;
}

/// Transform Whoop v2 sleep records into partial daily-note ingest
/// records keyed on the WAKE date (the sleep `end`'s local day). Naps
/// and score-less (in-progress / pending) records are skipped. One row
/// per wake-date; the latest-ending night wins a collision.
///
/// Record shape (v2 /activity/sleep): {id, nap: bool, start, end,
/// score: {sleep_performance_percentage, stage_summary:
/// {total_in_bed_time_milli, total_awake_time_milli}}}. Sleep-hours =
/// (in-bed − awake) ms → hours, 1dp.
List<Map<String, dynamic>> whoopSleepToNotes(List<dynamic> records) {
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
    final perf = score['sleep_performance_percentage'] as num?;

    final rec = <String, dynamic>{
      'date': {'kind': 'date', 'value': day},
      if (hours != null) 'sleep_hours': {'kind': 'float', 'value': hours},
      if (perf != null)
        'sleep_quality': {
          'kind': 'int',
          'value': whoopSleepQuality(perf),
        },
    };
    byDay[day] = rec;
    endByDay[day] = endMs;
  }
  final days = byDay.keys.toList()..sort();
  return [for (final d in days) byDay[d]!];
}

/// Transform Whoop v2 recovery records into a day → readiness (1-5) map,
/// keyed on the recovery's `created_at` local day. Score-less records are
/// skipped. Later `created_at` wins a same-day collision.
Map<String, int> whoopRecoveryToReadiness(List<dynamic> records) {
  final out = <String, int>{};
  final atByDay = <String, int>{};
  for (final r in records) {
    if (r is! Map) continue;
    final score = r['score'];
    if (score is! Map) continue;
    final pct = score['recovery_score'] as num?;
    if (pct == null) continue;
    final createdStr = (r['created_at'] ?? r['updated_at']) as String?;
    if (createdStr == null) continue;
    final created = DateTime.tryParse(createdStr);
    if (created == null) continue;
    final ms = created.millisecondsSinceEpoch;
    final day = _isoDate(created.toUtc());
    final existing = atByDay[day];
    if (existing != null && existing >= ms) continue;
    out[day] = whoopReadiness(pct);
    atByDay[day] = ms;
  }
  return out;
}

/// Fold the readiness-by-day map into the sleep records (matched on the
/// same daily_notes date), producing the final ingest record list. A
/// readiness day with no matching sleep still yields a row (readiness
/// only). Output sorted by date.
List<Map<String, dynamic>> whoopMergeDailyNotes({
  required List<Map<String, dynamic>> sleep,
  required Map<String, int> readiness,
}) {
  final byDay = <String, Map<String, dynamic>>{};
  for (final s in sleep) {
    final day = ((s['date'] as Map)['value']) as String;
    byDay[day] = Map<String, dynamic>.from(s);
  }
  readiness.forEach((day, r) {
    final rec = byDay.putIfAbsent(
        day, () => {'date': {'kind': 'date', 'value': day}});
    rec['readiness'] = {'kind': 'int', 'value': r};
  });
  final days = byDay.keys.toList()..sort();
  return [for (final d in days) byDay[d]!];
}

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
    required this.dailyNotesViewJson,
  });

  final WhoopApiConfig? config;
  final EngineLedgerRepository repo;

  /// Engine JSON of the daily_notes view (with date_field applied).
  final Map<String, dynamic> dailyNotesViewJson;

  static const _storage = FlutterSecureStorage();
  static const _kAccess = 'whoop_api_access';
  static const _kRefresh = 'whoop_api_refresh';
  static const _kExpiry = 'whoop_api_expiry';

  // Ledger-meta keys (shared source of truth with the page).
  static const _kLastPull = 'integration_whoop_api_last_pull';
  static const _kStatus = 'integration_whoop_api_status';
  static const _kError = 'integration_whoop_api_error';
  static const _kDays = 'integration_whoop_api_days';

  static const _ownedFields = ['sleep_hours', 'sleep_quality', 'readiness'];

  @override
  String get id => 'whoop_api';
  @override
  String get displayName => 'Whoop (sleep)';
  @override
  String get targetDescription => '→ daily notes';
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

      final records = whoopMergeDailyNotes(
        sleep: whoopSleepToNotes(sleepRecs),
        readiness: whoopRecoveryToReadiness(recoveryRecs),
      );

      if (records.isNotEmpty) {
        // match-by-date (no match_field) — one daily_notes row per day.
        // note stays fill-if-blank so a manual journal entry is never
        // overwritten by an empty Whoop pull.
        await repo.ingest(dailyNotesViewJson, {
          'source': 'whoop_api',
          'owned_fields': _ownedFields,
          'fill_if_blank_fields': const ['note'],
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
