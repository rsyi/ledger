// Perf batch 3 (2026-10-12): last-good snapshots PERSIST to disk so a
// cold start never waits on GitHub / Sheets before first paint. DocCache
// + SwrCache serve the disk copy immediately, revalidate in the
// background, and publish on RevalidationBus when the content changed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/disk_cache.dart';
import 'package:airledger/services/doc_cache.dart';
import 'package:airledger/services/revalidation_bus.dart';
import 'package:airledger/services/swr_cache.dart';

void main() {
  late MemoryDiskCacheStore disk;
  setUp(() {
    disk = MemoryDiskCacheStore();
    DiskCache.instance = disk;
    DocCache.debugColdStart();
    DocCache.diskScope = 'src1';
  });
  tearDown(() {
    DiskCache.instance = null;
    DocCache.diskScope = null;
    DocCache.debugColdStart();
  });

  group('DocCache disk', () {
    test('a successful fetch persists; a COLD start serves the disk copy '
        'without waiting on the network, then revalidates', () async {
      expect(await DocCache.fetch('coach/program.yaml', (_) async => 'v1'),
          'v1');
      await pumpEventQueue();
      expect(disk.entries.length, 1);

      DocCache.debugColdStart(); // process restart: memory gone, disk kept
      final gate = Completer<void>();
      var calls = 0;
      Future<String?> slow(String _) async {
        calls++;
        await gate.future;
        return 'v1';
      }

      final events = <String>[];
      final sub = RevalidationBus.instance.stream.listen(events.add);
      // Served from disk while the network fetch is still blocked.
      expect(await DocCache.fetch('coach/program.yaml', slow), 'v1');
      expect(calls, 1, reason: 'one background revalidation');
      gate.complete();
      await pumpEventQueue();
      expect(events, isEmpty, reason: 'unchanged content: no notify');
      await sub.cancel();
    });

    test('revalidation that CHANGES the content updates memory + disk and '
        'notifies', () async {
      await DocCache.fetch('coach/phase.yaml', (_) async => 'old');
      await pumpEventQueue();
      DocCache.debugColdStart();

      final events = <String>[];
      final sub = RevalidationBus.instance.stream.listen(events.add);
      expect(await DocCache.fetch('coach/phase.yaml', (_) async => 'new'),
          'old', reason: 'last-good first');
      await pumpEventQueue();
      expect(events, ['doc:coach/phase.yaml']);
      expect(await DocCache.fetch('coach/phase.yaml', (_) async => 'x'),
          'new', reason: 'memory now holds the revalidated copy');

      DocCache.debugColdStart();
      expect(await DocCache.fetch('coach/phase.yaml', (_) async => 'new'),
          'new', reason: 'disk holds the revalidated copy');
      await sub.cancel();
    });

    test('scoped per config source: another source never sees the copy',
        () async {
      await DocCache.fetch('p', (_) async => 'mine');
      await pumpEventQueue();
      DocCache.debugColdStart();
      DocCache.diskScope = 'src2';
      expect(await DocCache.fetch('p', (_) async => 'theirs'), 'theirs');
    });

    test('offline cold start falls back to disk; clear() (pull-to-refresh) '
        'awaits the network instead of serving disk', () async {
      await DocCache.fetch('p', (_) async => 'saved');
      await pumpEventQueue();
      DocCache.debugColdStart();
      expect(await DocCache.fetch('p', (_) async => throw Exception('x')),
          'saved');

      DocCache.clear();
      expect(await DocCache.fetch('p', (_) async => 'fresh'), 'fresh');
    });

    test('no disk configured → memory-only (old behaviour)', () async {
      DiskCache.instance = null;
      expect(await DocCache.fetch('p', (_) async => 'a'), 'a');
      DocCache.debugColdStart();
      expect(await DocCache.fetch('p', (_) async => 'b'), 'b');
    });
  });

  group('SwrCache disk', () {
    SwrCache<List<String>> cache() => SwrCache(
          name: 'wm_store',
          ttl: const Duration(minutes: 3),
          persist: SwrPersist(
            key: 'wm|sheet1',
            encode: (v) => v,
            decode: (j) => (j as List).cast<String>(),
          ),
        );

    test('cold start serves the persisted value immediately; revalidation '
        'notifies only on change', () async {
      expect(await cache().get(() async => ['a']), ['a']);
      await pumpEventQueue();

      final events = <String>[];
      final sub = RevalidationBus.instance.stream.listen(events.add);
      final c = cache(); // a new process
      final gate = Completer<void>();
      var loads = 0;
      Future<List<String>> slow() async {
        loads++;
        await gate.future;
        return ['b'];
      }

      expect(await c.get(slow), ['a'], reason: 'disk copy, no network wait');
      expect(loads, 1);
      gate.complete();
      await pumpEventQueue();
      expect(events, ['wm_store']);
      expect(await c.get(slow), ['b']);

      final c2 = cache();
      expect(await c2.get(() async => ['b']), ['b'], reason: 'disk updated');
      await pumpEventQueue();
      expect(events, ['wm_store'], reason: 'same value: no notify');
      await sub.cancel();
    });

    test('force awaits the network even with a disk copy', () async {
      await cache().get(() async => ['a']);
      await pumpEventQueue();
      expect(await cache().get(() async => ['z'], force: true), ['z']);
    });
  });

  test('FileDiskCacheStore round-trips through a directory', () async {
    final dir = await Directory.systemTemp.createTemp('disk_cache');
    addTearDown(() => dir.delete(recursive: true));
    final store = FileDiskCacheStore(Future.value(dir));
    expect(await store.read('doc|s|coach/program.yaml'), isNull);
    await store.write('doc|s|coach/program.yaml', jsonEncode({'a': 1}));
    expect(await store.read('doc|s|coach/program.yaml'), '{"a":1}');
    expect(await store.read('doc|other'), isNull);
  });
}
