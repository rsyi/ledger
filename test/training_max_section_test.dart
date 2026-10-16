// HITL training-max UI (2026-10-16): Progress' TRAINING MAXES section
// (pending review cards with Accept / Keep, "recommended" drops, the TM
// in force, the dated change log + lift filter), Today's review pill,
// and the once-per-proposal notification composition.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/tm_proposal_notifier.dart';
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/services/working_max.dart';
import 'package:airledger/ui/design/design.dart';
import 'package:airledger/ui/widgets/training_max_section.dart';

DateTime _d(String s) => DateTime.parse('${s}T00:00:00Z');

WorkingMaxRow _row(String lift, double v, String date, String source,
        {String reason = '', String readingId = '', bool? confirmed}) =>
    WorkingMaxRow(
      lift: lift,
      variant: defaultVariantByLift[lift]!,
      valueLb: v,
      effectiveFrom: _d(date),
      source: source,
      reason: reason,
      readingId: readingId,
      confirmed: confirmed,
    );

/// Live-shaped tab after the HITL conversion + tonight's press grinder.
List<WorkingMaxRow> _rows() => [
      _row('squat', 320, '2026-09-21', 'seed',
          reason: '§5 seed', confirmed: true),
      _row('bench', 245, '2026-09-21', 'manual',
          reason: 'current working single 225x1', confirmed: true),
      _row('press', 145, '2026-09-28', 'rule',
          reason: 'slow loop nightly recompute → 145'),
      _row('deadlift', 340, '2026-09-25', 'manual',
          reason: 'set 340', confirmed: true),
      _row('deadlift', 360, '2026-10-15', 'rule',
          reason: 'slow loop: median implied 358.0',
          readingId: '2026-10-15|deadlift'),
      _row('deadlift', 340, '2026-10-15', 'revert_to_pending',
          reason: 'converted to proposal under HITL gating',
          confirmed: true),
      _row('deadlift', 360, '2026-10-15', 'auto',
          reason: 'from 295×5 @ RPE 8.5 (est 358, median of 3 sets)',
          readingId: '2026-10-15|deadlift',
          confirmed: false),
      _row('press', 135, '2026-10-16', 'auto',
          reason: 'recommended: grinder on 120×4 @ RPE 9.5 (implied 137)',
          readingId: '2026-10-16|press',
          confirmed: false),
    ];

