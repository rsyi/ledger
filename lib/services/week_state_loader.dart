/// One loader for "this Mon–Sun week, as it stands": the program's
/// prescription with the week's `program_moves` applied, the week's
/// logged work, and (optionally) the missed-work detector over it.
///
/// Shared by the program day card, CoachBrain's moves/missed section,
/// the day synthesis and the in-app carryover check so every surface
/// reads the same sources the same way (spec 2026-10-02 §3/§7). Each
/// source is listed ONCE per load; every read degrades honestly (a
/// failed moves read = an unmoved week, a failed log read = nothing
/// logged) — only a failed program-doc load yields null.
library;

import 'day_prescription.dart' show DayPrescription;
import 'intent_docs.dart';
import 'missed_work.dart';
import 'program_moves.dart';
import 'program_week.dart' show dayOnly, mondayOf, prescribedDay, prescribedWeek;
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';
import '../models/view_schema.dart';
import 'whoop_activity.dart';
import 'working_sets.dart';

/// Cardio `type`s that count as a 4x4 session (blank counts too) — same
/// filter as the Goals tab and tool/missed_work.dart.
const fourByFourCardioTypes = {'treadmill', 'bike', 'stairmaster'};

class WeekState {
  final IntentDocs docs;

  /// The loaded day (local midnight).
  final DateTime date;

  /// [date]'s prescription (never null here — a missing program yields
  /// no state at all).
  final DayPrescription prescription;

  /// Active moves for the week (latest per key).
  final Map<String, ProgramMove> moves;

  /// The effective (post-moves) Mon–Sun week.
  final Map<DateTime, List<EffectiveItem>> week;

  /// Every strength row (null when no strength source / the read
  /// failed) — the card's info sheet reuses it.
  final List<Record>? strengthRows;

  /// Exercise names of the WORKING sets logged on [date] (warm-ups
  /// excluded — `workingSetRecords`), one entry per set.
  final List<String> loggedOnDate;

  /// Whoop workouts (all days; empty when no source / failed).
  final List<WhoopActivity> whoop;

  /// Missed work as of [date] (only when loaded `withMissed` and a
  /// strength source exists; null otherwise).
  final MissedWork? missed;

  const WeekState({
    required this.docs,
    required this.date,
    required this.prescription,
    required this.moves,
    required this.week,
    required this.strengthRows,
    required this.loggedOnDate,
    required this.whoop,
    required this.missed,
  });

  /// [date]'s effective items (ghosts included).
  List<EffectiveItem> get day => week[date] ?? const <EffectiveItem>[];
}

class WeekStateLoader {
  /// Program/phase/strategy docs (e.g. `ProgramProvider.load`).
  final Future<IntentDocs> Function() loadDocs;

  final ViewSchema? programMovesView;
  final WarehouseConnector? programMovesRepo;
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;
  final ViewSchema? workoutsView;
  final WarehouseConnector? workoutsRepo;
  final ViewSchema? cardioView;
  final WarehouseConnector? cardioRepo;
  final ViewSchema? climbingView;
  final WarehouseConnector? climbingRepo;

  const WeekStateLoader({
    required this.loadDocs,
    this.programMovesView,
    this.programMovesRepo,
    this.strengthView,
    this.strengthRepo,
    this.workoutsView,
    this.workoutsRepo,
    this.cardioView,
    this.cardioRepo,
    this.climbingView,
    this.climbingRepo,
  });

  /// Whether the strength source is configured (missed work needs it).
  bool get hasStrength => strengthView != null && strengthRepo != null;

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  /// Loads [date]'s week. [withMissed] also reads climbing + cardio and
  /// runs [detectMissedWork] with [date] as "today" (requires a strength
  /// source). Null when the docs can't load or there is no program.
  Future<WeekState?> load(
    DateTime date, {
    String label = 'Today',
    bool withMissed = false,
  }) async {
    IntentDocs docs;
    try {
      docs = await loadDocs();
    } catch (_) {
      return null;
    }
    final day = dayOnly(date);
    final mon = mondayOf(day);
    final (prescription, _) = prescribedDay(docs, day, label: label);
    if (prescription == null) return null;

    var moves = const <String, ProgramMove>{};
    final mv = programMovesView;
    final mr = programMovesRepo;
    if (mv != null && mr != null) {
      try {
        moves = activeMoves([
          for (final r in await mr.list(mv)) ?ProgramMove.fromRecord(r),
        ], mon);
      } catch (_) {/* honest: unmoved week */}
    }
    final week = effectiveWeek(prescribedWeek(docs, day, label: label), moves);

    List<Record>? strengthRows;
    final logged = <String>[];
    final strengthWeek = <({DateTime date, String exercise})>[];
    final sv = strengthView;
    final sr = strengthRepo;
    if (sv != null && sr != null) {
      try {
        final rows = await sr.list(sv);
        strengthRows = rows;
        // Only WORKING sets credit prescribed items (card + detector).
        for (final r in workingSetRecords(rows)) {
          final d = _date(r['date']);
          final ex = r['exercise']?.toString().trim();
          if (d == null || ex == null || ex.isEmpty) continue;
          if (dayOnly(d) == day) logged.add(ex);
          if (mondayOf(d) == mon) {
            strengthWeek.add((date: dayOnly(d), exercise: ex));
          }
        }
      } catch (_) {/* honest empty */}
    }

    var whoop = const <WhoopActivity>[];
    final wv = workoutsView;
    final wr = workoutsRepo;
    if (wv != null && wr != null) {
      try {
        whoop = whoopActivitiesFromRecords(await wr.list(wv));
      } catch (_) {/* honest: logged-only */}
    }

    MissedWork? missed;
    if (withMissed && sv != null && sr != null) {
      final kaya = <DateTime>[];
      final cv = climbingView;
      final cr = climbingRepo;
      if (cv != null && cr != null) {
        try {
          for (final r in await cr.list(cv)) {
            final d = _date(r['date']);
            if (d != null) kaya.add(d);
          }
        } catch (_) {/* honest: Whoop-only */}
      }
      final cardioDays = <DateTime>{};
      final kv = cardioView;
      final kr = cardioRepo;
      if (kv != null && kr != null) {
        try {
          for (final r in await kr.list(kv)) {
            final type = r['type']?.toString().trim().toLowerCase() ?? '';
            if (type.isNotEmpty && !fourByFourCardioTypes.contains(type)) {
              continue;
            }
            final d = _date(r['date']);
            if (d != null) cardioDays.add(dayOnly(d));
          }
        } catch (_) {/* honest empty */}
      }
      missed = detectMissedWork(
        week: week,
        strengthRows: strengthWeek,
        climbDays: climbDaysUnion(kaya, whoopClimbDays(whoop)),
        cardio4x4Days: cardioDays,
        today: day,
      );
    }

    return WeekState(
      docs: docs,
      date: day,
      prescription: prescription,
      moves: moves,
      week: week,
      strengthRows: strengthRows,
      loggedOnDate: logged,
      whoop: whoop,
      missed: missed,
    );
  }
}
