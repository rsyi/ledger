/// Withings → weight integration.
///
/// OAuth2 (in-app WebView consent intercepting the custom-scheme
/// callback airledger://oauth/withings), tokens in secure storage,
/// `getmeas` pulls transformed to engine ingest batches, and a
/// rolling-window reconcile — backed by the engine's provenance
/// table — that both unwinds deletions and re-ingests the window's
/// values so revised measurements land.
library;

import 'dart:convert';
import 'dart:math';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../app_config.dart' show WithingsConfig;
import '../../ui/oauth_webview_screen.dart';
import 'integration.dart';

const _kAuthorizeUrl = 'https://account.withings.com/oauth2_user/authorize2';
const _kTokenUrl = 'https://wbsapi.withings.net/v2/oauth2';
const _kMeasureUrl = 'https://wbsapi.withings.net/measure';
const _kRedirectUri = 'airledger://oauth/withings';
const _kScope = 'user.metrics';
const _kMinPullInterval = Duration(hours: 6);
const _kReconcileWindow = Duration(days: 90);

const _lbsPerKg = 2.20462;

/// Transform Withings measuregrps into engine ingest records — one
/// record per local day, the EARLIEST weigh-in of the day wins.
/// Group shape (from getmeas): {grpid, date: epochSecs, measures:
/// [{value, unit, type}]} where real value = value * 10^unit;
/// type 1 = weight (kg), type 6 = fat ratio (%).
List<Map<String, dynamic>> withingsGroupsToRecords(List<dynamic> grps) {
  // day -> earliest group that has a weight or fat measure.
  final byDay = <String, Map<String, dynamic>>{};
  final epochByDay = <String, int>{};
  for (final g in grps) {
    if (g is! Map) continue;
    final epoch = (g['date'] as num?)?.toInt();
    if (epoch == null) continue;
    final local = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    final day = _isoDate(local);
    final existing = epochByDay[day];
    if (existing != null && existing <= epoch) continue;

    double? kg;
    double? fat;
    for (final m in (g['measures'] as List? ?? const [])) {
      if (m is! Map) continue;
      final value = (m['value'] as num?)?.toDouble();
      final unit = (m['unit'] as num?)?.toInt();
      if (value == null || unit == null) continue;
      final real = value * pow(10, unit);
      switch (m['type']) {
        case 1:
          kg = real.toDouble();
        case 6:
          fat = real.toDouble();
      }
    }
    if (kg == null && fat == null) continue;

    final rec = <String, dynamic>{
      'date': {'kind': 'date', 'value': day},
      'time': {
        'kind': 'string',
        'value': '${local.hour.toString().padLeft(2, '0')}:'
            '${local.minute.toString().padLeft(2, '0')}',
      },
      if (kg != null)
        'weight_lbs': {
          'kind': 'float',
          'value': _round1(kg * _lbsPerKg),
        },
      if (fat != null)
        'body_fat_withing': {'kind': 'float', 'value': _round1(fat)},
    };
    byDay[day] = rec;
    epochByDay[day] = epoch;
  }
  final days = byDay.keys.toList()..sort();
  return [for (final d in days) byDay[d]!];
}

/// Days the ledger credits to Withings that Withings no longer has —
/// the `deleted_dates` for the reconcile batch.
List<String> withingsDeletedDates({
  required Set<String> windowDaysWithData,
  required Set<String> provenanceDays,
}) {
  final gone = provenanceDays.difference(windowDaysWithData).toList()..sort();
  return gone;
}

double _round1(double v) => (v * 10).roundToDouble() / 10;

