// Perf #8 (2026-10-12): DocCache is stale-while-revalidate — a stale
// entry is served immediately while ONE background refetch refreshes it,
// concurrent misses share one request, a failed refresh keeps last-good.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/doc_cache.dart';

void main() {
  setUp(DocCache.clear);

  test('stale entry served immediately; background refresh updates it',
      () async {
    var clock = DateTime(2026, 10, 12, 8);
    var calls = 0;
    var body = 'v1';
    Completer<void>? gate;
    Future<String?> fetch(String _) async {
      calls++;
      if (gate != null) await gate.future;
      return body;
    }

    expect(await DocCache.fetch('p', fetch, now: () => clock), 'v1');
    clock = clock.add(const Duration(hours: 2)); // stale
    body = 'v2';
    gate = Completer<void>();
    // Last-good comes back without waiting on the (blocked) refetch.
    expect(await DocCache.fetch('p', fetch, now: () => clock), 'v1');
    expect(await DocCache.fetch('p', fetch, now: () => clock), 'v1');
    expect(calls, 2, reason: 'one coalesced background refresh');
    gate.complete();
    await pumpEventQueue();
    expect(await DocCache.fetch('p', fetch, now: () => clock), 'v2');
    expect(calls, 2);
  });

  test('failed refresh keeps last-good; concurrent misses coalesce',
      () async {
    var clock = DateTime(2026, 10, 12, 8);
    var calls = 0;
    var fail = false;
    Future<String?> fetch(String _) async {
      calls++;
      await Future<void>.delayed(Duration.zero);
      if (fail) throw Exception('offline');
      return 'ok';
    }

    final both = await Future.wait([
      DocCache.fetch('q', fetch, now: () => clock),
      DocCache.fetch('q', fetch, now: () => clock),
    ]);
    expect(both, ['ok', 'ok']);
    expect(calls, 1);

    clock = clock.add(const Duration(hours: 2));
    fail = true;
    expect(await DocCache.fetch('q', fetch, now: () => clock), 'ok');
    await pumpEventQueue();
    expect(await DocCache.fetch('q', fetch, now: () => clock), 'ok');
  });

  test('clear() busts: a pre-bust in-flight fetch never repopulates',
      () async {
    final gate = Completer<void>();
    Future<String?> slow(String _) async {
      await gate.future;
      return 'old';
    }

    final pending = DocCache.fetch('r', slow);
    DocCache.clear();
    gate.complete();
    expect(await pending, 'old');
    expect(await DocCache.fetch('r', (_) async => 'new'), 'new');
  });
}
