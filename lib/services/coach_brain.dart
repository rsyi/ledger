import '../models/coach_proposal.dart';
import '../models/github_config.dart';
import '../models/model_config.dart';
import '../models/view_schema.dart';
import 'chat_runner.dart';
import 'coach_tools.dart';
import 'github_client.dart';
import 'missed_work.dart';
import 'program_current.dart';
import 'program_moves.dart';
import 'program_provider.dart';
import 'program_week.dart' show mondayOf;
import 'program_slice_text.dart';
import 'video_rpe.dart';
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';
import 'week_planner.dart' show buildWeekPlannedEntries;
import 'week_state_loader.dart';
import 'whoop_activity.dart';

/// Fetches one coach doc by repo path (e.g. `coach/goals.md`). Returns
/// the file's contents, or null when the file doesn't exist. Throwing is
/// treated the same as null (doc unavailable).
typedef CoachDocFetcher = Future<String?> Function(String path);

/// Produces in-app coach replies via the ChatRunner tool loop over API
/// credits — no Mac relay involved. Context assembly: coach docs from
/// GitHub (1 h cache), a 28-day local ledger dump, and the current
/// thread's chat history (up to 40 messages). Available tools:
/// read_program_day / propose_schedule. The caller persists
/// the returned text as a `role=coach, kind=reply` row; proposal rows are
/// persisted by the [ProposalSink] callback (onProposal) during the loop.
/// The nightly briefing still arrives through the synced `coach_chat`
/// view.
class CoachBrain {
  /// Coach docs pulled from the schemas repo. Order matters — it's the
  /// order they appear in the prompt.
  /// routine.md is retained this release for fallback; the program slice
  /// above is now authoritative for weekly structure.
  static const docPaths = [
    'coach/goals.md',
    'coach/routine.md', // deprecated: kept as fallback only; see program slice
    'coach/metrics.md',
  ];

  /// Intent-layer YAML paths fetched alongside docs. strategy.yaml may 404
  /// — tolerated (null slice section → fall back to docs only). Exposed as
  /// a public constant so tests can account for the extra fetches.
  static const intentPaths = [
    'coach/program.yaml',
    'coach/phase.yaml',
    'coach/strategy.yaml', // may 404 — null is fine
  ];

  /// Ledger views dumped into the prompt (those that exist). Covers the
  /// data domains the coach reasons over: the lifting/cardio/weight/
  /// journal ledgers PLUS the integration surfaces — recovery (Whoop
  /// sleep/HRV/recovery), whoop_workouts (Whoop per-workout strain),
  /// meals (Macrofactor macros), and climbing (Kaya ascents).
  /// Integration/read-only views (climbing) list through the direct-sheet
  /// [readOnlyRepo]; the rest ride the local-first [repository]. All are
  /// windowed + row-capped by [renderTable], so even climbing's ~1.4k
  /// rows shrink to ≤200 of the last 28 days. whoop_workouts lands in the
  /// SAME window as strength/cardio so the coach can line a day's workout
  /// strain up against that day's logged training session (temporal join).
  static const dumpViews = [
    'strength',
    'cardio',
    'weight',
    'daily_notes',
    'recovery',
    'whoop_workouts',
    'meals',
    'climbing',
  ];

  /// Rows older than this are dropped from the dump (future rows —
  /// planned entries — are always kept).
  static const dumpWindow = Duration(days: 28);

  /// Per-view row cap for the dump (most recent kept).
  static const maxRowsPerView = 200;

  /// Chat-history cap (most recent kept).
  static const maxHistoryMessages = 40;

  /// How long fetched coach docs stay fresh. Cached statically so the
  /// cache survives home-screen rebuilds recreating the brain.
  static const docCacheTtl = Duration(hours: 1);
  static final Map<String, ({DateTime at, String content})> _docCache = {};

  /// Test hook — the doc cache is process-global. Also clears
  /// [ProgramProvider]'s cache so tests that use both get a clean slate.
  static void clearDocCache() {
    _docCache.clear();
    ProgramProvider.clearCache();
  }

  /// Anthropic model the reply turn runs on (ChatRunner requires
  /// anthropic vendor — home_screen's _chatModel already selects one).
  final ModelConfig model;