String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class WithingsIntegration implements Integration {
  WithingsIntegration({
    required this.config,
    required this.repo,
    required this.weightViewJson,
  });

  final WithingsConfig? config;
  final EngineLedgerRepository repo;

  /// Engine JSON of the weight view (with date_field applied).
  final Map<String, dynamic> weightViewJson;

  static const _storage = FlutterSecureStorage();
  static const _kAccess = 'withings_access';
  static const _kRefresh = 'withings_refresh';
  static const _kExpiry = 'withings_expiry';

  // Ledger-meta keys (shared source of truth with the page).
  static const _kCursor = 'integration_withings_cursor';
  static const _kLastPull = 'integration_withings_last_pull';
  static const _kStatus = 'integration_withings_status';
  static const _kError = 'integration_withings_error';
  static const _kDays = 'integration_withings_days';

  @override
  String get id => 'withings';
  @override
  String get displayName => 'Withings';
  @override
  String get targetDescription => '→ weight';
  @override
  bool get isConfigured => config?.isConfigured ?? false;

  @override
  Future<bool> get isConnected async =>
      (await _storage.read(key: _kRefresh)) != null;

  @override
  Future<String> get statusLine async {
    if (!isConfigured) {
      return 'Set WITHINGS_CLIENT_ID / _SECRET in .env and rebrand';
    }
    if (!await isConnected) return 'Not connected';
    final status = await repo.metaGet(_kStatus);
    if (status == 'reconnect') return 'Reconnect needed';
    if (status == 'error') {
      final e = await repo.metaGet(_kError) ?? 'unknown';
      return 'Error: $e';
    }
    final last = await repo.metaGet(_kLastPull);
    final days = _decodeDays(await repo.metaGet(_kDays)).length;
    final when = last == null
        ? 'never'
        : DateTime.tryParse(last)
                ?.toLocal()
                .toString()
                .substring(11, 16) ??
            last;
    return 'Connected · last pulled $when · $days day(s) synced';
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
    // In-app WebView, not a Custom Tab: Chrome silently blocks the
    // post-consent redirect to a custom scheme, so we intercept the
    // callback navigation ourselves.
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => OAuthWebViewScreen(
          title: 'Connect Withings',
          authorizeUrl: url,
          callbackScheme: 'airledger',
        ),
      ),
    );
    if (result == null) return; // user backed out
    final back = Uri.parse(result);
    if (back.queryParameters['state'] != state) {
      throw StateError('withings oauth: state mismatch');
    }
    final code = back.queryParameters['code'];
    if (code == null) {
      throw StateError('withings oauth: no code in callback');
    }
    final body = await _tokenRequest({
      'action': 'requesttoken',
      'grant_type': 'authorization_code',
      'client_id': cfg.clientId,
      'client_secret': cfg.clientSecret,
      'code': code,
      'redirect_uri': _kRedirectUri,
    });
    await _storeTokens(body);
    await repo.metaSet(_kStatus, 'ok');
    // First pull = full backfill; don't block the UI on it.
    // ignore: unawaited_futures
    pull(force: true);
  }

  @override
  Future<void> disconnect() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kExpiry);
    await repo.metaSet(_kCursor, '');
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

      // 1. Incremental pull since cursor.
      final cursor =
          int.tryParse(await repo.metaGet(_kCursor) ?? '') ?? 0;
      final grps = await _getmeas(token, {'lastupdate': '$cursor'});
      final records = withingsGroupsToRecords(
          grps.where((g) => (g as Map)['deleted'] != true).toList());
      var maxSeen = cursor;
      for (final g in grps) {
        for (final k in ['modified', 'created', 'date']) {
          final v = ((g as Map)[k] as num?)?.toInt();
          if (v != null && v > maxSeen) maxSeen = v;
        }
      }
      if (records.isNotEmpty) {
        await repo.ingest(weightViewJson, {
          'source': 'withings',
          'owned_fields': ['body_fat_withing'],
          'fill_if_blank_fields': ['weight_lbs', 'time'],
          'records': records,
        });
        final days = _decodeDays(await repo.metaGet(_kDays));
        for (final r in records) {
          days.add(((r['date'] as Map)['value']) as String);
        }
        await repo.metaSet(_kDays, jsonEncode(days.toList()..sort()));
      }

      // 2. Reconcile over the window (or all history): re-ingest the
      //    window's values so self-correction can revise the source's
      //    own measurements, and unwind days Withings no longer has.
      final now = DateTime.now();
      final windowStart = fullReconcile
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : now.subtract(_kReconcileWindow);
      final windowGrps = await _getmeas(token, {
        'startdate': '${windowStart.millisecondsSinceEpoch ~/ 1000}',
        'enddate': '${now.millisecondsSinceEpoch ~/ 1000}',
      });
      final windowRecords = withingsGroupsToRecords(
          windowGrps.where((g) => (g as Map)['deleted'] != true).toList());
      final currentDays = windowRecords
          .map((r) => ((r['date'] as Map)['value']) as String)
          .toSet();
      final knownDays = _decodeDays(await repo.metaGet(_kDays));
      final inWindow = knownDays
          .where((d) =>
              fullReconcile ||
              DateTime.parse(d).isAfter(windowStart.subtract(const Duration(days: 1))))
          .toSet();
      final deleted = withingsDeletedDates(
        windowDaysWithData: currentDays,
        provenanceDays: inWindow,
      );
      if (windowRecords.isNotEmpty || deleted.isNotEmpty) {
        await repo.ingest(weightViewJson, {
          'source': 'withings',
          'owned_fields': ['body_fat_withing'],
          'fill_if_blank_fields': ['weight_lbs', 'time'],
          'records': windowRecords,
          'deleted_dates': deleted,
        });
        knownDays.addAll(currentDays);
        knownDays.removeAll(deleted);
        await repo.metaSet(_kDays, jsonEncode(knownDays.toList()..sort()));
      }

      await repo.metaSet(_kCursor, '$maxSeen');
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

  /// Withings wraps every response as {status: 0, body: {...}};
  /// non-zero status is an API error.
  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> form) async {
    final resp = await http.post(Uri.parse(_kTokenUrl), body: form);
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    if (decoded['status'] != 0) {
      throw StateError('withings token: ${resp.body}');
    }
    return decoded['body'] as Map<String, dynamic>;
  }

  Future<void> _storeTokens(Map<String, dynamic> body) async {
    await _storage.write(key: _kAccess, value: body['access_token'] as String);
    await _storage.write(
        key: _kRefresh, value: body['refresh_token'] as String);
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 10800;
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
        'action': 'requesttoken',
        'grant_type': 'refresh_token',
        'client_id': cfg.clientId,
        'client_secret': cfg.clientSecret,
        'refresh_token': refresh,
      });
      await _storeTokens(body);
      return body['access_token'] as String;
    } catch (_) {
      await repo.metaSet(_kStatus, 'reconnect');
      return null;
    }
  }

  Future<List<dynamic>> _getmeas(
      String token, Map<String, String> extra) async {
    final resp = await http.post(
      Uri.parse(_kMeasureUrl),
      headers: {'Authorization': 'Bearer $token'},
      body: {
        'action': 'getmeas',
        'meastypes': '1,6',
        'category': '1',
        ...extra,
      },
    );
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    if (decoded['status'] != 0) {
      throw StateError('withings getmeas: ${resp.body}');
    }
    final body = decoded['body'] as Map<String, dynamic>;
    return (body['measuregrps'] as List?) ?? const [];
  }
}
