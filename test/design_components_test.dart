// Design system (lib/ui/design/) — tokens + shared components.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/ui/design/design.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme:
      theme ??
      ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(),
        extensions: const [StatusColors.dark],
      ),
  home: Scaffold(body: child),
);

void main() {
  group('tokens', () {
    testWidgets('type roles carry the spec sizes/weights', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(AppText.title(ctx).fontSize, 16);
      expect(AppText.title(ctx).fontWeight, FontWeight.w600);
      expect(AppText.row(ctx).fontSize, 14);
      expect(AppText.row(ctx).fontWeight, FontWeight.w500);
      expect(AppText.meta(ctx).fontSize, 12);
      expect(AppText.meta(ctx).fontWeight, FontWeight.w400);
      expect(
        AppText.meta(ctx).color,
        Theme.of(ctx).colorScheme.onSurfaceVariant,
      );
      expect(AppText.section(ctx).fontSize, 11);
      expect(AppText.section(ctx).letterSpacing, greaterThan(0));
      expect(AppSpace.gutter, 16);
      expect(AppSpace.sectionGap, 12);
      expect(AppSpace.row, 44);
      expect(AppRadius.card, 12);
    });

    testWidgets('StatusColors falls back when the extension is absent', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
          theme: ThemeData(brightness: Brightness.dark),
        ),
      );
      expect(StatusColors.of(ctx), StatusColors.dark);
      expect(
        StatusColors.of(ctx).forStatus(ctx, ItemStatus.done),
        StatusColors.dark.done,
      );
      expect(
        StatusColors.dark.lerp(StatusColors.light, 1).done,
        StatusColors.light.done,
      );
    });

    testWidgets('AppCard: surfaceContainer, radius 12, no outline', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const AppCard(child: Text('x'))));
      final m = tester.widget<Material>(
        find
            .ancestor(of: find.text('x'), matching: find.byType(Material))
            .first,
      );
      expect(m.borderRadius, BorderRadius.circular(12));
      expect(m.shape, isNull);
    });
  });

  group('ExerciseRow', () {
    testWidgets('name + meta on one line, chips, trailing, taps', (
      tester,
    ) async {
      var taps = 0, longs = 0, chipTaps = 0;
      await tester.pumpWidget(
        _host(
          ExerciseRow(
            name: 'Overhead Press',
            meta: '3×6 · 105 lb',
            status: ItemStatus.partial,
            chips: [SetChip(label: '105×6', onTap: () => chipTaps++)],
            trailing: const Icon(Icons.more_vert),
            onTap: () => taps++,
            onLongPress: () => longs++,
          ),
        ),
      );
      expect(find.textContaining('Overhead Press'), findsOneWidget);
      expect(find.textContaining('3×6 · 105 lb'), findsOneWidget);
      expect(find.text('105×6'), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      expect(find.byIcon(Icons.contrast), findsOneWidget); // partial mark
      await tester.tap(find.text('105×6'));
      expect(chipTaps, 1);
      expect(taps, 0, reason: 'chip tap must not bubble to the row');
      await tester.tap(find.textContaining('Overhead Press'));
      await tester.longPress(find.textContaining('Overhead Press'));
      expect(taps, 1);
      expect(longs, 1);
    });

    testWidgets('single-line row is ≈44 px', (tester) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [ExerciseRow(name: 'Pull Up', meta: '3×8 · BW')],
          ),
        ),
      );
      final h = tester.getSize(find.byType(ExerciseRow)).height;
      expect(h, inInclusiveRange(44, 48));
    });

    testWidgets('status marks per status', (tester) async {
      for (final (s, icon) in [
        (ItemStatus.pending, Icons.radio_button_unchecked),
        (ItemStatus.done, Icons.check_circle),
        (ItemStatus.problem, Icons.error_outline),
      ]) {
        await tester.pumpWidget(_host(ExerciseRow(name: 'x', status: s)));
        expect(find.byIcon(icon), findsOneWidget, reason: s.name);
      }
    });

    testWidgets('leading overrides the status mark', (tester) async {
      await tester.pumpWidget(
        _host(
          const ExerciseRow(
            name: 'x',
            leading: Icon(Icons.check_box),
            status: ItemStatus.done,
          ),
        ),
      );
      expect(find.byIcon(Icons.check_box), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
    });
  });

  group('SetChip', () {
    testWidgets('tap and long-press are separate', (tester) async {
      var taps = 0, longs = 0;
      await tester.pumpWidget(
        _host(
          SetChip(
            label: '120×5',
            onTap: () => taps++,
            onLongPress: () => longs++,
          ),
        ),
      );
      await tester.tap(find.text('120×5'));
      await tester.longPress(find.text('120×5'));
      expect((taps, longs), (1, 1));
    });

    testWidgets('done chip shows a check', (tester) async {
      await tester.pumpWidget(_host(const SetChip(label: '45×10', done: true)));
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('SectionHeader', () {
    testWidgets('upper-cases label, shows count + actions', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        _host(
          SectionHeader(
            label: 'From your program',
            count: '3 / 21',
            actions: [
              IconButton(
                icon: const Icon(Icons.done_all),
                onPressed: () => pressed++,
              ),
            ],
          ),
        ),
      );
      expect(find.text('FROM YOUR PROGRAM'), findsOneWidget);
      expect(find.text('3 / 21'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.done_all));
      expect(pressed, 1);
    });

    testWidgets('upperCase: false keeps user-authored names', (tester) async {
      await tester.pumpWidget(
        _host(const SectionHeader(label: 'Coach: Tue', upperCase: false)),
      );
      expect(find.text('Coach: Tue'), findsOneWidget);
    });
  });

  testWidgets('StatStrip renders label/value pairs', (tester) async {
    await tester.pumpWidget(
      _host(
        const StatStrip(
          items: [
            StatItem('Sleep', '7.2h'),
            StatItem('HRV', '61', status: ItemStatus.done),
          ],
        ),
      ),
    );
    expect(find.textContaining('Sleep'), findsOneWidget);
    expect(find.textContaining('7.2h'), findsOneWidget);
    expect(find.textContaining('HRV'), findsOneWidget);
  });

  testWidgets('StatusChip tints with the status colour', (tester) async {
    await tester.pumpWidget(
      _host(const StatusChip(label: 'missed', status: ItemStatus.problem)),
    );
    final t = tester.widget<Text>(find.text('missed'));
    expect(t.style?.color, StatusColors.dark.problem);
  });

  testWidgets('showDetailSheet pops then runs the action', (tester) async {
    var ran = 0;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showDetailSheet(
              context: ctx,
              title: 'Overhead Press',
              subtitle: '3×6 · 105 lb',
              actions: [
                DetailAction(
                  icon: Icons.delete_outline,
                  label: 'Remove',
                  destructive: true,
                  onTap: () => ran++,
                ),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Overhead Press'), findsOneWidget);
    expect(find.text('3×6 · 105 lb'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(ran, 1);
    expect(find.text('Overhead Press'), findsNothing);
  });
}
