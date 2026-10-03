/// One loader for "this week, as it stands" — the CONFIGURED week
/// (week_start.dart: synced setting > program.yaml `week_start` >
/// Monday; Saturday for the user since 2026-10-03): the program's
/// prescription with the week's `program_moves` applied, the week's
/// logged work, and (optionally) the missed-work detector over it.
///
/// Shared by the program day card, CoachBrain's moves/missed section,
/// the day synthesis and the in-app carryover check so every surface
/// reads the same sources the same way (spec 2026-10-02 §3/§7). Each
/// source is listed ONCE per load, all in parallel (the read-only Kaya
/// climbing tab is session-cached — [WeekStateLoader.kayaCacheTtl]);
/// every read degrades honestly (a
/// failed moves read = an unmoved week, a failed log read = nothing
/// logged) — only a failed program-doc load yields null.
library;

import 'day_achievement.dart' show AchievedSet, DayClip;
import 'day_prescription.dart' show DayPrescription;
import 'day_status.dart';
import 'intent_docs.dart';
import 'missed_work.dart';
import 'prescribed_exercises.dart' show PrescribedItem;
import 'program_moves.dart';
import 'program_current.dart' show currentVersion;
import 'program_week.dart' show dayOnly, prescribedDay;
import 'resolved_week.dart';
import 'week_start.dart';
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

  /// The week's intentional skips, keyed by [skipKey] (day|item).
  final Map<String, ProgramMove> skips;

  /// The effective (post-moves) week — exactly its 7 days, in order.
  final Map<DateTime, List<EffectiveItem>> week;

  /// `DateTime.monday..sunday` the week starts on (resolved).
  final int weekStartDay;

  /// The week's prescribed items — its 7 days + any next-week home day a
  /// move pulls work from (ResolvedWeek.prescribed).
  final Map<DateTime, List<PrescribedItem>> prescribed;

  /// Every strength row (null when no strength source / the read
  /// failed) — the card's info sheet reuses it.
  final List<Record>? strengthRows;

  /// Exercise names of the WORKING sets logged on [date] (warm-ups
  /// excluded — `workingSetRecords`), one entry per set.
  final List<String> loggedOnDate;

  /// Parallel to [loggedOnDate]: the strength record behind each entry,
  /// or null for a calisthenics set (no per-set record). Lets the card
  /// say WHAT was achieved for each item (weight × reps).
  final List<Record?> loggedRecordsOnDate;

  /// The week's WORKING sets (strength + calisthenics, warm-ups
  /// excluded), one entry per set, over the week — what the missed-work
  /// detector allocates; the Week tab's program progress reuses it.
  final List<({DateTime date, String exercise})> weekSets;

  /// Whoop workouts (all days; empty when no source / failed).
  final List<WhoopActivity> whoop;

  /// Missed work as of [date] (only when loaded `withMissed` and a
  /// strength source exists; null otherwise).
  final MissedWork? missed;

  /// Kaya ascent dates (read only when loaded `withMissed`; empty
  /// otherwise) — credits a day's climb item ([buildDayStatus]).
  final List<DateTime> kayaDays;

  /// Days with a logged 4x4 cardio session (empty when no cardio source).
  final Set<DateTime> cardio4x4Days;

  const WeekState({
    required this.docs,
    required this.date,
    required this.prescription,
    required this.moves,
    this.skips = const {},
    required this.week,
    this.weekStartDay = DateTime.monday,
    this.prescribed = const {},
    required this.strengthRows,
    required this.loggedOnDate,
    this.loggedRecordsOnDate = const [],
    this.weekSets = const [],
    required this.whoop,
    required this.missed,
    this.kayaDays = const [],
    this.cardio4x4Days = const {},
  });

  /// The week's first day (local midnight).
  DateTime get weekStart => weekStartOf(date, weekStartDay);

  /// [date]'s effective items (ghosts included).
  List<EffectiveItem> get day => week[date] ?? const <EffectiveItem>[];

  /// [date]'s per-item status — the ONE resolution the program card, the
  /// day synthesis and the coach chat share ([buildDayStatus]).
  /// [trackSets] false (no strength source) leaves lift items pending;
  /// [clips] / [isTop] are the card's display refinements.
  DayStatus dayStatus({
    bool trackSets = true,
    List<DayClip> clips = const [],
    bool Function(EffectiveItem e)? isTop,
  }) =>
      buildDayStatus(
        date: date,
        entries: day,
        logged: !trackSets
            ? null
            : [
                for (var j = 0; j < loggedOnDate.length; j++)
                  AchievedSet.fromRecord(
                      loggedOnDate[j],
                      j < loggedRecordsOnDate.length
                          ? loggedRecordsOnDate[j]
                          : null),
              ],
        clips: clips,
        isTop: isTop,
        whoop: whoop,
        kayaDays: kayaDays,
        cardio4x4Days: cardio4x4Days,
        skips: skips,
      );
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

  /// Calisthenics log (skill/variation/sets) — credits skill items like
  /// "Handstand practice" exactly as strength sets do.
  final ViewSchema? calisthenicsView;
  final WarehouseConnector? calisthenicsRepo;

  /// Clock for the Kaya cache TTL.
  final DateTime Function() now;

  /// The synced week-start setting (app: `AppSettings.weekStartSetting`)
  /// — resolved against the loaded program's `week_start` default.
  final Object? Function()? weekStartSetting;

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
    this.calisthenicsView,
    this.calisthenicsRepo,
    this.now = DateTime.now,
    this.weekStartSetting,
  });

  /// Whether the strength source is configured (missed work needs it).
  bool get hasStrength => strengthView != null && strengthRepo != null;

  /// Session cache of the read-only Kaya climbing tab's dates: that read
  /// is a NETWORK fetch of ~1.4k rows, and the tab only changes on a Kaya
  /// import — re-reading it on every log event (program card) / coach
  /// turn was the slow path. Single entry keyed by repo identity + view
  /// name (the card and the coach share the bootstrap's read-only repo);
  /// failed reads are never cached.
  static const kayaCacheTtl = Duration(minutes: 30);
  static ({
    WarehouseConnector repo,
    String view,
    DateTime at,
    List<DateTime> days,
  })? _kaya;

  /// Drops the Kaya cache (after an import; tests).
  static void clearKayaCache() => _kaya = null;

  static Future<List<DateTime>> _kayaDays(
      ViewSchema view, WarehouseConnector repo, DateTime now) async {
    final c = _kaya;
    if (c != null &&
        identical(c.repo, repo) &&
        c.view == view.name &&
        now.difference(c.at) < kayaCacheTtl &&
        !now.isBefore(c.at)) {
      return c.days;
    }
    final days = <DateTime>[
      for (final r in await repo.list(view)) ?_date(r['date']),
    ];
    _kaya = (repo: repo, view: view.name, at: now, days: days);
    return days;
  }

  /// [read], or null when the source is missing or the read throws
  /// (every source degrades honestly).
  static Future<T?> _try<T>(Future<T> Function()? read) async {
    if (read == null) return null;
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  /// Loads [date]'s week. Cardio (a local read) is always read when
  /// configured. [withMissed] also reads the Kaya climbing tab and
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
    final wsDay = resolveWeekStartDay(
      setting: weekStartSetting?.call(),
      programVersion: currentVersion(docs.program),
    );
    final mon = weekStartOf(day, wsDay); // the week's first day
    final (prescription, _) = prescribedDay(docs, day, label: label);
    if (prescription == null) return null;

    // Independent sources, read in parallel (each once per load).
    final mv = programMovesView;
    final mr = programMovesRepo;
    final sv = strengthView;
    final sr = strengthRepo;
    final wv = workoutsView;
    final wr = workoutsRepo;
    final cv = climbingView;
    final cr = climbingRepo;
    final kv = cardioView;
    final kr = cardioRepo;
    final xv = calisthenicsView;
    final xr = calisthenicsRepo;
    final missedOn = withMissed && sv != null && sr != null;
    final reads = await Future.wait<Object?>([
      _try(mv == null || mr == null ? null : () => mr.list(mv)),
      _try(sv == null || sr == null ? null : () => sr.list(sv)),
      _try(wv == null || wr == null ? null : () => wr.list(wv)),
      _try(!missedOn || cv == null || cr == null
          ? null
          : () => _kayaDays(cv, cr, now())),
      // Cardio is a local read: always (credits the day's 4x4 item).
      _try(kv == null || kr == null ? null : () => kr.list(kv)),
      _try(xv == null || xr == null ? null : () => xr.list(xv)),
    ]);
    final moveRows = reads[0] as List<Record>?;
    final strengthList = reads[1] as List<Record>?;
    final workoutRows = reads[2] as List<Record>?;
    final kaya = (reads[3] as List<DateTime>?) ?? const <DateTime>[];
    final cardioRows = reads[4] as List<Record>?;
    final calisthenicsRows = reads[5] as List<Record>?;

    var allMoves = const <ProgramMove>[];
    if (moveRows != null) {
      try {
        allMoves = [for (final r in moveRows) ?ProgramMove.fromRecord(r)];
      } catch (_) {/* honest: unmoved week */}
    }
    final rw = resolveProgramWeek(docs, day, allMoves,
        weekStartDay: wsDay, label: label);
    final moves = rw.moves;
    final skips = rw.skips;
    final week = rw.week;

    List<Record>? strengthRows;
    final logged = <String>[];
    final loggedRecords = <Record?>[];
    final strengthWeek = <({DateTime date, String exercise})>[];
    if (strengthList != null) {
      try {
        strengthRows = strengthList;
        // Only WORKING sets credit prescribed items (card + detector).
        for (final r in workingSetRecords(strengthList)) {
          final d = _date(r['date']);
          final ex = r['exercise']?.toString().trim();
          if (d == null || ex == null || ex.isEmpty) continue;
          if (dayOnly(d) == day) {
            logged.add(ex);
            loggedRecords.add(r);
          }
          if (weekStartOf(d, wsDay) == mon) {
            strengthWeek.add((date: dayOnly(d), exercise: ex));
          }
        }
      } catch (_) {/* honest empty */}
    }
    // Calisthenics sets credit skill items the same way (one per set).
    if (calisthenicsRows != null) {
      try {
        for (final c in calisthenicsLoggedSets(calisthenicsRows)) {
          if (c.date == day) {
            logged.add(c.exercise);
            loggedRecords.add(null);
          }
          if (weekStartOf(c.date, wsDay) == mon) strengthWeek.add(c);
        }
      } catch (_) {/* honest: strength-only */}
    }

    var whoop = const <WhoopActivity>[];
    if (workoutRows != null) {
      try {
        whoop = whoopActivitiesFromRecords(workoutRows);
      } catch (_) {/* honest: logged-only */}
    }

    final cardioDays = <DateTime>{};
    for (final r in cardioRows ?? const <Record>[]) {
      final type = r['type']?.toString().trim().toLowerCase() ?? '';
      if (type.isNotEmpty && !fourByFourCardioTypes.contains(type)) {
        continue;
      }
      final d = _date(r['date']);
      if (d != null) cardioDays.add(dayOnly(d));
    }
    MissedWork? missed;
    if (missedOn) {
      missed = detectMissedWork(
        week: week,
        strengthRows: strengthWeek,
        climbDays: climbDaysUnion(kaya, whoopClimbDays(whoop)),
        cardio4x4Days: cardioDays,
        today: day,
        skipped: skips.keys.toSet(),
        weekStartDay: wsDay,
      );
    }

    return WeekState(
      docs: docs,
      date: day,
      prescription: prescription,
      moves: moves,
      skips: skips,
      week: week,
      weekStartDay: wsDay,
      prescribed: rw.prescribed,
      strengthRows: strengthRows,
      loggedOnDate: logged,
      loggedRecordsOnDate: loggedRecords,
      weekSets: strengthWeek,
      whoop: whoop,
      missed: missed,
      kayaDays: kaya,
      cardio4x4Days: cardioDays,
    );
  }
}
