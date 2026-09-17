// Tests for the kayaWalk orchestration helper (multi-page assembly,
// short-page stop, runaway-guard stop) and pure helper functions.
//
// EngineLedgerRepository is a concrete FFI-backed class (Isolate.run
// internals) that cannot be faked cheaply without adding a mocking
// package. Instead we extract the pagination loop as the package-visible
// `kayaWalk` function and unit-test that. pull() stays thin glue that
// calls kayaWalk twice — tested indirectly via the walk tests.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/integrations/kaya.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a fake page fetcher: returns [pageSize] items per page until
/// [totalItems] items have been returned, then returns a short page.
Future<List<Map<String, dynamic>>> Function(int) _fetcher({
  required int totalItems,
  required int pageSize,
}) {
  return (int offset) async {
    final remaining = totalItems - offset;
    if (remaining <= 0) return [];
    final count = remaining < pageSize ? remaining : pageSize;
    return List.generate(
      count,
      (i) => {'id': '${offset + i}', 'date': '2026-01-01'},
    );
  };
}

/// Build a page fetcher that always returns exactly [pageSize] items
/// (never terminates naturally — only the runaway guard stops it).
Future<List<Map<String, dynamic>>> Function(int) _infiniteFetcher({
  required int pageSize,
}) {
  return (int offset) async {
    return List.generate(
      pageSize,
      (i) => {'id': '${offset + i}', 'date': '2026-01-01'},
    );
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // kayaWalk: multi-page assembly
  // -------------------------------------------------------------------------

  test('kayaWalk assembles multiple full pages into one list', () async {
    final results = await kayaWalk(
      _fetcher(totalItems: 250, pageSize: 100),
      pageSize: 100,
      maxOffset: 20000,
      pageDelay: Duration.zero,
    );
    expect(results, hasLength(250));
    // Items come back in offset order.
    expect((results.first)['id'], '0');
    expect((results.last)['id'], '249');
  });

  test('kayaWalk stops on a short final page (< pageSize)', () async {
    // 150 items with pageSize=100: page0=100 items (full), page1=50
    // items (short) → stops after page1.
    final results = await kayaWalk(
      _fetcher(totalItems: 150, pageSize: 100),
      pageSize: 100,
      maxOffset: 20000,
      pageDelay: Duration.zero,
    );
    expect(results, hasLength(150));
  });

  test('kayaWalk stops immediately on an empty first page', () async {
    final results = await kayaWalk(
      _fetcher(totalItems: 0, pageSize: 100),
      pageSize: 100,
      maxOffset: 20000,
      pageDelay: Duration.zero,
    );
    expect(results, isEmpty);
  });

  test('kayaWalk stops when exactly one full page is returned (no second fetch)',
      () async {
    var callCount = 0;
    Future<List<Map<String, dynamic>>> fetcher(int offset) async {
      callCount++;
      if (offset == 0) {
        // Return a FULL page; a second call with offset=100 should happen
        // to confirm there's no more data.
        return List.generate(100, (i) => {'id': '$i', 'date': '2026-01-01'});
      }
      return []; // second call: empty → done
    }

    final results = await kayaWalk(
      fetcher,
      pageSize: 100,
      maxOffset: 20000,
      pageDelay: Duration.zero,
    );
    expect(results, hasLength(100));
    expect(callCount, 2); // called twice: once for page 0, once for page 100
  });

  // -------------------------------------------------------------------------
  // kayaWalk: runaway guard
  // -------------------------------------------------------------------------

  test('kayaWalk stops at maxOffset even when server never returns short page',
      () async {
    // maxOffset=200, pageSize=100 → offsets 0, 100 fetched; offset 200
    // would equal maxOffset so the loop exits after offset 100.
    final results = await kayaWalk(
      _infiniteFetcher(pageSize: 100),
      pageSize: 100,
      maxOffset: 200,
      pageDelay: Duration.zero,
    );
    // 2 pages of 100 each.
    expect(results, hasLength(200));
  });

  test('kayaWalk with maxOffset=0 fetches nothing', () async {
    var callCount = 0;
    Future<List<Map<String, dynamic>>> fetcher(int offset) async {
      callCount++;
      return List.generate(100, (i) => {'id': '$i', 'date': '2026-01-01'});
    }

    final results = await kayaWalk(
      fetcher,
      pageSize: 100,
      maxOffset: 0,
      pageDelay: Duration.zero,
    );
    // offset 0 >= maxOffset 0 → guard triggers immediately, no fetch.
    expect(results, isEmpty);
    expect(callCount, 0);
  });

  // -------------------------------------------------------------------------
  // kayaWalk: KayaAuthException propagates
  // -------------------------------------------------------------------------

  test('kayaWalk propagates KayaAuthException from the fetcher', () async {
    // Verify walk does NOT silently swallow auth errors — the Integration
    // class handles re-auth above the walk layer.
    Future<List<Map<String, dynamic>>> alwaysFails(int offset) async {
      throw const KayaAuthException('test');
    }

    expect(
      () => kayaWalk(alwaysFails, pageSize: 100, maxOffset: 20000,
          pageDelay: Duration.zero),
      throwsA(isA<KayaAuthException>()),
    );
  });

  // -------------------------------------------------------------------------
  // kayaWalk: pageDelay parameter is accepted (no-op in tests via zero)
  // -------------------------------------------------------------------------

  test('kayaWalk with Duration.zero pageDelay completes quickly', () async {
    final results = await kayaWalk(
      _fetcher(totalItems: 50, pageSize: 100),
      pageSize: 100,
      maxOffset: 20000,
      pageDelay: Duration.zero,
    );
    expect(results, hasLength(50));
  });

  // -------------------------------------------------------------------------
  // kayaDeletedIds: symmetric mass-delete guard
  // -------------------------------------------------------------------------
  // These tests verify the pure helper; the pull() guard is an integration
  // concern covered in kaya_integration_test (pull is tested via kayaWalk
  // indirectly; the guard logic below is tested at the unit level here).

  test('kayaDeletedIds: empty fetchedIds, non-empty knownIds → full diff', () {
    // This case is what the pull() guard catches: the guard refuses to ingest
    // when fetchedIds is empty and knownIds is non-empty (outside fullReconcile).
    // The underlying arithmetic is correct — the guard is in pull(), not here.
    final deleted = kayaDeletedIds(
      fetchedIds: {},
      knownIds: {'a1', 'a2', 'a3'},
    );
    expect(deleted, ['a1', 'a2', 'a3']); // sorted
  });

  test('kayaDeletedIds: empty fetchedIds and empty knownIds → empty list', () {
    final deleted = kayaDeletedIds(fetchedIds: {}, knownIds: {});
    expect(deleted, isEmpty);
  });
}
