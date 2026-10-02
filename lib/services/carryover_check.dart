/// In-app daily carryover check — the fallback for the nightly Mac
/// briefing (spec 2026-10-02-missed-work-carryover-design §5): on the
/// first foreground of a day after 06:00 (or a home-poller tick — kiosk
/// mode never resumes), when this week has missed work and the nightly
/// has NOT already planned today (no briefing since yesterday 18:00, no
/// moves proposal from last night / today), ask the in-app coach where
/// the missed work goes. It answers with a `propose_moves` card in the
/// general coach thread (+ a local notification).
///
/// The nightly posts at 23:30 and stamps its rows with the POSTING day
/// (yesterday), so "already planned" keys off `ts` in the window, not
/// `date == today`. coach_chat is read only after a sync that finished
/// after the check started ([awaitFreshSync]) — reading a stale local
/// copy would miss last night's briefing and duplicate its proposal.
///
/// [CarryoverCheck.maybeRun] is pure-ish: every dependency is injected so
/// each gate is unit-testable. The meta key is written BEFORE asking, so
/// it runs at most once per day even when the coach call fails.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
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
  alreadyPlanned,
  notSynced,
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

  /// Runs the gates in cheap-first order — hour, meta, missed work
  /// non-empty (local reads), a FRESH sync ([freshSync]: false → return
  /// without touching meta, retried on the next resume/tick), then
  /// [alreadyPlanned] (reads the freshly synced coach_chat; true → the
  /// nightly covered today: meta set, no ask) — then sets [metaKey] to
  /// today and calls [ask] with the missed work. Never throws: a failing
  /// gate read skips the run; a failing [ask] is swallowed (meta stays
  /// set). Concurrent calls (bootstrap + resume + poller) collapse to one.
  static Future<CarryoverOutcome> maybeRun({
    required DateTime now,
    required Future<String?> Function(String key) metaGet,
    required Future<void> Function(String key, String value) metaSet,
    required Future<MissedWork?> Function() missed,
    required Future<bool> Function() freshSync,
    required Future<bool> Function() alreadyPlanned,
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
      final mw = await missed();
      if (mw == null || mw.isEmpty) return CarryoverOutcome.nothingMissed;
      if (!await freshSync()) return CarryoverOutcome.notSynced;
      if (await alreadyPlanned()) {
        await metaSet(metaKey, today);
        return CarryoverOutcome.alreadyPlanned;
      }
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

/// Tolerant datetime parse: ISO, space-separated, one-digit-hour Sheets
/// renderings ("2026-10-01 9:00:00"); a UTC (`Z`) stamp converts to
/// local.
DateTime? _dateTime(Object? v) {
  if (v is DateTime) return v;
  final raw = v?.toString().trim() ?? '';
  if (raw.isEmpty || raw == 'null') return null;
  final s = raw.replaceFirstMapped(
    RegExp(r'^(\d{4}-\d{2}-\d{2})[ T](\d):'),
    (m) => '${m[1]} 0${m[2]}:',
  );
  final d = DateTime.tryParse(s);
  return d == null ? null : (d.isUtc ? d.toLocal() : d);
}

/// True when [rows] (coach_chat, any thread) show today is already
/// planned: a `kind=briefing` row in the `briefings` thread with `ts` at
/// or after yesterday 18:00 (the 23:30 nightly — dated YESTERDAY — or a
/// morning re-run), or a moves `kind=proposal` row with `ts` in that
/// window or dated today. A nightly that deliberately proposed nothing
/// still counts (its briefing is the plan).
bool alreadyPlannedToday(List<Record> rows, DateTime now) {
  final since = DateTime(now.year, now.month, now.day - 1, 18);
  final today = _ymd(now);
  for (final r in rows) {
    final kind = r['kind']?.toString().trim();
    final ts = _dateTime(r['ts']);
    final fresh = ts != null && !ts.isBefore(since);
    if (kind == 'briefing') {
      if (fresh && r['thread']?.toString().trim() == 'briefings') return true;
      continue;
    }
    if (kind != 'proposal') continue;
    if (MovesProposal.tryParse(r['text']?.toString() ?? '') == null) continue;
    if (fresh) return true;
    final d = _dateTime(r['date']);
    if (d != null && _ymd(d) == today) return true;
  }
  return false;
}

/// Makes sure a sync FINISHED after [since] before coach_chat is read:
/// when one is already running ([syncing] true — `maybeSync` would return
/// immediately) waits for it to end (up to [timeout]); otherwise awaits
/// [sync]. True only when [lastSync] is after [since] and [chatFailed]
/// reports no coach_chat error for that sync.
Future<bool> awaitFreshSync({
  required DateTime since,
  required ValueListenable<bool> syncing,
  required ValueListenable<DateTime?> lastSync,
  required bool Function() chatFailed,
  required Future<void> Function() sync,
  Duration timeout = const Duration(seconds: 60),
}) async {
  if (syncing.value) {
    final done = Completer<void>();
    void listener() {
      if (!syncing.value && !done.isCompleted) done.complete();
    }

    syncing.addListener(listener);
    try {
      listener(); // ended between the check and addListener
      await done.future.timeout(timeout);
    } on TimeoutException {
      return false;
    } finally {
      syncing.removeListener(listener);
    }
  } else {
    try {
      await sync().timeout(timeout);
    } catch (_) {
      return false;
    }
  }
  final last = lastSync.value;
  return last != null && last.isAfter(since) && !chatFailed();
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
