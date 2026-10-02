import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/coach_proposal_store.dart';
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/coach_chat_screen.dart';

class _FakeRepo implements WarehouseConnector {
  final List<Record> rows;
  final created = <Record>[];
  final deleted = <Record>[];
  _FakeRepo([List<Record>? rows]) : rows = rows ?? [];

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      rows;
  @override
  Future<Record> create(ViewSchema view, Record record) async {
    created.add(record);
    return record;
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async =>
      deleted.add(record);
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
            type: d.endsWith('date') ? DimensionType.date : DimensionType.string,
            expr: d,
          ),
      ],
    );

void main() {
  final chatView =
      _view('coach_chat', ['id', 'date', 'ts', 'role', 'kind', 'thread', 'text']);
  final movesView = _view('program_moves',
      ['id', 'date', 'from_date', 'item', 'period', 'source', 'note']);

  final proposal = MovesProposal(summary: 'Missed Wed bench', moves: [
    ProposedMove(
        item: 'Bench heavy',
        from: DateTime(2026, 9, 30),
        to: DateTime(2026, 10, 2),
        period: 'PM',
        note: 'Fri has room'),
    ProposedMove(
        item: 'Pull-ups', from: DateTime(2026, 9, 30), to: DateTime(2026, 10, 3)),
  ]);

  _FakeRepo chatRepo() => _FakeRepo([
        {
          'id': 'row-1',
          'date': DateTime(2026, 10, 1),
          'ts': '2026-10-01T23:30:00',
          'role': 'coach',
          'kind': 'proposal',
          'thread': 'general',
          'text': proposal.encode(),
        }
      ]);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, _FakeRepo chat,
      {ViewSchema? moves, WarehouseConnector? movesRepo}) async {
    await tester.pumpWidget(MaterialApp(
      home: CoachChatScreen(
        view: chatView,
        repository: chat,
        threadId: 'general',
        title: 'General',
        programMovesView: moves,
        programMovesRepository: movesRepo,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Schedule writes one program_moves row per move',
      (tester) async {
    final moves = _FakeRepo();
    await pump(tester, chatRepo(), moves: movesView, movesRepo: moves);
    expect(find.text('Missed Wed bench'), findsOneWidget);
    expect(find.text('Bench heavy: Wed 9/30 → Fri 10/2'), findsOneWidget);

    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();

    expect(moves.created, hasLength(2));
    final parsed = [for (final r in moves.created) ProgramMove.fromRecord(r)!];
    expect(parsed[0].item, 'Bench heavy');
    expect(parsed[0].from, DateTime(2026, 9, 30));
    expect(parsed[0].to, DateTime(2026, 10, 2));
    expect(parsed[0].period, 'PM');
    expect(parsed[0].note, 'Fri has room');
    expect(parsed.every((m) => m.source == 'coach'), isTrue);
    expect(parsed.every((m) => m.createdAt != null), isTrue);
    expect(parsed[0].id, isNot(parsed[1].id));
    expect(parsed[0].id, hasLength(36)); // UUID v4

    final st = await CoachProposalStore.load('row-1');
    expect(st!.status, CoachProposalStatus.scheduled);
    expect(st.localIds, [parsed[0].id, parsed[1].id]);
    expect(find.textContaining('Scheduled'), findsOneWidget);

    // Undo deletes exactly the created rows.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(moves.deleted.map((r) => r['id']), [parsed[0].id, parsed[1].id]);
    expect((await CoachProposalStore.load('row-1'))!.status,
        CoachProposalStatus.undone);
  });

  testWidgets('Not now marks dismissed and writes nothing', (tester) async {
    final moves = _FakeRepo();
    await pump(tester, chatRepo(), moves: movesView, movesRepo: moves);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(moves.created, isEmpty);
    expect((await CoachProposalStore.load('row-1'))!.status,
        CoachProposalStatus.dismissed);
    expect(find.textContaining('Dismissed'), findsOneWidget);
  });

  testWidgets('no program_moves view → Schedule disabled with hint',
      (tester) async {
    await pump(tester, chatRepo());
    final btn =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Schedule'));
    expect(btn.onPressed, isNull);
    expect(find.textContaining('unavailable'), findsOneWidget);
  });
}