  /// Local-first ledger connector — writable [dumpViews] list through it.
  final WarehouseConnector repository;

  /// Direct-sheet connector for read-only views (climbing/kaya_ascents):
  /// the local engine never owns those tabs, so listing them through
  /// [repository] returns nothing. Null → read-only dump views are
  /// silently skipped (same fallback as a missing view).
  final WarehouseConnector? readOnlyRepo;

  /// All loaded views by name; [dumpViews] absent from this map are
  /// silently skipped.
  final Map<String, ViewSchema> views;

  final CoachDocFetcher fetchDoc;

  /// Optional ledger-meta reader (engine builds pass repo.metaGet).
  /// Feeds the video-RPE calibration section; null = section omitted.
  final Future<String?> Function(String key)? metaGet;

  /// Injectable clock for tests.
  final DateTime Function() now;

  CoachBrain({
    required this.model,
    required this.repository,
    required this.views,
    required this.fetchDoc,
    this.readOnlyRepo,
    this.metaGet,
    this.now = DateTime.now,
  });

  /// Builds a [CoachDocFetcher] over the configured GitHub repo. Null
  /// config (no `github:` block) → a fetcher that always misses, which
  /// surfaces as the "coach docs unavailable" fallback note.
  static CoachDocFetcher githubFetcher(GithubConfig? config) {
    if (config == null) return (_) async => null;
    final client = GithubClient(config);
    return (path) async => (await client.readFile(path))?.content;
  }

  /// One full reply turn on the ChatRunner tool loop: system prompt =
  /// docs + ledger dump; the thread history rides in a single user
  /// turn (keeps Anthropic's user-first/alternation rules trivially
  /// satisfied). [onProposal] fires when the model calls
  /// propose_schedule — the caller persists the proposal row. Returns
  /// the assistant's text (all text blocks, tool-turn preambles
  /// included). Throws on API failure — the caller surfaces the error.
  ///
  /// Note: a proposal row may have been persisted (via [onProposal]) even
  /// if a later API call in the same turn fails — this partial side-effect
  /// is accepted.
  Future<String> reply(
    List<Record> history, {
    required ProposalSink onProposal,
    MovesProposalSink? onMovesProposal,
  }) {
    final userTurn = '## Chat history (oldest first)\n\n'
        '${renderHistory(history)}\n\n'
        'Reply to the newest user message(s) now.';
    return _runTurn(userTurn,
        onProposal: onProposal, onMovesProposal: onMovesProposal);
  }

  /// One app-initiated turn (no chat history) — e.g. the daily
  /// carryover check's "Missed work detected…" ask. Same system prompt
  /// and tools as [reply]; returns the assistant's text.
  Future<String> ask(
    String userMessage, {
    required ProposalSink onProposal,
    MovesProposalSink? onMovesProposal,
  }) =>
      _runTurn(userMessage,
          onProposal: onProposal, onMovesProposal: onMovesProposal);

  Future<String> _runTurn(
    String userTurn, {
    required ProposalSink onProposal,
    MovesProposalSink? onMovesProposal,
  }) async {
    final system = await buildSystemPrompt(now());
    final tools = CoachToolset(
      views: views,
      onProposal: onProposal,
      programDay: _programDayResolver,
      onMovesProposal: onMovesProposal,
      now: now,
      // propose_moves checks each item exists on its from_date.
      movesWeek: () async => (await weekStateLoader().load(now()))?.week,
    ).build();
    final runner = ChatRunner(model);
    final texts = <String>[];
    await for (final ev in runner.runStream(
      systemPrompt: system,
      initialConversation: [ChatTurn(role: 'user', content: userTurn)],
      tools: tools,
    )) {
      if (ev is TurnComplete) {
        for (final turn in ev.conversation) {
          if (turn.role != 'assistant') continue;
          final t = turn.text;
          if (t.isNotEmpty) texts.add(t);
        }
        if (ev.truncated) {
          texts.add('(reply cut short — tool loop hit its iteration cap)');
        }
      }
    }
    return texts.join('\n\n').trim();
  }

