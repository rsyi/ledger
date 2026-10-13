// Perf #8 (2026-10-12): WmStore / ForecastMetaStore /
// ProjectionSnapshotStore read through SwrCache — last-good served
// immediately when stale, one coalesced background refresh, invalidate()
// (after a write) forces an awaited refetch.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/swr_cache.dart';

void main() {
  test('fresh → no load; stale → last-good now + one background refresh',
      () async {
    var clock = DateTime(2026, 10, 12, 8);
    final c = SwrCache<String>(
        name: 't', ttl: const Duration(minutes: 3), now: () => clock);
    var loads = 0;
    var next = 'a';
    Completer<void>? gate;
    Future<String> load() async {
      loads++;
      if (gate != null) await gate.future;
      return next;
    }

    // Concurrent cold loads coalesce.
    final cold = await Future.wait([c.get(load), c.get(load)]);
    expect(cold, ['a', 'a']);
    expect(loads, 1);

    clock = clock.add(const Duration(minutes: 1));
    expect(await c.get(load), 'a');
    expect(loads, 1, reason: 'fresh: no network');

    clock = clock.add(const Duration(minutes: 5));
    next = 'b';
    gate = Completer<void>();
    expect(await c.get(load), 'a', reason: 'stale: served immediately');
    expect(await c.get(load), 'a');
    expect(loads, 2, reason: 'ONE background refresh');
    expect(c.refreshing, isTrue);
    gate.complete();
    await pumpEventQueue();
    expect(await c.get(load), 'b');
    expect(loads, 2);
  });

  test('failure keeps last-good; force + invalidate await fresh', () async {
    final c = SwrCache<String>(name: 't', ttl: const Duration(hours: 1));
    var fail = false;
    var next = 'v1';
    Future<String> load() async {
      if (fail) throw Exception('offline');
      return next;
    }

    expect(await c.get(load), 'v1');
    fail = true;
    expect(await c.get(load, force: true), 'v1', reason: 'last-good');
    fail = false;
    next = 'v2';
    expect(await c.get(load), 'v1', reason: 'still fresh');
    c.invalidate();
    expect(await c.get(load), 'v2', reason: 'post-write read awaits');
  });

  test('a load started before invalidate() never stores its result',
      () async {
    final c = SwrCache<String>(name: 't', ttl: const Duration(hours: 1));
    final gate = Completer<void>();
    Future<String> slow() async {
      await gate.future;
      return 'pre-write';
    }

    final pending = c.get(slow);
    c.invalidate();
    gate.complete();
    expect(await pending, 'pre-write');
    expect(await c.get(() async => 'post-write'), 'post-write');
  });

  test('null before first success', () async {
    final c = SwrCache<String>(name: 't', ttl: const Duration(hours: 1));
    expect(await c.get(() async => throw Exception('x')), isNull);
  });
}
