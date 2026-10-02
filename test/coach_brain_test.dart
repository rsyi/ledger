import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/model_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/coach_brain.dart';
import 'package:airledger/services/missed_work.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/whoop_activity.dart';

/// Serves canned rows per view name. No network, no LLM calls.
class _FakeRepo implements WarehouseConnector {
  final Map<String, List<Record>> byView;
  _FakeRepo(this.byView);

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      byView[view.name] ?? const [];
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

ViewSchema _view(String name, List<String> dims) => ViewSchema(
      name: name,
      datasource: 'gsheets',
      table: name,
      entities: const [],
      measures: const [],
      dimensions: [
        for (final d in dims)
          Dimension(
            name: d,
            type: d == 'date' ? DimensionType.date : DimensionType.string,
            expr: d,
          ),
      ],
    );

void main() {
  final today = DateTime(2026, 9, 13);

  CoachBrain brain({
    Map<String, List<Record>> rows = const {},
    Map<String, ViewSchema>? views,
    CoachDocFetcher? fetchDoc,
  }) =>
      CoachBrain(
        model: ModelConfig(
          name: 'sonnet',
          vendor: ModelVendor.anthropic,
          modelRef: 'claude-sonnet-4-6',
          apiKey: 'test-key',
          apiUrl: 'https://api.anthropic.com/v1',
        ),
        repository: _FakeRepo(rows),
        views: views ?? {'weight': _view('weight', ['id', 'date', 'weight'])},
        fetchDoc: fetchDoc ?? (path) async => '$path contents',
        now: () => today,
      );

  setUp(CoachBrain.clearDocCache);

  test('renderTable skips id, drops rows older than 28d, keeps future,'
      ' caps at maxRows', () {
    final view = _view('weight', ['id', 'date', 'weight']);
    // 250 in-window rows + one stale + one future.
    final rows = <Record>[
      {'id': 'stale', 'date': today.subtract(const Duration(days: 40)),
        'weight': 99},
      {'id': 'future', 'date': today.add(const Duration(days: 2)),
        'weight': 71},
      for (var i = 0; i < 250; i++)
        {'id': 'r$i', 'date': today.subtract(const Duration(days: 1)),
          'weight': 70},
    ];
    final table = CoachBrain.renderTable(view, rows, today: today);
    final lines = table.split('\n');
    // header + separator + 200 data rows.
    expect(lines.length, 2 + CoachBrain.maxRowsPerView);
    expect(lines.first, '| date | weight |'); // id skipped
    expect(table, isNot(contains('99'))); // stale row dropped
    expect(lines.last, contains('2026-09-15')); // future kept, sorted last
  });

  test('renderHistory sorts by ts and caps to the most recent 40', () {
    final rows = <Record>[
      for (var i = 0; i < 50; i++)
        {
          'ts': DateTime(2026, 9, 1).add(Duration(minutes: i))
              .toIso8601String(),
          'role': i.isEven ? 'user' : 'coach',
          'text': 'msg $i',
        },
    ]..shuffle();
    final out = CoachBrain.renderHistory(rows);
    final lines = out.split('\n');
    expect(lines.length, CoachBrain.maxHistoryMessages);
    expect(lines.first, '[user] msg 10'); // oldest kept after cap
    expect(lines.last, '[coach] msg 49');
    expect(out, isNot(contains('msg 9'))); // pre-cap message dropped
  });

  test('buildPrompt falls back to one-line note when docs fetch fails',
      () async {
    final b = brain(fetchDoc: (_) async => throw Exception('offline'));
    final prompt = await b.buildPrompt(const []);
    expect(prompt,
        contains('coach docs unavailable — advise from ledger data only'));
    expect(prompt, contains('TODAY: 2026-09-13'));
  });

  test('buildPrompt includes fetched docs (cached) and ledger dump',
      () async {
    var fetches = 0;
    final b = brain(
      rows: {
        'weight': [
          {'id': 'a', 'date': today, 'weight': 70.5},
        ],
      },
      fetchDoc: (path) async {
        fetches++;
        return '$path body';
      },
    );
    final prompt = await b.buildPrompt([
      {'ts': '2026-09-13T08:00:00', 'role': 'user', 'text': 'hi coach'},
    ]);
    expect(prompt, contains('coach/goals.md body'));
    expect(prompt, contains('coach/routine.md body'));
    expect(prompt, contains('coach/metrics.md body'));
    expect(prompt, contains('| 2026-09-13 | 70.5 |'));
    expect(prompt, contains('[user] hi coach'));
    // First build fetches both the doc paths and the intent-layer YAML paths.
    expect(fetches, CoachBrain.docPaths.length + CoachBrain.intentPaths.length);
    // Second build serves everything from the 1h cache — no new fetches.
    await b.buildPrompt(const []);
    expect(fetches, CoachBrain.docPaths.length + CoachBrain.intentPaths.length);
  });

  test('buildSystemPrompt has docs+dump but no chat history; buildPrompt '
      'still appends history', () async {
    final b = brain();
    final system = await b.buildSystemPrompt(today);
    expect(system, contains('## Coach docs'));
    expect(system, contains('## Ledger data'));
    expect(system, isNot(contains('## Chat history')));
    final full = await b.buildPrompt([
      {'role': 'user', 'ts': '2026-09-13T10:00:00', 'text': 'hi'},
    ]);
    expect(full, contains('## Chat history'));
    expect(full, contains('[user] hi'));
  });

  test('renderHistory renders proposal rows compactly (no raw JSON)', () {
    final proposal = CoachProposal(
      view: 'strength',
      date: DateTime(2026, 9, 15),
      summary: 'Heavy squat day',
      entries: [
        {'exercise': 'squat', 'sets': 5, 'reps': 5},
        {'exercise': 'rdl', 'sets': 3, 'reps': 8},
      ],
    );
    final rows = <Record>[
      {
        'ts': '2026-09-13T09:00:00',
        'role': 'coach',
        'kind': 'proposal',
        'text': proposal.encode(),
      },
      {
        'ts': '2026-09-13T09:01:00',
        'role': 'user',
        'kind': 'user',
        'text': 'Looks good!',
      },
    ];
    final out = CoachBrain.renderHistory(rows);
    // Proposal line should not contain raw JSON markers.
    expect(out, isNot(contains('{"v":1')));
    expect(out, isNot(contains('"view"')));
    // Should render compactly with view, date, and summary.
    expect(out, contains('[coach] (proposed strength plan for 2026-09-15: Heavy squat day)'));
    // Normal user row unchanged.
    expect(out, contains('[user] Looks good!'));
  });

  test('renderHistory falls back to raw text for malformed proposal rows', () {
    final rows = <Record>[
      {
        'ts': '2026-09-13T10:00:00',
        'role': 'coach',
        'kind': 'proposal',
        'text': 'not valid json {{{',
      },
    ];
    final out = CoachBrain.renderHistory(rows);
    // Should fall back to the raw text, not crash.
    expect(out, contains('[coach] not valid json {{{'));
  });

  test('renderActivitySection flags unlogged Whoop sessions', () {
    final s = CoachBrain.renderActivitySection(
      activities: [
        WhoopActivity(
            date: DateTime(2026, 9, 27),
            start: DateTime(2026, 9, 27, 13, 45),
            sport: 'running',
            kind: ActivityKind.run,
            strain: 9.3,
            avgHr: 122,
            maxHr: 170,
            durationMin: 43),
        WhoopActivity(
            date: DateTime(2026, 9, 28),
            sport: 'weightlifting',
            kind: ActivityKind.lift,
            strain: 11.8),
      ],
      strengthDays: {DateTime(2026, 9, 28)},
      climbDays: const {},
      today: DateTime(2026, 9, 29),
    )!;
    expect(s, contains('## Activity (Whoop, last 14 days)'));
    expect(s, contains('2026-09-27 13:45 running · strain 9.3 · 43 min · HR 122/170 [unlogged]'));
    expect(s, contains('2026-09-28 weightlifting · strain 11.8'));
    expect(s, isNot(contains('11.8 [unlogged]')));
  });

  test('activity section (I1): a Kaya climbing day D+1 counts a Whoop '
      'climb on D as logged (Kaya/Whoop date-skew fold)', () async {
    final b = brain(
      rows: {
        'whoop_workouts': [
          {'date': DateTime(2026, 9, 12), 'sport': 'rock-climbing',
            'strain': 10.0},
        ],
        'climbing': [
          {'date': DateTime(2026, 9, 13)}, // Kaya's export date, D+1
        ],
      },
      views: {
        'whoop_workouts':
            _view('whoop_workouts', ['date', 'sport', 'strain']),
        'climbing': _view('climbing', ['date']),
      },
    );
    final s = await b.buildSystemPrompt(today);
    expect(s, contains('rock-climbing'));
    expect(s, isNot(contains('rock-climbing \u{b7} strain 10.0 [unlogged]')));
  });

  test('activity section (M1): a logged cardio row un-flags a same-day '
      'Whoop run/other; walk stays [unlogged]', () async {
    final b = brain(
      rows: {
        'whoop_workouts': [
          {'date': DateTime(2026, 9, 12), 'sport': 'running',
            'strain': 9.0},
          {'date': DateTime(2026, 9, 12), 'sport': 'walking',
            'strain': 3.0},
        ],
        'cardio': [
          {'date': DateTime(2026, 9, 12)},
        ],
      },
      views: {
        'whoop_workouts':
            _view('whoop_workouts', ['date', 'sport', 'strain']),
        'cardio': _view('cardio', ['date']),
      },
    );
    final s = await b.buildSystemPrompt(today);
    expect(s, isNot(contains('running \u{b7} strain 9.0 [unlogged]')));
    expect(s, contains('walking \u{b7} strain 3.0 [unlogged]'));
  });

  group('renderMovesSection', () {
    // Thu 2026-10-01; week Mon 9/28..Sun 10/4.
    final thu = DateTime(2026, 10, 1, 9);
    DateTime d(int i) => DateTime(2026, 9, 28 + i);
    final bench = PrescribedItem(
        name: 'Bench top set', scheme: '1x3 @ RPE 8', period: 'PM',
        targetSets: 1);
    final rdl = PrescribedItem(
        name: 'RDL', scheme: '2x8-12', period: 'PM', targetSets: 2);
    final move = ProgramMove(
        id: 'm1', from: d(0), to: d(4), item: 'RDL', period: 'PM',
        source: 'manual');

    test('lists moves, missed keys, remaining days, rules, instruction',
        () {
      final week = <DateTime, List<EffectiveItem>>{
        d(0): [EffectiveItem(item: rdl, home: d(0), movedTo: d(4), move: move)],
        d(2): [EffectiveItem(item: bench, home: d(2))],
        d(3): const [],
        d(4): [EffectiveItem(item: rdl, home: d(0), movedFrom: d(0), move: move)],
      };
      final missed = MissedWork(
        missed: [
          MissedItem(
              item: bench.withLogged(0), day: d(2), home: d(2),
              setsShort: 1, kind: 'lift'),
        ],
        remainingDays: [d(3), d(4), d(5), d(6)],
      );
      final s = CoachBrain.renderMovesSection(
        moves: {move.key: move},
        missed: missed,
        week: week,
        today: thu,
      );
      expect(s, startsWith('## This week: moves + missed work'));
      expect(s, contains('Week Mon 9/28 – Sun 10/4'));
      expect(s, contains('- RDL: Mon 9/28 → Fri 10/2 (manual)'));
      expect(s, contains('- Bench top set (1x3 @ RPE 8) — due Wed 9/30, 0/1 sets'));
      expect(s, contains('item="Bench top set" from_date=2026-09-30 period=PM'));
      expect(s, contains('- Thu 10/1: rest / nothing prescribed'));
      expect(s, contains('- Fri 10/2: PM RDL (moved from Mon)'));
      expect(s, contains('- Sun 10/4: rest / nothing prescribed'));
      expect(s, isNot(contains('Wed 9/30:'))); // past days aren't remaining
      expect(s, contains('no lifting on Tuesday'));
      expect(s, contains('squat and deadlift never on the same day'));
      expect(s, contains('Whoop recovery < 34'));
      expect(s, contains('call propose_moves — never claim'));
    });

    test('lists skipped items with reasons, tags them on remaining days',
        () {
      final skip = ProgramMove(
          id: 's1', from: d(4), to: d(4), item: 'RDL', period: 'PM',
          source: 'skip', note: 'low back tight');
      final s = CoachBrain.renderMovesSection(
        moves: const {},
        skips: {skipKey(d(4), 'RDL'): skip},
        missed: MissedWork(missed: const [], remainingDays: [d(3)]),
        week: {
          d(4): [EffectiveItem(item: rdl, home: d(4))],
        },
        today: thu,
      );
      expect(s, contains('SKIPPED THIS WEEK:\n- RDL — Fri 10/2: low back tight'));
      expect(s, contains('- Fri 10/2: PM RDL (SKIPPED: low back tight)'));
      expect(s, contains('NOT missed'));
      final none = CoachBrain.renderMovesSection(
        moves: const {}, missed: null, week: const {}, today: thu);
      expect(none, contains('SKIPPED THIS WEEK:\nnone'));
    });

    test('none / unknown when nothing moved or no strength log', () {
      final s = CoachBrain.renderMovesSection(
        moves: const {},
        missed: null,
        week: const {},
        today: thu,
      );
      expect(s, contains('MOVES THIS WEEK:\nnone'));
      expect(s, contains('(unknown — no strength log available)'));
      final s2 = CoachBrain.renderMovesSection(
        moves: const {},
        missed: MissedWork(missed: const [], remainingDays: [d(3)]),
        week: const {},
        today: thu,
      );
      expect(s2, contains('MISSED THIS WEEK:\nnone'));
    });

    test('section omitted from the system prompt without a program',
        () async {
      final s = await brain().buildSystemPrompt(today);
      expect(s, isNot(contains('## This week: moves + missed work')));
    });
  });

  test('renderHistory renders a moves proposal compactly', () {
    final p = MovesProposal(summary: 'x', moves: [
      ProposedMove(
          item: 'RDL', from: DateTime(2026, 9, 28), to: DateTime(2026, 10, 2)),
    ]);
    final out = CoachBrain.renderHistory([
      {'role': 'coach', 'kind': 'proposal', 'ts': '1', 'text': p.encode()},
    ]);
    expect(out, '[coach] (proposed moves: RDL 2026-09-28 → 2026-10-02)');
  });

  test('moves section rides the system prompt (live program.yaml)',
      () async {
    const fitness = '../airledger-fitness';
    if (!File('$fitness/coach/program.yaml').existsSync()) {
      markTestSkipped('airledger-fitness not checked out');
      return;
    }
    CoachBrain.clearDocCache();
    addTearDown(CoachBrain.clearDocCache);
    final fri = DateTime(2026, 10, 2, 9);
    final move = ProgramMove(
      id: 'm1',
      to: DateTime(2026, 10, 2),
      from: DateTime(2026, 9, 30),
      item: 'Bench heavy',
      period: 'AM',
      source: 'coach',
    );
    final b = CoachBrain(
      model: ModelConfig(
        name: 'sonnet',
        vendor: ModelVendor.anthropic,
        modelRef: 'claude-sonnet-4-6',
        apiKey: 'test-key',
        apiUrl: 'https://api.anthropic.com/v1',
      ),
      repository: _FakeRepo({
        'program_moves': [move.toRecord()],
        'strength': const [],
      }),
      views: {
        'program_moves': _view('program_moves',
            ['id', 'date', 'from_date', 'item', 'period', 'source']),
        'strength': _view('strength', ['id', 'date', 'exercise']),
      },
      fetchDoc: (p) async {
        final f = File('$fitness/$p');
        return f.existsSync() ? f.readAsStringSync() : null;
      },
      now: () => fri,
    );
    final s = await b.buildSystemPrompt(fri);
    expect(s, contains('## This week: moves + missed work'));
    expect(s, contains('- Bench heavy: Wed 9/30 → Fri 10/2 (coach)'));
    expect(s, contains('(moved from Wed)'));
    expect(s, contains('MISSED THIS WEEK:'));
  });
}
