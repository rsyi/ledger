// History panel → timeline (2026-10-23, user: "click on a record and then
// go to that day in the log view and have that entry be highlighted").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/design/design.dart';
import 'package:airledger/ui/timeline_screen.dart';
import 'package:airledger/ui/widgets/history_panel.dart';

class _Repo implements WarehouseConnector {
  final List<Record> rows;
  _Repo(this.rows);
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async => [
    for (final r in rows)
      if (onDate == null || (r['date'] as DateTime).isAtSameMomentAs(onDate)) r,
  ];
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

Dimension _d(String name, DimensionType t, [WidgetType? w, bool h = false]) =>
    Dimension(
      name: name,
      type: t,
      expr: name,
      input: w == null ? null : InputSpec(widget: w, history: h),
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
    _d('exercise', DimensionType.string, WidgetType.text, true),
    _d('weight', DimensionType.number, WidgetType.number),
    _d('reps', DimensionType.number, WidgetType.number),
    _d('rpe', DimensionType.number, WidgetType.number),
  ],
  listDisplay: ListDisplay(title: 'exercise', subtitle: r'${weight} × ${reps}'),
);

Record _row(String id, DateTime d, num w, int reps) => {
  'id': id,
  'date': d,
  'exercise': 'Flat Barbell Bench Press',
  'weight': w,
  'reps': reps,
  'rpe': 8,
};

final _rows = [
  _row('a1', DateTime(2026, 10, 1), 225, 5),
  _row('a2', DateTime(2026, 10, 1), 235, 3),
  _row('b1', DateTime(2026, 10, 5), 245, 3),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tapping a past set opens that day with the set highlighted', (
    tester,
  ) async {
    const scheme = ColorScheme.light();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: scheme,
          extensions: const [StatusColors.light],
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showHistorySheet(
                context: context,
                view: _view,
                dim: _view.dimensionByName('exercise')!,
                value: 'Flat Barbell Bench Press',
                repository: _Repo(_rows),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('235 × 3'));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Sheet closed; the timeline sits on that day with that row keyed in.
    expect(find.text('History · exercise'), findsNothing);
    final tl = tester.widget<TimelineScreen>(find.byType(TimelineScreen));
    expect(tl.initialDate, DateTime(2026, 10, 1));
    expect(tl.highlightKeys, {'a2'});

    // The row is visibly TINTED (not just expanded); its sibling isn't.
    Color? tint(String id) {
      final c = tester.widget<AnimatedContainer>(
        find.byKey(ValueKey('logged-row-$id')),
      );
      return (c.decoration as BoxDecoration?)?.color;
    }

    expect(tint('a2'), loggedRowHighlight(scheme));
    expect(tint('a1'), isNot(loggedRowHighlight(scheme)));
    // The tint fades after a few seconds.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tint('a2'), isNot(loggedRowHighlight(scheme)));
  });
}
