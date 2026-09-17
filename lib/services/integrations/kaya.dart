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

// No flutter imports needed: pure Dart transform functions only.

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Transform a raw list of Kaya ascent maps (from `ascentsForUser`) into
/// engine ingest records tagged with kind metadata.
///
/// [destinationBySession] maps session_id → destination name for outdoor
/// sessions; build it with [kayaDestinationsBySession] before calling this.
///
/// Malformed ascents (non-map, missing/null id, unparseable date) are silently
/// dropped — caller should log the count if needed.
List<Map<String, dynamic>> kayaAscentsToRecords(
  List<dynamic> ascents, {
  Map<String, String> destinationBySession = const {},
}) {
  final result = <Map<String, dynamic>>[];
  for (final raw in ascents) {
    if (raw is! Map) continue;
    final id = raw['id'];
    if (id == null) continue;
    final day = kayaDay(raw['date']);
    if (day == null) continue;

    final rec = <String, dynamic>{
      'kaya_id': _str(id.toString()),
      'date': {'kind': 'date', 'value': day},
    };

    // Derive session destination for location lookup; session_id may be a
    // number on the wire so coerce to string.
    final sessionId = raw['session_id']?.toString();

    final climb = raw['climb'] as Map?;

    // Climb-level fields (only when climb is present).
    if (climb != null) {
      final climbName = climb['name'];
      if (climbName != null) rec['climb_name'] = _str(climbName as String);

      // Derive boulder/route from climb_type_group first; fall back to
      // lowercased climb_type.name prefix match ('boulder…' → boulder, else
      // route). The API returns PLURAL names ("Boulders", "Routes") so the
      // simple startsWith works correctly.
      final grade = climb['grade'] as Map?;
      final ctGroup = grade?['climb_type_group'] as String?;
      final climbTypeName =
          ((climb['climb_type'] as Map?)?['name'] as String? ?? '').toLowerCase();
      final isBoulder = ctGroup != null
          ? ctGroup == 'boulder'
          : climbTypeName.startsWith('boulder');
      rec['climb_type'] = _str(isBoulder ? 'boulder' : 'route');

      if (grade != null) {
        final gradeName = grade['name'] as String?;
        if (gradeName != null) rec['grade'] = _str(gradeName);
      }

      // lead: only emit for non-boulder rows. The wire value is false on
      // boulders (not null), so we must gate on type, not null-check.
      if (!isBoulder) {
        final lead = climb['lead'];
        if (lead != null) rec['lead'] = {'kind': 'bool', 'value': lead as bool};
      }
    }

    // Ascent-type: lowercase the name (e.g. 'Flash' → 'flash').
    final ascentType = (raw['ascent_type'] as Map?)?['name'] as String?;
    if (ascentType != null) rec['ascent_type'] = _str(ascentType.toLowerCase());

    // Attempts.
    final attempts = raw['attempts'];
    if (attempts != null) {
      rec['attempts'] = {'kind': 'int', 'value': (attempts as num).toInt()};
    }

    // Gym name: prefer ascent-level gym, fall back to climb.gym.name.
    // If neither, and the session has a destination, emit location instead.
    final ascentGymName = (raw['gym'] as Map?)?['name'] as String?;
    final climbGymName = (climb?['gym'] as Map?)?['name'] as String?;
    final gymName = ascentGymName ?? climbGymName;

    if (gymName != null) {
      rec['gym'] = _str(gymName);
    } else if (sessionId != null) {
      final dest = destinationBySession[sessionId];
      if (dest != null) rec['location'] = _str(dest);
    }

    // Notes from comment, only when non-empty.
    final comment = raw['comment'] as String?;
    if (comment != null && comment.isNotEmpty) rec['notes'] = _str(comment);

    result.add(rec);
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

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

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
  // UTC is the right frame: dates on Kaya are stamped at the gym timezone but
  // transmitted as UTC ISO strings; we trust the date portion as-is.
  final d = dt.isUtc ? dt : dt.toUtc();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
