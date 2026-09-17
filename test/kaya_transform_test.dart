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

  // -------------------------------------------------------------------------
  // 9. is-guards: wrong-typed fields skip gracefully instead of throwing.
  // -------------------------------------------------------------------------

  test('wrong-typed climb.name (int) → record produced without climb_name', () {
    final a = _gymAscent();
    // Overwrite climb.name with a non-String to trigger the guard.
    (a['climb'] as Map)['name'] = 123;
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect(recs.first.containsKey('climb_name'), isFalse);
  });

  test("wrong-typed attempts ('two') → record produced without attempts", () {
    final a = _gymAscent();
    a['attempts'] = 'two';
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect(recs.first.containsKey('attempts'), isFalse);
  });

  test('wrong-typed ascent_type (not a Map) → record produced without ascent_type', () {
    final a = _gymAscent();
    a['ascent_type'] = 'Flash';
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect(recs.first.containsKey('ascent_type'), isFalse);
  });

  test('wrong-typed ascent.gym (not a Map) falls through to climb.gym', () {
    // When ascent.gym is not a Map it is skipped; climb.gym.name is the fallback.
    final a = _gymAscent(ascentGymName: 'Ascent Gym', climbGymName: 'Climb Gym');
    a['gym'] = 'not-a-map';
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    // ascent.gym is malformed → falls back to climb.gym
    expect(recs.first['gym'], {'kind': 'string', 'value': 'Climb Gym'});
  });

  test('wrong-typed ascent.gym and no climb.gym → gym field absent', () {
    // Both ascent.gym and climb.gym are non-Map → no gym key emitted.
    final a = _gymAscent(ascentGymName: null, climbGymName: null);
    a['gym'] = 'not-a-map';
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect(recs.first.containsKey('gym'), isFalse);
  });

  test('wrong-typed lead (not a bool) → lead field skipped', () {
    final a = _outdoorRoute();
    (a['climb'] as Map)['lead'] = 'yes';
    final recs = kayaAscentsToRecords([a], destinationBySession: {'s2': 'Dest'});
    expect(recs, hasLength(1));
    expect(recs.first.containsKey('lead'), isFalse);
  });

  test('wrong-typed climb (not a Map) → record produced without climb fields', () {
    final a = _gymAscent();
    a['climb'] = 'not a map';
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect(recs.first.containsKey('climb_name'), isFalse);
    expect(recs.first.containsKey('climb_type'), isFalse);
    expect(recs.first.containsKey('grade'), isFalse);
  });

  test('wrong-typed comment (not a String) → notes field skipped', () {
    final a = _gymAscent();
    a['comment'] = 42;
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect(recs.first.containsKey('notes'), isFalse);
  });

  // -------------------------------------------------------------------------
  // 10. kayaFetchedIds: extracts ids from the raw list.
  // -------------------------------------------------------------------------

  test('kayaFetchedIds: returns id of each valid ascent map', () {
    final ascents = [
      _gymAscent(id: 'a1'),
      _outdoorRoute(id: 'a2'),
    ];
    final ids = kayaFetchedIds(ascents);
    expect(ids, {'a1', 'a2'});
  });

  test('kayaFetchedIds: numeric ids coerced to string', () {
    final ascents = [
      {'id': 12345, 'date': '2026-09-14T00:00:00.000Z'},
    ];
    final ids = kayaFetchedIds(ascents);
    expect(ids, {'12345'});
  });

  test('kayaFetchedIds: mixed junk list → only real ids', () {
    final ascents = [
      'not a map', // non-map: skipped
      {'date': '2026-09-01T00:00:00.000Z'}, // no id: skipped
      {'id': null, 'date': '2026-09-01T00:00:00.000Z'}, // null id: skipped
      {'id': '', 'date': '2026-09-01T00:00:00.000Z'}, // empty id: skipped
      {'id': 'real', 'date': '2026-09-01T00:00:00.000Z'},
    ];
    final ids = kayaFetchedIds(ascents);
    expect(ids, {'real'});
  });

  test('kayaFetchedIds: ascent with unparseable date still contributes its id', () {
    final ascents = [
      {'id': 'bad-date', 'date': 'garbage'},
    ];
    // Transform would drop this ascent, but kayaFetchedIds must still return it.
    final ids = kayaFetchedIds(ascents);
    expect(ids, {'bad-date'});
  });

  // -------------------------------------------------------------------------
  // 11. Empty-string id → ascent dropped in transform.
  // -------------------------------------------------------------------------

  test('ascent with empty-string id is dropped by transform', () {
    final a = _gymAscent();
    a['id'] = '';
    final recs = kayaAscentsToRecords([a]);
    expect(recs, isEmpty);
  });

  // -------------------------------------------------------------------------
  // 12. No climb_type when climb present but no usable type signal.
  // -------------------------------------------------------------------------

  test('climb present but no grade.climb_type_group and no climb_type.name → no climb_type key', () {
    final a = _gymAscent(climbTypeGroup: null, climbTypeName: '');
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect(recs.first.containsKey('climb_type'), isFalse);
  });

  // -------------------------------------------------------------------------
  // 13. Numeric ascent id coercion in transform.
  // -------------------------------------------------------------------------

  test('numeric ascent id coerced to string kaya_id', () {
    final a = Map<String, dynamic>.from(_gymAscent());
    a['id'] = 12345;
    final recs = kayaAscentsToRecords([a]);
    expect(recs, hasLength(1));
    expect(recs.first['kaya_id'], {'kind': 'string', 'value': '12345'});
  });
}
