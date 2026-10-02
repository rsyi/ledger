// carryover_check.dart — the in-app daily fallback that asks the coach
// for a moves proposal when work was missed (spec 2026-10-02 §5).
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/carryover_check.dart';
import 'package:airledger/services/missed_work.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';

class _FakeRepo implements WarehouseConnector {
  final created = <Record>[];
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      created;
  @override
  Future<Record> create(ViewSchema view, Record record) async {
    created.add(record);
    return record;
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

final _chatView = ViewSchema(
  name: 'coach_chat',
  datasource: 'gsheets',
  table: 'coach_chat',
  entities: const [],
  measures: const [],
  dimensions: [
    for (final d in ['id', 'date', 'ts', 'role', 'kind', 'thread', 'text'])
      Dimension(name: d, type: DimensionType.string, expr: d),
  ],
);

MissedWork _missed() => MissedWork(
  missed: [
    MissedItem(
      item: const PrescribedItem(
        name: 'Bench top set',
        scheme: '1x3',
        period: 'PM',
        targetSets: 1,
      ),
      day: DateTime(2026, 9, 30),
      home: DateTime(2026, 9, 30),
      setsShort: 1,
      kind: 'lift',
    ),
  ],
  remainingDays: [DateTime(2026, 10, 2)],
);

MovesProposal _proposal() => MovesProposal(
  summary: 'Bench Wed → Sat',
  moves: [
    ProposedMove(
      item: 'Bench top set',
      from: DateTime(2026, 9, 30),
      to: DateTime(2026, 10, 3),
    ),
  ],
);

void main() {
  final fri7 = DateTime(2026, 10, 2, 7, 15);

  group('CarryoverCheck.maybeRun gates', () {
    late Map<String, String> meta;
    late int asks;
    late int missedLoads;
    late List<String> order;

    setUp(() {
      meta = {};
      asks = 0;
      missedLoads = 0;
      order = [];
    });

    Future<CarryoverOutcome> run({
      DateTime? now,
      MissedWork? missed,
      bool proposalToday = false,
      bool synced = true,
      Future<void> Function()? ask,
    }) => CarryoverCheck.maybeRun(
      now: now ?? fri7,
      metaGet: (k) async => meta[k],
      metaSet: (k, v) async {
        order.add('meta');
        meta[k] = v;
      },
      missed: () async {
        order.add('missed');
        missedLoads++;
        return missed ?? _missed();
      },
      freshSync: () async {
        order.add('sync');
        return synced;
      },
      alreadyPlanned: () async {
        order.add('planned');
        return proposalToday;
      },
      ask: (_) async {
        order.add('ask');
        asks++;
        if (ask != null) await ask();
      },
    );

    test('runs once: sets meta BEFORE asking, then asks', () async {
      expect(await run(), CarryoverOutcome.asked);
      expect(order, ['missed', 'sync', 'planned', 'meta', 'ask']);
      expect(meta[CarryoverCheck.metaKey], '2026-10-02');
      expect(asks, 1);
    });

    test('before 06:00 → skipped, no meta, no load', () async {
      expect(
        await run(now: DateTime(2026, 10, 2, 5, 59)),
        CarryoverOutcome.tooEarly,
      );
      expect(meta, isEmpty);
      expect(missedLoads, 0);
      expect(asks, 0);
    });

    test('already checked today → skipped', () async {
      meta[CarryoverCheck.metaKey] = '2026-10-02';
      expect(await run(), CarryoverOutcome.alreadyChecked);
      expect(missedLoads, 0);
      expect(asks, 0);
    });

    test('checked YESTERDAY → runs again today', () async {
      meta[CarryoverCheck.metaKey] = '2026-10-01';
      expect(await run(), CarryoverOutcome.asked);
    });

    test('already planned (nightly briefing / proposal) → skipped; the '
        'day counts as checked', () async {
      expect(await run(proposalToday: true), CarryoverOutcome.alreadyPlanned);
      expect(meta[CarryoverCheck.metaKey], '2026-10-02');
      expect(asks, 0);
      expect(await run(), CarryoverOutcome.alreadyChecked);
    });

    test('no fresh sync → returns WITHOUT meta (retry next resume); '
        'coach_chat is never read', () async {
      expect(await run(synced: false), CarryoverOutcome.notSynced);
      expect(meta, isEmpty);
      expect(order, isNot(contains('planned')));
      expect(asks, 0);
      // Next resume, sync works → asks.
      expect(await run(), CarryoverOutcome.asked);
      expect(asks, 1);
    });

    test('nothing missed → no sync attempted (cheap gate first)', () async {
      await run(missed: MissedWork(missed: const [], remainingDays: const []));
      expect(order, ['missed']);
    });

    test('nothing missed → skipped, meta untouched', () async {
      expect(
        await run(
          missed: MissedWork(missed: const [], remainingDays: const []),
        ),
        CarryoverOutcome.nothingMissed,
      );
      expect(meta, isEmpty);
      expect(asks, 0);
    });

    test('missed unavailable (null) → skipped', () async {
      final out = await CarryoverCheck.maybeRun(
        now: fri7,
        metaGet: (k) async => null,
        metaSet: (k, v) async => meta[k] = v,
        missed: () async => null,
        freshSync: () async => true,
        alreadyPlanned: () async => false,
        ask: (_) async => asks++,
      );
      expect(out, CarryoverOutcome.nothingMissed);
      expect(asks, 0);
    });

    test('ask failure is swallowed; meta stays set (at most once/day)',
        () async {
      final out = await run(ask: () async => throw StateError('api down'));
      expect(out, CarryoverOutcome.failed);
      expect(meta[CarryoverCheck.metaKey], '2026-10-02');
      // A second foreground the same day does nothing.
      expect(await run(), CarryoverOutcome.alreadyChecked);
      expect(asks, 1);
    });

    test('concurrent calls ask at most once', () async {
      final results = await Future.wait([run(), run()]);
      expect(asks, 1);
      expect(results, contains(CarryoverOutcome.asked));
    });
  });

  group('alreadyPlannedToday', () {
    final now = DateTime(2026, 10, 2, 7, 15);
    Record row(String kind, String text,
            {String ts = '', Object? date, String thread = ''}) =>
        {
          'kind': kind,
          'text': text,
          'ts': ts,
          'date': ?date,
          'thread': thread,
        };

    test('a nightly briefing posted last night (dated YESTERDAY) covers '
        'today', () {
      expect(
        alreadyPlannedToday([
          row('briefing', 'Plan for Fri…',
              ts: '2026-10-01T23:30:12.123', date: '2026-10-01',
              thread: 'briefings'),
        ], now),
        isTrue,
      );
      // A one-digit-hour Sheets rendering parses too.
      expect(
        alreadyPlannedToday([
          row('briefing', 'x', ts: '2026-10-02 6:59:00',
              thread: 'briefings'),
        ], now),
        isTrue,
      );
    });

    test('a briefing before yesterday 18:00 or outside the briefings '
        'thread does not count', () {
      expect(
        alreadyPlannedToday([
          row('briefing', 'x', ts: '2026-10-01T17:59:00',
              thread: 'briefings'),
          row('briefing', 'x', ts: '2026-10-01T23:30:00'),
          row('reply', 'x', ts: '2026-10-01T23:30:00', thread: 'briefings'),
        ], now),
        isFalse,
      );
    });

    test('a moves proposal from last night (dated yesterday) or dated '
        'today covers today', () {
      expect(
        alreadyPlannedToday([
          row('proposal', _proposal().encode(),
              ts: '2026-10-01T23:30:05', date: '2026-10-01',
              thread: 'briefings'),
        ], now),
        isTrue,
      );
      expect(
        alreadyPlannedToday([
          row('proposal', _proposal().encode(), date: DateTime(2026, 10, 2)),
        ], now),
        isTrue,
      );
    });

    test('older / legacy / non-moves proposals do not count', () {
      final legacy = CoachProposal(
        view: 'strength',
        date: DateTime(2026, 10, 2),
        summary: 's',
        entries: const [
          {'exercise': 'Squat'},
        ],
      ).encode();
      expect(
        alreadyPlannedToday([
          row('proposal', _proposal().encode(),
              ts: '2026-10-01T12:00:00', date: '2026-10-01'),
          row('proposal', legacy, ts: '2026-10-02T07:00:00',
              date: '2026-10-02'),
          row('reply', _proposal().encode(), ts: '2026-10-02T07:00:00'),
        ], now),
        isFalse,
      );
    });
  });

  group('awaitFreshSync', () {
    final resumeAt = DateTime(2026, 10, 2, 7, 15);
    late ValueNotifier<bool> syncing;
    late ValueNotifier<DateTime?> lastSync;
    setUp(() {
      syncing = ValueNotifier(false);
      lastSync = ValueNotifier(DateTime(2026, 10, 2, 6));
    });

    test('idle → runs a sync; true once lastSync is after resume', () async {
      var syncs = 0;
      final ok = await awaitFreshSync(
        since: resumeAt,
        syncing: syncing,
        lastSync: lastSync,
        chatFailed: () => false,
        sync: () async {
          syncs++;
          lastSync.value = resumeAt.add(const Duration(seconds: 3));
        },
      );
      expect(ok, isTrue);
      expect(syncs, 1);
    });

    test('a sync already running → waits for it instead of a no-op '
        'maybeSync', () async {
      syncing.value = true;
      var syncs = 0;
      final f = awaitFreshSync(
        since: resumeAt,
        syncing: syncing,
        lastSync: lastSync,
        chatFailed: () => false,
        sync: () async => syncs++,
      );
      await Future<void>.delayed(Duration.zero);
      lastSync.value = resumeAt.add(const Duration(seconds: 5));
      syncing.value = false;
      expect(await f, isTrue);
      expect(syncs, 0);
    });

    test('running sync never finishes → false after the timeout', () async {
      syncing.value = true;
      final ok = await awaitFreshSync(
        since: resumeAt,
        syncing: syncing,
        lastSync: lastSync,
        chatFailed: () => false,
        sync: () async {},
        timeout: const Duration(milliseconds: 20),
      );
      expect(ok, isFalse);
    });

    test('sync did not complete (lastSync stale) → false', () async {
      final ok = await awaitFreshSync(
        since: resumeAt,
        syncing: syncing,
        lastSync: lastSync,
        chatFailed: () => false,
        sync: () async {},
      );
      expect(ok, isFalse);
    });

    test('coach_chat failed in that sync → false', () async {
      final ok = await awaitFreshSync(
        since: resumeAt,
        syncing: syncing,
        lastSync: lastSync,
        chatFailed: () => true,
        sync: () async =>
            lastSync.value = resumeAt.add(const Duration(seconds: 1)),
      );
      expect(ok, isFalse);
    });
  });

  group('postCarryoverTurn', () {
    test('posts the moves proposal + reply in the general thread and '
        'notifies with the summary', () async {
      final repo = _FakeRepo();
      final notes = <(String, String)>[];
      String? asked;
      await postCarryoverTurn(
        now: () => fri7,
        view: _chatView,
        repository: repo,
        ask: (prompt, onProposal, onMovesProposal) async {
          asked = prompt;
          await onMovesProposal(_proposal());
          return 'Bench Wed → Sat: Fri is deadlift day.';
        },
        notify: (t, b) async => notes.add((t, b)),
      );
      expect(asked, CarryoverCheck.prompt);
      expect(repo.created, hasLength(2));
      final p = repo.created[0];
      expect(p['kind'], 'proposal');
      expect(p['role'], 'coach');
      expect(p['thread'], 'general');
      expect(p['date'], DateTime(2026, 10, 2));
      expect(MovesProposal.tryParse(p['text'] as String)!.summary,
          'Bench Wed → Sat');
      final r = repo.created[1];
      expect(r['kind'], 'reply');
      expect(r['thread'], 'general');
      expect(r['text'], 'Bench Wed → Sat: Fri is deadlift day.');
      expect(notes.single.$2, contains('Bench Wed → Sat'));
    });

    test('no proposal → reply only; notification uses the reply', () async {
      final repo = _FakeRepo();
      final notes = <(String, String)>[];
      await postCarryoverTurn(
        now: () => fri7,
        view: _chatView,
        repository: repo,
        ask: (prompt, onProposal, onMovesProposal) async =>
            'Let the Wed laterals expire — no room.',
        notify: (t, b) async => notes.add((t, b)),
      );
      expect(repo.created.single['kind'], 'reply');
      expect(notes.single.$2, 'Let the Wed laterals expire — no room.');
    });

    test('empty reply + no proposal → nothing posted, no notification',
        () async {
      final repo = _FakeRepo();
      final notes = <(String, String)>[];
      await postCarryoverTurn(
        now: () => fri7,
        view: _chatView,
        repository: repo,
        ask: (prompt, onProposal, onMovesProposal) async => '  ',
        notify: (t, b) async => notes.add((t, b)),
      );
      expect(repo.created, isEmpty);
      expect(notes, isEmpty);
    });
  });
}