WmSnapshot _snap(List<WorkingMaxRow> rows) =>
    (workingMax: rows, readings: const <ReadingRow>[]);

Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(extensions: const [StatusColors.light]),
      home: Scaffold(body: ListView(children: [child])),
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('TrainingMaxSection', () {
    testWidgets('pending cards first: old → new, evidence, Accept / Keep',
        (tester) async {
      _tall(tester);
      final calls = <String>[];
      var decided = 0;
      await tester.pumpWidget(_app(TrainingMaxSection(
        snapshot: Future.value(_snap(_rows())),
        onAccept: (lift, id) async {
          calls.add('accept $lift $id');
          return true;
        },
        onDecline: (lift, id) async {
          calls.add('keep $lift $id');
          return true;
        },
        onDecided: () => decided++,
      )));
      await tester.pumpAndSettle();

      expect(find.text('TRAINING MAXES'), findsOneWidget);
      expect(find.text('2 to review'), findsOneWidget);
      expect(find.text('Deadlift: 340 → 360'), findsOneWidget);
      expect(
          find.textContaining(
              'from 295×5 @ RPE 8.5 (est 358, median of 3 sets)'),
          findsWidgets);
      expect(find.text('Accept 360'), findsOneWidget);
      expect(find.text('Keep 340'), findsOneWidget);

      // Fast-loop drop: "recommended" chip, evidence without the prefix.
      expect(find.text('Overhead press: 145 → 135'), findsOneWidget);
      expect(find.text('recommended'), findsOneWidget);
      expect(find.textContaining('grinder on 120×4 @ RPE 9.5'),
          findsOneWidget);
      expect(find.textContaining('recommended: grinder'), findsNothing);

      // The TM in force (accepted values only — never the proposals).
      expect(find.textContaining('340 lb', findRichText: true), findsWidgets);
      expect(find.textContaining('Deadlift 360 lb', findRichText: true),
          findsNothing);

      // Cards sit above the change log.
      final card = tester.getTopLeft(find.text('Deadlift: 340 → 360')).dy;
      final log = tester
          .getTopLeft(find.byKey(const ValueKey('tm-history')))
          .dy;
      expect(card, lessThan(log));

      await tester.tap(find.byKey(const ValueKey('tm-accept-deadlift')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tm-keep-press')));
      await tester.pumpAndSettle();
      expect(calls, [
        'accept deadlift tm:deadlift:2026-10-15:360',
        'keep press tm:press:2026-10-16:135',
      ]);
      expect(decided, 2);
    });

    testWidgets('change log: outcomes + filter by lift', (tester) async {
      _tall(tester);
      final rows = [
        ..._rows(),
        tmDeclineRow(pendingTmProposal(_rows(), 'press')!, 145,
            _d('2026-10-17')),
      ];
      await tester.pumpWidget(_app(TrainingMaxSection(
        snapshot: Future.value(_snap(rows)),
        historyLimit: 20,
      )));
      await tester.pumpAndSettle();

      // Declined press: old → declined value, "kept (declined)".
      expect(
          find.textContaining('Overhead press 145 → 135 lb',
              findRichText: true),
          findsOneWidget);
      expect(
          find.textContaining('Oct 17, 2026 · kept (declined) (recommended)',
              findRichText: true),
          findsOneWidget);
      expect(find.textContaining('reverted to proposal', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('set by you', findRichText: true),
          findsWidgets);
      expect(find.textContaining('starting value', findRichText: true),
          findsOneWidget);
      // Press is no longer pending; deadlift still is.
      expect(find.text('1 to review'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tm-filter-squat')));
      await tester.pumpAndSettle();
      expect(find.textContaining('starting value', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('kept (declined)', findRichText: true),
          findsNothing);
      // One-lift view drops the lift prefix.
      expect(find.textContaining('320 lb', findRichText: true), findsWidgets);
    });

    testWidgets('no proposals: explainer line, no cards', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(TrainingMaxSection(
        snapshot: Future.value(_snap(_rows().take(4).toList())),
      )));
      await tester.pumpAndSettle();
      expect(find.byType(TmProposalCard), findsNothing);
      expect(find.textContaining('wait here for your OK'), findsOneWidget);
    });
  });

  group('TmProposalPill', () {
    testWidgets('shows the count and opens Progress; hidden when none',
        (tester) async {
      var opened = 0;
      await tester.pumpWidget(_app(TmProposalPill(
        load: () async => _snap(_rows()),
        onOpen: () => opened++,
      )));
      await tester.pumpAndSettle();
      expect(find.text('2 training-max updates to review ›'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tm-pill')));
      expect(opened, 1);

      await tester.pumpWidget(_app(TmProposalPill(
        key: const ValueKey('none'),
        load: () async => _snap(_rows().take(4).toList()),
        onOpen: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tm-pill')), findsNothing);
    });

    test('singular label', () {
      expect(tmReviewLabel(1), '1 training-max update to review');
    });
  });

  group('notification (once per proposal)', () {
    test('only unseen pending proposals notify', () {
      final snap = _snap(_rows());
      final all = unseenTmProposals(snap, const {});
      expect([for (final p in all) p.lift], ['deadlift', 'press']);
      final fresh =
          unseenTmProposals(snap, {'tm:deadlift:2026-10-15:360'});
      expect([for (final p in fresh) p.lift], ['press']);
      expect(
          unseenTmProposals(snap, {
            'tm:deadlift:2026-10-15:360',
            'tm:press:2026-10-16:135',
          }),
          isEmpty);
    });

    test('composition names old → new + evidence', () {
      final rows = _rows();
      final note = composeTmProposalNotification(
          unseenTmProposals(_snap(rows), const {}), rows)!;
      expect(note.title, '2 training max updates to review');
      expect(note.body, contains('Deadlift: 340 → 360 · from 295×5'));
      expect(note.body, contains('Overhead press: 145 → 135 (recommended)'));
      expect(note.body, contains('Progress → Training maxes'));
      expect(composeTmProposalNotification(const [], rows), isNull);
    });
  });
}
