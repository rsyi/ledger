/// Working-max tab layer (WM-2) — append-only `working_max` + `readings`
/// sheet tabs on top of the WM-1 controller (`working_max.dart`).
///
/// Pure Dart — no Flutter, no IO. The nightly tool
/// (`tool/program_status_update.dart`) and the app-side store
/// (`wm_store.dart`) both read/write the tabs through the row codecs and
/// state helpers here; the evaluation chain ([runWmChain]) decides what to
/// APPEND. Nothing in this file ever rewrites tab history.
///
/// Tab schemas (header order is the write order):
///   working_max: lift, variant, value_lb, effective_from, source, reason,
///                reading_id, confirmed
///   readings:    id, date, lift, variant, weight_lb, reps, rpe, kind,
///                grinder, missed, implied_max, decision, wm_after
///
/// Row semantics:
///   - `confirmed` is only meaningful on VALUE rows (seed/manual/confirm):
///     seeds land with `false` (pending in-app confirmation, spec §5);
///     the app confirms by APPENDING a duplicate row with `true` (append-
///     only-honest — the pending row stays as history). Controller rows
///     and pain-cap markers leave the cell empty (null).
///   - pain-cap state is carried by explicit marker rows: a `source=
///     pain_cap` row activates the cap for its lift; a later row whose
///     reason starts with [painCapLiftedReasonPrefix] clears it.
///   - HUMAN-IN-THE-LOOP (2026-10-16): automatic TM changes land as
///     PENDING PROPOSALS (`source=auto`, `confirmed=false`) that never
///     price anything until the user accepts them in-app (see the
///     "Human-in-the-loop TM gating" section). A readings row's
///     `wm_after` is the controller's COMPUTED TM — a proposal under the
///     gate; the value in force lives in working_max.
library;

import 'program_metrics.dart' show StrengthRow, mainLiftByExercise;
import 'working_max.dart';

/// Sheet tab names.
const wmTabName = 'working_max';
const readingsTabName = 'readings';

/// Column headers, in write order.
const wmTabHeaders = [
  'lift',
  'variant',
  'value_lb',
  'effective_from',
  'source',
  'reason',
  'reading_id',
  'confirmed',
];
const readingsTabHeaders = [
  'id',
  'date',
  'lift',
  'variant',
  'weight_lb',
  'reps',
  'rpe',
  'kind',
  'grinder',
  'missed',
  'implied_max',
  'decision',
  'wm_after',
];

/// Reason prefix of the row that clears an active pain cap.
const painCapLiftedReasonPrefix = 'pain cap lifted';

/// One reading per (day, lift): the natural row id.
String readingIdOf(DateTime date, String lift) => '${_ymd(date)}|$lift';

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime? _parseDay(Object? v) {
  final s = v?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  final d = DateTime.tryParse(s);
  return d == null ? null : DateTime.utc(d.year, d.month, d.day);
}