  /// Adapted from the schemas repo's coach/PROMPT.md, MODE: REPLY.
  static const systemPrompt = '''
MODE: REPLY

You are Robert's training coach, replying inside his phone's ledger app.
Below you are given a PROGRAM SLICE (the authoritative current-week
intent: block, week type, today's template, targets, and flag rules),
followed by his goals, metric definitions, and recent ledger data (last
28 days plus any planned future rows), and the coach-chat history. The
newest user message(s) in the history are unanswered — reply to them
conversationally as his coach, grounded in the ledger data, program
slice, and metric definitions.

(routine.md retired; the program slice above is authoritative)

Plain text, concise (this renders as a chat bubble on a phone). Light
markdown is fine — short lines, a few bullets. Do NOT output JSON in
your text.

You have tools. When he asks to plan or schedule a workout (or agrees
to a plan you suggested), use read_program_day to pull the program's
prescribed exercises + weights for that day, fill in concrete numbers
from the ledger data, and call propose_schedule — it shows him a card
with Schedule / Not now buttons. Never claim something is scheduled;
the card handles confirmation. Follow the program slice's weekly
template and carryover rule; state your reasoning in one line. If he
asks to change goals or
routine, describe the change and note that editing coach/*.yaml happens
in a desktop Claude session — you cannot edit files from here.''';

  /// System-prompt half: instructions, TODAY, program slice, coach docs,
  /// ledger dump. The program slice is injected BEFORE the docs so the LLM
  /// sees current intent first. Falls back gracefully when YAML is missing.
  Future<String> buildSystemPrompt(DateTime today) async {
    final sliceSection = await _programSliceSection(today);
    final docs = await _docsSection();
    final dump = await _ledgerDump(today);
    final activity = await _activitySection(today);
    final movesSection = await _movesSection(today);
    final videoRpe = await _videoRpeSection();
    final sections = [
      systemPrompt,
      'TODAY: ${_fmtDate(today)}',
      ?sliceSection,
      '## Coach docs\n\n$docs',
      '## Ledger data (last ${dumpWindow.inDays} days + planned)\n\n$dump',
      ?activity,
      ?movesSection,
      ?videoRpe,
    ];
    return sections.join('\n\n');
  }

  /// Full single-string prompt (system half + history). Kept for tests
  /// and prompt inspection; [reply] sends the halves separately.
  Future<String> buildPrompt(List<Record> history) async {
    final system = await buildSystemPrompt(now());
    return [
      system,
      '## Chat history (oldest first)\n\n${renderHistory(history)}',
      'Reply to the newest user message(s) now.',
    ].join('\n\n');
  }

  /// Fetches program.yaml, phase.yaml, strategy.yaml (via [ProgramProvider]
  /// with 1 h caching), runs the Dart resolver, and returns the rendered
  /// program slice section. Returns null on any failure so the caller can
  /// fall back to current behaviour including routine.md.
  Future<String?> _programSliceSection(DateTime today) async {
    try {
      final provider = ProgramProvider(fetchDoc, now: now);
      final docs = await provider.load();

      final programYaml = docs.program;
      if (programYaml == null) return null;

      final phaseYaml = docs.phase;
      final strategyYaml = docs.strategy;

      final slice = programCurrent(programYaml, phaseYaml, today);
      if (slice == null) return null;

      final phase = phaseYaml != null ? currentVersion(phaseYaml) : null;
      final strategy =
          strategyYaml != null ? currentVersion(strategyYaml) : null;

      final rendered =
          renderProgramSlice(slice, phase: phase, strategy: strategy);
      return rendered;
    } catch (_) {
      // Any parse/resolve failure → fall back gracefully.
      return null;
    }
  }

