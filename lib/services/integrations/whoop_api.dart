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
const _kWorkoutUrl = 'https://api.prod.whoop.com/developer/v2/activity/workout';
const _kRedirectUri = 'ledger://oauth/whoop';
// offline → refresh token; read scopes for the record types pulled.
// read:workout was missing when the workouts pull landed (2026-09-30),
// so tokens granted before then 401 on /activity/workout — a refresh
// can't widen scope; the user must Reconnect (menu action below).
const _kScope = 'read:sleep read:recovery read:cycles read:workout offline';

const _kMinPullInterval = Duration(hours: 6);
const _kFirstPullWindow = Duration(days: 30);
const _kRollingWindow = Duration(days: 14);

/// Whoop's per-record `timezone_offset` ("-07:00", "+05:30", "Z") as a
/// Duration. Null when absent or malformed — callers then fall back to
/// the UTC instant (the pre-2026-10-01 behaviour), never throw.
Duration? whoopOffset(Object? raw) {
  if (raw is! String) return null;
  final s = raw.trim();
  if (s == 'Z') return Duration.zero;
  final m = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(s);
  if (m == null) return null;
  final mins = int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!);
  return Duration(minutes: m.group(1) == '-' ? -mins : mins);
}

/// The wall-clock reading of [instant] at [offset], as a UTC DateTime
/// whose fields ARE the local time (so `_isoDate`/`_isoDateTime` print
/// local values). Null offset → the UTC reading.
DateTime _wall(DateTime instant, Duration? offset) =>
    instant.toUtc().add(offset ?? Duration.zero);

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
    // Wake day = the sleep end's LOCAL date (timezone_offset); UTC when
    // the record carries no offset.
    final day = _isoDate(_wall(end, whoopOffset(s['timezone_offset'])));
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

