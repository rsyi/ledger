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
    metrics:
      - id: session_frequency
        kind: series
        goal: 2
''';

void main() {
  group('parseDomainConfigs', () {
    test('parses the fixture shape', () {
      final domains = parseDomainConfigs(fixtureYaml)!;
      expect(domains, hasLength(4));

      final strength = domains[0];
      expect(strength.name, 'strength');
      expect(strength.paradigm, DomainParadigm.entry);
      expect(strength.views, ['strength']);
      expect(strength.primaryView, 'strength');
      expect(strength.icon, 'dumbbell');
      expect(strength.metrics, hasLength(3));
      expect(strength.metrics[0].id, 'pl_total');
      expect(strength.metrics[0].kind, MetricKind.stat);
      expect(strength.metrics[0].label, 'PL total');
      expect(strength.metrics[0].unit, 'lb');
      expect(strength.metrics[0].goal, isNull); // explicit goal: null
      expect(strength.metrics[1].lifts,
          ['squat', 'bench', 'deadlift', 'press']);
      expect(strength.metrics[2].kind, MetricKind.best);

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
      expect((await provider.load())!, hasLength(4));
      expect((await provider.load())!, hasLength(4));
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