  /// Resolves the program's PRESCRIBED rows for [view] on [date] — the
  /// same planned entries the routine screen + timeline show, built from
  /// the program's routine week via [buildWeekPlannedEntries]. Feeds the
  /// coach's `read_program_day` tool so proposals mirror the actual
  /// program day (by weekday) instead of a static template.
  ///
  /// Only `strength` yields planner rows (the planner emits strength
  /// entries; cardio/climbing are prose in the program slice already in
  /// the prompt) — other views return an empty list. Weights are priced
  /// from the program's rep/%-based fill; the working-max tab isn't read
  /// here, so main-lift working weights may be absent — the coach fills
  /// concrete numbers from the ledger data in its prompt.
  Future<List<Map<String, Object?>>> _programDayResolver(
    String view,
    DateTime date,
  ) async {
    if (view != 'strength') return const [];
    final provider = ProgramProvider(fetchDoc, now: now);
    final docs = await provider.load();
    final programYaml = docs.program;
    if (programYaml == null) return const [];
    final entries = buildWeekPlannedEntries(
      programYaml,
      date,
      snapToWeekStart: false,
    );
    final dayUtc = DateTime.utc(date.year, date.month, date.day);
    // Keep only rows for the requested day; strip the internal `date`
    // marker (the proposal carries the date at the top level) and the
    // routine-screen-only display markers.
    final out = <Map<String, Object?>>[];
    for (final e in entries) {
      final d = e['date'];
      if (d is! DateTime) continue;
      if (DateTime.utc(d.year, d.month, d.day) != dayUtc) continue;
      final row = Map<String, Object?>.from(e)
        ..remove('date')
        ..remove('top')
        ..remove('reps_hi')
        ..remove('pct');
      out.add(row);
    }
    return out;
  }

