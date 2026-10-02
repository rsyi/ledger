/// In-app daily carryover check — the fallback for the nightly Mac
/// briefing (spec 2026-10-02-missed-work-carryover-design §5): on the
/// first foreground of a day after 06:00, when this week has missed work
/// and no moves proposal is dated today, ask the in-app coach where the
/// missed work goes. It answers with a `propose_moves` card in the
/// general coach thread (+ a local notification).
///
/// [CarryoverCheck.maybeRun] is pure-ish: every dependency is injected so
/// each gate is unit-testable. The meta key is written BEFORE asking, so
/// it runs at most once per day even when the coach call fails.
library;

import 'package:uuid/uuid.dart';

import '../models/coach_proposal.dart';
import '../models/view_schema.dart';
import 'coach_thread_const.dart';
import 'coach_tools.dart' show MovesProposalSink, ProposalSink;
import 'missed_work.dart';
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';

/// What [CarryoverCheck.maybeRun] did (tests + debugging).
enum CarryoverOutcome {
  tooEarly,
  alreadyChecked,
  proposalExists,
  nothingMissed,
  busy,
  asked,
  failed,
}

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class CarryoverCheck {
  /// Ledger meta key (device-local): the yyyy-mm-dd last checked.
  static const metaKey = 'carryover_checked_day';

  /// Earliest local hour the check runs.
  static const earliestHour = 6;

  /// The app-authored user turn sent to the coach.
  static const prompt = 'Missed work detected this week — propose where it '
      'goes (propose_moves).';

  static bool _running = false;

  /// Runs the gates in cheap-first order — hour, meta, an existing moves
  /// proposal today, missed work non-empty — then sets [metaKey] to today
  /// and calls [ask] with the missed work. Never throws: a failing gate
  /// read skips the run; a failing [ask] is swallowed (meta stays set).
  /// Concurrent calls (bootstrap + resume) collapse to one.
  static Future<CarryoverOutcome> maybeRun({
    required DateTime now,
    required Future<String?> Function(String key) metaGet,
    required Future<void> Function(String key, String value) metaSet,
    required Future<MissedWork?> Function() missed,
    required Future<bool> Function() hasMovesProposalToday,
    required Future<void> Function(MissedWork missed) ask,
  }) async {
    if (now.hour < earliestHour) return CarryoverOutcome.tooEarly;
    if (_running) return CarryoverOutcome.busy;
    _running = true;
    try {
      final today = _ymd(now);
      if (await metaGet(metaKey) == today) {
        return CarryoverOutcome.alreadyChecked;
      }
      if (await hasMovesProposalToday()) {
        return CarryoverOutcome.proposalExists;
      }
      final mw = await missed();
      if (mw == null || mw.isEmpty) return CarryoverOutcome.nothingMissed;
      // At most once per day, even if the ask below fails.
      await metaSet(metaKey, today);
      try {
        await ask(mw);
        return CarryoverOutcome.asked;
      } catch (_) {
        return CarryoverOutcome.failed;
      }
    } catch (_) {
      return CarryoverOutcome.failed;
    } finally {
      _running = false;
    }
  }
}

/// True when [rows] (coach_chat, any thread) hold a `kind=proposal` row
/// of type moves dated [day] (by `date`, falling back to `ts`).
bool hasMovesProposalOn(List<Record> rows, DateTime day) {
  final want = _ymd(day);
  for (final r in rows) {
    if (r['kind']?.toString() != 'proposal') continue;
    if (MovesProposal.tryParse(r['text']?.toString() ?? '') == null) continue;
    final raw = r['date'] ?? r['ts'];
    final d = raw is DateTime ? raw : DateTime.tryParse(raw?.toString() ?? '');
    if (d != null && _ymd(d) == want) return true;
  }
  return false;
}

/// One coach turn: (user prompt, legacy-proposal sink, moves sink) →
/// assistant text. `CoachBrain.ask` in the app.
typedef CarryoverAsk = Future<String> Function(
  String prompt,
  ProposalSink onProposal,
  MovesProposalSink onMovesProposal,
);

/// Runs the carryover turn and posts its output to the GENERAL coach
/// thread (never the day thread — a coach row there would stop the Today
/// synthesis from seeding it): proposal rows as the tool fires (moves or
/// a stray legacy schedule proposal), then the reply text. Notifies with
/// the moves summary (else the reply's first line). Throws on an ask /
/// write failure — [CarryoverCheck.maybeRun] swallows it.
Future<void> postCarryoverTurn({
  required ViewSchema view,
  required WarehouseConnector repository,
  required CarryoverAsk ask,
  Future<void> Function(String title, String body)? notify,
  DateTime Function() now = DateTime.now,
}) async {
  Record row(String kind, String text) {
    final t = now();
    return <String, Object?>{
      'id': const Uuid().v4(),
      'date': DateTime(t.year, t.month, t.day),
      'ts': t.toIso8601String(),
      'role': 'coach',
      'kind': kind,
      'thread': kCoachThreadGeneral,
      'text': text,
    };
  }

  final moves = <MovesProposal>[];
  final text = await ask(
    CarryoverCheck.prompt,
    (p) async {
      await repository.create(view, row('proposal', p.encode()));
    },
    (p) async {
      await repository.create(view, row('proposal', p.encode()));
      moves.add(p);
    },
  );
  final reply = text.trim();
  if (reply.isNotEmpty) await repository.create(view, row('reply', reply));
  if (notify == null) return;
  final body = moves.isNotEmpty && moves.first.summary.trim().isNotEmpty
      ? 'Proposed: ${moves.first.summary.trim()} — tap Schedule in Coach.'
      : reply.split('\n').first.trim();
  if (body.isEmpty) return;
  try {
    await notify('Coach: missed work', body);
  } catch (_) {/* best-effort */}
}
