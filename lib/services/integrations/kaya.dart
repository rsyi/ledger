/// Kaya climbing-app → ledger integration: transform, reconcile-diff, and
/// the Integration class that drives the full pull loop.
///
/// Design: no cursor. Every pull fetches ALL ascents for the user (the Kaya
/// GraphQL endpoint supports offset+count paging but has no updatedat filter).
/// Because we fetch the full logbook every time, the transform is sort-order-
/// independent and all upserts are idempotent by kaya_id — re-running with the
/// same data is a no-op at the engine layer. Deletions are computed as
/// (knownIds - fetchedIds), matching the full-walk reconcile pattern used by
/// Withings. [KayaIntegration] drives the pull loop and plugs into the
/// integration registry; the pure transform functions it depends on are below.
library;

import 'dart:convert';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'integration.dart';
import 'kaya_api.dart';

export 'kaya_api.dart' show KayaAuthException;

/// Transform a raw list of Kaya ascent maps (from `ascentsForUser`) into
/// engine ingest records tagged with kind metadata.
///
/// [destinationBySession] maps session_id → destination name for outdoor
/// sessions; build it with [kayaDestinationsBySession] before calling this.
///
/// Malformed ascents (non-map, missing/null/empty id, unparseable date) are
/// silently dropped — caller should log the count if needed. Wrong-typed
/// fields within an otherwise-valid ascent are omitted rather than crashing.
List<Map<String, dynamic>> kayaAscentsToRecords(
  List<dynamic> ascents, {
  Map<String, String> destinationBySession = const {},
}) {
  final result = <Map<String, dynamic>>[];
  for (final raw in ascents) {
    if (raw is! Map) continue;
    final id = raw['id'];
    if (id == null) continue;
    final idStr = id.toString();
    if (idStr.isEmpty) continue;
    final day = kayaDay(raw['date']);
    if (day == null) continue;

    final rec = <String, dynamic>{
      'kaya_id': _str(idStr),
      'date': {'kind': 'date', 'value': day},
    };

    // Derive session destination for location lookup; session_id may be a
    // number on the wire so coerce to string.
    final sessionId = raw['session_id']?.toString();

    final climbRaw = raw['climb'];
    final climb = climbRaw is Map ? climbRaw : null;

    // Climb-level fields (only when climb is a Map).
    if (climb != null) {
      final climbName = climb['name'];
      if (climbName is String) rec['climb_name'] = _str(climbName);

      // Derive boulder/route from climb_type_group first; fall back to
      // lowercased climb_type.name prefix match ('boulder…' → boulder, else
      // route). The API returns PLURAL names ("Boulders", "Routes") so the
      // simple startsWith works correctly.
      //
      // Omit climb_type entirely when no usable signal is available.
      final gradeRaw = climb['grade'];
      final grade = gradeRaw is Map ? gradeRaw : null;
      final ctGroupRaw = grade?['climb_type_group'];
      final ctGroup = ctGroupRaw is String ? ctGroupRaw : null;
      final climbTypeRaw = climb['climb_type'];
      final climbTypeMap = climbTypeRaw is Map ? climbTypeRaw : null;
      final climbTypeNameRaw = climbTypeMap?['name'];
      final climbTypeName =
          climbTypeNameRaw is String ? climbTypeNameRaw.toLowerCase() : '';

      final bool? isBoulder;
      if (ctGroup != null) {
        isBoulder = ctGroup == 'boulder';
      } else if (climbTypeName.isNotEmpty) {
        isBoulder = climbTypeName.startsWith('boulder');
      } else {
        isBoulder = null;
      }

      if (isBoulder != null) {
        rec['climb_type'] = _str(isBoulder ? 'boulder' : 'route');
      }

      if (grade != null) {
        final gradeNameRaw = grade['name'];
        if (gradeNameRaw is String) rec['grade'] = _str(gradeNameRaw);
      }

      // lead: always emitted so the engine can clear stale values when an
      // ascent is revised from route→boulder or vice-versa. Boulders and rows
      // where climb_type is unknown or lead is wrong-typed always get
      // {'kind':'null'}; non-boulder rows with a valid bool wire value get
      // {'kind':'bool','value':…}.
      //
      // NOTE: grade/climb_name/attempts/climb_type/ascent_type/notes are NOT
      // extended here — for those fields, absence-on-drift must stay
      // omit-don't-clear (they have no exclusive-pair semantics and their
      // drift scenarios don't require active clearing).
      if (isBoulder == false) {
        final leadRaw = climb['lead'];
        rec['lead'] = leadRaw is bool
            ? {'kind': 'bool', 'value': leadRaw}
            : {'kind': 'null'};
      } else {
        // Boulder (isBoulder == true) or unknown type (isBoulder == null):
        // emit null-kind so any stale route lead is cleared on update.
        rec['lead'] = {'kind': 'null'};
      }
    } else {
      // No climb map: unknown type → emit null-kind for lead so the engine
      // can clear any stale value from a previous, more-complete record.
      rec['lead'] = {'kind': 'null'};
    }

    // Ascent-type: lowercase the name (e.g. 'Flash' → 'flash').
    final ascentTypeRaw = raw['ascent_type'];
    if (ascentTypeRaw is Map) {
      final nameRaw = ascentTypeRaw['name'];
      if (nameRaw is String) rec['ascent_type'] = _str(nameRaw.toLowerCase());
    }

    // Attempts.
    final attempts = raw['attempts'];
    if (attempts is num) {
      rec['attempts'] = {'kind': 'int', 'value': attempts.toInt()};
    }

    // Gym / location: always emit BOTH so the engine clears the stale member
    // when an ascent is revised across the gym↔outdoor boundary.
    //
    // gym: prefer ascent-level gym, fall back to climb.gym.name; null-kind
    //   when neither is available.
    // location: the session destination name when no gym is present AND the
    //   session maps to an outdoor destination; null-kind otherwise.
    //
    // NOTE: grade/climb_name/attempts/climb_type/ascent_type/notes are NOT
    // extended here — absence-on-drift must stay omit-don't-clear for those
    // fields (no exclusive-pair semantics).
    final ascentGymRaw = raw['gym'];
    final ascentGymMap = ascentGymRaw is Map ? ascentGymRaw : null;
    final ascentGymNameRaw = ascentGymMap?['name'];
    final ascentGymName = ascentGymNameRaw is String ? ascentGymNameRaw : null;

    final climbGymRaw = climb?['gym'];
    final climbGymMap = climbGymRaw is Map ? climbGymRaw : null;
    final climbGymNameRaw = climbGymMap?['name'];
    final climbGymName = climbGymNameRaw is String ? climbGymNameRaw : null;

    final gymName = ascentGymName ?? climbGymName;

    rec['gym'] = gymName != null ? _str(gymName) : {'kind': 'null'};

    if (gymName == null && sessionId != null) {
      final dest = destinationBySession[sessionId];
      rec['location'] = dest != null ? _str(dest) : {'kind': 'null'};
    } else {
      rec['location'] = {'kind': 'null'};
    }

    // Notes from comment, only when non-empty.
    final commentRaw = raw['comment'];
    if (commentRaw is String && commentRaw.isNotEmpty) {
      rec['notes'] = _str(commentRaw);
    }

    result.add(rec);
  }
  return result;
}

