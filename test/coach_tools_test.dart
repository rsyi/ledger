import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/coach_tools.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';

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

  test('legacy `template` param still labels the group', () async {
    final t = toolset();
    await run(t, {
      'view': 'strength',
      'date': '2026-09-14',
      'template': 'Squat day',
      'entries': [
        {'exercise': 'Squat'},
      ],
    });
    expect(sunk.single.template, 'Squat day');
  });

  test('`group` param labels the group', () async {
    final t = toolset();
    await run(t, {
      'view': 'strength',
      'date': '2026-09-14',
      'group': 'Press day',
      'entries': [
        {'exercise': 'Bench'},
      ],
    });
    expect(sunk.single.template, 'Press day');
  });

  test('read_program_day omitted without a resolver; present with one',
      () async {
    final noResolver = CoachToolset(
      views: {
        'strength': _view('strength', ['id', 'date', 'exercise']),
      },
      onProposal: (_) async {},
    );
    expect(
      noResolver.build().map((t) => t.name),
      isNot(contains('read_program_day')),
    );

    final withResolver = CoachToolset(
      views: {
        'strength': _view('strength', ['id', 'date', 'exercise']),
      },
      onProposal: (_) async {},
      programDay: (view, date) async => [
        {'exercise': 'Squat', 'reps': 5, 'weight': 260},
      ],
    );
    final tool = withResolver
        .build()
        .firstWhere((t) => t.name == 'read_program_day');
    final out = await tool.run({'view': 'strength', 'date': '2026-09-14'});
    expect(out, contains('Squat'));
    expect(out, contains('"entry_count": 1'));
  });

  group('propose_moves', () {
    // Thu 2026-10-01 → week Mon 9/28..Sun 10/4.
    late List<MovesProposal> moved;
    CoachToolset movesToolset() {
      moved = [];
      return CoachToolset(
        views: const {},
        onProposal: (_) async {},
        onMovesProposal: (p) async => moved.add(p),
        now: () => DateTime(2026, 10, 1, 9),
      );
    }

    Future<String> runMoves(CoachToolset t, Map<String, dynamic> input) => t
        .build()
        .firstWhere((tool) => tool.name == 'propose_moves')
        .run(input);

    test('omitted without a sink', () {
      final t = CoachToolset(views: const {}, onProposal: (_) async {});
      expect(t.build().map((x) => x.name), isNot(contains('propose_moves')));
    });

    test('happy path sinks a MovesProposal that round-trips', () async {
      final out = await runMoves(movesToolset(), {
        'summary': 'Bench top set Wed → Fri',
        'moves': [
          {
            'item': 'Bench top set',
            'from_date': '2026-09-30',
            'to_date': '2026-10-02',
            'period': 'PM',
            'note': 'missed Wed',
          },
        ],
      });
      expect(out, contains('Do not claim'));
      expect(moved, hasLength(1));
      final p = moved.single;
      expect(p.summary, 'Bench top set Wed → Fri');
      expect(p.moves.single.item, 'Bench top set');
      expect(p.moves.single.from, DateTime(2026, 9, 30));
      expect(p.moves.single.to, DateTime(2026, 10, 2));
      expect(p.moves.single.period, 'PM');
      final back = MovesProposal.tryParse(p.encode())!;
      expect(back.moves.single.to, DateTime(2026, 10, 2));
    });

    test('moving into today is allowed', () async {
      await runMoves(movesToolset(), {
        'summary': 's',
        'moves': [
          {'item': 'RDL', 'from_date': '2026-09-28', 'to_date': '2026-10-01'},
        ],
      });
      expect(moved.single.moves.single.to, DateTime(2026, 10, 1));
    });

    for (final (name, move, msg) in [
      (
        'to outside the week',
        {'item': 'RDL', 'from_date': '2026-09-28', 'to_date': '2026-10-05'},
        'outside this week',
      ),
      (
        'from outside the week',
        {'item': 'RDL', 'from_date': '2026-09-27', 'to_date': '2026-10-02'},
        'outside this week',
      ),
      (
        'to == from',
        {'item': 'RDL', 'from_date': '2026-10-02', 'to_date': '2026-10-02'},
        'equals from_date',
      ),
      (
        'to in the past',
        {'item': 'RDL', 'from_date': '2026-09-28', 'to_date': '2026-09-29'},
        'in the past',
      ),
      (
        'bad date',
        {'item': 'RDL', 'from_date': 'Wed', 'to_date': '2026-10-02'},
        'yyyy-MM-dd',
      ),
      (
        'blank item',
        {'item': ' ', 'from_date': '2026-09-28', 'to_date': '2026-10-02'},
        'item is required',
      ),
    ]) {
      test('rejects $name', () async {
        final t = movesToolset();
        await expectLater(
          runMoves(t, {
            'summary': 's',
            'moves': [move],
          }),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains(msg))),
        );
        expect(moved, isEmpty);
      });
    }

    group('item validation against the program week', () {
      final wed = DateTime(2026, 9, 30);
      Map<DateTime, List<EffectiveItem>> week() => effectiveWeek({
            for (var i = 0; i < 7; i++)
              DateTime(2026, 9, 28 + i): i == 2
                  ? const [
                      PrescribedItem(
                          name: 'Bench heavy', scheme: '1x3', period: 'PM'),
                      PrescribedItem(
                          name: 'Pull-ups', scheme: '3x8', period: 'PM'),
                    ]
                  : const <PrescribedItem>[],
          }, const {});

      CoachToolset weekToolset({bool fail = false}) {
        moved = [];
        return CoachToolset(
          views: const {},
          onProposal: (_) async {},
          onMovesProposal: (p) async => moved.add(p),
          now: () => DateTime(2026, 10, 1, 9),
          movesWeek: () async {
            if (fail) throw StateError('docs down');
            return week();
          },
        );
      }

      test('an item not on from_date → model-visible error listing the '
          'valid names; nothing sunk', () async {
        await expectLater(
          runMoves(weekToolset(), {
            'summary': 's',
            'moves': [
              {
                'item': 'Bench top set',
                'from_date': '2026-09-30',
                'to_date': '2026-10-02',
              },
            ],
          }),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              allOf(contains('"Bench heavy"'), contains('"Pull-ups"')))),
        );
        expect(moved, isEmpty);
      });

      test('case-insensitive match → canonical name + program period',
          () async {
        await runMoves(weekToolset(), {
          'summary': 's',
          'moves': [
            {
              'item': 'bench heavy',
              'from_date': '2026-09-30',
              'to_date': '2026-10-02',
            },
          ],
        });
        final m = moved.single.moves.single;
        expect(m.item, 'Bench heavy');
        expect(m.from, wed);
        expect(m.period, 'PM');
      });

      test('week provider failure → item check skipped', () async {
        await runMoves(weekToolset(fail: true), {
          'summary': 's',
          'moves': [
            {'item': 'RDL', 'from_date': '2026-09-28', 'to_date': '2026-10-02'},
          ],
        });
        expect(moved, hasLength(1));
      });
    });

    test('rejects empty moves', () async {
      final t = movesToolset();
      await expectLater(
        runMoves(t, {'summary': 's', 'moves': []}),
        throwsA(isA<StateError>()),
      );
    });
  });
}