double? _parseNum(Object? v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

bool? _parseBool(Object? v) {
  final s = v?.toString().trim().toLowerCase() ?? '';
  if (s == 'true') return true;
  if (s == 'false') return false;
  return null;
}

/// Numbers write as ints when whole so the sheet shows 240, not 240.0.
Object _numCell(num v) => v == v.roundToDouble() ? v.round() : v;

Object? _cell(Map<String, int> head, List<Object?> row, String col) {
  final i = head[col];
  return i == null || i < 0 || i >= row.length ? null : row[i];
}

/// UTC-midnight normalization by CALENDAR components — every date
/// comparison in this file goes through it, so local-midnight dates
/// (e.g. `DateTime.parse('2026-09-29')`) and UTC ones never mis-order.
DateTime _dayUtc(DateTime d) => DateTime.utc(d.year, d.month, d.day);

DateTime _mondayOf(DateTime d) {
  final day = _dayUtc(d);
  return day.subtract(Duration(days: day.weekday - 1));
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

/// One `working_max` tab row (spec §1.1 + `confirmed`).
class WorkingMaxRow {
  final String lift;
  final String variant;
  final double valueLb;
  final DateTime effectiveFrom;

  /// seed | rule | test | manual | pain_cap.
  final String source;
  final String reason;

  /// Id of the reading that produced this change ('' for seeds/markers).
  final String readingId;

  /// null on controller rows + markers; false = pending seed; true =
  /// user-confirmed (seed confirmation or manual override).
  final bool? confirmed;

  const WorkingMaxRow({
    required this.lift,
    required this.variant,
    required this.valueLb,
    required this.effectiveFrom,
    required this.source,
    required this.reason,
    this.readingId = '',
    this.confirmed,
  });

  List<Object?> toSheetRow() => [
        lift,
        variant,
        _numCell(valueLb),
        _ymd(effectiveFrom),
        source,
        reason,
        readingId,
        confirmed == null ? '' : '$confirmed',
      ];

  static WorkingMaxRow? fromCells(Map<String, int> head, List<Object?> row) {
    final lift = _cell(head, row, 'lift')?.toString().trim() ?? '';
    final value = _parseNum(_cell(head, row, 'value_lb'));
    final from = _parseDay(_cell(head, row, 'effective_from'));
    if (lift.isEmpty || value == null || from == null) return null;
    return WorkingMaxRow(
      lift: lift,
      variant: _cell(head, row, 'variant')?.toString().trim() ?? '',
      valueLb: value,
      effectiveFrom: from,
      source: _cell(head, row, 'source')?.toString().trim() ?? '',
      reason: _cell(head, row, 'reason')?.toString() ?? '',
      readingId: _cell(head, row, 'reading_id')?.toString().trim() ?? '',
      confirmed: _parseBool(_cell(head, row, 'confirmed')),
    );
  }
}

/// One `readings` tab row (spec §1.2 + the decision it produced).
class ReadingRow {
  final String id;
  final DateTime date;
  final String lift;

  /// Parsed variant (shown in app for correction).
  final String variant;

  /// Weight CONVERTED to the lift's default variant.
  final double weightLb;
  final int reps;
  final double rpe;
  final String kind;
  final bool grinder;
  final bool missed;
  final double impliedMax;

  /// The controller action this reading produced (raise|hold|drop|freeze|
  /// reset).
  final String decision;
  final double wmAfter;

  const ReadingRow({
    required this.id,
    required this.date,
    required this.lift,
    required this.variant,
    required this.weightLb,
    required this.reps,
    required this.rpe,
    required this.kind,
    required this.grinder,
    required this.missed,
    required this.impliedMax,
    required this.decision,
    required this.wmAfter,
  });

  List<Object?> toSheetRow() => [
        id,
        _ymd(date),
        lift,
        variant,
        _numCell(weightLb),
        reps,
        _numCell(rpe),
        kind,
        '$grinder',
        '$missed',
        _numCell(impliedMax),
        decision,
        _numCell(wmAfter),
      ];

  static ReadingRow? fromCells(Map<String, int> head, List<Object?> row) {
    final lift = _cell(head, row, 'lift')?.toString().trim() ?? '';
    final date = _parseDay(_cell(head, row, 'date'));
    final weight = _parseNum(_cell(head, row, 'weight_lb'));
    final reps = _parseNum(_cell(head, row, 'reps'));
    final rpe = _parseNum(_cell(head, row, 'rpe'));
    if (lift.isEmpty ||
        date == null ||
        weight == null ||
        reps == null ||
        rpe == null) {
      return null;
    }
    return ReadingRow(
      id: _cell(head, row, 'id')?.toString().trim() ?? '',
      date: date,
      lift: lift,
      variant: _cell(head, row, 'variant')?.toString().trim() ?? '',
      weightLb: weight,
      reps: reps.round(),
      rpe: rpe,
      kind: _cell(head, row, 'kind')?.toString().trim() ?? 'heavy_top',
      grinder: _parseBool(_cell(head, row, 'grinder')) ?? false,
      missed: _parseBool(_cell(head, row, 'missed')) ?? false,
      impliedMax: _parseNum(_cell(head, row, 'implied_max')) ?? 0,
      decision: _cell(head, row, 'decision')?.toString().trim() ?? '',
      wmAfter: _parseNum(_cell(head, row, 'wm_after')) ?? weight,
    );
  }
}

/// Parsed pair of the two tabs.
typedef WmSnapshot = ({
  List<WorkingMaxRow> workingMax,
  List<ReadingRow> readings,
});

// ---------------------------------------------------------------------------
// §5 seeds
// ---------------------------------------------------------------------------

/// The §5 seed rows (Sep 21 2026), written by the nightly when the
/// `working_max` tab is empty/missing. All four values land with
/// `confirmed=false` — the controller treats them as usable, and the app
/// shows a confirmation card. The deadlift seed is followed by an explicit
/// pain-cap marker row (Sep 17 back twinge, spec §5): frozen + top sets
/// capped at RPE 7 until two consecutive clean heavy sessions.
List<WorkingMaxRow> seedWorkingMaxRows() {
  final day = DateTime.utc(2026, 9, 21);
  WorkingMaxRow seed(String lift, double value, String reason) =>
      WorkingMaxRow(
        lift: lift,
        variant: defaultVariantByLift[lift]!,
        valueLb: value,
        effectiveFrom: day,
        source: 'seed',
        reason: reason,
        confirmed: false,
      );
  return [
    seed('bench', 240, '§5 seed: 230x1@9 paused Sep 14 → implied 241'),
    seed('squat', 320, '§5 seed: 295x1@8 Sep 15 → implied 320'),
    seed(
        'deadlift',
        330,
        '§5 seed: 315x1@8 Sep 11 → 342; 325x1@9 Aug 28 → 340; '
        'set conservatively at 330'),
    seed(
        'press',
        140,
        '§5 seed: 120x5@8 Aug 22 → 150; 105x5@7 Sep 14 → 134; median'),
    WorkingMaxRow(
      lift: 'deadlift',
      variant: 'belted',
      valueLb: 330,
      effectiveFrom: day,
      source: 'pain_cap',
      reason: 'back twinge Sep 17 (§5): frozen, top sets capped at RPE 7 '
          'until two consecutive clean heavy sessions',
    ),
  ];
}

// ---------------------------------------------------------------------------
// Tab-state helpers
// ---------------------------------------------------------------------------

/// The lift's current ACCEPTED row = the LAST tab row for it that is not
/// a pending HITL proposal ([isTmProposal]) — tabs are append-only, so
/// tab order is chronological; markers / decision rows carry the
/// unchanged value. Every pricing / planner / MCP consumer reads the TM
/// through this (or [workingMaxAsOf] / [currentWorkingMaxesByLift]), so
/// a proposal never prices anything until the user accepts it.
WorkingMaxRow? currentWorkingMax(List<WorkingMaxRow> rows, String lift) {
  WorkingMaxRow? last;
  for (final r in rows) {
    if (r.lift == lift && !isTmProposal(r)) last = r;
  }
  return last;
}

/// True while the lift's newest confirm-bearing row says `false` — i.e. a
/// pending seed with no confirmation (or manual override) appended yet.
/// Marker/controller rows (confirmed == null) and HITL proposals (their
/// `false` means "awaiting review", not "unconfirmed seed") are skipped.
bool needsConfirmation(List<WorkingMaxRow> rows, String lift) {
  bool? latest;
  for (final r in rows) {
    if (r.lift == lift && r.confirmed != null && !isTmProposal(r)) {
      latest = r.confirmed;
    }
  }
  return latest == false;
}

// ---------------------------------------------------------------------------
// Human-in-the-loop TM gating (2026-10-16)
// ---------------------------------------------------------------------------
//
// Automatic TM changes (slow-loop raises/lowers, the nightly recompute,
// fast-loop grinder/missed drops, MCP log_rows) are appended as PENDING
// PROPOSALS — never applied. Row shapes (all append-only):
//
//   proposal   source=auto, confirmed=false, value=proposed TM,
//              reason=evidence ("from 295×5 @ RPE 8.5 (est 358, median
//              of 3 sets)"; fast-loop drops prefixed [tmRecommendedPrefix]),
//              reading_id=the driving reading ('' for recomputes).
//   accept     source=auto_accepted, confirmed=true, value=proposed,
//              reading_id=[tmProposalIdOf] the proposal.
//   decline    source=declined, confirmed=true, value=accepted TM (kept),
//              reading_id=[tmProposalIdOf] — carries the declined value.
//   withdrawn  source=withdrawn, confirmed=null, value=accepted — the
//              estimate came back to the accepted TM while pending.
//   revert     source=revert_to_pending, confirmed=true — restores the
//              accepted value when an already-applied auto change is
//              converted to a proposal (tool/wm_hitl_convert.dart).
//
// A newer proposal for the same lift supersedes older pending ones; any
// accepted-value row (manual / accept / decline / revert / seed) resolves
// the pending one. Pain-cap markers are NOT gated.

/// `source` of a pending proposal row.
const tmProposalSource = 'auto';

/// `source` of the row appended when the user accepts a proposal.
const tmAcceptedSource = 'auto_accepted';

/// `source` of the row appended when the user keeps the current TM.
const tmDeclinedSource = 'declined';

/// `source` of the nightly row that withdraws a stale proposal.
const tmWithdrawnSource = 'withdrawn';

/// `source` of the conversion row restoring the accepted value.
const tmRevertSource = 'revert_to_pending';

/// A declined proposal is re-proposed only when the new estimate moves
/// at least this far from it (or the direction flips).
const tmReproposeMinDiffLb = 5.0;

/// Reason prefix of fast-loop (grinder / missed) drop proposals — the
/// UI labels them "recommended".
const tmRecommendedPrefix = 'recommended: ';

/// True for a pending-or-historical proposal row (source=auto,
/// confirmed=false).
bool isTmProposal(WorkingMaxRow r) =>
    r.source == tmProposalSource && r.confirmed == false;

/// Fast-loop drop proposals are flagged "recommended".
bool isTmRecommended(WorkingMaxRow r) =>
    r.reason.startsWith(tmRecommendedPrefix);

/// The proposal's evidence without the recommended prefix.
String tmProposalEvidence(WorkingMaxRow r) => isTmRecommended(r)
    ? r.reason.substring(tmRecommendedPrefix.length)
    : r.reason;

/// Stable id of a proposal (decision rows carry it in `reading_id`):
/// `tm:<lift>:<effective_from>:<value>`.
String tmProposalIdOf(WorkingMaxRow p) =>
    'tm:${p.lift}:${_ymd(p.effectiveFrom)}:${_fmtNum(p.valueLb)}';

/// The proposed value encoded in a [tmProposalIdOf] id; null otherwise.
double? tmProposalValueOfId(String id) {
  if (!id.startsWith('tm:')) return null;
  return double.tryParse(id.split(':').last);
}

/// Rows that neither change nor resolve a TM: pain-cap activations and
/// the controller's pain-cap-lifted markers.
bool _isTmMarker(WorkingMaxRow r) =>
    r.source == 'pain_cap' ||
    (r.source == 'rule' && r.reason.startsWith(painCapLiftedReasonPrefix));

/// The lift's PENDING proposal: the newest proposal row not followed by
/// any resolving row (accept / decline / withdraw / manual / revert /
/// seed / legacy rule change). Older proposals are superseded by it.
WorkingMaxRow? pendingTmProposal(List<WorkingMaxRow> rows, String lift) {
  WorkingMaxRow? p;
  for (final r in rows) {
    if (r.lift != lift) continue;
    if (isTmProposal(r)) {
      p = r;
    } else if (!_isTmMarker(r)) {
      p = null;
    }
  }
  return p;
}

/// Pending proposals for every lift (lift order of
/// [defaultVariantByLift]).
List<WorkingMaxRow> pendingTmProposals(List<WorkingMaxRow> rows) => [
  for (final lift in defaultVariantByLift.keys) ?pendingTmProposal(rows, lift),
];

/// The value of the lift's declined proposal still in force — the last
/// decline not followed by an accepted-value change (manual / accept /
/// revert / seed / legacy rule). Proposals, withdrawals and markers keep
/// it. Null when nothing is declined.
double? declinedTmValue(List<WorkingMaxRow> rows, String lift) {
  double? v;
  for (final r in rows) {
    if (r.lift != lift) continue;
    if (r.source == tmDeclinedSource) {
      v = tmProposalValueOfId(r.readingId);
    } else if (isTmProposal(r) ||
        _isTmMarker(r) ||
        r.source == tmWithdrawnSource) {
      continue;
    } else {
      v = null;
    }
  }
  return v;
}

/// The row appended when the user ACCEPTS [proposal] on [day].
WorkingMaxRow tmAcceptRow(WorkingMaxRow proposal, DateTime day) =>
    WorkingMaxRow(
      lift: proposal.lift,
      variant: proposal.variant,
      valueLb: proposal.valueLb,
      effectiveFrom: _dayUtc(day),
      source: tmAcceptedSource,
      reason: 'accepted ${_ymd(day)} — ${tmProposalEvidence(proposal)}',
      readingId: tmProposalIdOf(proposal),
      confirmed: true,
    );

/// The row appended when the user KEEPS the current TM ([acceptedLb])
/// instead of [proposal] on [day]. Its `reading_id` carries the declined
/// value so the nightly doesn't re-propose it ([declinedTmValue]).
WorkingMaxRow tmDeclineRow(
  WorkingMaxRow proposal,
  double acceptedLb,
  DateTime day,
) => WorkingMaxRow(
  lift: proposal.lift,
  variant: proposal.variant,
  valueLb: acceptedLb,
  effectiveFrom: _dayUtc(day),
  source: tmDeclinedSource,
  reason:
      'kept ${_fmtNum(acceptedLb)} ${_ymd(day)} — declined '
      '${_fmtNum(proposal.valueLb)} (${tmProposalEvidence(proposal)})',
  readingId: tmProposalIdOf(proposal),
  confirmed: true,
);

/// What the gate does with an automatic TM candidate.
enum TmGateAction {
  /// Nothing to append.
  none,

  /// Append a new pending proposal (superseding any pending one).
  propose,

  /// Append a withdrawn row: the estimate is back at the accepted TM.
  withdraw,
}

/// The HITL gate (pure; mirrored by ledger-mcp `gateTmCandidate`, pinned
/// by coach/fixtures/tm_gate_cases.yaml).
///
/// [candidate] is the controller's TM (null = no information this run —
/// keep whatever is pending). Equal to [accepted] → withdraw a pending
/// proposal, else nothing. Equal to [pending] → nothing (idempotent
/// nightly). Same direction as a [declined] proposal and within
/// [minDiffLb] of it → suppressed. Otherwise → propose.
TmGateAction gateTmCandidate({
  required double accepted,
  required double? candidate,
  double? pending,
  double? declined,
  double minDiffLb = tmReproposeMinDiffLb,
}) {
  if (candidate == null) return TmGateAction.none;
  if (candidate == accepted) {
    return pending != null ? TmGateAction.withdraw : TmGateAction.none;
  }
  if (pending != null && candidate == pending) return TmGateAction.none;
  if (declined != null) {
    final sameDirection =
        (candidate - accepted).sign == (declined - accepted).sign;
    if (sameDirection && (candidate - declined).abs() < minDiffLb) {
      return TmGateAction.none;
    }
  }
  return TmGateAction.propose;
}

/// Evidence line for a proposal (shared format with the TS twin):
///   slow loop  `from 295×5 @ RPE 8.5 (est 358, median of 3 sets)`
///   guarded    `from 295×5 @ RPE 8.5 (implied 358)`
///   fast loop  `recommended: grinder on 295×5 @ RPE 9.5 (implied 345)`
String tmEvidence({
  required double weightLb,
  required int reps,
  required double rpe,
  required double impliedMax,
  double? estMedian,
  int? estSets,
  bool grinder = false,
  bool missed = false,
}) {
  final top = '${_fmtNum(weightLb)}×$reps @ RPE ${_fmtNum(rpe)}';
  if (grinder || missed) {
    return '$tmRecommendedPrefix${grinder ? 'grinder' : 'missed reps'} on '
        '$top (implied ${impliedMax.toStringAsFixed(0)})';
  }
  if (estMedian != null && estSets != null) {
    return 'from $top (est ${estMedian.toStringAsFixed(0)}, median of '
        '$estSets ${estSets == 1 ? 'set' : 'sets'})';
  }
  return 'from $top (implied ${impliedMax.toStringAsFixed(0)})';
}

/// One row of the human-readable TM change log (Progress + Lift pages).
class TmHistoryEvent {
  final DateTime date;
  final String lift;

  /// Accepted TM before the event (null for the first value).
  final double? fromLb;

  /// The value the event is about (new TM, or the declined/withdrawn
  /// proposal's value).
  final double toLb;

  /// starting value | set by you | accepted | kept (declined) | auto |
  /// withdrawn | reverted to proposal | pain cap | pain cap lifted |
  /// confirmed.
  final String outcome;

  /// Evidence / reason text (proposal evidence for decisions).
  final String evidence;

  /// Fast-loop drop ([tmRecommendedPrefix]).
  final bool recommended;

  /// True when the TM in force changed.
  final bool changed;

  const TmHistoryEvent({
    required this.date,
    required this.lift,
    required this.fromLb,
    required this.toLb,
    required this.outcome,
    required this.evidence,
    this.recommended = false,
    this.changed = false,
  });
}

/// The dated change log, NEWEST FIRST, optionally for one [lift].
/// Pending/superseded proposals are not events (pending ones render as
/// review cards); their evidence surfaces on the decision row.
List<TmHistoryEvent> tmChangeHistory(List<WorkingMaxRow> rows, {String? lift}) {
  final out = <TmHistoryEvent>[];
  final accepted = <String, double>{};
  final proposals = <String, WorkingMaxRow>{};
  for (final r in rows) {
    if (lift != null && r.lift != lift) continue;
    final before = accepted[r.lift];
    if (isTmProposal(r)) {
      proposals[tmProposalIdOf(r)] = r;
      continue;
    }
    final prop = proposals[r.readingId];
    String outcome;
    var to = r.valueLb;
    var evidence = r.reason;
    var recommended = false;
    switch (r.source) {
      case 'seed':
        outcome = r.confirmed == true && before == r.valueLb
            ? 'confirmed'
            : 'starting value';
      case 'manual':
        outcome = 'set by you';
      case tmAcceptedSource:
        outcome = 'accepted';
        if (prop != null) {
          evidence = tmProposalEvidence(prop);
          recommended = isTmRecommended(prop);
        }
      case tmDeclinedSource:
        outcome = 'kept (declined)';
        to = tmProposalValueOfId(r.readingId) ?? r.valueLb;
        if (prop != null) {
          evidence = tmProposalEvidence(prop);
          recommended = isTmRecommended(prop);
        }
      case tmWithdrawnSource:
        outcome = 'withdrawn';
        to = tmProposalValueOfId(r.readingId) ?? r.valueLb;
      case tmRevertSource:
        outcome = 'reverted to proposal';
      case 'pain_cap':
        outcome = 'pain cap';
      default:
        outcome = r.reason.startsWith(painCapLiftedReasonPrefix)
            ? 'pain cap lifted'
            : 'auto';
    }
    final valueRow =
        r.source != tmDeclinedSource &&
        r.source != tmWithdrawnSource &&
        r.source != 'pain_cap' &&
        !(r.source == 'rule' && r.reason.startsWith(painCapLiftedReasonPrefix));
    if (valueRow) accepted[r.lift] = r.valueLb;
    out.add(
      TmHistoryEvent(
        date: r.effectiveFrom,
        lift: r.lift,
        fromLb: before,
        toLb: to,
        outcome: outcome,
        evidence: evidence.trim(),
        recommended: recommended,
        changed: valueRow && before != r.valueLb,
      ),
    );
  }
  return out.reversed.toList();
}

/// The conversion of already-APPLIED automatic changes into pending
/// proposals (HITL rollout, tool/wm_hitl_convert.dart). For each lift
/// whose newest value row is an auto-applied `rule`/`test` change dated
/// on/after [since]: a [tmRevertSource] row restoring the previously
/// accepted value (same effective date, confirmed=true) + a pending
/// proposal of the applied value (evidence rebuilt from the driving
/// reading). Idempotent: once converted, the newest value row is the
/// revert, so a re-run returns nothing.
List<WorkingMaxRow> hitlConversionRows(
  WmSnapshot snap, {
  required DateTime since,
}) {
  final out = <WorkingMaxRow>[];
  final sinceDay = _dayUtc(since);
  for (final lift in defaultVariantByLift.keys) {
    final liftRows = [
      for (final r in snap.workingMax)
        if (r.lift == lift && !isTmProposal(r) && !_isTmMarker(r)) r,
    ];
    if (liftRows.length < 2) continue;
    final last = liftRows.last;
    if (last.source != 'rule' && last.source != 'test') continue;
    if (last.confirmed != null) continue;
    if (_dayUtc(last.effectiveFrom).isBefore(sinceDay)) continue;
    final prior = liftRows[liftRows.length - 2].valueLb;
    if (prior == last.valueLb) continue;
    ReadingRow? reading;
    for (final rd in snap.readings) {
      if (rd.id == last.readingId) reading = rd;
    }
    final m = RegExp(
      r'median implied ([\d.]+) over (\d+) top sets',
    ).firstMatch(last.reason);
    final evidence = reading == null
        ? 'converted auto change: ${last.reason}'
        : tmEvidence(
            weightLb: reading.weightLb,
            reps: reading.reps,
            rpe: reading.rpe,
            impliedMax: reading.impliedMax,
            estMedian: m == null ? null : double.parse(m.group(1)!),
            estSets: m == null ? null : int.parse(m.group(2)!),
            grinder: reading.grinder && last.valueLb < prior,
            missed: reading.missed && last.valueLb < prior,
          );
    out.add(
      WorkingMaxRow(
        lift: lift,
        variant: last.variant,
        valueLb: prior,
        effectiveFrom: last.effectiveFrom,
        source: tmRevertSource,
        reason:
            'converted to proposal under HITL gating (auto change → '
            '${_fmtNum(last.valueLb)} on ${_ymd(last.effectiveFrom)} was '
            'applied without review)',
        readingId: last.readingId,
        confirmed: true,
      ),
    );
    out.add(
      WorkingMaxRow(
        lift: lift,
        variant: last.variant,
        valueLb: last.valueLb,
        effectiveFrom: last.effectiveFrom,
        source: tmProposalSource,
        reason: evidence,
        readingId: last.readingId,
        confirmed: false,
      ),
    );
  }
  return out;
}

/// True when the lift's most recent pain-cap event row is an activation
/// (`source=pain_cap`) rather than a lift (`reason` starts with
/// [painCapLiftedReasonPrefix]).
bool painCapActive(List<WorkingMaxRow> rows, String lift) {
  var active = false;
  for (final r in rows) {
    if (r.lift != lift) continue;
    if (r.source == 'pain_cap') active = true;
    if (r.reason.startsWith(painCapLiftedReasonPrefix)) active = false;
  }
  return active;
}

/// Date of the lift's newest pain-cap event row (activation or lift), for
/// deduping pain notes across nightly runs. Null when none exist.
DateTime? _lastPainEventDate(List<WorkingMaxRow> rows, String lift) {
  DateTime? last;
  for (final r in rows) {
    if (r.lift != lift) continue;
    if (r.source == 'pain_cap' ||
        r.reason.startsWith(painCapLiftedReasonPrefix)) {
      last = r.effectiveFrom;
    }
  }
  return last;
}

/// Working max in force for [lift] on [day] (last ACCEPTED row — pending
/// proposals excluded — with effective_from on or before it). Null before
/// the controller started.
double? workingMaxAsOf(List<WorkingMaxRow> rows, String lift, DateTime day) {
  final d = _dayUtc(day);
  double? value;
  for (final r in rows) {
    if (r.lift == lift &&
        !isTmProposal(r) &&
        !_dayUtc(r.effectiveFrom).isAfter(d)) {
      value = r.valueLb;
    }
  }
  return value;
}

/// Active next-top-set RPE cap per lift, from tab state: an active pain
/// cap caps at 7 (spec §2); otherwise a most-recent reading whose decision
/// was `drop` caps the next top set at the policy's `cap_after_drop_rpe`.
/// Lifts with no active cap are absent.
Map<String, double> activeCapsByLift(
  WmSnapshot snapshot,
  LoadPolicy? Function(DateTime date) policyFor,
) {
  final out = <String, double>{};
  for (final lift in defaultVariantByLift.keys) {
    if (painCapActive(snapshot.workingMax, lift)) {
      out[lift] = 7;
      continue;
    }
    ReadingRow? last;
    for (final r in snapshot.readings) {
      if (r.lift != lift) continue;
      if (last == null || !r.date.isBefore(last.date)) last = r;
    }
    if (last != null && last.decision == 'drop') {
      final cap = policyFor(last.date)?.capAfterDropRpe;
      if (cap != null) out[lift] = cap;
    }
  }
  return out;
}

/// Current working-max values per lift (for the planner's weight math).
Map<String, double> currentWorkingMaxesByLift(List<WorkingMaxRow> rows) => {
      for (final lift in defaultVariantByLift.keys)
        if (currentWorkingMax(rows, lift) != null)
          lift: currentWorkingMax(rows, lift)!.valueLb,
    };

/// `wm_decisions` cell for a program_status week row: the week's readings
/// as `lift:action` (with `→wm` when the value moved), oldest first.
String wmDecisionsForWeek(List<ReadingRow> readings, DateTime weekMonday) {
  final monday = _mondayOf(weekMonday);
  final week = [
    for (final r in readings)
      if (_mondayOf(r.date) == monday) r,
  ]..sort((a, b) => a.date.compareTo(b.date));
  const moves = {'raise', 'drop', 'reset', 'manual'};
  return [
    for (final r in week)
      '${r.lift}:${r.decision}'
      '${moves.contains(r.decision) ? '→${_fmtNum(r.wmAfter)}' : ''}',
  ].join('; ');
}

String _fmtNum(num v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

// ---------------------------------------------------------------------------
// runWmChain — the nightly evaluation chain
// ---------------------------------------------------------------------------

/// Output of one chain run: rows to APPEND (never rewrite) + flags.
class WmChainResult {
  /// New readings rows, in evaluation order.
  final List<ReadingRow> newReadings;

  /// New working_max rows (value changes, pain-cap markers, lifted
  /// markers), in evaluation order.
  final List<WorkingMaxRow> newWorkingMaxRows;

  /// Controller flags per lift (NO_READING, VARIANT_MISMATCH, PAIN_CAP,
  /// PAIN_CAP_LIFTED, TWO_SIGNALS...).
  final Map<String, List<String>> flagsByLift;

  const WmChainResult({
    required this.newReadings,
    required this.newWorkingMaxRows,
    required this.flagsByLift,
  });
}

/// True when [variant] (possibly `a+b`) can't be converted for [lift] —
/// used to keep reconstructed VARIANT_MISMATCH holds out of the raise
/// streak.
bool _variantUnconvertible(String lift, String variant) {
  final conv = variantConversions[lift] ?? const {};
  return variant.split('+').any((k) => !conv.containsKey(k));
}

/// Rebuilds the WM-1 decision-threading state from the last stored
/// reading row: `action` (consecutive-drop rule), `raiseEligible`
/// (cut_early twice-in-a-row rule) and — when the pain cap was active —
/// the PAIN_CAP_CLEAN flag, all recomputed against the policy in force at
/// the reading's date. Keeps streaks alive across nightly runs without
/// storing controller internals in the tab.
WmDecision _syntheticPrior(
    ReadingRow r, LoadPolicy? policy, bool painCapWasActive) {
  final flags = <String>[];
  if (painCapWasActive && r.decision == 'freeze') {
    final clean = (r.kind == 'heavy_top' || r.kind == 'capped') &&
        !r.grinder &&
        !r.missed &&
        (policy?.dropIfRpeGte == null || r.rpe < policy!.dropIfRpeGte!);
    flags.add('PAIN_CAP');
    if (clean) flags.add('PAIN_CAP_CLEAN');
  }
  final raiseEligible = policy != null &&
      r.decision == 'hold' &&
      policy.raiseIfRpeLte != null &&
      policy.readingsThatRaise.contains(r.kind) &&
      r.rpe <= policy.raiseIfRpeLte! &&
      !_variantUnconvertible(r.lift, r.variant);
  return WmDecision(
    date: r.date,
    lift: r.lift,
    action: r.decision,
    wmBefore: r.wmAfter,
    wmAfter: r.wmAfter,
    source: 'rule',
    reason: 'reconstructed from readings tab',
    raiseEligible: raiseEligible,
    flags: flags,
  );
}

/// Evaluates every NEW reading (strength rows → §1.2 readings, minus the
/// ones already in the tab) chronologically through the WM-1 controller,
/// per lift, and returns the rows to append.
///
/// State comes entirely from the snapshot (append-only tabs):
///   - working max + pain-cap state from `working_max` rows,
///   - the post-drop cap + raise streak from the last `readings` row
///     ([_syntheticPrior]).
///
/// Only readings dated on/after the lift's first working_max row are
/// considered (pre-controller history stays out), and only readings NEWER
/// than the lift's last stored reading (edits to already-evaluated days
/// are ignored — history is never rewritten). Lifts with no working_max
/// rows at all are skipped (controller not active).
///
/// [painNotes] (daily notes with cause=pain) activate pain caps for the
/// lifts named in their text (spec §2: back → squat+deadlift,
/// elbow/finger → press+bench), each producing a `source=pain_cap` marker
/// row; notes older than the lift's newest pain-cap event are ignored so
/// re-runs don't duplicate markers. [twoSignalsWeeks] (Mondays) freeze
/// evaluations falling in those ISO weeks. [today] bounds the window and
/// drives the NO_READING flag (two readingless weeks, spec §2).
WmChainResult runWmChain({
  required WmSnapshot snapshot,
  required List<StrengthRow> strengthRows,
  required LoadPolicy? Function(DateTime date) policyFor,
  String? Function(DateTime date)? weekTypeOf,
  DateTime? today,
  Set<DateTime> twoSignalsWeeks = const {},
  List<({DateTime date, String text})> painNotes = const [],
  TmRule? tmRule,
}) {
  final newReadings = <ReadingRow>[];
  final newWm = <WorkingMaxRow>[];
  final flagsByLift = <String, List<String>>{};

  for (final lift in defaultVariantByLift.keys) {
    final wmRows = [
      for (final r in snapshot.workingMax)
        if (r.lift == lift) r,
    ];
    if (wmRows.isEmpty) continue; // controller not seeded for this lift
    final startDate = _dayUtc(wmRows.first.effectiveFrom);
    final todayDay = today == null ? null : _dayUtc(today);
    // HITL gating (2026-10-16): every reading evaluates against the
    // ACCEPTED TM (the value in force — proposals never price or
    // evaluate anything); controller changes become a single candidate
    // that the gate turns into (at most) one proposal row per run.
    final accepted = currentWorkingMax(wmRows, lift)!.valueLb;
    final wm = accepted;
    final pendingAtStart = pendingTmProposal(wmRows, lift);
    final declined = declinedTmValue(wmRows, lift);
    ({double value, String reason, String readingId})? cand;
    var painCap = painCapActive(wmRows, lift);
    final lastPainEvent = _lastPainEventDate(wmRows, lift);

    final existing = [
      for (final r in snapshot.readings)
        if (r.lift == lift) r,
    ]..sort((a, b) => a.date.compareTo(b.date));
    final existingIds = {for (final r in existing) r.id};
    final lastDate =
        existing.isEmpty ? null : _dayUtc(existing.last.date);
    var capActive =
        existing.isNotEmpty && existing.last.decision == 'drop';
    WmDecision? prior = existing.isEmpty
        ? null
        : _syntheticPrior(
            existing.last, policyFor(existing.last.date), painCap);

    // Candidate readings: day-top RPE-bearing sets, controller-window
    // only, not already stored.
    final liftRows = [
      for (final r in strengthRows)
        if (mainLiftByExercise[r.exercise] == lift) r,
    ];
    final base = extractReadings(liftRows, kindOf: (_, _) => 'heavy_top');

    // v13 slow loop: the estimator's sample history = ALL of the lift's
    // day-top readings (recent completed training), kind-classified by
    // week type only (light/deload exclusion; the post-drop `capped`
    // kind is irrelevant to sampling). The last manual set_working_max
    // row pins the TM until `manual_outvote_sets` qualifying sets are
    // logged after it, and permanently scopes the estimator to
    // post-manual sets (overridden history is never resurrected).
    final slowLoop = tmRule?.slowLoop == true;
    final samples = !slowLoop
        ? const <Reading>[]
        : [
            for (final r in base)
              Reading(
                date: _dayUtc(r.date),
                lift: r.lift,
                variant: r.variant,
                weightLb: r.weightLb,
                rawWeightLb: r.rawWeightLb,
                reps: r.reps,
                rpe: r.rpe,
                kind: classifyKind(
                  lift: lift,
                  date: r.date,
                  weekType: weekTypeOf?.call(r.date),
                ),
                grinder: r.grinder,
                missed: r.missed,
                variantMismatch: r.variantMismatch,
              ),
          ];
    DateTime? manualSince;
    for (final r in wmRows) {
      if (r.source == 'manual') manualSince = _dayUtc(r.effectiveFrom);
    }

    final candidates = [
      for (final r in base)
        if (!_dayUtc(r.date).isBefore(startDate) &&
            (lastDate == null || _dayUtc(r.date).isAfter(lastDate)) &&
            !existingIds.contains(readingIdOf(r.date, lift)) &&
            (todayDay == null || !_dayUtc(r.date).isAfter(todayDay)))
          r,
    ];

    // Pain-note activations for this lift, newer than any recorded
    // pain-cap event.
    final notes = [
      for (final n in painNotes)
        if (painCapLiftsForNote(n.text).contains(lift) &&
            !_dayUtc(n.date).isBefore(startDate) &&
            (lastPainEvent == null ||
                _dayUtc(n.date).isAfter(_dayUtc(lastPainEvent))) &&
            (todayDay == null || !_dayUtc(n.date).isAfter(todayDay)))
          n,
    ]..sort((a, b) => a.date.compareTo(b.date));

    // Merge events chronologically (notes before readings on the same
    // day: the morning note caps that day's session).
    var ni = 0;
    void applyNotesThrough(DateTime day) {
      while (
          ni < notes.length && !_dayUtc(notes[ni].date).isAfter(_dayUtc(day))) {
        final n = notes[ni++];
        if (painCap) continue; // already active — no duplicate marker
        painCap = true;
        newWm.add(WorkingMaxRow(
          lift: lift,
          variant: defaultVariantByLift[lift]!,
          valueLb: wm,
          effectiveFrom: _dayUtc(n.date),
          source: 'pain_cap',
          reason: 'pain note ${_ymd(n.date)} ("${n.text}"): frozen, top '
              'sets capped at RPE 7 until two consecutive clean heavy '
              'sessions',
        ));
        (flagsByLift[lift] ??= []).add('PAIN_CAP');
      }
    }

    DateTime? lastReadingDate = lastDate;
    for (final r in candidates) {
      applyNotesThrough(r.date);
      final policy = policyFor(r.date);
      if (policy == null) continue; // outside every policy: not evaluable
      final kind = classifyKind(
        lift: lift,
        date: r.date,
        weekType: weekTypeOf?.call(r.date),
        capActive: capActive || painCap,
        saturdaySingle: policy.saturdaySingle,
      );
      final reading = Reading(
        date: r.date,
        lift: r.lift,
        variant: r.variant,
        weightLb: r.weightLb,
        rawWeightLb: r.rawWeightLb,
        reps: r.reps,
        rpe: r.rpe,
        kind: kind,
        grinder: r.grinder,
        missed: r.missed,
        variantMismatch: r.variantMismatch,
      );
      SlowTmEstimate? slowTm;
      ManualPin? pin;
      if (slowLoop) {
        slowTm = slowTmEstimate(
          samples: samples,
          currentTm: wm,
          rule: tmRule!,
          asOf: _dayUtc(r.date),
          notBefore: manualSince,
        );
        if (manualSince != null) {
          pin = (
            since: manualSince,
            newSets: qualifyingTmSamples(samples, wm, tmRule,
                    asOf: _dayUtc(r.date), notBefore: manualSince)
                .length,
            needed: tmRule.manualOutvoteSets,
          );
        }
      }
      final d = evaluate(
        lift: lift,
        policy: policy,
        workingMax: wm,
        date: r.date,
        reading: reading,
        priorDecisions: [?prior],
        painCapActive: painCap,
        twoSignalsThisWeek: twoSignalsWeeks.contains(_mondayOf(r.date)),
        tmRule: tmRule,
        slowTm: slowTm,
        manualPin: pin,
      );
      final id = readingIdOf(r.date, lift);
      newReadings.add(ReadingRow(
        id: id,
        date: _dayUtc(r.date),
        lift: lift,
        variant: r.variant,
        weightLb: double.parse(r.weightLb.toStringAsFixed(1)),
        reps: r.reps,
        rpe: r.rpe,
        kind: kind,
        grinder: r.grinder,
        missed: r.missed,
        impliedMax: double.parse(reading.impliedMax.toStringAsFixed(1)),
        decision: d.action,
        wmAfter: d.wmAfter,
      ));
      if (d.wmAfter != wm) {
        // Gated: a candidate, not an applied change.
        cand = (
          value: d.wmAfter,
          reason: tmEvidence(
            weightLb: r.rawWeightLb,
            reps: r.reps,
            rpe: r.rpe,
            impliedMax: reading.impliedMax,
            estMedian: slowTm?.median,
            estSets: slowTm?.sampleCount,
            grinder: d.action == 'drop' && r.grinder,
            missed: d.action == 'drop' && r.missed,
          ),
          readingId: id,
        );
      }
      if (d.flags.contains('PAIN_CAP_LIFTED')) {
        painCap = false;
        newWm.add(WorkingMaxRow(
          lift: lift,
          variant: defaultVariantByLift[lift]!,
          valueLb: d.wmAfter,
          effectiveFrom: _dayUtc(r.date),
          source: 'rule',
          reason: '$painCapLiftedReasonPrefix — two consecutive clean '
              'heavy sessions',
          readingId: id,
        ));
      }
      if (d.flags.isNotEmpty) {
        (flagsByLift[lift] ??= []).addAll(d.flags);
      }
      capActive = d.action == 'drop' && d.capNextTopSetRpe != null;
      prior = d;
      lastReadingDate = _dayUtc(r.date);
    }
    // Pain notes dated after the last reading still activate the cap.
    if (todayDay != null) applyNotesThrough(todayDay);

    // v13 slow-loop NIGHTLY RECOMPUTE: the TM is a pure function of the
    // recent history, so reconcile against the current estimate even
    // when no NEW reading arrived (rule/mode changes, edited history, a
    // manual pin getting outvoted). Guards: pain caps freeze; a
    // still-pinned manual value holds; a freshest-qualifying grinder/miss
    // never gets raised past (its drop stands until clean data). The ≤3
    // iterations run the min_top_fraction gate (which reads the current
    // TM) to its fixed point. HITL: it runs on a VIRTUAL TM — this run's
    // candidate, else the pending proposal, else the accepted value (the
    // old as-if-applied semantics) — and only yields a candidate; the
    // gate below decides what (if anything) to append.
    if (slowLoop && todayDay != null && !painCap) {
      var tm = cand?.value ?? pendingAtStart?.valueLb ?? accepted;
      var reached = false;
      Reading? newest;
      SlowTmEstimate? lastEst;
      for (var i = 0; i < 3; i++) {
        final qual = qualifyingTmSamples(
          samples,
          tm,
          tmRule!,
          asOf: todayDay,
          notBefore: manualSince,
        );
        if (qual.isEmpty) break;
        if (manualSince != null && qual.length < tmRule.manualOutvoteSets) {
          break; // manual pin still in force
        }
        final est = slowTmEstimate(
          samples: samples,
          currentTm: tm,
          rule: tmRule,
          asOf: todayDay,
          notBefore: manualSince,
        );
        if (est == null) break;
        final last = qual.last;
        if ((last.grinder || last.missed) && est.value > tm) break;
        reached = true;
        newest = last;
        lastEst = est;
        if (est.value == tm) break;
        tm = est.value;
      }
      if (reached && tm != cand?.value) {
        cand = (
          value: tm,
          reason: tmEvidence(
            weightLb: newest!.rawWeightLb,
            reps: newest.reps,
            rpe: newest.rpe,
            impliedMax: newest.impliedMax,
            estMedian: lastEst!.median,
            estSets: lastEst.sampleCount,
          ),
          readingId: '',
        );
      }
    }

    // The HITL gate: at most one proposal (or withdrawal) per lift per
    // run. Pain caps freeze the TM — no candidate is produced under one.
    final candValue = cand?.value;
    switch (gateTmCandidate(
      accepted: accepted,
      candidate: candValue,
      pending: pendingAtStart?.valueLb,
      declined: declined,
    )) {
      case TmGateAction.propose:
        newWm.add(
          WorkingMaxRow(
            lift: lift,
            variant: defaultVariantByLift[lift]!,
            valueLb: candValue!,
            effectiveFrom:
                todayDay ??
                (cand!.readingId.isEmpty
                    ? startDate
                    : _parseDay(cand.readingId.split('|').first)!),
            source: tmProposalSource,
            reason: cand!.reason,
            readingId: cand.readingId,
            confirmed: false,
          ),
        );
      case TmGateAction.withdraw:
        newWm.add(
          WorkingMaxRow(
            lift: lift,
            variant: defaultVariantByLift[lift]!,
            valueLb: accepted,
            effectiveFrom: todayDay ?? lastReadingDate ?? startDate,
            source: tmWithdrawnSource,
            reason:
                'estimate back at ${_fmtNum(accepted)} — proposal '
                '${_fmtNum(pendingAtStart!.valueLb)} withdrawn',
            readingId: tmProposalIdOf(pendingAtStart),
          ),
        );
      case TmGateAction.none:
        break;
    }

    // NO_READING: two consecutive readingless weeks (spec §2/§7.6).
    if (todayDay != null) {
      final base = lastReadingDate ?? startDate;
      final weeksWithout = todayDay.difference(base).inDays ~/ 7;
      if (weeksWithout >= 2) {
        (flagsByLift[lift] ??= []).add('NO_READING');
      }
    }
  }
  return WmChainResult(
    newReadings: newReadings,
    newWorkingMaxRows: newWm,
    flagsByLift: flagsByLift,
  );
}
