import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/coach_tools.dart';

ViewSchema _view(String name, List<String> dims,
        {Set<String> requiredDims = const {}}) =>
    ViewSchema(
      name: name,
      datasource: 'gsheets',
      table: name,
      entities: const [],
      measures: const [],
      dateField: dims.contains('date') ? 'date' : null,
      dimensions: [
        for (final d in dims)
          Dimension(
            name: d,
            type: d == 'date' ? DimensionType.date : DimensionType.string,
            expr: d,
            input: requiredDims.contains(d)
                ? InputSpec(widget: WidgetType.text, required: true)
                : null,
          ),
      ],
    );

void main() {
  late List<CoachProposal> sunk;

  CoachToolset toolset() {
    sunk = [];
    return CoachToolset(
      views: {
        'strength': _view('strength', ['id', 'date', 'exercise', 'weight', 'reps'],
            requiredDims: {'exercise'}),
        'cardio': _view('cardio', ['id', 'date', 'type']),
        'coach_chat': _view('coach_chat', ['id', 'date', 'ts', 'text']),
      },
      onProposal: (p) async => sunk.add(p),
      now: () => DateTime(2026, 9, 13),
    );
  }

  Future<String> run(CoachToolset t, Map<String, dynamic> input) =>
      t.build().firstWhere((tool) => tool.name == 'propose_schedule').run(input);

  test('happy path sinks a proposal and returns confirmation', () async {
    final t = toolset();
    final result = await run(t, {
      'view': 'strength',
      'date': '2026-09-14',
      'template': 'cut_press_heavy',
      'summary': 'Combined press day',
      'entries': [
        {'exercise': 'Bench Press', 'weight': 185, 'reps': 5},
      ],
    });
    expect(sunk, hasLength(1));
    expect(sunk.first.view, 'strength');
    expect(sunk.first.date, DateTime(2026, 9, 14));
    expect(sunk.first.entries.single['exercise'], 'Bench Press');
    expect(result, contains('confirm'));
  });

  test('rejects non-plannable view', () async {
    final t = toolset();
    await expectLater(
        run(t, {
          'view': 'coach_chat',
          'date': '2026-09-14',
          'entries': [
            {'text': 'hi'}
          ],
        }),
        throwsStateError);
    expect(sunk, isEmpty);
  });

  test('rejects bad date, empty entries, unknown field, missing required',
      () async {
    final t = toolset();
    await expectLater(
        run(t, {
          'view': 'strength',
          'date': 'next monday',
          'entries': [
            {'exercise': 'Bench'}
          ],
        }),
        throwsStateError);
    await expectLater(
        run(t, {'view': 'strength', 'date': '2026-09-14', 'entries': []}),
        throwsStateError);
    await expectLater(
        run(t, {
          'view': 'strength',
          'date': '2026-09-14',
          'entries': [
            {'exercise': 'Bench', 'wieght': 185}
          ],
        }),
        throwsStateError);
    await expectLater(
        run(t, {
          'view': 'strength',
          'date': '2026-09-14',
          'entries': [
            {'weight': 185}
          ],
        }),
        throwsStateError);
    expect(sunk, isEmpty);
  });

  test('date dim inside an entry is stripped, not rejected', () async {
    final t = toolset();
    await run(t, {
      'view': 'strength',
      'date': '2026-09-14',
      'entries': [
        {'date': '2026-09-14', 'exercise': 'Bench'},
      ],
    });
    expect(sunk.single.entries.single.containsKey('date'), isFalse);
  });
}
