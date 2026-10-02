// UI redesign phase 5 (docs/superpowers/specs/2026-10-02-ui-redesign-
// design.md): human names on the Log list + forms, RPE / set-type quick
// picks, the notebook-pen icon, and the coach threads single app bar.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/display_names.dart';
import 'package:airledger/services/domain_config.dart';
import 'package:airledger/services/icon_resolver.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/coach_threads_screen.dart';
import 'package:airledger/ui/design/design.dart';
import 'package:airledger/ui/form_screen.dart';
import 'package:airledger/ui/widgets/field_widgets.dart';
import 'package:airledger/ui/widgets/log_list_row.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class _FakeRepo implements WarehouseConnector {
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async => [];
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(),
    extensions: const [StatusColors.dark],
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Dimension _dim(
  String name, {
  DimensionType type = DimensionType.string,
  WidgetType? widget,
  bool required = false,
  List<String>? options,
  String? description,
}) => Dimension(
  name: name,
  type: type,
  expr: name,
  description: description,
  input: widget == null
      ? null
      : InputSpec(widget: widget, required: required, options: options),
);

ViewSchema _view(String name, List<Dimension> dims) => ViewSchema(
  name: name,
  datasource: 'gsheets',
  table: name,
  entities: const [],
  measures: const [],
  dimensions: dims,
);