/// Ids of every ascent Kaya RETURNED, independent of whether the
/// transform could produce a record for it. The reconcile diff must use
/// this — never the transformed records — so a parse regression reads
/// as "row not updated", never "row deleted".
Set<String> kayaFetchedIds(List<dynamic> ascents) {
  final result = <String>{};
  for (final raw in ascents) {
    if (raw is! Map) continue;
    final id = raw['id'];
    if (id == null) continue;
    final idStr = id.toString();
    if (idStr.isEmpty) continue;
    result.add(idStr);
  }
  return result;
}

/// Build a session-id → destination-name map from a list of raw session maps
/// (from `sessionsForUser`). Only sessions that have a non-null `destination`
/// are included. Numeric session ids are coerced to strings.
Map<String, String> kayaDestinationsBySession(List<dynamic> sessions) {
  final result = <String, String>{};
  for (final raw in sessions) {
    if (raw is! Map) continue;
    final id = raw['id'];
    if (id == null) continue;
    final dest = raw['destination'] as Map?;
    if (dest == null) continue;
    final name = dest['name'] as String?;
    if (name == null || name.isEmpty) continue;
    result[id.toString()] = name;
  }
  return result;
}

/// Parse any Kaya date representation to a `yyyy-mm-dd` string, or null if
/// the value cannot be interpreted.
///
/// Accepted forms:
/// - ISO 8601 datetime string: `"2026-09-14T19:03:00.000Z"`
/// - Bare date string: `"2026-09-14"`
/// - Epoch seconds (num < 10^10): `1621728939`
/// - Epoch milliseconds (num ≥ 10^10): `1621728939000`
/// - JS `Date.toString()`: `"Sun May 23 2021 14:15:39 GMT+0000 (GMT)"`
String? kayaDay(dynamic v) {
  if (v == null) return null;

  if (v is num) {
    // Distinguish epoch seconds vs milliseconds by magnitude: values above
    // 10^10 are almost certainly milliseconds (year > 2286 if treated as secs).
    final ms = v >= 1e10 ? v.toInt() : v.toInt() * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    return _fmtDate(dt);
  }

  if (v is String) {
    // ISO 8601 (datetime or bare date) — DateTime.tryParse handles both.
    final dt = DateTime.tryParse(v);
    if (dt != null) return _fmtDate(dt);

    // JS Date.toString() format: "Sun May 23 2021 14:15:39 GMT+0000 (GMT)"
    // Dart's DateTime.tryParse doesn't handle this locale format; parse
    // manually by extracting month-name, day, and year from the string.
    final jsDate = _parseJsDateString(v);
    if (jsDate != null) return jsDate;

    return null;
  }

  return null;
}

