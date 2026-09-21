// Pure-transform tests for the Macrofactor (Health Connect nutrition)
// → meals integration. The gateway (platform channel) cannot run in
// tests, so MacrofactorIntegration stays thin glue over these
// functions, which are exercised exhaustively here on plain maps.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/integrations/macrofactor.dart';

// ---------------------------------------------------------------------------
// Fixture builders — mirror the gateway map shape including noise fields.
// ---------------------------------------------------------------------------

/// Full nutrition point as the gateway adapter emits it. Callers mutate
/// the returned map to exercise edge cases; `source_name` is noise the
/// transform must ignore.
Map<String, dynamic> _point({
  Object? uuid = 'hc-1',
  Object? dateFrom,
  Object? name = 'Chicken and rice',
  Object? mealType = 'LUNCH',
  Object? calories = 650.0,
  Object? protein = 42.0,
  Object? carbs = 71.5,
  Object? fat = 12.0,
}) {
  return {
    'uuid': uuid,
    'date_from': dateFrom ?? DateTime(2026, 9, 14, 12, 30, 5),
    'name': name,
    'meal_type': mealType,
    'calories': calories,
    'protein': protein,
    'carbs': carbs,
    'fat': fat,
    'source_name': 'com.example.macrofactor', // noise — ignored
  };
}

