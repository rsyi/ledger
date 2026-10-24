// Strength header "Wilks · est. total" → breakdown sheet (2026-10-23).
// The sheet must show the header's exact numbers (one computation), SBD
// only, and each lift's source set opens its day highlighted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/domain_config.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/design/design.dart';
import 'package:airledger/ui/domain_screen.dart';
import 'package:airledger/ui/timeline_screen.dart';

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

Dimension _d(String name, DimensionType t, [WidgetType? w]) => Dimension(
  name: name,
  type: t,
  expr: name,
  input: w == null ? null : InputSpec(widget: w),
);

ViewSchema _view(String name, List<Dimension> dims) => ViewSchema(
  name: name,
  datasource: 'gsheets',
  table: name,
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
    ...dims,
  ],
  listDisplay: ListDisplay(title: 'exercise', subtitle: r'${weight} × ${reps}'),
);

final _strength = _view('strength', [
  _d('exercise', DimensionType.string, WidgetType.text),
  _d('weight', DimensionType.number, WidgetType.number),
  _d('reps', DimensionType.number, WidgetType.number),
  _d('rpe', DimensionType.number, WidgetType.number),
  _d('belted', DimensionType.boolean, WidgetType.switch_),
]);
final _weight = _view('weight', [
  _d('weight_lbs', DimensionType.number, WidgetType.number),
]);

Record _set(
  String id,
  DateTime d,
  String ex,
  num w,
  int reps,
  num rpe, {
  bool? belted,
}) => {
  'id': id,
  'date': d,
  'exercise': ex,
  'weight': w,
  'reps': reps,
  'rpe': rpe,
  'belted': ?belted,
};

final _rows = [
  _set('s1', DateTime(2026, 10, 6), 'Barbell Squat', 275, 5, 8.5, belted: true),
  _set('b1', DateTime(2026, 10, 7), 'Flat Barbell Bench Press', 185, 4, 8),
  _set('d1', DateTime(2026, 10, 8), 'Barbell Deadlift', 285, 3, 7),
  // A heavy press: must never reach the total, the Wilks or the sheet.
  _set('p1', DateTime(2026, 10, 8), 'Overhead Press', 185, 3, 8),
];
final _weighIns = [
  {'id': 'w1', 'date': DateTime(2026, 10, 6), 'weight_lbs': 160.0},
  {'id': 'w2', 'date': DateTime(2026, 10, 8), 'weight_lbs': 161.0},
];

const _domain = DomainConfig(
  name: 'strength',
  paradigm: DomainParadigm.entry,
  views: ['strength'],
  headline: ['wilks', 'pl_total'],
  metrics: [
    MetricConfig(id: 'wilks'),
    MetricConfig(id: 'pl_total', unit: 'lb'),
  ],
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('header tap → breakdown with the SAME numbers, SBD only; '
      'a lift row opens its source set highlighted', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: const ColorScheme.light(),
          extensions: const [StatusColors.light],
        ),
        home: DomainScreen(
          domain: _domain,
          view: _strength,
          repository: _Repo(_rows),
          weightView: _weight,
          weightRepository: _Repo(_weighIns),
          today: DateTime(2026, 10, 9),
        ),
      ),
    );
    await _settle(tester);

    final header = tester
        .widget<Text>(find.byKey(const ValueKey('domain-headline')))
        .textSpan!
        .toPlainText();
    final m = RegExp(
      r'Wilks ([\d.]+)\s+·\s+est\. total (\d+ lb)',
    ).firstMatch(header);
    expect(m, isNotNull, reason: header);

    await tester.tap(find.byKey(const ValueKey('domain-headline')));
    await _settle(tester);
    String text(String key) =>
        tester.widget<Text>(find.byKey(ValueKey(key))).data!;
    expect(text('strength-total-wilks'), m!.group(1));
    expect(text('strength-total-total'), m.group(2));

    // SBD only: the press total would be 275·(1+6.5/30) + 185·(1+6/30) +
    // 285·(1+6/30) = 334.6 + 222 + 342 → 899; adding the press would be
    // ~1121.
    expect(m.group(2), '899 lb');
    expect(find.text('Squat  335 lb est. 1RM'), findsOneWidget);
    expect(find.textContaining('275×5 @ RPE 8.5 · belted'), findsOneWidget);
    expect(find.textContaining('Overhead'), findsNothing);
    expect(find.textContaining('185×3'), findsNothing);
    expect(find.textContaining('335 + 222 + 342 = 899 lb'), findsOneWidget);
    expect(find.textContaining('Bodyweight 160.5 lb'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('strength-total-squat')));
    await _settle(tester);
    final tl = tester.widget<TimelineScreen>(find.byType(TimelineScreen).last);
    expect(tl.initialDate, DateTime(2026, 10, 6));
    expect(tl.highlightKeys, {'s1'});
    await tester.pump(const Duration(seconds: 5));
  });
}
