// Set-type tags (2026-10-12): every strength set_type reads as a small
// coloured pill — heavy red, hypertrophy orange, skill blue, rehab green,
// warm-up the existing muted grey — in the Log timeline's logged rows and
// on planned rows whose values carry a set_type.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/planned_entry.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/plan_store.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/design/design.dart';
import 'package:airledger/ui/timeline_screen.dart';

/// WCAG relative-luminance contrast ratio.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

ThemeData _theme(Brightness b) => ThemeData(
      brightness: b,
      colorScheme:
          b == Brightness.dark ? const ColorScheme.dark() : const ColorScheme.light(),
      extensions: [b == Brightness.dark ? StatusColors.dark : StatusColors.light],
    );

class _FakeRepo implements WarehouseConnector {
  final List<Record> rows;
  _FakeRepo(this.rows);

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async => [
        for (final r in rows) Map<String, Object?>.from(r),
      ];
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

Dimension _d(String name, DimensionType t) =>
    Dimension(name: name, type: t, expr: name);

final _view = ViewSchema(
  name: 'strength',
  datasource: 'gsheets',
  table: 'strength',
  entities: const [],
  measures: const [],
  dateField: 'date',
  dimensions: [
    _d('id', DimensionType.string),
    _d('date', DimensionType.date),
    _d('start_time', DimensionType.string),
    _d('exercise', DimensionType.string),
    _d('weight', DimensionType.number),
    _d('reps', DimensionType.number),
    _d('set_type', DimensionType.string),
  ],
  listDisplay: ListDisplay(title: 'exercise', subtitle: r'${weight} × ${reps}'),
  plannable: Plannable(logField: 'start_time', logFormat: LogFormat.timeString),
);

final _day = DateTime(2026, 10, 12);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> _pumpTimeline(WidgetTester tester,
    {List<Record> logged = const [],
    List<PlannedEntry> planned = const []}) async {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.6;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  if (planned.isNotEmpty) await PlanStore.addAll(_view, planned);
  await tester.pumpWidget(MaterialApp(
    theme: _theme(Brightness.dark),
    home: TimelineScreen(
        view: _view, repository: _FakeRepo(logged), initialDate: _day),
  ));
  await _settle(tester);
}

void main() {
  group('parseSetType', () {
    test('reads the five schema options (case/space tolerant)', () {
      expect(parseSetType('heavy'), SetType.heavy);
      expect(parseSetType(' Hypertrophy '), SetType.hypertrophy);
      expect(parseSetType('skill'), SetType.skill);
      expect(parseSetType('REHAB'), SetType.rehab);
      expect(parseSetType('warmup'), SetType.warmup);
      expect(parseSetType('warm-up'), SetType.warmup);
    });

    test('blank / unknown → null (no tag, never a guess)', () {
      expect(parseSetType(null), isNull);
      expect(parseSetType(''), isNull);
      expect(parseSetType('amrap'), isNull);
    });
  });

  group('SetTypeTag label + colour', () {
    const labels = {
      SetType.heavy: 'heavy',
      SetType.hypertrophy: 'hypertrophy',
      SetType.skill: 'skill',
      SetType.rehab: 'rehab',
      SetType.warmup: 'warm-up',
    };

    for (final b in Brightness.values) {
      for (final t in SetType.values) {
        testWidgets('${t.name} (${b.name})', (tester) async {
          final theme = _theme(b);
          await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: Scaffold(body: Center(child: SetTypeTag(type: t))),
          ));
          final text = tester.widget<Text>(find.text(labels[t]!));
          final fg = text.style!.color!;
          final scheme = theme.colorScheme;
          final palette =
              b == Brightness.dark ? SetTypeColors.dark : SetTypeColors.light;
          final box = tester.widget<Container>(find.descendant(
              of: find.byType(SetTypeTag), matching: find.byType(Container)));
          final bg = (box.decoration! as BoxDecoration).color!;
          if (t == SetType.warmup) {
            // The existing muted grey warm-up tag, unchanged.
            expect(fg, scheme.onSurfaceVariant);
            expect(bg, scheme.surfaceContainerHighest);
          } else {
            expect(fg, palette.forType(t));
            // Readable on its own tint over the page surface.
            final composited = Color.alphaBlend(bg, scheme.surface);
            expect(_contrast(fg, composited), greaterThanOrEqualTo(4.5),
                reason: '${t.name} on ${b.name}');
          }
        });
      }
    }

    test('the four hues are the requested ones', () {
      for (final p in [SetTypeColors.dark, SetTypeColors.light]) {
        final hue = {
          for (final t in [
            SetType.heavy,
            SetType.hypertrophy,
            SetType.skill,
            SetType.rehab,
          ])
            t: HSVColor.fromColor(p.forType(t)!).hue,
        };
        expect(hue[SetType.heavy]!, anyOf(lessThan(10), greaterThan(345)));
        expect(hue[SetType.hypertrophy]!, inInclusiveRange(15, 40)); // orange
        expect(hue[SetType.skill]!, inInclusiveRange(200, 235)); // blue
        expect(hue[SetType.rehab]!, inInclusiveRange(110, 160)); // green
        expect(p.forType(SetType.warmup), isNull); // muted grey path
      }
    });
  });

  testWidgets('Log timeline: each logged set_type shows its tag; untagged '
      'working sets show none', (tester) async {
    Record r(String id, String ex, num w, num reps, String? type,
            String time) =>
        {
          'id': id,
          'date': _day,
          'start_time': time,
          'exercise': ex,
          'weight': w,
          'reps': reps,
          'set_type': ?type,
        };
    await _pumpTimeline(tester, logged: [
      r('1', 'Barbell Squat', 135, 5, 'warmup', '9:00:00 AM'),
      r('2', 'Barbell Squat', 260, 5, 'heavy', '9:10:00 AM'),
      r('3', 'Bulgarian Split Squat', 50, 10, 'hypertrophy', '9:20:00 AM'),
      r('4', 'Handstand Hold', 0, 1, 'skill', '9:30:00 AM'),
      r('5', 'Cable External Rotation', 10, 15, 'rehab', '9:40:00 AM'),
      r('6', 'Lateral Dumbbell Raise', 20, 12, null, '9:50:00 AM'),
    ]);
    for (final t in SetType.values) {
      expect(
          find.byWidgetPredicate((w) => w is SetTypeTag && w.type == t),
          findsOneWidget,
          reason: t.name);
    }
    expect(find.byType(SetTypeTag), findsNWidgets(5));
    expect(find.text('heavy'), findsOneWidget);
    expect(find.text('hypertrophy'), findsOneWidget);
    expect(find.text('skill'), findsOneWidget);
    expect(find.text('rehab'), findsOneWidget);
    expect(find.text('warm-up'), findsOneWidget);
  });

  testWidgets('planned rows: a known set_type tags the row; warm-up slots '
      'keep their "Warm-up" name without a duplicate tag', (tester) async {
    PlannedEntry e(String ex, num reps, num weight, String? type) =>
        PlannedEntry.create(
          view: _view,
          date: _day,
          values: {
            'exercise': ex,
            'reps': reps,
            'weight': weight,
            'set_type': ?type,
          },
          templateName: 'coach: squat day',
        );
    await _pumpTimeline(tester, planned: [
      e('Barbell Squat', 10, 45, 'warmup'),
      e('Barbell Squat', 5, 260, 'heavy'),
      e('Barbell Squat', 5, 240, 'hypertrophy'),
      e('Barbell Squat', 5, 240, 'hypertrophy'),
      e('Lateral Dumbbell Raise', 12, 20, null),
    ]);
    Finder rowTag(SetType t) => find.descendant(
        of: find.byType(ExerciseRow),
        matching: find.byWidgetPredicate((w) => w is SetTypeTag && w.type == t));
    expect(rowTag(SetType.heavy), findsOneWidget);
    expect(rowTag(SetType.hypertrophy), findsOneWidget);
    expect(rowTag(SetType.warmup), findsNothing);
    expect(find.textContaining('Warm-up'), findsOneWidget);
    // The untagged lateral-raise row carries no tag.
    expect(
        find.descendant(
            of: find.ancestor(
                of: find.textContaining('Lateral Dumbbell Raise'),
                matching: find.byType(ExerciseRow)),
            matching: find.byType(SetTypeTag)),
        findsNothing);
  });
}
