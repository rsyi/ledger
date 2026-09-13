import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/coach_brain.dart';
import 'package:airledger/services/llm_client.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';

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
        llm: LlmClient(const []),
        modelName: 'sonnet',
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
    expect(fetches, CoachBrain.docPaths.length);
    // Second build serves docs from the 1h cache.
    await b.buildPrompt(const []);
    expect(fetches, CoachBrain.docPaths.length);
  });
}
