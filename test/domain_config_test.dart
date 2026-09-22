import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/doc_cache.dart';
import 'package:airledger/services/domain_config.dart';

const fixtureYaml = '''
# comment header
domains:
  - name: strength
    paradigm: entry
    views: [strength]
    icon: dumbbell
    metrics:
      - id: pl_total
        kind: stat
        label: "PL total"
        unit: lb
        goal: null
      - id: e1rm_reference
        kind: stat
        lifts: [squat, bench, deadlift, press]
      - id: all_time_best_weight
        kind: best
        lifts: [squat, bench, deadlift, press]
      - id: wilks_series
        kind: series
        from: "2026-09-21"
        floor_pct: 2.5
        goal_note: "hold within 2.5% of cut start"
  - name: weight
    paradigm: entry
    views: [weight]
    icon: scale
    metrics:
      - id: bw_series
        kind: series
        unit: lb
        goal: 154
        goal_note: "phase target"
      - id: bf_series
        kind: series
        unit: "%"
  - name: daily_notes
    paradigm: entry
    views: [daily_notes]
    icon: notebook-pen
    metrics: []
  - name: climbing
    paradigm: integration
    views: [climbing]
    icon: mountain
    list_fields: [grade, color, gym, ascent_type]
    metrics:
      - id: session_frequency
        kind: series
        goal: 2
  - name: meals
    paradigm: integration
    views: [meals]
    list_fields:
      - meal
      - { field: calories, unit: kcal }
      - { field: protein_g, unit: g }
    metrics:
      - id: protein_series
        kind: series
        unit: g
        goal_band_per_lb: [0.8, 1.0]
''';