/// Transform Whoop v2 recovery records into a day → objective-fields map.
/// Each record is keyed on its linked sleep's LOCAL wake day (via
/// [sleepDays], `sleep_id` → day — recovery records carry no offset of
/// their own); when the sleep_id is unknown (or missing), falls back to
/// `created_at` shifted by [fallbackOffset] (the user's current zone,
/// from [whoopLatestOffset]), else raw UTC. Score-less records are
/// skipped. Later `created_at` wins a same-day collision. Fields:
/// recovery_score, hrv_ms (hrv_rmssd_milli), resting_hr
/// (resting_heart_rate).
Map<String, Map<String, dynamic>> whoopRecoveryFields(
  List<dynamic> records, {
  Map<String, String> sleepDays = const {},
  Duration? fallbackOffset,
}) {
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
    // Recovery is "this morning's" read: key it on its sleep's local wake
    // day; else created_at shifted by the user's current zone; else UTC.
    final day = sleepDays[r['sleep_id']?.toString()] ??
        _isoDate(_wall(created, fallbackOffset));
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

/// Sleep id → its LOCAL wake day, for keying recovery records (which
/// carry no offset of their own). Naps and records without id/end skip.
Map<String, String> whoopSleepWakeDays(List<dynamic> sleeps) {
  final out = <String, String>{};
  for (final s in sleeps) {
    if (s is! Map || s['nap'] == true) continue;
    final id = s['id']?.toString();
    final end = DateTime.tryParse(s['end']?.toString() ?? '');
    if (id == null || id.isEmpty || end == null) continue;
    out[id] = _isoDate(_wall(end, whoopOffset(s['timezone_offset'])));
  }
  return out;
}

/// The offset of the latest-ending sleep in the batch (the user's current
/// zone), or null when none carries one.
Duration? whoopLatestOffset(List<dynamic> sleeps) {
  DateTime? best;
  Duration? off;
  for (final s in sleeps) {
    if (s is! Map) continue;
    final end = DateTime.tryParse(s['end']?.toString() ?? '');
    final o = whoopOffset(s['timezone_offset']);
    if (end == null || o == null) continue;
    if (best == null || end.isAfter(best)) {
      best = end;
      off = o;
    }
  }
  return off;
}

/// Days the source previously wrote ([known]) inside the diff window
/// (>= [diffFrom]) that this pull did not re-emit — they moved (local-date
/// fix) or vanished upstream. Null = refuse to diff: nothing was emitted
/// but in-window days are known (an API glitch, not a wipe) unless
/// [fullReconcile].
/// [pending] (I2, 2026-10-01): days whose sleep came back THIS pull with
/// no score — pending/re-scoring after an edit in the Whoop app, not a
/// deletion — are excluded from the candidate set entirely, so they
/// neither get flagged stale nor count toward the empty-fetch refuse
/// guard above.
List<String>? whoopStaleDays({
  required Set<String> known,
  required Set<String> emitted,
  required String diffFrom,
  required bool fullReconcile,
  Set<String> pending = const {},
}) {
  final inWindow = [
    for (final d in known)
      if (d.compareTo(diffFrom) >= 0 && !pending.contains(d)) d,
  ]..sort();
  if (emitted.isEmpty && inWindow.isNotEmpty && !fullReconcile) return null;
  return [for (final d in inWindow) if (!emitted.contains(d)) d];
}

/// Local wake days of non-nap sleep records that came back with NO score
/// map this pull (score absent/not a map) — pending/re-scoring in the
/// Whoop app (e.g. an edited sleep), not a deletion. Feeds [whoopStaleDays]
/// `pending` (I2).
Set<String> whoopPendingWakeDays(List<dynamic> sleeps) {
  final out = <String>{};
  for (final s in sleeps) {
    if (s is! Map || s['nap'] == true) continue;
    if (s['score'] is Map) continue; // scored → not pending
    final end = DateTime.tryParse(s['end']?.toString() ?? '');
    if (end == null) continue;
    out.add(_isoDate(_wall(end, whoopOffset(s['timezone_offset']))));
  }
  return out;
}

/// Previously-seen workout ids ([knownIds], via [dayById]) whose day
/// falls inside the pulled window (>= [windowStartDay]) that THIS pull
/// did not re-fetch ([fetchedIds]) — deleted upstream. [windowStartDay]
/// must carry the SAME +2-day margin as [whoopStaleDays]' `diffFrom`
/// (C1): the API filters by START INSTANT, so a workout whose LOCAL DAY
/// is the window's first calendar day can have started just before the
/// cutoff instant and legitimately be excluded from the fetch — without
/// the margin that workout is wrongly diffed as deleted. Null = refuse to
/// diff: nothing was fetched but in-window ids are known (an API
/// glitch, not a mass delete) unless [fullReconcile].
List<String>? whoopStaleWorkoutIds({
  required Set<String> knownIds,
  required Map<String, String> dayById,
  required Set<String> fetchedIds,
  required String windowStartDay,
  required bool fullReconcile,
}) {
  final inWindow = [
    for (final id in knownIds)
      if ((dayById[id] ?? '').compareTo(windowStartDay) >= 0) id,
  ];
  if (fetchedIds.isEmpty && inWindow.isNotEmpty && !fullReconcile) {
    return null;
  }
  return [for (final id in inWindow) if (!fetchedIds.contains(id)) id];
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

/// Whoop sport_id → sport name. Best-judgment map of the common ids from
/// Whoop's documented sport list (the enum is large and occasionally
/// renumbered; unknowns fall back to the raw id string in
/// [whoopWorkoutsToRows]). -1 is Whoop's generic "activity" sentinel.
const _kWhoopSports = <int, String>{
  -1: 'activity',
  0: 'running',
  1: 'cycling',
  16: 'baseball',
  18: 'basketball',
  22: 'golf',
  24: 'ice hockey',
  33: 'rowing',
  34: 'rugby',
  39: 'skiing',
  42: 'soccer',
  43: 'softball',
  44: 'squash',
  45: 'weightlifting',
  48: 'swimming',
  52: 'hiking',
  // 'functional fitness' / HIIT — common Whoop label for circuit work.
  56: 'spin',
  63: 'walking',
  66: 'yoga',
  70: 'meditation',
  71: 'martial arts',
  82: 'hiit',
  83: 'elliptical',
  84: 'stairmaster',
  96: 'hiit',
  97: 'spin',
  101: 'rock climbing',
  // Common gym-strength label in recent app versions.
  123: 'strength trainer',
};

/// Transform Whoop v2 workout records into row-grained `whoop_workouts`
/// ingest records — ONE row per workout, keyed on the Whoop workout `id`
/// (the match_field). SESSION-level: a day can carry multiple workouts
/// (each a row); they are NEVER merged into per-set strength rows.
/// Score-less (in-progress / pending) workouts are skipped; a workout
/// missing id/start/end is skipped. Duplicate ids keep the first
/// (ingest is keyed by workout_id, so later duplicates would be no-op
/// updates anyway). Output sorted by start instant ascending.
///
/// Record shape (v2 /activity/workout): {id, start, end, sport_id,
/// sport_name?, score: {strain, average_heart_rate, max_heart_rate,
/// kilojoule}}. kcal = kilojoule / 4.184 (1dp); duration_min =
/// (end − start) minutes (1dp); strain 1dp. The workout DATE and
/// start/end times are LOCAL wall-clock via the record's
/// `timezone_offset` (UTC when absent) — the raw UTC date put evening
/// Pacific sessions on the next day (fixed 2026-10-01). start_time/
/// end_time are carried as second-precision datetime strings for the
/// date/time overlap join the coach uses to line a workout up with the
/// day's logged training session.
List<Map<String, dynamic>> whoopWorkoutsToRows(List<dynamic> records) {
  final byId = <String, Map<String, dynamic>>{};
  final startByIdMs = <String, int>{};
  for (final w in records) {
    if (w is! Map) continue;
    final id = w['id']?.toString();
    if (id == null || id.isEmpty) continue;
    if (byId.containsKey(id)) continue; // first wins (idempotent)
    final score = w['score'];
    if (score is! Map) continue; // no score → in-progress / pending
    final startStr = w['start'] as String?;
    final endStr = w['end'] as String?;
    if (startStr == null || endStr == null) continue;
    final start = DateTime.tryParse(startStr);
    final end = DateTime.tryParse(endStr);
    if (start == null || end == null) continue;

    final off = whoopOffset(w['timezone_offset']);
    final day = _isoDate(_wall(start, off));
    final durationMin =
        _round1(end.difference(start).inMilliseconds / 60000.0);

    final rec = <String, dynamic>{
      'workout_id': {'kind': 'string', 'value': id},
      'date': {'kind': 'date', 'value': day},
      // Engine serde tag is `date_time` (NOT `datetime` — the Macrofactor
      // trap pinned by integration_kind_tags_test).
      'start_time': {
        'kind': 'date_time',
        'value': _isoDateTime(_wall(start, off)),
      },
      'end_time': {
        'kind': 'date_time',
        'value': _isoDateTime(_wall(end, off)),
      },
      'sport': {'kind': 'string', 'value': _sportName(w)},
      ..._numRound1(score, 'strain', 'strain'),
      ..._num(score, 'average_heart_rate', 'avg_hr'),
      ..._num(score, 'max_heart_rate', 'max_hr'),
      ..._kcal(score),
      if (durationMin >= 0) 'duration_min': _float(durationMin),
    };
    byId[id] = rec;
    startByIdMs[id] = start.millisecondsSinceEpoch;
  }
  final ids = byId.keys.toList()
    ..sort((a, b) => startByIdMs[a]!.compareTo(startByIdMs[b]!));
  return [for (final id in ids) byId[id]!];
}

/// Resolve a workout's sport label: prefer the explicit `sport_name`
/// (v2 provides it), else map `sport_id` through [_kWhoopSports], else
/// the raw sport_id as a string, else 'activity'.
String _sportName(Map w) {
  final name = w['sport_name'];
  if (name is String && name.trim().isNotEmpty) return name.trim();
  final sid = w['sport_id'];
  if (sid is num) {
    final mapped = _kWhoopSports[sid.toInt()];
    return mapped ?? sid.toInt().toString();
  }
  return 'activity';
}

/// strain is reported to 4dp; store 1dp.
Map<String, dynamic> _numRound1(Map score, String srcKey, String dstKey) {
  final v = score[srcKey];
  if (v is num) return {dstKey: _float(_round1(v.toDouble()))};
  return const {};
}

/// kcal = kilojoule / 4.184 (1dp). Absent kilojoule → omit (don't clear).
Map<String, dynamic> _kcal(Map score) {
  final kj = score['kilojoule'];
  if (kj is num) return {'kcal': _float(_round1(kj.toDouble() / 4.184))};
  return const {};
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

/// Second-precision ISO datetime from the wire instant's UTC date/time
/// portion (same wall-clock convention as [_isoDate] — no zone shift).
String _isoDateTime(DateTime d) {
  final u = d.toUtc();
  return '${_isoDate(u)}T${u.hour.toString().padLeft(2, '0')}:'
      '${u.minute.toString().padLeft(2, '0')}:'
      '${u.second.toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------------------
// Integration.
// ---------------------------------------------------------------------------

class WhoopApiIntegration implements Integration {
  WhoopApiIntegration({
    required this.config,
    required this.repo,
    required this.recoveryViewJson,
    this.workoutsViewJson,
  });

  final WhoopApiConfig? config;
  final EngineLedgerRepository repo;

  /// Engine JSON of the `recovery` view (with date_field applied).
  final Map<String, dynamic> recoveryViewJson;

  /// Engine JSON of the `whoop_workouts` view. Null (older schema set
  /// without the view) → the workouts pull is skipped; sleep/recovery
  /// still run. Workouts ingest ROW-GRAINED by workout_id (match_field),
  /// so a day can carry several strain scores without collision.
  final Map<String, dynamic>? workoutsViewJson;

  static const _storage = FlutterSecureStorage();
  static const _kAccess = 'whoop_api_access';
  static const _kRefresh = 'whoop_api_refresh';
  static const _kExpiry = 'whoop_api_expiry';

  // Ledger-meta keys (shared source of truth with the page).
  static const _kLastPull = 'integration_whoop_api_last_pull';
  static const _kStatus = 'integration_whoop_api_status';
  static const _kError = 'integration_whoop_api_error';
  static const _kDays = 'integration_whoop_api_days';
  // Known-workout-id baseline (row-grained ingest provenance) + the
  // id→day map that scopes the deletion diff to the pulled window.
  static const _kWorkoutIds = 'integration_whoop_api_workout_ids';
  static const _kWorkoutDayMap = 'integration_whoop_api_workout_days';

  // Objective workout fields owned by the integration; notes
  // (fill-if-blank) stays user-owned.
  static const _ownedWorkoutFields = [
    'date',
    'start_time',
    'end_time',
    'sport',
    'strain',
    'avg_hr',
    'max_hr',
    'kcal',
    'duration_min',
  ];

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
  String get targetDescription => '→ recovery + workouts';
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
    if (status == 'reconnect') return 'Reconnect needed (⋮ → Reconnect)';
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

  /// Reconnect re-runs the consent flow while connected — the only way
  /// to pick up scopes added after the original grant.
  @override
  Map<String, Future<void> Function(BuildContext)> get extraMenuActions =>
      {'Reconnect': connect};

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
        recovery: whoopRecoveryFields(
          recoveryRecs,
          sleepDays: whoopSleepWakeDays(sleepRecs),
          fallbackOffset: whoopLatestOffset(sleepRecs),
        ),
      );
      final emitted = <String>{
        for (final r in records) ((r['date'] as Map)['value']) as String,
      };
      // Stale-day diff starts 2 days inside the window: the API filters
      // by START, so the window's first night can fall outside it.
      final stale = whoopStaleDays(
        known: known,
        emitted: emitted,
        diffFrom: _isoDate(
            now.subtract(window).add(const Duration(days: 2)).toUtc()),
        fullReconcile: fullReconcile,
        // I2: a night that re-scored (no score this pull, non-nap) is
        // pending, not deleted.
        pending: whoopPendingWakeDays(sleepRecs),
      );
      if (records.isNotEmpty || (stale?.isNotEmpty ?? false)) {
        // match-by-date (no match_field) — one recovery row per day.
        // notes stays fill-if-blank so a manual note is never
        // overwritten by an empty Whoop pull.
        await repo.ingest(recoveryViewJson, {
          'source': 'whoop_api',
          'owned_fields': _ownedFields,
          'fill_if_blank_fields': const ['notes'],
          'records': records,
          if (stale != null && stale.isNotEmpty) 'deleted_dates': stale,
        });
        known
          ..addAll(emitted)
          ..removeAll(stale ?? const <String>[]);
        await repo.metaSet(_kDays, jsonEncode(known.toList()..sort()));
      }

      // Workouts (strain) — ROW-GRAINED by workout_id. Pulled over the
      // SAME window so the coach's dump lands sleep/recovery AND the
      // day's workouts together (the temporal association the LLM joins
      // on). Deletion diff: known ids whose workout HC no longer returns
      // inside the window → deleted_ids (same raw-id, mass-delete-guard
      // shape as Kaya/Macrofactor). Skipped when the view is absent.
      final workoutsView = workoutsViewJson;
      if (workoutsView != null) {
        final workoutRecs = await _getAll(_kWorkoutUrl, token, start, end);
        final rows = whoopWorkoutsToRows(workoutRecs);
        final fetchedIds = <String>{
          for (final r in rows) ((r['workout_id'] as Map)['value']) as String,
        };
        final knownIds = _decodeDays(await repo.metaGet(_kWorkoutIds));
        final workoutDayById = _decodeDayMap(await repo.metaGet(_kWorkoutDayMap));
        // Deletions: a previously-seen id that falls in the pulled window
        // but was NOT returned this pull. Margin matches whoopStaleDays'
        // diffFrom (C1): the API filters by START INSTANT, so a workout
        // on the window's first calendar day can start before the cutoff
        // instant and legitimately be excluded — without the +2-day
        // margin that workout is wrongly flagged deleted. Guard: a
        // non-empty baseline vanishing entirely is treated as an API
        // glitch, not a wipe — refuse to diff (fullReconcile overrides).
        final windowStartDay = _isoDate(
            now.subtract(window).add(const Duration(days: 2)).toUtc());
        final deleted = whoopStaleWorkoutIds(
              knownIds: knownIds,
              dayById: workoutDayById,
              fetchedIds: fetchedIds,
              windowStartDay: windowStartDay,
              fullReconcile: fullReconcile,
            ) ??
            const <String>[];

        if (rows.isNotEmpty || deleted.isNotEmpty) {
          await repo.ingest(workoutsView, {
            'source': 'whoop_api',
            'match_field': 'workout_id',
            'owned_fields': _ownedWorkoutFields,
            'fill_if_blank_fields': const ['notes'],
            'records': rows,
            if (deleted.isNotEmpty) 'deleted_ids': deleted,
          });
          // Update the id baseline + the id→day map (window-scoped).
          for (final r in rows) {
            final id = ((r['workout_id'] as Map)['value']) as String;
            knownIds.add(id);
            workoutDayById[id] = ((r['date'] as Map)['value']) as String;
          }
          for (final id in deleted) {
            knownIds.remove(id);
            workoutDayById.remove(id);
          }
          await repo.metaSet(_kWorkoutIds, jsonEncode(knownIds.toList()..sort()));
          await repo.metaSet(_kWorkoutDayMap, jsonEncode(workoutDayById));
        }
      }

      await repo.metaSet(_kLastPull, DateTime.now().toIso8601String());
      await repo.metaSet(_kStatus, 'ok');
      await repo.metaSet(_kError, '');
    } on _WhoopUnauthorized catch (e) {
      // Token rejected by a data endpoint (revoked, or a scope the grant
      // lacks) — refreshing won't fix it; only a fresh consent will.
      await repo.metaSet(_kStatus, 'reconnect');
      await repo.metaSet(_kError, e.toString());
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

  /// Decode the workout id→day map (meta `_kWorkoutDayMap`).
  Map<String, String> _decodeDayMap(String? json) {
    if (json == null || json.isEmpty) return <String, String>{};
    final decoded = jsonDecode(json);
    return decoded is Map
        ? decoded.map((k, v) => MapEntry(k as String, v as String))
        : <String, String>{};
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
      if (resp.statusCode == 401) {
        throw _WhoopUnauthorized('whoop $base: 401 ${resp.body}');
      }
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

class _WhoopUnauthorized implements Exception {
  _WhoopUnauthorized(this.message);
  final String message;
  @override
  String toString() => message;
}
