// Strength form previous-record hint (2026-10-19): renders inside the
// weight field, follows the paused/belted switches live, and a tap opens
// that set's day in the timeline.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/design/design.dart';
import 'package:airledger/ui/form_screen.dart';
import 'package:airledger/ui/timeline_screen.dart';

class _Repo implements WarehouseConnector {
  final List<Record> rows;
  int lists = 0;
  _Repo(this.rows);
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    lists++;
    return [
      for (final r in rows)
        if (onDate == null ||
            (r['date'] as DateTime).isAtSameMomentAs(onDate))
          r,
    ];
  }

  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

Dimension _d(String name, DimensionType t, [WidgetType? w]) => Dimension(
  name: name,
  type: t,
  expr: name,
  input: w == null ? null : InputSpec(widget: w),
);

final _view = ViewSchema(
  name: 'strength',
  datasource: 'gsheets',
  table: 'strength',
  entities: const [],
  measures: const [],
  dateField: 'date',
  dimensions: [
    Dimension(
      name: 'id',
      type: DimensionType.string,
      expr: 'id',
      input: InputSpec(widget: WidgetType.text, editable: false),
    ),
    _d('date', DimensionType.date, WidgetType.date),
    _d('exercise', DimensionType.string, WidgetType.text),
    _d('weight', DimensionType.number, WidgetType.number),
    _d('reps', DimensionType.number, WidgetType.number),
    _d('rpe', DimensionType.number, WidgetType.number),
    _d('paused', DimensionType.boolean, WidgetType.switch_),
    _d('set_type', DimensionType.string, WidgetType.text),
  ],
  listDisplay: ListDisplay(title: 'exercise', subtitle: r'${weight} × ${reps}'),
);

Record _row(String id, DateTime d, num w, int reps,
        {num? rpe, bool? paused, String? setType}) =>
    {
      'id': id,
      'date': d,
      'exercise': 'Flat Barbell Bench Press',
      'weight': w,
      'reps': reps,
      'rpe': ?rpe,
      'paused': ?paused,
      'set_type': ?setType,
    };

final _rows = [
  _row('p1', DateTime(2026, 10, 1), 225, 3, rpe: 8, paused: true),
  _row('t1', DateTime(2026, 10, 5), 245, 3, rpe: 8, paused: false),
  _row('w1', DateTime(2026, 10, 6), 300, 5, setType: 'warmup'),
];

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(
    colorScheme: const ColorScheme.light(),
    extensions: const [StatusColors.light],
  ),
  home: child,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('PR hint tracks the paused switch; warm-up never wins', (
    tester,
  ) async {
    final repo = _Repo(_rows);
    await tester.pumpWidget(_host(FormScreen(
      view: _view,
      repository: repo,
      planMode: true,
      existing: {
        'date': DateTime(2026, 10, 12),
        'exercise': 'Flat Barbell Bench Press',
      },
    )));
    await tester.pumpAndSettle();
    // Paused unset → any state: touch-and-go 245 wins (warm-up 300 is out).
    expect(find.text('PR 245×3 @ 8'), findsOneWidget);
    expect(find.textContaining('300'), findsNothing);

    // Toggle paused ON → the paused record.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('PR 225×3 @ 8'), findsOneWidget);
    expect(find.text('PR 245×3 @ 8'), findsNothing);

    // OFF (explicit false) → touch-and-go again.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('PR 245×3 @ 8'), findsOneWidget);
    // One deferred list for the whole session — toggles never re-list.
    expect(repo.lists, 1);
  });

  testWidgets('no hint before an exercise is chosen', (tester) async {
    await tester.pumpWidget(_host(FormScreen(
      view: _view,
      repository: _Repo(_rows),
      planMode: true,
      existing: {'date': DateTime(2026, 10, 12)},
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('PR '), findsNothing);
  });

  testWidgets('tapping the PR opens that day, set expanded', (tester) async {
    await tester.pumpWidget(_host(FormScreen(
      view: _view,
      repository: _Repo(_rows),
      planMode: true,
      existing: {
        'date': DateTime(2026, 10, 12),
        'exercise': 'Flat Barbell Bench Press',
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('prev-record-best')));
    // Real async (prefs / row-cache opens) between frames.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    final tl = tester.widget<TimelineScreen>(find.byType(TimelineScreen));
    expect(tl.initialDate, DateTime(2026, 10, 5));
    expect(tl.highlightKeys, {'t1'});
    // The recorded set's tile arrives expanded (its expand_less chevron).
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    // Drain the timeline's one-shot highlight fade.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('long-press fills the weight field', (tester) async {
    await tester.pumpWidget(_host(FormScreen(
      view: _view,
      repository: _Repo(_rows),
      planMode: true,
      existing: {
        'date': DateTime(2026, 10, 12),
        'exercise': 'Flat Barbell Bench Press',
      },
    )));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('prev-record-best')));
    await tester.pumpAndSettle();
    final weight = find.descendant(
      of: find.byKey(const ValueKey('weight')),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(weight).controller!.text, '245');
  });
}
