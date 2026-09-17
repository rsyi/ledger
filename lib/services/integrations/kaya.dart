/// Kaya climbing-app → ledger integration: transform + reconcile-diff.
///
/// Design: no cursor. Every pull fetches ALL ascents for the user (the Kaya
/// GraphQL endpoint supports offset+count paging but has no updatedat filter).
/// Because we fetch the full logbook every time, the transform is sort-order-
/// independent and all upserts are idempotent by kaya_id — re-running with the
/// same data is a no-op at the engine layer. Deletions are computed as
/// (knownIds - fetchedIds), matching the full-walk reconcile pattern used by
/// Withings. A KayaIntegration class (next task) drives the pull loop and
/// plugs into the integration registry; this file contains only the pure
/// transform functions it depends on.
library;

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

      // lead: only emit for non-boulder rows. The wire value is false on
      // boulders (not null), so we must gate on type, not null-check.
      if (isBoulder == false) {
        final leadRaw = climb['lead'];
        if (leadRaw is bool) rec['lead'] = {'kind': 'bool', 'value': leadRaw};
      }
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

    // Gym name: prefer ascent-level gym, fall back to climb.gym.name.
    // If neither, and the session has a destination, emit location instead.
    final ascentGymRaw = raw['gym'];
    final ascentGymMap = ascentGymRaw is Map ? ascentGymRaw : null;
    final ascentGymNameRaw = ascentGymMap?['name'];
    final ascentGymName = ascentGymNameRaw is String ? ascentGymNameRaw : null;

    final climbGymRaw = climb?['gym'];
    final climbGymMap = climbGymRaw is Map ? climbGymRaw : null;
    final climbGymNameRaw = climbGymMap?['name'];
    final climbGymName = climbGymNameRaw is String ? climbGymNameRaw : null;

    final gymName = ascentGymName ?? climbGymName;

    if (gymName != null) {
      rec['gym'] = _str(gymName);
    } else if (sessionId != null) {
      final dest = destinationBySession[sessionId];
      if (dest != null) rec['location'] = _str(dest);
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
