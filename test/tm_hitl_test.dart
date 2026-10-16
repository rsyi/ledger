// Human-in-the-loop TM gating (2026-10-16, user: "I'd like to know that
// training maxes have been updated, rather than it happening
// automatically"). Automatic TM changes land as PENDING proposals
// (source=auto, confirmed=false); pricing/planner read only the accepted
// value; accept/decline append decision rows; a declined proposal is not
// re-proposed unless the estimate moves >= 5 lb (or flips direction); a
// newer proposal supersedes older pending ones; fast-loop drops are
// flagged "recommended"; already-applied auto changes convert to
// proposals (tool/wm_hitl_convert.dart).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/program_metrics.dart' show StrengthRow;
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/services/working_max.dart';

const _slow = TmRule(mode: tmModeMedian);

LoadPolicy _policy() => const LoadPolicy(
  name: 'test_policy',
  targetRpeLow: 7.5,
  targetRpeHigh: 8,
  raiseIfRpeLte: null,
  raiseRequiresConsecutive: 1,
  holdBand: null,
  dropIfRpeGte: null,
  stepLb: {'bench': 5, 'press': 5, 'squat': 5, 'deadlift': 5},
  frozen: false,
  capRpe: 8.5,
  capAfterDropRpe: 8.5,
  consecutiveDropsAction: 'no_top_sets_next_week',
  readingsThatRaise: [],
  readingsThatLower: [],
  resetOnTest: true,
  readingsIgnored: false,
  saturdaySingle: false,
  applies: {},
);

DateTime _d(String s) => DateTime.parse('${s}T00:00:00Z');

WorkingMaxRow _row(
  String lift,
  double value,
  String date,
  String source, {
  String reason = '',
  String readingId = '',
  bool? confirmed,
}) => WorkingMaxRow(
  lift: lift,
  variant: defaultVariantByLift[lift]!,
  valueLb: value,
  effectiveFrom: _d(date),
  source: source,
  reason: reason,
  readingId: readingId,
  confirmed: confirmed,
);

WorkingMaxRow _proposal(
  String lift,
  double value,
  String date, {
  String reason = 'from 295×5 @ RPE 8.5 (est 358, median of 3 sets)',
}) =>
    _row(lift, value, date, tmProposalSource, reason: reason, confirmed: false);

/// The LIVE working_max tab shape for deadlift as of 2026-10-16 (rows
/// 4, 6, 8, 11, 13 of the sheet).
List<WorkingMaxRow> _liveDeadlift() => [
  _row(
    'deadlift',
    330,
    '2026-09-21',
    'seed',
    reason: '§5 seed',
    confirmed: false,
  ),
  _row(
    'deadlift',
    330,
    '2026-09-21',
    'pain_cap',
    reason: 'back twinge Sep 17 (§5): frozen',
  ),
  _row(
    'deadlift',
    340,
    '2026-09-21',
    'manual',
    reason: 'current working single 315x1',
    confirmed: true,
  ),
  _row(
    'deadlift',
    340,
    '2026-09-25',
    'manual',
    reason: 'pain cap lifted — user-directed removal 2026-09-25',
  ),
  _row(
    'deadlift',
    360,
    '2026-10-15',
    'rule',
    reason:
        'slow loop: median implied 358.0 over 3 top sets '
        '(2026-10-02..2026-10-15, 21d ∨ 5-set window) → 360',
    readingId: '2026-10-15|deadlift',
  ),
];

ReadingRow _reading(
  String date,
  double w,
  int reps,
  double rpe,
  double implied,
  String decision,
  double after,
) => ReadingRow(
  id: '$date|deadlift',
  date: _d(date),
  lift: 'deadlift',
  variant: 'belted',
  weightLb: w,
  reps: reps,
  rpe: rpe,
  kind: 'heavy_top',
  grinder: false,
  missed: false,
  impliedMax: implied,
  decision: decision,
  wmAfter: after,
);

List<ReadingRow> _liveReadings() => [
  _reading('2026-09-25', 315, 1, 7.5, 347.3, 'hold', 340),
  _reading('2026-10-02', 275, 6, 7.5, 355.3, 'hold', 340),
  _reading('2026-10-06', 285, 6, 7.5, 368.2, 'hold', 340),
  _reading('2026-10-15', 295, 5, 8.5, 358, 'raise', 360),
];

