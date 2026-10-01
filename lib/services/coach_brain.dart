import '../models/coach_proposal.dart';
import '../models/github_config.dart';
import '../models/model_config.dart';
import '../models/view_schema.dart';
import 'chat_runner.dart';
import 'coach_tools.dart';
import 'github_client.dart';
import 'program_current.dart';
import 'program_provider.dart';
import 'program_slice_text.dart';
import 'video_rpe.dart';
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';
import 'week_planner.dart' show buildWeekPlannedEntries;

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
  /// sleep/HRV/recovery), meals (Macrofactor macros), and climbing (Kaya
  /// ascents). Integration/read-only views (climbing) list through the
  /// direct-sheet [readOnlyRepo]; the rest ride the local-first
  /// [repository]. All are windowed + row-capped by [renderTable], so
  /// even climbing's ~1.4k rows shrink to ≤200 of the last 28 days.
  static const dumpViews = [
    'strength',
    'cardio',
    'weight',
    'daily_notes',
    'recovery',
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
  }) async {
    final system = await buildSystemPrompt(now());
    final userTurn = '## Chat history (oldest first)\n\n'
        '${renderHistory(history)}\n\n'
        'Reply to the newest user message(s) now.';
    final tools = CoachToolset(
      views: views,
      onProposal: onProposal,
      programDay: _programDayResolver,
      now: now,
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
    final videoRpe = await _videoRpeSection();
    final sections = [
      systemPrompt,
      'TODAY: ${_fmtDate(today)}',
      ?sliceSection,
      '## Coach docs\n\n$docs',
      '## Ledger data (last ${dumpWindow.inDays} days + planned)\n\n$dump',
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
