import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/services/coach_proposal_store.dart';
import 'package:airledger/ui/widgets/coach_proposal_card.dart';

void main() {
  final proposal = CoachProposal(
    view: 'strength',
    date: DateTime(2026, 9, 14),
    template: 'cut_press_heavy',
    summary: 'Combined press day',
    entries: [
      {'exercise': 'Bench Press', 'weight': 185, 'reps': 5},
      {'exercise': 'Overhead Press', 'weight': 115, 'reps': 5},
    ],
  );

  Future<void> pump(
    WidgetTester tester, {
    CoachProposalStatus? status,
    VoidCallback? onSchedule,
    VoidCallback? onUndo,
    VoidCallback? onDismiss,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CoachProposalCard(
          proposal: proposal,
          status: status,
          busy: false,
          onSchedule: onSchedule ?? () {},
          onUndo: onUndo ?? () {},
          onDismiss: onDismiss ?? () {},
        ),
      ),
    ));
  }

  testWidgets('pending shows entries + Schedule/Not now; tap fires',
      (tester) async {
    var scheduled = false;
    await pump(tester, onSchedule: () => scheduled = true);
    expect(find.textContaining('Mon, Sep 14'), findsOneWidget);
    expect(find.textContaining('cut_press_heavy'), findsOneWidget);
    expect(find.textContaining('Bench Press'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    await tester.tap(find.text('Schedule'));
    expect(scheduled, isTrue);
  });

  testWidgets('scheduled shows Undo; tap fires', (tester) async {
    var undone = false;
    await pump(tester,
        status: CoachProposalStatus.scheduled, onUndo: () => undone = true);
    expect(find.textContaining('Scheduled'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('Schedule'), findsNothing);
    await tester.tap(find.text('Undo'));
    expect(undone, isTrue);
  });

  testWidgets('undone/dismissed offer Schedule again', (tester) async {
    await pump(tester, status: CoachProposalStatus.undone);
    expect(find.textContaining('Undone'), findsOneWidget);
    expect(find.text('Schedule again'), findsOneWidget);
    await pump(tester, status: CoachProposalStatus.dismissed);
    expect(find.textContaining('Dismissed'), findsOneWidget);
    expect(find.text('Schedule again'), findsOneWidget);
  });
}