  /// "Activity (Whoop)" section: every Whoop workout in the last 14 days
  /// (local time), flagged `[unlogged]` when nothing else in the app
  /// records it — so the coach knows a climb/run/hike happened even with
  /// no Kaya export or manual log. Null when there are no activities.
  static String? renderActivitySection({
    required List<WhoopActivity> activities,
    required Set<DateTime> strengthDays,
    required Set<DateTime> climbDays,
    required DateTime today,
    Set<DateTime> cardioDays = const {},
  }) {
    final from = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 13));
    final lines = <String>[];
    for (final a in activities) {
      if (a.date.isBefore(from)) continue;
      final d = '${a.date.year}-${a.date.month.toString().padLeft(2, '0')}-'
          '${a.date.day.toString().padLeft(2, '0')}';
      final t = a.start == null
          ? ''
          : ' ${a.start!.hour.toString().padLeft(2, '0')}:'
              '${a.start!.minute.toString().padLeft(2, '0')}';
      final parts = [
        '$d$t ${a.sport}',
        if (a.strain != null) 'strain ${a.strain!.toStringAsFixed(1)}',
        if (a.durationMin != null) '${a.durationMin!.round()} min',
        if (a.avgHr != null && a.maxHr != null)
          'HR ${a.avgHr!.round()}/${a.maxHr!.round()}',
      ];
      final flag = isUnlogged(
        a,
        strengthDays: strengthDays,
        climbDays: climbDays,
        cardioDays: cardioDays,
      )
          ? ' [unlogged]'
          : '';
      lines.add('- ${parts.join(' \u{b7} ')}$flag');
    }
    if (lines.isEmpty) return null;
    return '## Activity (Whoop, last 14 days)\n\n'
        'Whoop is the record that a session HAPPENED (+ strain 0-21). '
        '[unlogged] = no Kaya ascents / logged sets that day \u{2014} treat it as '
        'done, not missed.\n\n${lines.join('\n')}';
  }

  /// Loads today's Activity (Whoop) section: `whoop_workouts` rows +
  /// the strength/climbing days needed to flag `[unlogged]`. Null on any
  /// read failure or when `whoop_workouts` isn't a configured view (the
  /// section is simply omitted).
  Future<String?> _activitySection(DateTime today) async {
    final wv = views['whoop_workouts'];
    if (wv == null) return null;
    try {
      final acts = whoopActivitiesFromRecords(await repository.list(wv));
      DateTime? d(Object? v) =>
          v is DateTime ? v : DateTime.tryParse(v?.toString() ?? '');
      Future<Set<DateTime>> days(String name) async {
        final v = views[name];
        if (v == null) return {};
        final repo = v.readOnly ? readOnlyRepo : repository;
        if (repo == null) return {};
        return {
          for (final r in await repo.list(v))
            if (d(r['date']) case final x?) DateTime(x.year, x.month, x.day),
        };
      }

      // I1: a Whoop climb on day D counts as logged when Kaya has D OR
      // D+1 — Kaya's export date can be the UTC date, so an evening
      // local-day session can land a day late in the export. Expand
      // each Kaya day k to {k, k-1} so a Whoop climb on k-1 matches.
      final kayaDays = await days('climbing');
      final expandedClimbDays = <DateTime>{
        for (final k in kayaDays) ...[k, k.subtract(const Duration(days: 1))],
      };

      return renderActivitySection(
        activities: acts,
        strengthDays: await days('strength'),
        climbDays: expandedClimbDays,
        cardioDays: await days('cardio'),
        today: today,
      );
    } catch (_) {
      return null;
    }
  }

  /// Placement rules for carried work (spec 2026-10-02 §6) — the same
  /// wording as coach/PROMPT.md's nightly "Missed work" section.
  static const placementRules =
      'Within this week only · no lifting on Tuesday (program says "NO '
      'lifting today, ever") · squat and deadlift never on the same day · '
      'at most one carried MAIN lift per day · mains before accessories; '
      "if it can't all fit, accessories expire first · never on a day with "
      'a pain flag in daily_notes · respect low recovery (Whoop recovery < '
      "34 → don't add load that day) · state the reasoning in one line.";

  /// "## This week: moves + missed work": active moves, the missed list
  /// (each item followed by the exact item/from_date/period keys
  /// propose_moves must copy — tool/missed_work.dart's format), what each
  /// remaining day holds (moves applied), the placement rules and the
  /// propose_moves instruction. Pure.
  static String renderMovesSection({
    required Map<String, ProgramMove> moves,
    required MissedWork? missed,
    required Map<DateTime, List<EffectiveItem>> week,
    required DateTime today,
    Map<String, ProgramMove> skips = const {},
  }) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    String label(DateTime d) => '${wd[d.weekday - 1]} ${d.month}/${d.day}';
    final t = DateTime(today.year, today.month, today.day);
    final mon = mondayOf(t);
    final sun = DateTime(mon.year, mon.month, mon.day + 6);
    final b = StringBuffer()
      ..writeln('## This week: moves + missed work')
      ..writeln()
      ..writeln('Week ${label(mon)} – ${label(sun)} (Mon–Sun). Unplaced '
          'work expires at the end of Sunday; next week starts clean.')
      ..writeln()
      ..writeln('MOVES THIS WEEK:');
    if (moves.isEmpty) {
      b.writeln('none');
    } else {
      final ms = moves.values.toList()
        ..sort((a, c) => a.from.compareTo(c.from));
      for (final m in ms) {
        final src = m.source.isEmpty ? '' : ' (${m.source})';
        final note = m.note.isEmpty ? '' : ' — ${m.note}';
        b.writeln('- ${m.item}: ${label(m.from)} → ${label(m.to)}$src$note');
      }
    }
    b
      ..writeln()
      ..writeln('MISSED THIS WEEK:');
    if (missed == null) {
      b.writeln('(unknown — no strength log available)');
    } else if (missed.isEmpty) {
      b.writeln('none');
    } else {
      final lines = missed.toPromptLines().split('\n');
      for (var i = 0; i < missed.missed.length; i++) {
        final m = missed.missed[i];
        final moved =
            m.day == m.home ? '' : ' (moved from ${label(m.home)})';
        b
          ..writeln('${lines[i]}$moved')
          ..writeln('    item="${m.item.name}" from_date=${_fmtDate(m.home)} '
              'period=${m.item.period.isEmpty ? '-' : m.item.period}');
      }
    }
    b
      ..writeln()
      ..writeln('SKIPPED THIS WEEK:');
    b.writeln(skippedLines(skips));
    b
      ..writeln()
      ..writeln('REMAINING DAYS:');
    for (var d = t; !d.isAfter(sun); d = DateTime(d.year, d.month, d.day + 1)) {
      final items = [
        for (final e in week[d] ?? const <EffectiveItem>[])
          if (!e.isGhost) e,
      ];
      if (items.isEmpty) {
        b.writeln('- ${label(d)}: rest / nothing prescribed');
        continue;
      }
      String from(EffectiveItem e) => e.movedFrom == null
          ? ''
          : ' (moved from ${wd[e.movedFrom!.weekday - 1]})';
      String skipped(EffectiveItem e) {
        final s = skips[skipKey(d, e.item.name)];
        return s == null ? '' : ' (SKIPPED${s.note.isEmpty ? '' : ': ${s.note}'})';
      }
      final parts = [
        for (final e in items)
          '${e.item.period.isEmpty ? '' : '${e.item.period} '}'
              '${e.item.name}${from(e)}${skipped(e)}',
      ];
      b.writeln('- ${label(d)}: ${parts.join('; ')}');
    }
    b
      ..writeln()
      ..writeln('Placement rules (you decide within them): $placementRules')
      ..writeln('Only move an item to a day in REMAINING DAYS (never the '
          'past, never next week). Copy item / from_date / period EXACTLY '
          'from the missed line (from_date is the program\'s original day, '
          'even if the item was already moved once). One entry per item; '
          'items you let expire are simply left out (say so).')
      ..writeln('SKIPPED items were skipped on purpose by the user, with the '
          'stated reason — they are NOT missed: never re-propose them as '
          'moves; weigh the reason (pain/fatigue → adjust load or recovery '
          'advice, time/equipment → no action needed).')
      ..write('When something is missed, call propose_moves — never claim '
          "it's moved; the card handles it.");
    return b.toString();
  }

  /// Loads the effective week + missed work through the shared
  /// [WeekStateLoader] and renders [renderMovesSection]. Null (section
  /// omitted) on any failure or when there's no program.
  Future<String?> _movesSection(DateTime today) async {
    try {
      final state = await weekStateLoader().load(today, withMissed: true);
      if (state == null) return null;
      return renderMovesSection(
        moves: state.moves,
        skips: state.skips,
        missed: state.missed,
        week: state.week,
        today: today,
      );
    } catch (_) {
      return null;
    }
  }

  /// A [WeekStateLoader] over this brain's views + repos (read-only views
  /// such as climbing ride [readOnlyRepo]). Missing views are skipped.
  WeekStateLoader weekStateLoader() {
    WarehouseConnector? repoFor(ViewSchema? v) =>
        v == null ? null : (v.readOnly ? readOnlyRepo : repository);
    final moves = views['program_moves'];
    final strength = views['strength'];
    final workouts = views['whoop_workouts'];
    final cardio = views['cardio'];
    final climbing = views['climbing'];
    final calisthenics = views['calisthenics'];
    return WeekStateLoader(
      loadDocs: ProgramProvider(fetchDoc, now: now).load,
      programMovesView: moves,
      programMovesRepo: repoFor(moves),
      strengthView: strength,
      strengthRepo: repoFor(strength),
      workoutsView: workouts,
      workoutsRepo: repoFor(workouts),
      cardioView: cardio,
      cardioRepo: repoFor(cardio),
      climbingView: climbing,
      climbingRepo: repoFor(climbing),
      calisthenicsView: calisthenics,
      calisthenicsRepo: repoFor(calisthenics),
    );
  }

  /// AI-vs-logged RPE calibration lines from meta `video_rpe_log`
  /// (written by VideoRpeService at estimate/save time). Null (section
  /// omitted) when there's no meta seam, no log, or any read error.
  Future<String?> _videoRpeSection() async {
    final get = metaGet;
    if (get == null) return null;
    try {
      final rendered = renderVideoRpeLog(
        await get(VideoRpeService.kLogMetaKey),
      );
      if (rendered == null) return null;
      return '## Video RPE estimates (AI vs logged — calibration)\n\n'
          '$rendered';
    } catch (_) {
      return null;
    }
  }

  /// Fetches (or serves cached) coach docs. Docs that fail to fetch are
  /// skipped; if none survive, a one-line fallback note stands in.
  Future<String> _docsSection() async {
    final parts = <String>[];
    for (final path in docPaths) {
      final at = now();
      final cached = _docCache[path];
      String? content;
      if (cached != null && at.difference(cached.at) < docCacheTtl) {
        content = cached.content;
      } else {
        try {
          content = await fetchDoc(path);
        } catch (_) {
          content = null;
        }
        if (content != null) _docCache[path] = (at: at, content: content);
      }
      if (content != null) parts.add('### $path\n\n${content.trim()}');
    }
    if (parts.isEmpty) {
      return 'coach docs unavailable — advise from ledger data only';
    }
    return parts.join('\n\n');
  }

  Future<String> _ledgerDump(DateTime today) async {
    final sections = <String>[];
    for (final name in dumpViews) {
      final view = views[name];
      if (view == null) continue;
      // Read-only views (climbing/kaya_ascents) live only in the sheet,
      // never the local engine — list them through the direct-sheet
      // repo, matching the dashboard's readOnlyRepo path.
      final repo = view.readOnly ? readOnlyRepo : repository;
      if (repo == null) continue; // read-only view, no direct-sheet repo
      List<Record> rows;
      try {
        rows = await repo.list(view);
      } catch (_) {
        continue; // view exists but isn't listable here — skip
      }
      sections.add('### $name\n\n${renderTable(view, rows, today: today)}');
    }
    return sections.isEmpty ? '(no ledger data available)' : sections.join('\n\n');
  }

  /// Renders [rows] as a compact markdown table: schema dimensions as
  /// columns (id skipped), rows within [dumpWindow] of [today] (future
  /// kept), capped to the most recent [maxRows], oldest first.
  static String renderTable(
    ViewSchema view,
    List<Record> rows, {
    required DateTime today,
    int maxRows = maxRowsPerView,
  }) {
    final cols = [
      for (final d in view.dimensions)
        if (d.name != 'id') d.name,
    ];
    if (cols.isEmpty) return '(no columns)';
    final dateCol = view.dateField ?? (cols.contains('date') ? 'date' : null);
    final cutoff = today.subtract(dumpWindow);

    var kept = rows;
    if (dateCol != null) {
      kept = [
        for (final r in rows)
          if (_dateOf(r[dateCol]) case final d? when !d.isBefore(cutoff)) r,
      ];
      kept.sort((a, b) {
        final da = _dateOf(a[dateCol]);
        final db = _dateOf(b[dateCol]);
        if (da == null || db == null) return 0;
        return da.compareTo(db);
      });
    }
    if (kept.length > maxRows) {
      kept = kept.sublist(kept.length - maxRows); // most recent
    }
    if (kept.isEmpty) return '(no rows)';

    final buf = StringBuffer()
      ..writeln('| ${cols.join(' | ')} |')
      ..writeln('| ${cols.map((_) => '---').join(' | ')} |');
    for (final r in kept) {
      buf.writeln('| ${cols.map((c) => _fmtCell(r[c])).join(' | ')} |');
    }
    return buf.toString().trimRight();
  }

  /// Renders chat history as `[role] text` lines, sorted by `ts`
  /// ascending, capped to the most recent [maxMessages]. Proposal rows
  /// (`kind == 'proposal'`) are rendered compactly; malformed payloads
  /// fall back to the raw text.
  static String renderHistory(
    List<Record> history, {
    int maxMessages = maxHistoryMessages,
  }) {
    final sorted = List<Record>.of(history)
      ..sort((a, b) =>
          (a['ts']?.toString() ?? '').compareTo(b['ts']?.toString() ?? ''));
    final kept = sorted.length > maxMessages
        ? sorted.sublist(sorted.length - maxMessages)
        : sorted;
    if (kept.isEmpty) return '(no messages)';
    return kept.map((r) {
      final role = r['role']?.toString() ?? '?';
      final text = r['text']?.toString() ?? '';
      if (r['kind']?.toString() == 'proposal') {
        final p = CoachProposal.tryParse(text);
        if (p != null) {
          final dateStr = _fmtDate(p.date);
          final detail = p.summary.isEmpty
              ? '${p.entries.length} entries'
              : p.summary;
          return '[$role] (proposed ${p.view} plan for $dateStr: $detail)';
        }
        final mp = MovesProposal.tryParse(text);
        if (mp != null) {
          final moves = [
            for (final m in mp.moves)
              '${m.item} ${_fmtDate(m.from)} → ${_fmtDate(m.to)}',
          ].join('; ');
          return '[$role] (proposed moves: $moves)';
        }
      }
      return '[$role] $text';
    }).join('\n');
  }

  static DateTime? _dateOf(Object? v) {
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _fmtCell(Object? v) {
    if (v == null) return '';
    if (v is DateTime) {
      // Date dims come back as midnight DateTimes — render date-only.
      final dateOnly = v.hour == 0 && v.minute == 0 && v.second == 0;
      return dateOnly ? _fmtDate(v) : v.toIso8601String();
    }
    if (v is num) {
      final s = v.toString();
      return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    }
    // Keep the table one-line-per-row: collapse newlines, escape pipes.
    return v.toString().replaceAll('\n', ' ').replaceAll('|', r'\|').trim();
  }
}