void main() {
  group('display names', () {
    test('exercise labels: lowercase names title-cased, cased kept', () {
      expect(exerciseLabel('handstand'), 'Handstand');
      expect(exerciseLabel('muscle-up'), 'Muscle Up');
      expect(exerciseLabel('front lever'), 'Front Lever');
      expect(exerciseLabel('hspu'), 'HSPU');
      expect(exerciseLabel('Cable Face Pull'), 'Cable Face Pull');
      expect(exerciseLabel('EZ-Bar Preacher Curl'), 'EZ-Bar Preacher Curl');
      expect(exerciseLabel(''), '');
    });

    test('sentence case for generated summaries', () {
      expect(sentenceCase('squat heavy · bench volume'),
          'Squat heavy · bench volume');
      expect(sentenceCase('4x4 · hard climb'), '4x4 · hard climb');
      expect(sentenceCase(''), '');
    });

    test('view labels', () {
      expect(viewLabel('daily_notes'), 'Daily notes');
      expect(viewLabel('whoop_workouts'), 'Whoop workouts');
      expect(viewLabel('strength'), 'Strength');
      expect(viewLabel('program_moves'), 'Program moves');
      expect(kHiddenLogViews, contains('program_moves'));
    });

    test('field labels: humanizer + overrides + units', () {
      expect(fieldLabel('start_time'), 'Start time');
      expect(fieldLabel('rpe'), 'RPE');
      expect(fieldLabel('set_type'), 'Set type');
      expect(fieldLabel('video_url'), 'Video');
      expect(fieldLabel('hold_seconds'), 'Hold (s)');
      expect(fieldLabel('protein_g'), 'Protein (g)');
      expect(fieldLabel('max_hr'), 'Max HR');
      expect(fieldLabel('sleep_hours'), 'Sleep hours');
    });

    test('helper text: overrides, short first clause, else none', () {
      expect(
        fieldHelp(_dim('video_url', widget: WidgetType.video)),
        'Attach a clip from your phone',
      );
      expect(fieldHelp(_dim('set_type', widget: WidgetType.dropdown)), isNull);
      // Long schema prose is dropped, not truncated mid-sentence.
      expect(
        fieldHelp(
          _dim(
            'variation',
            description:
                'Progression or variation used for this particular skill set '
                'including band colour and wall assistance level',
          ),
        ),
        isNull,
      );
      // Short first clause survives.
      expect(
        fieldHelp(
          _dim('pain', description: 'Any pain/tendon/joint issue (free text)'),
        ),
        'Any pain/tendon/joint issue',
      );
      // Date fields never carry one.
      expect(
        fieldHelp(
          _dim('date', type: DimensionType.date, description: 'Workout day'),
        ),
        isNull,
      );
    });

    test('dashboards.yaml label/description parse, humanized fallback', () {
      final cfg = parseDomainConfigs('''
domains:
  - name: daily_notes
    paradigm: entry
    views: [daily_notes]
  - name: whoop_workouts
    label: Workouts (Whoop)
    description: "Whoop strain per workout"
    paradigm: integration
    views: [whoop_workouts]
''')!;
      expect(cfg[0].displayName, 'Daily notes');
      expect(cfg[0].description, isNull);
      expect(cfg[1].displayName, 'Workouts (Whoop)');
      expect(cfg[1].description, 'Whoop strain per workout');
    });
  });

  group('Log list rows', () {
    testWidgets('daily_notes renders the notebook-pen glyph, not text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          LogListRow(
            label: viewLabel('daily_notes'),
            icon: 'notebook-pen',
            description:
                'One free-form journal entry per day — training context',
            onTap: () {},
          ),
        ),
      );
      expect(find.text('Daily notes'), findsOneWidget);
      expect(find.text('no'), findsNothing);
      expect(find.byIcon(LucideIcons.notebookPen), findsOneWidget);
      expect(find.text('One free-form journal entry per day'), findsOneWidget);
    });

    testWidgets('unmapped icon names fall back to a glyph', (tester) async {
      await tester.pumpWidget(_host(IconResolver.resolve('not-a-real-icon')));
      expect(find.byIcon(LucideIcons.list), findsOneWidget);
      expect(find.text('not-a-real-icon'), findsNothing);
    });

    testWidgets('today call wins; rows share one height', (tester) async {
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              LogListRow(
                key: const ValueKey('a'),
                label: 'Strength',
                icon: 'dumbbell',
                todayCall: 'deadlift heavy + bench volume',
                waiting: true,
                summary: 'Sets, weight × reps, RPE',
                onTap: () {},
              ),
              LogListRow(
                key: const ValueKey('b'),
                label: 'Whoop workouts',
                icon: 'activity',
                onTap: () {},
              ),
            ],
          ),
        ),
      );
      expect(
        find.text('Today: deadlift heavy + bench volume · waiting to log'),
        findsOneWidget,
      );
      expect(find.text('Sets, weight × reps, RPE'), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('a'))).height,
        tester.getSize(find.byKey(const ValueKey('b'))).height,
      );
    });

    test('summary beats the description', () {
      final m = logRowMeta(summary: 'Kaya ascents', description: 'Long — x');
      expect(m.text, 'Kaya ascents');
      expect(m.accent, isFalse);
    });
  });

  group('form fields', () {
    testWidgets('human labels; RPE quick picks write the value', (
      tester,
    ) async {
      Object? value;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => buildFieldWidget(
              dim: _dim(
                'rpe',
                type: DimensionType.number,
                widget: WidgetType.number,
                description:
                    'Rate of Perceived Exertion (1-10). RIR convention: RIR = '
                    '10 - RPE — no separate RIR field by design.',
              ),
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      );
      expect(find.text('RPE'), findsOneWidget);
      expect(find.text('RIR = 10 − RPE'), findsOneWidget);
      for (final v in kRpeQuickPicks) {
        expect(find.text(v), findsOneWidget);
      }
      await tester.tap(
        find.descendant(
          of: find.byType(QuickPicks),
          matching: find.text('8.5'),
        ),
      );
      await tester.pump();
      expect(value, 8.5);
      // The text field mirrors the pick.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '8.5',
      );
      // Tapping the selected pick clears it.
      await tester.tap(
        find.descendant(
          of: find.byType(QuickPicks),
          matching: find.text('8.5'),
        ),
      );
      await tester.pump();
      expect(value, isNull);
    });

    testWidgets('set type renders as quick-pick chips', (tester) async {
      Object? value;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => buildFieldWidget(
              dim: _dim(
                'set_type',
                widget: WidgetType.dropdown,
                options: const [
                  'warmup',
                  'heavy',
                  'hypertrophy',
                  'skill',
                  'rehab',
                ],
                description: 'What the set was for: warmup | heavy | …',
              ),
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      );
      expect(find.text('Set type'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byType(QuickPicks), findsOneWidget);
      // The long schema description is gone.
      expect(find.textContaining('What the set was for'), findsNothing);
      await tester.tap(find.text('hypertrophy'));
      await tester.pump();
      expect(value, 'hypertrophy');
    });

    testWidgets('video field: "Video" label + new helper text', (tester) async {
      await tester.pumpWidget(
        _host(
          buildFieldWidget(
            dim: _dim(
              'video_url',
              widget: WidgetType.video,
              description: 'Google Photos link to a video of this set',
            ),
            value: null,
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.text('Video'), findsOneWidget);
      expect(find.text('Attach a clip from your phone'), findsOneWidget);
      expect(find.textContaining('Google Photos'), findsNothing);
    });

    testWidgets('required miss: snackbar names the human label', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final view = _view('daily_notes', [
        _dim(
          'sleep_hours',
          type: DimensionType.number,
          widget: WidgetType.number,
          required: true,
        ),
        _dim('note', widget: WidgetType.longtext),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: FormScreen(view: view, repository: _FakeRepo()),
        ),
      );
      await tester.pump();
      expect(find.text('New daily notes'), findsOneWidget);
      expect(find.text('Sleep hours *'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      expect(find.text('Missing required: Sleep hours'), findsOneWidget);
    });
  });

  testWidgets('coach threads route: exactly one app bar with back and +', (
    tester,
  ) async {
    final view = _view('coach_chat', [_dim('id'), _dim('thread')]);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  coachThreadsRoute(
                    CoachThreadsScreen(view: view, repository: _FakeRepo()),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Coach'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.byTooltip('New thread'), findsOneWidget);
    // Dispose the screen (cancels its 30 s poll timer).
    await tester.pumpWidget(const SizedBox());
  });
}