void main() {
  // -------------------------------------------------------------------------
  // hcNutritionToRecords: happy path
  // -------------------------------------------------------------------------

  test('full point maps to a kind-tagged meals record', () {
    final recs = hcNutritionToRecords([_point()]);
    expect(recs, hasLength(1));
    final r = recs.first;
    expect(r['hc_id'], {'kind': 'string', 'value': 'hc-1'});
    expect(r['eaten_at'],
        {'kind': 'date_time', 'value': '2026-09-14T12:30:05'});
    expect(r['meal'], {'kind': 'string', 'value': 'Chicken and rice'});
    expect(r['meal_type'], {'kind': 'string', 'value': 'lunch'});
    expect(r['calories'], {'kind': 'float', 'value': 650.0});
    expect(r['protein_g'], {'kind': 'float', 'value': 42.0});
    expect(r['carbs_g'], {'kind': 'float', 'value': 71.5});
    expect(r['fat_g'], {'kind': 'float', 'value': 12.0});
    // Noise never leaks into the record.
    expect(r.containsKey('source_name'), isFalse);
    expect(r.containsKey('name'), isFalse);
  });

  test('macro values round to one decimal', () {
    final recs = hcNutritionToRecords([
      _point(calories: 650.456, protein: 41.94, carbs: 0.049, fat: 12)
    ]);
    final r = recs.first;
    expect(r['calories'], {'kind': 'float', 'value': 650.5});
    expect(r['protein_g'], {'kind': 'float', 'value': 41.9});
    expect(r['carbs_g'], {'kind': 'float', 'value': 0.0});
    expect(r['fat_g'], {'kind': 'float', 'value': 12.0});
  });

  test('ISO-string date_from is accepted (component-preserving)', () {
    final recs =
        hcNutritionToRecords([_point(dateFrom: '2026-09-14T07:05:00')]);
    expect(recs.first['eaten_at'],
        {'kind': 'date_time', 'value': '2026-09-14T07:05:00'});
  });

  // -------------------------------------------------------------------------
  // hcNutritionToRecords: meal name fallbacks
  // -------------------------------------------------------------------------

  test('empty name falls back to Macrofactor <meal type>', () {
    final recs = hcNutritionToRecords([_point(name: '')]);
    expect(recs.first['meal'],
        {'kind': 'string', 'value': 'Macrofactor lunch'});
  });

  test('null name + UNKNOWN meal type falls back to Macrofactor entry', () {
    final recs =
        hcNutritionToRecords([_point(name: null, mealType: 'UNKNOWN')]);
    expect(recs.first['meal'],
        {'kind': 'string', 'value': 'Macrofactor entry'});
  });

  // -------------------------------------------------------------------------
  // hcNutritionToRecords: meal_type mapping
  // -------------------------------------------------------------------------

  test('all four known meal types map to lowercase dropdown values', () {
    for (final mt in ['BREAKFAST', 'LUNCH', 'DINNER', 'SNACK']) {
      final recs = hcNutritionToRecords([_point(mealType: mt)]);
      expect(recs.first['meal_type'],
          {'kind': 'string', 'value': mt.toLowerCase()},
          reason: mt);
    }
  });

  test('UNKNOWN / null / garbage meal type is omitted', () {
    for (final mt in ['UNKNOWN', null, 'BRUNCH', 42]) {
      final recs = hcNutritionToRecords([_point(mealType: mt)]);
      expect(recs.first.containsKey('meal_type'), isFalse, reason: '$mt');
    }
  });

  // -------------------------------------------------------------------------
  // hcNutritionToRecords: malformed points
  // -------------------------------------------------------------------------

  test('non-map, missing/empty uuid, and bad date points are dropped', () {
    final recs = hcNutritionToRecords([
      'not a map',
      42,
      null,
      _point(uuid: null),
      _point(uuid: ''),
      _point(dateFrom: 'yesterday-ish'),
      _point(dateFrom: null)..remove('date_from'),
      _point(uuid: 'keep-me'),
    ]);
    expect(recs, hasLength(1));
    expect(recs.first['hc_id'], {'kind': 'string', 'value': 'keep-me'});
  });

  test('wrong-typed macro fields are omitted, row survives', () {
    final recs = hcNutritionToRecords([
      _point(calories: 'lots', protein: null, carbs: true, fat: 12.0)
    ]);
    expect(recs, hasLength(1));
    final r = recs.first;
    expect(r.containsKey('calories'), isFalse);
    expect(r.containsKey('protein_g'), isFalse);
    expect(r.containsKey('carbs_g'), isFalse);
    expect(r['fat_g'], {'kind': 'float', 'value': 12.0});
  });

  test('int macro values are accepted as floats', () {
    final recs = hcNutritionToRecords([_point(calories: 650)]);
    expect(recs.first['calories'], {'kind': 'float', 'value': 650.0});
  });

  test('duplicate uuids keep the first point only', () {
    final recs = hcNutritionToRecords([
      _point(uuid: 'dup', calories: 100.0),
      _point(uuid: 'dup', calories: 999.0),
    ]);
    expect(recs, hasLength(1));
    expect(recs.first['calories'], {'kind': 'float', 'value': 100.0});
  });

  // -------------------------------------------------------------------------
  // hcFetchedIds — raw wire ids, independent of transform success
  // -------------------------------------------------------------------------

  test('hcFetchedIds keeps ids the transform drops (bad date)', () {
    final ids = hcFetchedIds([
      _point(uuid: 'a'),
      _point(uuid: 'b', dateFrom: 'garbage'), // transform drops this one
      _point(uuid: null),
      _point(uuid: ''),
      'not a map',
    ]);
    expect(ids, {'a', 'b'});
  });

  // -------------------------------------------------------------------------
  // hcDatetime
  // -------------------------------------------------------------------------

  test('hcDatetime formats DateTime components without conversion', () {
    expect(hcDatetime(DateTime(2026, 1, 2, 3, 4, 5)), '2026-01-02T03:04:05');
  });

  test('hcDatetime parses ISO strings and rejects garbage', () {
    expect(hcDatetime('2026-09-14T19:03:00.000'), '2026-09-14T19:03:00');
    expect(hcDatetime('2026-09-14'), '2026-09-14T00:00:00');
    expect(hcDatetime('sometime'), isNull);
    expect(hcDatetime(null), isNull);
    expect(hcDatetime(42), isNull);
  });

  // -------------------------------------------------------------------------
  // hcKnownIdsInWindow — deletion diff scoped to the read window
  // -------------------------------------------------------------------------

  test('hcKnownIdsInWindow keeps only ids on/after the window start day', () {
    final known = {
      'old': '2026-08-01',
      'edge': '2026-09-01',
      'new': '2026-09-10',
    };
    expect(
      hcKnownIdsInWindow(known, windowStartDay: '2026-09-01'),
      {'edge', 'new'},
    );
    // Epoch-ish start → everything (full reconcile).
    expect(
      hcKnownIdsInWindow(known, windowStartDay: '1970-01-01'),
      {'old', 'edge', 'new'},
    );
  });

  // -------------------------------------------------------------------------
  // hcDeletedIds
  // -------------------------------------------------------------------------

  test('hcDeletedIds is the sorted known-minus-fetched difference', () {
    expect(
      hcDeletedIds(
        fetchedIds: {'b'},
        knownIdsInWindow: {'c', 'a', 'b'},
      ),
      ['a', 'c'],
    );
    expect(
      hcDeletedIds(fetchedIds: {'a'}, knownIdsInWindow: {'a'}),
      isEmpty,
    );
  });
}