StrengthRow _dl(String date, double w, int reps, double rpe, {String? notes}) =>
    StrengthRow(
      date: DateTime.parse(date),
      exercise: 'Barbell Deadlift',
      weight: w,
      reps: reps,
      rpe: rpe,
      notes: notes,
      belted: true,
    );

List<StrengthRow> _liveStrength() => [
  _dl('2026-09-25', 315, 1, 7.5),
  _dl('2026-10-02', 275, 6, 7.5),
  _dl('2026-10-06', 285, 6, 7.5),
  _dl('2026-10-15', 295, 5, 8.5),
];

void main() {
  group('accepted value (pricing never sees a proposal)', () {
    final rows = [
      _row('bench', 245, '2026-09-21', 'manual', confirmed: true),
      _proposal('bench', 255, '2026-10-16'),
    ];

    test('currentWorkingMax / ByLift / AsOf skip pending proposals', () {
      expect(currentWorkingMax(rows, 'bench')!.valueLb, 245);
      expect(currentWorkingMaxesByLift(rows)['bench'], 245);
      expect(workingMaxAsOf(rows, 'bench', _d('2026-10-20')), 245);
      expect(pendingTmProposal(rows, 'bench')!.valueLb, 255);
    });

    test('a proposal is not an unconfirmed seed', () {
      expect(needsConfirmation(rows, 'bench'), isFalse);
    });

    test('accept appends a confirmed auto_accepted row → value in force', () {
      final p = pendingTmProposal(rows, 'bench')!;
      final accept = tmAcceptRow(p, _d('2026-10-17'));
      expect(accept.source, 'auto_accepted');
      expect(accept.confirmed, isTrue);
      expect(accept.valueLb, 255);
      expect(accept.readingId, 'tm:bench:2026-10-16:255');
      expect(accept.reason, startsWith('accepted 2026-10-17'));
      final after = [...rows, accept];
      expect(currentWorkingMax(after, 'bench')!.valueLb, 255);
      expect(pendingTmProposal(after, 'bench'), isNull);
    });

    test('decline appends a confirmed row keeping the value + the key', () {
      final p = pendingTmProposal(rows, 'bench')!;
      final decline = tmDeclineRow(p, 245, _d('2026-10-17'));
      expect(decline.source, 'declined');
      expect(decline.confirmed, isTrue);
      expect(decline.valueLb, 245);
      expect(decline.readingId, 'tm:bench:2026-10-16:255');
      final after = [...rows, decline];
      expect(currentWorkingMax(after, 'bench')!.valueLb, 245);
      expect(pendingTmProposal(after, 'bench'), isNull);
      expect(declinedTmValue(after, 'bench'), 255);
    });

    test('a manual set resolves the pending proposal + resets declines', () {
      final p = pendingTmProposal(rows, 'bench')!;
      final after = [
        ...rows,
        tmDeclineRow(p, 245, _d('2026-10-17')),
        _row('bench', 250, '2026-10-18', 'manual', confirmed: true),
      ];
      expect(declinedTmValue(after, 'bench'), isNull);
      final pendingThenManual = [
        ...rows,
        _row('bench', 250, '2026-10-18', 'manual', confirmed: true),
      ];
      expect(pendingTmProposal(pendingThenManual, 'bench'), isNull);
      expect(currentWorkingMax(pendingThenManual, 'bench')!.valueLb, 250);
    });

    test('a newer proposal supersedes the older pending one', () {
      final both = [...rows, _proposal('bench', 250, '2026-10-18')];
      expect(pendingTmProposal(both, 'bench')!.valueLb, 250);
      expect(pendingTmProposals(both), hasLength(1));
      // Pain-cap markers don't resolve a proposal.
      final marked = [
        ...both,
        _row('bench', 245, '2026-10-19', 'pain_cap', reason: 'elbow'),
      ];
      expect(pendingTmProposal(marked, 'bench')!.valueLb, 250);
    });
  });

  group('gateTmCandidate', () {
    test('no candidate → none; candidate = accepted → none / withdraw', () {
      expect(
        gateTmCandidate(accepted: 340, candidate: null),
        TmGateAction.none,
      );
      expect(gateTmCandidate(accepted: 340, candidate: 340), TmGateAction.none);
      expect(
        gateTmCandidate(accepted: 340, candidate: 340, pending: 360),
        TmGateAction.withdraw,
      );
    });

    test(
      'same as pending → none (idempotent nightly); new value → propose',
      () {
        expect(
          gateTmCandidate(accepted: 340, candidate: 360, pending: 360),
          TmGateAction.none,
        );
        expect(
          gateTmCandidate(accepted: 340, candidate: 365, pending: 360),
          TmGateAction.propose,
        );
      },
    );

    test('declined: no re-propose within 5 lb in the same direction', () {
      expect(
        gateTmCandidate(accepted: 340, candidate: 360, declined: 360),
        TmGateAction.none,
      );
      expect(
        gateTmCandidate(accepted: 340, candidate: 355, declined: 360),
        TmGateAction.propose,
      ); // exactly 5 lb away
      expect(
        gateTmCandidate(accepted: 340, candidate: 365, declined: 360),
        TmGateAction.propose,
      );
      // Direction flips → always re-proposed.
      expect(
        gateTmCandidate(accepted: 340, candidate: 335, declined: 345),
        TmGateAction.propose,
      );
      expect(
        gateTmCandidate(accepted: 340, candidate: 345, declined: 345),
        TmGateAction.none,
      );
    });
  });

  group('runWmChain under the gate', () {
    WmChainResult run(
      List<WorkingMaxRow> wm,
      List<ReadingRow> readings,
      List<StrengthRow> strength,
      String today,
    ) => runWmChain(
      snapshot: (workingMax: wm, readings: readings),
      strengthRows: strength,
      policyFor: (_) => _policy(),
      today: _d(today),
      tmRule: _slow,
    );

    final base = [
      _row('deadlift', 340, '2026-09-25', 'manual', confirmed: true),
    ];
    final stored = _liveReadings().take(3).toList();

    test('a slow-loop raise lands as ONE pending proposal with evidence', () {
      final res = run(base, stored, _liveStrength(), '2026-10-16');
      expect(res.newReadings.single.decision, 'raise');
      final p = res.newWorkingMaxRows.single;
      expect(p.source, 'auto');
      expect(p.confirmed, isFalse);
      expect(p.valueLb, 360);
      expect(p.reason, 'from 295×5 @ RPE 8.5 (est 358, median of 3 sets)');
      expect(isTmRecommended(p), isFalse);
      // Not applied.
      final all = [...base, ...res.newWorkingMaxRows];
      expect(currentWorkingMax(all, 'deadlift')!.valueLb, 340);
    });

    test('re-running with the proposal pending appends nothing', () {
      final first = run(base, stored, _liveStrength(), '2026-10-16');
      final second = run(
        [...base, ...first.newWorkingMaxRows],
        [...stored, ...first.newReadings],
        _liveStrength(),
        '2026-10-17',
      );
      expect(second.newReadings, isEmpty);
      expect(second.newWorkingMaxRows, isEmpty);
    });

    test('declined → not re-proposed nightly; re-proposed at ≥ 5 lb', () {
      final first = run(base, stored, _liveStrength(), '2026-10-16');
      final p = first.newWorkingMaxRows.single;
      final declinedRows = [...base, p, tmDeclineRow(p, 340, _d('2026-10-16'))];
      final readings = [...stored, ...first.newReadings];
      final again = run(declinedRows, readings, _liveStrength(), '2026-10-17');
      expect(again.newWorkingMaxRows, isEmpty);
      expect(currentWorkingMax(declinedRows, 'deadlift')!.valueLb, 340);

      // A big new day moves the median ≥ 5 lb past the declined 360.
      final strength = [
        ..._liveStrength(),
        _dl('2026-10-19', 315, 5, 8), // implied 389
        _dl('2026-10-22', 320, 5, 8), // implied 395
      ];
      final moved = run(declinedRows, readings, strength, '2026-10-22');
      final proposals = [
        for (final r in moved.newWorkingMaxRows)
          if (isTmProposal(r)) r,
      ];
      expect(proposals, hasLength(1));
      expect(proposals.single.valueLb, greaterThanOrEqualTo(365));
    });

    test('estimate back at the accepted TM withdraws the stale proposal', () {
      // Pending 360, but the accepted value is already what the history
      // says (an accepted 360): the proposal is now stale.
      final rows = [
        ...base,
        _proposal('deadlift', 370, '2026-10-16'),
        _row('deadlift', 360, '2026-10-16', 'manual', confirmed: true),
        _proposal('deadlift', 375, '2026-10-17'),
      ];
      final strength = [
        _dl('2026-10-17', 300, 5, 8.5), // post-manual qualifying sets
        _dl('2026-10-18', 300, 5, 8.5),
        _dl('2026-10-19', 300, 5, 8.5), // implied ~364 → 365
      ];
      final res = run(rows, const [], strength, '2026-10-20');
      final kinds = [for (final r in res.newWorkingMaxRows) r.source];
      expect(kinds, contains('auto')); // 365 ≠ pending 375 → re-proposed
      // Now an estimate equal to the accepted TM withdraws.
      final eq = [
        _dl('2026-10-17', 296, 5, 8.5),
        _dl('2026-10-18', 296, 5, 8.5),
        _dl('2026-10-19', 296, 5, 8.5), // implied ~359 → 360 = accepted
      ];
      final w = run(rows, const [], eq, '2026-10-20');
      final withdrawn = w.newWorkingMaxRows.single;
      expect(withdrawn.source, 'withdrawn');
      expect(withdrawn.valueLb, 360);
      expect(withdrawn.readingId, 'tm:deadlift:2026-10-17:375');
      expect(pendingTmProposal([...rows, withdrawn], 'deadlift'), isNull);
    });

    test('fast-loop grinder drop is gated and flagged recommended', () {
      final rows = [
        _row('bench', 245, '2026-09-21', 'manual', confirmed: true),
      ];
      final strength = [
        for (final day in ['2026-09-22', '2026-09-24', '2026-09-26'])
          StrengthRow(
            date: DateTime.parse(day),
            exercise: 'Flat Barbell Bench Press',
            weight: 215,
            reps: 2,
            rpe: 8,
            paused: true,
          ),
        StrengthRow(
          date: DateTime.parse('2026-09-28'),
          exercise: 'Flat Barbell Bench Press',
          weight: 225,
          reps: 1,
          rpe: 9.5,
          notes: 'grinder',
          paused: true,
        ),
      ];
      final res = runWmChain(
        snapshot: (workingMax: rows, readings: const []),
        strengthRows: strength,
        policyFor: (_) => _policy(),
        tmRule: _slow,
      );
      expect(res.newReadings.last.decision, 'drop');
      final p = res.newWorkingMaxRows.single;
      expect(p.source, 'auto');
      expect(p.valueLb, lessThan(245));
      expect(isTmRecommended(p), isTrue);
      expect(p.reason, startsWith('recommended: grinder on 225×1 @ RPE 9.5'));
      expect(currentWorkingMax([...rows, p], 'bench')!.valueLb, 245);
    });

    test('pain caps stay ungated (markers append, no proposal)', () {
      final rows = [_row('squat', 320, '2026-09-21', 'seed', confirmed: true)];
      final res = runWmChain(
        snapshot: (workingMax: rows, readings: const []),
        strengthRows: const [],
        policyFor: (_) => _policy(),
        today: _d('2026-09-23'),
        painNotes: [(date: _d('2026-09-22'), text: 'pain lower back')],
        tmRule: _slow,
      );
      expect(res.newWorkingMaxRows.single.source, 'pain_cap');
      expect(
        painCapActive([...rows, ...res.newWorkingMaxRows], 'squat'),
        isTrue,
      );
    });
  });

  group('existing-data conversion (2026-10-15 deadlift 340 → 360)', () {
    test('dry-run rows: revert to 340 + pending 360 proposal', () {
      final snap = (workingMax: _liveDeadlift(), readings: _liveReadings());
      final rows = hitlConversionRows(snap, since: _d('2026-10-15'));
      expect(rows, hasLength(2));
      final revert = rows[0];
      expect(revert.source, 'revert_to_pending');
      expect(revert.valueLb, 340);
      expect(revert.confirmed, isTrue);
      expect(revert.effectiveFrom, _d('2026-10-15'));
      expect(revert.reason, startsWith('converted to proposal under HITL'));
      final p = rows[1];
      expect(p.source, 'auto');
      expect(p.confirmed, isFalse);
      expect(p.valueLb, 360);
      expect(p.readingId, '2026-10-15|deadlift');
      expect(p.reason, 'from 295×5 @ RPE 8.5 (est 358, median of 3 sets)');
      // Sheet cells (what the tool writes).
      expect(p.toSheetRow(), [
        'deadlift',
        'belted',
        360,
        '2026-10-15',
        'auto',
        'from 295×5 @ RPE 8.5 (est 358, median of 3 sets)',
        '2026-10-15|deadlift',
        'false',
      ]);

      final after = [..._liveDeadlift(), ...rows];
      expect(currentWorkingMax(after, 'deadlift')!.valueLb, 340);
      expect(workingMaxAsOf(after, 'deadlift', _d('2026-10-16')), 340);
      expect(pendingTmProposal(after, 'deadlift')!.valueLb, 360);
      // Idempotent: a second conversion finds nothing.
      expect(
        hitlConversionRows((
          workingMax: after,
          readings: _liveReadings(),
        ), since: _d('2026-10-15')),
        isEmpty,
      );
    });

    test('older applied changes (before --since) are left alone', () {
      final rows = [
        _row('press', 140, '2026-09-21', 'seed', confirmed: true),
        _row('press', 145, '2026-09-28', 'rule', reason: 'slow loop'),
      ];
      expect(
        hitlConversionRows((
          workingMax: rows,
          readings: const [],
        ), since: _d('2026-10-15')),
        isEmpty,
      );
    });

    test('the nightly after conversion keeps the 360 pending (no dupes)', () {
      final snap = (workingMax: _liveDeadlift(), readings: _liveReadings());
      final converted = [
        ..._liveDeadlift(),
        ...hitlConversionRows(snap, since: _d('2026-10-15')),
      ];
      final res = runWmChain(
        snapshot: (workingMax: converted, readings: _liveReadings()),
        strengthRows: _liveStrength(),
        policyFor: (_) => _policy(),
        today: _d('2026-10-16'),
        tmRule: _slow,
      );
      expect(res.newWorkingMaxRows, isEmpty);
    });
  });

  group('tmChangeHistory', () {
    test('dated log newest first with outcomes + evidence', () {
      final snap = (workingMax: _liveDeadlift(), readings: _liveReadings());
      final converted = [
        ..._liveDeadlift(),
        ...hitlConversionRows(snap, since: _d('2026-10-15')),
      ];
      final p = pendingTmProposal(converted, 'deadlift')!;
      final rows = [...converted, tmDeclineRow(p, 340, _d('2026-10-16'))];
      final h = tmChangeHistory(rows, lift: 'deadlift');
      expect(h.first.outcome, 'kept (declined)');
      expect(h.first.fromLb, 340);
      expect(h.first.toLb, 360);
      expect(
        h.first.evidence,
        'from 295×5 @ RPE 8.5 (est 358, median of 3 sets)',
      );
      expect(
        [for (final e in h) e.outcome],
        [
          'kept (declined)',
          'reverted to proposal',
          'auto',
          'set by you',
          'set by you',
          'pain cap',
          'starting value',
        ],
      );
      expect(h[1].fromLb, 360);
      expect(h[1].toLb, 340);
      expect(h.last.fromLb, isNull);
      // Filter: other lifts excluded.
      expect(tmChangeHistory(rows, lift: 'bench'), isEmpty);
    });

    test('accepted shows old → new with the proposal evidence', () {
      final rows = [
        _row('press', 145, '2026-09-28', 'seed', confirmed: true),
        _proposal('press', 150, '2026-10-16', reason: 'from 125×5 @ RPE 8'),
      ];
      final all = [
        ...rows,
        tmAcceptRow(pendingTmProposal(rows, 'press')!, _d('2026-10-17')),
      ];
      final e = tmChangeHistory(all).first;
      expect(e.outcome, 'accepted');
      expect(e.fromLb, 145);
      expect(e.toLb, 150);
      expect(e.changed, isTrue);
      expect(e.evidence, 'from 125×5 @ RPE 8');
    });
  });
}