/// Ids the ledger credits to Kaya that are no longer in the fetched set —
/// i.e., the `deleted_ids` for a reconcile batch.
///
/// Returns sorted list of (knownIds − fetchedIds).
List<String> kayaDeletedIds({
  required Set<String> fetchedIds,
  required Set<String> knownIds,
}) {
  return (knownIds.difference(fetchedIds).toList())..sort();
}

// Month-name → 1-based month number for JS Date.toString() parsing.
const _kMonths = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

// Matches: "Sun May 23 2021 14:15:39 GMT+0000 (GMT)"
//           dow mon dd   yyyy hh:mm:ss TZ
final _kJsDate = RegExp(
  r'^\w{3}\s+(\w{3})\s+(\d{1,2})\s+(\d{4})\s+\d{2}:\d{2}:\d{2}\s+GMT',
);

/// Parse JS `Date.toString()` format to `yyyy-mm-dd` UTC date string, or
/// null if the string doesn't match the expected pattern.
String? _parseJsDateString(String v) {
  final m = _kJsDate.firstMatch(v);
  if (m == null) return null;
  final month = _kMonths[m.group(1)!.toLowerCase()];
  if (month == null) return null;
  final day = int.parse(m.group(2)!);
  final year = int.parse(m.group(3)!);
  return '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> _str(String v) => {'kind': 'string', 'value': v};

String _fmtDate(DateTime dt) {
  // Assumption: Kaya Z-suffixed timestamps carry the wall-clock date in the
  // gym's local timezone, transmitted as fake-UTC. The date portion is trusted
  // as-is without conversion. This assumption should be verified on-device
  // during rollout: an evening session must land on the correct calendar day.
  // A wrong assumption self-corrects on the next full walk because date is an
  // owned field keyed by kaya_id.
  final d = dt.isUtc ? dt : dt.toUtc();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------------------
// Pull-loop constants
// ---------------------------------------------------------------------------

const _kMinPullInterval = Duration(hours: 6);
const _kPageDelay = Duration(seconds: 2);
const _kPageSize = 100;
const _kMaxOffset = 20000; // runaway guard

// ---------------------------------------------------------------------------
// kayaWalk — extracted pagination loop (package-visible for unit tests)
// ---------------------------------------------------------------------------

/// Fetch all rows from a Kaya paginated endpoint by calling [page] repeatedly
/// starting at offset 0 and incrementing by [pageSize] until a short page
/// (fewer than [pageSize] rows) is received or [maxOffset] is reached.
///
/// A [pageDelay] is inserted BETWEEN pages (not before the first) to avoid
/// hammering the server. The default matches the production constant
/// [_kPageDelay]; tests pass [Duration.zero].
///
/// Propagates [KayaAuthException] directly — the Integration layer handles
/// re-auth above this helper.
Future<List<Map<String, dynamic>>> kayaWalk(
  Future<List<Map<String, dynamic>>> Function(int offset) page, {
  Duration pageDelay = _kPageDelay,
  int pageSize = _kPageSize,
  int maxOffset = _kMaxOffset,
}) async {
  final all = <Map<String, dynamic>>[];
  var offset = 0;
  var first = true;
  while (offset < maxOffset) {
    if (!first) await Future<void>.delayed(pageDelay);
    first = false;
    final rows = await page(offset);
    all.addAll(rows);
    if (rows.length < pageSize) break; // short page → done
    offset += pageSize;
  }
  return all;
}

// ---------------------------------------------------------------------------
// KayaIntegration
// ---------------------------------------------------------------------------

class KayaIntegration implements Integration {
  /// Kaya uses email/password authentication with no app-level credentials
  /// (no client_id or client_secret). The only secret is the user's own
  /// refresh token, which we store in secure storage after a successful login.
  /// Because there are no build-time app secrets, [isConfigured] is always
  /// true — the card is always live.
  KayaIntegration({
    required this.repo,
    required this.climbingViewJson,
    KayaApi? api,
  }) : api = api ?? KayaApi();

  final EngineLedgerRepository repo;

  /// Engine JSON of the climbing view (with date_field applied).
  final Map<String, dynamic> climbingViewJson;

  final KayaApi api;

  static const _storage = FlutterSecureStorage();
  static const _kToken = 'kaya_token';
  static const _kRefresh = 'kaya_refresh';
  static const _kUserId = 'kaya_user_id';

  // Ledger-meta keys (shared source of truth with the card).
  static const _kLastPull = 'integration_kaya_last_pull';
  static const _kStatus = 'integration_kaya_status';
  static const _kError = 'integration_kaya_error';
  static const _kIds = 'integration_kaya_ids';

  @override
  String get id => 'kaya';
  @override
  String get displayName => 'Kaya';
  @override
  String get targetDescription => '→ climbing';
  @override
  bool get isConfigured => true; // no app secrets; always live

  @override
  Future<bool> get isConnected async =>
      (await _storage.read(key: _kRefresh)) != null;

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
    final ids = _decodeIds(await repo.metaGet(_kIds));
    final count = ids.length;
    final when = last == null
        ? 'never'
        : DateTime.tryParse(last)
                ?.toLocal()
                .toString()
                .substring(11, 16) ??
            last;
    return 'Connected · last pulled $when · $count ascent(s) synced';
  }

  @override
  Map<String, Future<void> Function(BuildContext)> get extraMenuActions =>
      const {};

  @override
  Future<void> connect(BuildContext context) async {
    String? dialogError;
    bool busy = false;

    // Per-call controllers: created here, disposed after showDialog returns.
    // Password hygiene: values live only in these local controllers and are
    // never persisted beyond the dialog lifetime.
    final emailController = TextEditingController();
    final passwordController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Connect Kaya'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                enabled: !busy,
                controller: emailController,
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                enabled: !busy,
                controller: passwordController,
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 8),
                Text(
                  dialogError!,
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final email = emailController.text.trim();
                      final password = passwordController.text;
                      if (email.isEmpty || password.isEmpty) {
                        setState(() {
                          dialogError = 'Email and password are required.';
                        });
                        return;
                      }
                      setState(() {
                        busy = true;
                        dialogError = null;
                      });
                      try {
                        final auth = await api.login(email, password);
                        await _storage.write(
                            key: _kToken, value: auth.token);
                        await _storage.write(
                            key: _kRefresh, value: auth.refreshToken);
                        await _storage.write(
                            key: _kUserId, value: auth.userId);
                        if (ctx.mounted) Navigator.of(ctx).pop(true);
                      } catch (e) {
                        if (ctx.mounted) {
                          setState(() {
                            busy = false;
                            dialogError = _loginErrorMessage(e);
                          });
                        }
                      }
                    },
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );

    emailController.dispose();
    passwordController.dispose();

    if (confirmed != true) return;

    await repo.metaSet(_kStatus, 'ok');
    // First pull = full backfill; don't block the UI on it.
    // ignore: unawaited_futures
    pull(force: true);
  }

  @override
  Future<void> disconnect() async {
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kUserId);
    await repo.metaSet(_kStatus, '');
    await repo.metaSet(_kError, '');
    // _kIds intentionally kept: reconnect stays consistent with the
    // provenance the engine still holds (mirrors Withings _kDays).
  }

  @override
  Future<void> pull({bool force = false, bool fullReconcile = false}) async {
    // Every pull already walks the user's full logbook (Kaya's API has no
    // updated-at filter) and diffs against knownIds. fullReconcile bypasses
    // the symmetric mass-delete guard (item 1 below) for cases where the
    // user's logbook is genuinely empty or they want to force a wipe.
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

      // ----------------------------------------------------------------
      // 1. Walk both endpoints concurrently.
      // ----------------------------------------------------------------
      // Fall through with empty strings when token/userId are missing so
      // the first page 401s into the existing refresh/reconnect path and
      // self-heals the status instead of silently returning stale data.
      final token = await _storage.read(key: _kToken) ?? '';
      final userId = await _storage.read(key: _kUserId) ?? '';

      // Shared helper that wraps a single page call with one refresh-retry.
      Future<List<Map<String, dynamic>>> Function(int) ascentsPageFn(
          String tok) {
        return (int offset) => api.ascentsPage(
              token: tok,
              userId: userId,
              offset: offset,
              count: _kPageSize,
            );
      }

      Future<List<Map<String, dynamic>>> Function(int) sessionsPageFn(
          String tok) {
        return (int offset) => api.sessionsPage(
              token: tok,
              userId: userId,
              offset: offset,
              count: _kPageSize,
            );
      }

      // Walk ascents, retrying once on auth failure.
      final ascents = await _walkWithRefresh(ascentsPageFn, token);
      if (ascents == null) return; // reconnect status already set

      // Walk sessions, retrying once on auth failure.
      // We re-read the stored token after a possible refresh during ascents.
      final freshToken =
          await _storage.read(key: _kToken) ?? token;
      final sessions = await _walkWithRefresh(sessionsPageFn, freshToken);
      if (sessions == null) return; // reconnect status already set

      // ----------------------------------------------------------------
      // 2. Transform.
      // ----------------------------------------------------------------
      final records = kayaAscentsToRecords(
        ascents,
        destinationBySession: kayaDestinationsBySession(sessions),
      );

      // fetchedIds uses RAW ascent ids, never derived from records, so a
      // parse regression reads as "row not updated", never "row deleted".
      final fetchedIds = kayaFetchedIds(ascents);

      // ----------------------------------------------------------------
      // 3. Mass-drift guards.
      // ----------------------------------------------------------------
      // 3a. Ascents present but transform produced nothing → wire format
      //     changed; abort rather than mass-deleting rows.
      if (ascents.isNotEmpty && records.isEmpty) {
        await repo.metaSet(_kStatus, 'error');
        await repo.metaSet(
          _kError,
          'kaya: transform produced no records from '
          '${ascents.length} ascents (wire drift?)',
        );
        return;
      }

      final knownIds = _decodeIds(await repo.metaGet(_kIds));

      // 3b. Server returned no ascents but we have known local rows — refuse
      //     mass-delete unless the user explicitly ran Full reconcile, which
      //     is the sanctioned path for a genuinely emptied logbook.
      if (!fullReconcile && fetchedIds.isEmpty && knownIds.isNotEmpty) {
        await repo.metaSet(_kStatus, 'error');
        await repo.metaSet(
          _kError,
          'kaya: server returned no ascents but ${knownIds.length} are known '
          'locally — refusing to mass-delete (run Full reconcile to force)',
        );
        return;
      }

      // ----------------------------------------------------------------
      // 4. Compute deletions and ingest.
      // ----------------------------------------------------------------
      final deleted =
          kayaDeletedIds(fetchedIds: fetchedIds, knownIds: knownIds);

      if (records.isNotEmpty || deleted.isNotEmpty) {
        await repo.ingest(climbingViewJson, {
          'source': 'kaya',
          'match_field': 'kaya_id',
          'owned_fields': [
            'kaya_id',
            'date',
            'climb_name',
            'climb_type',
            'grade',
            'ascent_type',
            'attempts',
            'lead',
            'gym',
            'location',
          ],
          'fill_if_blank_fields': ['notes'],
          'records': records,
          'deleted_ids': deleted,
        });
        final sortedIds = fetchedIds.toList()..sort();
        await repo.metaSet(_kIds, jsonEncode(sortedIds));
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

  Set<String> _decodeIds(String? json) {
    if (json == null || json.isEmpty) return <String>{};
    final decoded = jsonDecode(json);
    return decoded is List ? decoded.cast<String>().toSet() : <String>{};
  }

  /// Walk a paginated endpoint, retrying once if a [KayaAuthException] is
  /// thrown. On retry failure (or refresh-token rejection) sets the status
  /// to 'reconnect' and returns null so pull() can abort silently.
  Future<List<Map<String, dynamic>>?> _walkWithRefresh(
    Future<List<Map<String, dynamic>>> Function(int) Function(String token)
        pageFn,
    String currentToken,
  ) async {
    try {
      return await kayaWalk(pageFn(currentToken));
    } on KayaAuthException {
      // First auth failure: try to refresh and retry once.
      final newToken = await _refreshToken();
      if (newToken == null) return null; // reconnect status already set
      try {
        return await kayaWalk(pageFn(newToken));
      } on KayaAuthException {
        await repo.metaSet(_kStatus, 'reconnect');
        return null;
      }
    }
  }

  /// Exchange the stored refresh token for a new bearer token and persist it.
  /// Returns the new token, or null on any failure (status set to 'reconnect').
  Future<String?> _refreshToken() async {
    final refreshToken = await _storage.read(key: _kRefresh);
    if (refreshToken == null) {
      await repo.metaSet(_kStatus, 'reconnect');
      return null;
    }
    try {
      final newToken = await api.refresh(refreshToken);
      await _storage.write(key: _kToken, value: newToken);
      return newToken;
    } catch (_) {
      await repo.metaSet(_kStatus, 'reconnect');
      return null;
    }
  }

  String _loginErrorMessage(Object e) {
    if (e is StateError) {
      final msg = e.message.toLowerCase();
      if (msg.contains('401') || msg.contains('login failed')) {
        return 'Incorrect email or password.';
      }
    }
    return 'Connection failed. Please try again.';
  }
}