void main() {
  group('parseDomainConfigs', () {
    test('parses the fixture shape', () {
      final domains = parseDomainConfigs(fixtureYaml)!;
      expect(domains, hasLength(5));

      final strength = domains[0];
      expect(strength.name, 'strength');
      expect(strength.paradigm, DomainParadigm.entry);
      expect(strength.views, ['strength']);
      expect(strength.primaryView, 'strength');
      expect(strength.icon, 'dumbbell');
      expect(strength.metrics, hasLength(4));
      expect(strength.metrics[0].id, 'pl_total');
      expect(strength.metrics[0].kind, MetricKind.stat);
      expect(strength.metrics[0].label, 'PL total');
      expect(strength.metrics[0].unit, 'lb');
      expect(strength.metrics[0].goal, isNull); // explicit goal: null
      expect(strength.metrics[1].lifts,
          ['squat', 'bench', 'deadlift', 'press']);
      expect(strength.metrics[2].kind, MetricKind.best);
      expect(strength.metrics[3].from, DateTime(2026, 9, 21));
      expect(strength.metrics[2].from, isNull); // absent key → null
      expect(strength.metrics[3].floorPct, 2.5);
      expect(strength.metrics[2].floorPct, isNull); // absent key → null

      final weight = domains[1];
      expect(weight.metrics[0].id, 'bw_series');
      expect(weight.metrics[0].kind, MetricKind.series);
      expect(weight.metrics[0].goal, 154);
      expect(weight.metrics[0].goalNote, 'phase target');
      expect(weight.metrics[1].goal, isNull);

      expect(domains[2].metrics, isEmpty);

      final climbing = domains[3];
      expect(climbing.paradigm, DomainParadigm.integration);
      expect(climbing.metrics.single.goal, 2);
      // Bare-string list_fields: field only, no unit.
      expect(
        climbing.listFields.map((f) => f.field),
        ['grade', 'color', 'gym', 'ascent_type'],
      );
      expect(climbing.listFields.every((f) => f.unit == null), isTrue);

      final meals = domains[4];
      // Map-form list_fields carry a unit; mixed with bare strings.
      expect(meals.listFields, hasLength(3));
      expect(meals.listFields[0].field, 'meal');
      expect(meals.listFields[0].unit, isNull);
      expect(meals.listFields[1].field, 'calories');
      expect(meals.listFields[1].unit, 'kcal');
      expect(meals.listFields[2].field, 'protein_g');
      expect(meals.listFields[2].unit, 'g');
      // goal_band_per_lb parses to a (low, high) record.
      final band = meals.metrics.single.goalBandPerLb!;
      expect(band.low, 0.8);
      expect(band.high, 1.0);
      // Domains without list_fields keep the empty default (heuristic
      // fallback downstream).
      expect(domains[0].listFields, isEmpty);
      // Metrics without a band keep null.
      expect(domains[0].metrics[0].goalBandPerLb, isNull);
    });

    test('malformed list_fields / goal_band_per_lb degrade, never throw', () {
      final domains = parseDomainConfigs('''
domains:
  - name: x
    views: [x]
    list_fields:
      - ""
      - { unit: kcal }
      - ok
      - 42
    metrics:
      - id: protein_series
        goal_band_per_lb: [0.8]
      - id: kcal_series
        goal_band_per_lb: "not a list"
      - id: bw_series
        goal_band_per_lb: [1.0, 0.8]
''')!;
      final d = domains.single;
      // Blank / field-less entries dropped; scalars coerce to strings.
      expect(d.listFields.map((f) => f.field), ['ok', '42']);
      // Wrong-arity and non-list bands → null.
      expect(d.metrics[0].goalBandPerLb, isNull);
      expect(d.metrics[1].goalBandPerLb, isNull);
      // Reversed bounds normalize to low <= high.
      expect(d.metrics[2].goalBandPerLb, (low: 0.8, high: 1.0));
    });

    test('null / empty / malformed input → null (fallback signal)', () {
      expect(parseDomainConfigs(null), isNull);
      expect(parseDomainConfigs(''), isNull);
      expect(parseDomainConfigs('   \n'), isNull);
      expect(parseDomainConfigs('just a string'), isNull);
      expect(parseDomainConfigs('domains: not-a-list'), isNull);
      expect(parseDomainConfigs('other_key: 1'), isNull);
      expect(parseDomainConfigs('{{{{ not yaml'), isNull);
    });

    test('bad entries are skipped, not fatal', () {
      final domains = parseDomainConfigs('''
domains:
  - name: ok
    paradigm: entry
    views: [strength]
  - "just a string entry"
  - name: no_views
    paradigm: entry
  - views: [orphan]
  - name: ok2
    paradigm: integration
    views: [meals, extra]
    metrics:
      - "bad metric"
      - kind: series
      - id: kcal_series
''')!;
      expect(domains.map((d) => d.name), ['ok', 'ok2']);
      expect(domains[1].views, ['meals', 'extra']);
      expect(domains[1].primaryView, 'meals');
      // Metrics without an id are dropped; the one valid metric remains.
      expect(domains[1].metrics.map((m) => m.id), ['kcal_series']);
    });

    test('unknown paradigm/kind fall back to safe defaults', () {
      final domains = parseDomainConfigs('''
domains:
  - name: x
    paradigm: mystery
    views: [x]
    metrics:
      - id: something
        kind: hologram
''')!;
      expect(domains.single.paradigm, DomainParadigm.entry);
      expect(domains.single.metrics.single.kind, MetricKind.stat);
    });
  });

  group('DomainConfigProvider', () {
    setUp(DocCache.clear);
    tearDown(DocCache.clear);

    test('fetches app/dashboards.yaml and caches for 1 h', () async {
      var calls = 0;
      var clock = DateTime(2026, 9, 22, 8);
      final provider = DomainConfigProvider(
        (path) async {
          expect(path, kDashboardsPath);
          calls++;
          return fixtureYaml;
        },
        now: () => clock,
      );
      expect((await provider.load())!, hasLength(5));
      expect((await provider.load())!, hasLength(5));
      expect(calls, 1); // second load served from cache

      clock = clock.add(const Duration(hours: 2));
      await provider.load();
      expect(calls, 2); // TTL elapsed → refetch

      DomainConfigProvider.clearCache();
      await provider.load();
      expect(calls, 3); // manual bust → refetch
    });

    test('missing doc (404 → null) yields null, never throws', () async {
      final provider = DomainConfigProvider((_) async => null);
      expect(await provider.load(), isNull);
    });

    test('fetch error yields null, never throws', () async {
      final provider =
          DomainConfigProvider((_) async => throw Exception('offline'));
      expect(await provider.load(), isNull);
    });
  });
}
