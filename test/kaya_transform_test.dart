import 'package:airledger/services/integrations/kaya.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fixture builders — mirror the wire shape including noise fields.
// ---------------------------------------------------------------------------

/// Full gym boulder ascent fixture. Callers mutate the returned map to
/// exercise edge cases; the noise fields (rating, stiffness) prove they're
/// ignored by the transform.
Map<String, dynamic> _gymAscent({
  String id = 'a1',
  String sessionId = 's1',
  String date = '2026-09-14T19:03:00.000Z',
  String comment = 'Felt great',
  String ascentTypeName = 'Flash',
  int attempts = 1,
  bool lead = false,
  String climbName = 'Some Boulder',
  String climbTypeName = 'Boulders',
  String? climbTypeGroup = 'boulder',
  String gradeName = 'V5',
  String? ascentGymName = 'Movement RiNo',
  String? climbGymName = 'Movement RiNo',
}) {
  return {
    'id': id,
    'session_id': sessionId,
    'date': date,
    'comment': comment,
    'rating': 4, // noise — ignored
    'stiffness': 2, // noise — ignored
    'attempts': attempts,
    'ascent_type': {'id': 'at1', 'name': ascentTypeName},
    'gym': ascentGymName != null
        ? {'id': 'g1', 'name': ascentGymName, 'city': 'Denver'}
        : null,
    'climb': {
      'id': 'c1',
      'name': climbName,
      'lead': lead,
      'climb_type': {'id': 'ct1', 'name': climbTypeName},
      'grade': {
        'id': 'gr1',
        'name': gradeName,
        'climb_type_group': climbTypeGroup,
      },
      'gym': climbGymName != null
          ? {'id': 'g1', 'name': climbGymName, 'city': 'Denver'}
          : null,
    },
  };
}

/// Minimal outdoor route ascent for the destination/location tests.
Map<String, dynamic> _outdoorRoute({
  String id = 'a2',
  String sessionId = 's2',
  String date = '2026-09-10T11:00:00.000Z',
  bool lead = true,
}) {
  return {
    'id': id,
    'session_id': sessionId,
    'date': date,
    'comment': '',
    'rating': 3,
    'stiffness': 1,
    'attempts': 2,
    'ascent_type': {'id': 'at2', 'name': 'Redpoint'},
    'gym': null,
    'climb': {
      'id': 'c2',
      'name': 'Classic Route',
      'lead': lead,
      'climb_type': {'id': 'ct2', 'name': 'Routes'},
      'grade': {
        'id': 'gr2',
        'name': '5.11a',
        'climb_type_group': 'route',
      },
      'gym': null,
    },
  };
}

