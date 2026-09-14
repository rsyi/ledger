import '../models/github_config.dart';
import '../models/model_config.dart';
import '../models/view_schema.dart';
import 'chat_runner.dart';
import 'coach_tools.dart';
import 'github_client.dart';
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';

/// Fetches one coach doc by repo path (e.g. `coach/goals.md`). Returns
/// the file's contents, or null when the file doesn't exist. Throwing is
/// treated the same as null (doc unavailable).
typedef CoachDocFetcher = Future<String?> Function(String path);

/// Produces in-app coach replies via the API-credit LLM plumbing
/// ([LlmClient]) — no Mac relay involved. The nightly briefing still
/// arrives through the synced `coach_chat` view; this class only handles
/// the interactive turn: assemble context (coach docs from GitHub, a
/// recent-ledger dump, the current thread's chat history), send one
/// prompt, return the reply text. The caller appends the reply as a
/// `role=coach, kind=reply` row in the same thread.
class CoachBrain {
  /// Coach docs pulled from the schemas repo. Order matters — it's the
  /// order they appear in the prompt.
  static const docPaths = [
    'coach/goals.md',
    'coach/routine.md',
    'coach/metrics.md',
  ];

  /// Ledger views dumped into the prompt (those that exist).
  static const dumpViews = ['strength', 'cardio', 'weight', 'daily_notes'];

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

  /// Test hook — the doc cache is process-global.
  static void clearDocCache() => _docCache.clear();

  /// Anthropic model the reply turn runs on (ChatRunner requires
  /// anthropic vendor — home_screen's _chatModel already selects one).
  final ModelConfig model;

  /// Local-first ledger connector — [dumpViews] are listed through it.
  final WarehouseConnector repository;

  /// All loaded views by name; [dumpViews] absent from this map are
  /// silently skipped.
  final Map<String, ViewSchema> views;

  final CoachDocFetcher fetchDoc;

  /// Injectable clock for tests.
  final DateTime Function() now;

  CoachBrain({
    required this.model,
    required this.repository,
    required this.views,
    required this.fetchDoc,
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
  Future<String> reply(
    List<Record> history, {
    required ProposalSink onProposal,
  }) async {
    final system = await buildSystemPrompt(now());
    final userTurn = '## Chat history (oldest first)\n\n'
        '${renderHistory(history)}\n\n'
        'Reply to the newest user message(s) now.';
    final tools =
        CoachToolset(views: views, onProposal: onProposal, now: now).build();
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
      }
    }
    return texts.join('\n\n').trim();
  }

  /// Adapted from the schemas repo's coach/PROMPT.md, MODE: REPLY.
  static const systemPrompt = '''
MODE: REPLY

You are Robert's training coach, replying inside his phone's ledger app.
Below you are given his goals, weekly routine rules, and metric
definitions (the coach docs), a dump of recent ledger data (last 28 days
plus any planned future rows), and the coach-chat history. The newest
user message(s) in the history are unanswered — reply to them
conversationally as his coach, grounded in the ledger data, routine
rules, and metric definitions.

Plain text, concise (this renders as a chat bubble on a phone). Light
markdown is fine — short lines, a few bullets. Do NOT output JSON in
your text.

You have tools. When he asks to plan or schedule a workout (or agrees
to a plan you suggested), use list_templates / read_template to ground
the plan in a template, fill in concrete numbers from the ledger data,
and call propose_schedule — it shows him a card with Schedule / Not
now buttons. Never claim something is scheduled; the card handles
confirmation. Follow routine.md's carryover rule and state your
reasoning in one line. If he asks to change goals or routine, describe
the change and note that editing coach/*.md happens in a desktop
Claude session — you cannot edit files from here.''';

  /// System-prompt half: instructions, TODAY, coach docs, ledger dump.
  Future<String> buildSystemPrompt(DateTime today) async {
    final docs = await _docsSection();
    final dump = await _ledgerDump(today);
    return [
      systemPrompt,
      'TODAY: ${_fmtDate(today)}',
      '## Coach docs\n\n$docs',
      '## Ledger data (last ${dumpWindow.inDays} days + planned)\n\n$dump',
    ].join('\n\n');
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
      List<Record> rows;
      try {
        rows = await repository.list(view);
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
  /// ascending, capped to the most recent [maxMessages].
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
    return kept
        .map((r) =>
            '[${r['role']?.toString() ?? '?'}] ${r['text']?.toString() ?? ''}')
        .join('\n');
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