void main() {
  // -------------------------------------------------------------------------
  // 1. Gym boulder ascent → full record with correct kind-tags.
  // -------------------------------------------------------------------------

  test('gym boulder: kind-tags exact, climb_type from climb_type_group, '
      'no lead key, no location, gym from ascent', () {
    final ascents = [_gymAscent()];
    final recs = kayaAscentsToRecords(ascents);

    expect(recs, hasLength(1));
    final r = recs.first;

    expect(r['kaya_id'], {'kind': 'string', 'value': 'a1'});
    expect(r['date'], {'kind': 'date', 'value': '2026-09-14'});
    expect(r['climb_name'], {'kind': 'string', 'value': 'Some Boulder'});
    expect(r['climb_type'], {'kind': 'string', 'value': 'boulder'});
    expect(r['grade'], {'kind': 'string', 'value': 'V5'});
    expect(r['ascent_type'], {'kind': 'string', 'value': 'flash'}); // lowercased
    expect(r['attempts'], {'kind': 'int', 'value': 1});
    expect(r['gym'], {'kind': 'string', 'value': 'Movement RiNo'});
    expect(r['notes'], {'kind': 'string', 'value': 'Felt great'});

    // Boulder → no lead key at all.
    expect(r.containsKey('lead'), isFalse);
    // No outdoor destination → no location key.
    expect(r.containsKey('location'), isFalse);
  });

  // -------------------------------------------------------------------------
  // 2. Outdoor route → route, lead emitted, location from destinationBySession.
  // -------------------------------------------------------------------------

  test('outdoor route: climb_type route, lead true emitted, '
      'location from destinationBySession, no gym key', () {
    final ascents = [_outdoorRoute()];
    final destMap = {'s2': 'Red Rock Canyon'};
    final recs = kayaAscentsToRecords(ascents, destinationBySession: destMap);

    expect(recs, hasLength(1));
    final r = recs.first;

    expect(r['climb_type'], {'kind': 'string', 'value': 'route'});
    expect(r['lead'], {'kind': 'bool', 'value': true});
    expect(r['location'], {'kind': 'string', 'value': 'Red Rock Canyon'});
    // No gym on ascent or climb, and has destination → location, not gym.
    expect(r.containsKey('gym'), isFalse);
    // Empty comment → no notes key.
    expect(r.containsKey('notes'), isFalse);
  });

  // -------------------------------------------------------------------------
  // 3. Plural-name fallback: grade.climb_type_group missing → derive from
  //    climb_type.name 'Boulders'.
  // -------------------------------------------------------------------------

  test('plural-name fallback: missing climb_type_group, '
      "climb_type.name 'Boulders' → boulder", () {
    final a = _gymAscent(climbTypeGroup: null, climbTypeName: 'Boulders');
    final recs = kayaAscentsToRecords([a]);

    expect(recs, hasLength(1));
    expect(recs.first['climb_type'], {'kind': 'string', 'value': 'boulder'});
  });

  // -------------------------------------------------------------------------
  // 4a. Boulder with lead:false → no lead key emitted.
  // -------------------------------------------------------------------------

  test('boulder with lead:false → no lead key', () {
    final a = _gymAscent(climbTypeGroup: 'boulder', lead: false);
    final recs = kayaAscentsToRecords([a]);

    expect(recs.first.containsKey('lead'), isFalse);
  });

  // -------------------------------------------------------------------------
  // 4b. Route with lead:false → lead false emitted.
  // -------------------------------------------------------------------------

  test('route with lead:false → lead:false emitted', () {
    final a = _outdoorRoute(lead: false);
    final recs = kayaAscentsToRecords([a], destinationBySession: {'s2': 'Dest'});

    expect(recs.first['lead'], {'kind': 'bool', 'value': false});
  });

  // -------------------------------------------------------------------------
  // 5. kayaDestinationsBySession: with/without destination, numeric ids.
  // -------------------------------------------------------------------------

  test('kayaDestinationsBySession: sessions with/without destination, '
      'numeric ids coerced to string', () {
    final sessions = [
      {
        'id': 10, // numeric — must be coerced
        'start_time': '2026-09-10T09:00:00.000Z',
        'end_time': '2026-09-10T11:00:00.000Z',
        'notes': null,
        'gym': null,
        'board': null,
        'destination': {'id': 'd1', 'name': 'Red Rock Canyon', 'latitude': 36.1},
      },
      {
        'id': '11',
        'start_time': '2026-09-12T09:00:00.000Z',
        'end_time': '2026-09-12T12:00:00.000Z',
        'notes': 'indoor day',
        'gym': {'id': 'g1', 'name': 'Movement'},
        'board': null,
        'destination': null, // gym session → no destination
      },
      {
        'id': '12',
        // no destination key at all
        'start_time': '2026-09-13T09:00:00.000Z',
      },
    ];
    final result = kayaDestinationsBySession(sessions);

    expect(result, {'10': 'Red Rock Canyon'});
    expect(result.containsKey('11'), isFalse);
    expect(result.containsKey('12'), isFalse);
  });

  // -------------------------------------------------------------------------
  // 6. Date tolerance: ISO datetime, bare date, epoch secs, epoch ms, JS
  //    toString format → yyyy-mm-dd; null / garbage → null (ascent dropped).
  // -------------------------------------------------------------------------

  test('kayaDay: ISO datetime string → yyyy-mm-dd', () {
    expect(kayaDay('2026-09-14T19:03:00.000Z'), '2026-09-14');
  });

  test('kayaDay: bare date string → yyyy-mm-dd', () {
    expect(kayaDay('2026-09-14'), '2026-09-14');
  });

  test('kayaDay: epoch seconds (small number) → yyyy-mm-dd', () {
    // 2021-05-23 in epoch seconds = 1621728939
    expect(kayaDay(1621728939), '2021-05-23');
  });

  test('kayaDay: epoch milliseconds (large number) → yyyy-mm-dd', () {
    // 2021-05-23 in epoch ms = 1621728939000
    expect(kayaDay(1621728939000), '2021-05-23');
  });

  test('kayaDay: JS Date.toString() format → yyyy-mm-dd', () {
    expect(
      kayaDay('Sun May 23 2021 14:15:39 GMT+0000 (GMT)'),
      '2021-05-23',
    );
  });

  test('kayaDay: null → null', () {
    expect(kayaDay(null), isNull);
  });

  test('kayaDay: garbage string → null', () {
    expect(kayaDay('not-a-date'), isNull);
  });

  test('ascents with unparseable date are dropped', () {
    final ascents = [
      _gymAscent(id: 'good', date: '2026-09-14T19:03:00.000Z'),
      {..._gymAscent(id: 'bad'), 'date': 'garbage'},
    ];
    final recs = kayaAscentsToRecords(ascents);
    expect(recs, hasLength(1));
    expect((recs.first['kaya_id'] as Map)['value'], 'good');
  });

  // -------------------------------------------------------------------------
  // 7. Junk resilience: non-map entries, missing id, missing date → dropped.
  // -------------------------------------------------------------------------

  test('junk resilience: non-map, missing id, missing date dropped; '
      'valid entries survive', () {
    final ascents = [
      'not a map', // non-map
      {'session_id': 's1', 'date': '2026-09-01T00:00:00.000Z'}, // missing id
      {..._gymAscent(id: 'ok'), 'date': null}, // null date
      _gymAscent(id: 'valid'),
    ];
    final recs = kayaAscentsToRecords(ascents);
    expect(recs, hasLength(1));
    expect((recs.first['kaya_id'] as Map)['value'], 'valid');
  });

  test('ascent with id but no climb still produces a record', () {
    final a = <String, dynamic>{
      'id': 'bare',
      'session_id': 's9',
      'date': '2026-09-01T12:00:00.000Z',
      'comment': '',
      'rating': 3,
      'stiffness': 0,
      'attempts': 1,
      'ascent_type': {'id': 'at1', 'name': 'Onsight'},
      'gym': {'id': 'g1', 'name': 'Local Gym'},
      'climb': null,
    };
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect((recs.first['kaya_id'] as Map)['value'], 'bare');
    expect(recs.first['date'], {'kind': 'date', 'value': '2026-09-01'});
    // gym from ascent-level gym
    expect(recs.first['gym'], {'kind': 'string', 'value': 'Local Gym'});
  });

  // -------------------------------------------------------------------------
  // 8. kayaDeletedIds: set arithmetic, sorted output.
  // -------------------------------------------------------------------------

  test('kayaDeletedIds: {a1,a3} fetched vs {a0,a1,a2,a3} known → [a0, a2]',
      () {
    final result = kayaDeletedIds(
      fetchedIds: {'a1', 'a3'},
      knownIds: {'a0', 'a1', 'a2', 'a3'},
    );
    expect(result, ['a0', 'a2']);
  });

  test('kayaDeletedIds: equal sets → empty list', () {
    final result = kayaDeletedIds(
      fetchedIds: {'x1', 'x2'},
      knownIds: {'x1', 'x2'},
    );
    expect(result, isEmpty);
  });

  // -------------------------------------------------------------------------
  // Gym preference: ascent.gym.name preferred over climb.gym.name.
  // -------------------------------------------------------------------------

  test('gym preference: ascent gym wins over climb gym', () {
    final a = _gymAscent(
      ascentGymName: 'Ascent Gym',
      climbGymName: 'Climb Gym',
    );
    final recs = kayaAscentsToRecords([a]);
    expect(recs.first['gym'], {'kind': 'string', 'value': 'Ascent Gym'});
  });

  test('gym fallback: ascent.gym null → climb.gym.name', () {
    final a = _gymAscent(
      ascentGymName: null,
      climbGymName: 'Climb Gym',
    );
    final recs = kayaAscentsToRecords([a]);
    expect(recs.first['gym'], {'kind': 'string', 'value': 'Climb Gym'});
  });
}
