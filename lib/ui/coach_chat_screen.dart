import 'dart:async';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../models/view_schema.dart';
import '../services/coach_brain.dart';
import '../services/sheets_repository.dart' show Record;
import '../services/sync_scheduler.dart';
import '../services/warehouse_connector.dart';

/// Legacy (pre-threads) meta key: `ts` of the newest coach message the
/// user has seen. Still consulted as the fallback for the `general`
/// thread so upgrades don't resurface old messages as unread.
const kCoachChatLastReadTsKey = 'coach_chat_last_read_ts';

/// Thread id rows with a blank `thread` dimension belong to (the
/// pre-threads history).
const kCoachThreadGeneral = 'general';

/// Fixed thread id the nightly briefings post into.
const kCoachThreadBriefings = 'briefings';

/// A row's thread id — blank/missing `thread` counts as [kCoachThreadGeneral].
String coachThreadOf(Record r) {
  final t = r['thread']?.toString().trim();
  return (t == null || t.isEmpty) ? kCoachThreadGeneral : t;
}

/// Per-thread read-marker meta key (device-local; meta never syncs).
String coachThreadReadKey(String threadId) => 'coach_chat_last_read_$threadId';

/// Reads a thread's read marker. For `general`, falls back to the
/// legacy single-chat key when the per-thread key is absent, so the
/// upgrade doesn't flag already-seen history as unread. Null/empty →
/// never read on this device.
Future<String?> coachThreadLastRead(
    EngineLedgerRepository ledger, String threadId) async {
  final v = await ledger.metaGet(coachThreadReadKey(threadId));
  if (v != null && v.isNotEmpty) return v;
  if (threadId == kCoachThreadGeneral) {
    return ledger.metaGet(kCoachChatLastReadTsKey);
  }
  return null;
}

/// Strips lightweight markdown syntax from a one-line preview string so
/// raw `**bold**`, `*em*`, `### Header`, and `- list` markers don't
/// appear as literal punctuation in thread-list tiles and the home row.
/// Not a full parser — just enough to clean the common LLM patterns.
String stripMarkdownPreview(String text) {
  var s = text;
  // Remove leading heading markers (#+ followed by space)
  s = s.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
  // Remove leading list marker ("- " or "* " at start)
  s = s.replaceAll(RegExp(r'^[*-]\s+', multiLine: true), '');
  // Remove bold/italic markers (**word**, *word*, __word__, _word_)
  s = s.replaceAll(RegExp(r'\*{1,2}([^*]+)\*{1,2}'), r'$1');
  s = s.replaceAll(RegExp(r'_{1,2}([^_]+)_{1,2}'), r'$1');
  return s.trim();
}

/// Chat surface over one thread of the synced `coach_chat` view. Coach
/// messages render left; user messages right. Sending appends a
/// `role=user, kind=user` row (carrying [threadId]) via the normal
/// repository create, triggers a manual sync, and — when [brain] is
/// available — asks the in-app [CoachBrain] for a reply (LlmClient over
/// API credits), appending it as `role=coach, kind=reply` in the same
/// thread. The nightly Mac-side briefing still arrives through sync,
/// picked up by the sync listener + a 30 s poll while the screen is
/// open.
class CoachChatScreen extends StatefulWidget {
  final ViewSchema view;
  final WarehouseConnector repository;

  /// Thread this screen shows; rows are filtered to it (blank `thread`
  /// counts as `general`) and new rows are stamped with it.
  final String threadId;

  /// App-bar title — the thread's display title, derived by the
  /// threads list (or "New thread" before the first message).
  final String title;

  /// Ledger meta access for the read marker. Null when the build isn't
  /// local-first — mark-read becomes a no-op.
  final EngineLedgerRepository? ledger;

  /// In-app reply generator. Null when the build has LLM disabled
  /// (`disable_post_log:`) or no Anthropic model configured — sends
  /// still work, they just don't get an in-app reply.
  final CoachBrain? brain;

  const CoachChatScreen({
    super.key,
    required this.view,
    required this.repository,
    required this.threadId,
    required this.title,
    this.ledger,
    this.brain,
  });

  @override
  State<CoachChatScreen> createState() => _CoachChatScreenState();
}

class _CoachChatScreenState extends State<CoachChatScreen> {
  final _controller = TextEditingController();
  List<Record> _messages = const [];
  bool _loaded = false;
  String? _error;
  bool _sending = false;

  /// One in-flight coach reply at a time. A send while a reply is being
  /// generated just lands in history — the in-flight call sees it if it
  /// hasn't dispatched yet; otherwise the user can send again.
  bool _replying = false;

  Timer? _poll;
  ValueListenable<bool>? _syncing;

  /// Last value written to the read marker — avoids redundant meta
  /// writes on every poll tick.
  String? _markedReadTs;

  @override
  void initState() {
    super.initState();
    _load();
    // Re-list when a background sync completes (a coach reply may have
    // just landed) …
    _syncing = SyncScheduler.instance?.syncing;
    _syncing?.addListener(_onSyncStateChanged);
    // … and poll every 30 s while the screen is visible, so replies
    // show up even if no sync trigger fires.
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _syncing?.removeListener(_onSyncStateChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSyncStateChanged() {
    if (_syncing?.value == false) _load();
  }

  /// Parses a row's `ts` (ISO datetime string) for ordering/compare.
  static DateTime? _tsOf(Record r) {
    final v = r['ts'];
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  static bool _isCoach(Record r) => r['role']?.toString() == 'coach';

  Future<void> _load() async {
    try {
      final all = await widget.repository.list(widget.view);
      final rows =
          all.where((r) => coachThreadOf(r) == widget.threadId).toList();
      rows.sort((a, b) {
        final ta = _tsOf(a);
        final tb = _tsOf(b);
        if (ta == null && tb == null) return 0;
        if (ta == null) return -1;
        if (tb == null) return 1;
        return ta.compareTo(tb);
      });
      if (!mounted) return;
      setState(() {
        _messages = rows;
        _loaded = true;
        _error = null;
      });
      unawaited(_markRead());
    } catch (e) {
      if (!mounted) return;
      // Keep showing what we have; only surface the error when there's
      // nothing to show (schema/view not synced yet).
      setState(() {
        if (!_loaded) _error = e.toString();
      });
    }
  }

  /// Writes the newest rendered coach `ts` to this thread's read-marker
  /// meta so unread accents clear. Best-effort + deduped.
  Future<void> _markRead() async {
    final ledger = widget.ledger;
    if (ledger == null) return;
    String? newest;
    for (final m in _messages) {
      if (!_isCoach(m)) continue;
      final ts = m['ts']?.toString();
      if (ts == null || ts.isEmpty) continue;
      if (newest == null || ts.compareTo(newest) > 0) newest = ts;
    }
    if (newest == null || newest == _markedReadTs) return;
    try {
      await ledger.metaSet(coachThreadReadKey(widget.threadId), newest);
      _markedReadTs = newest;
    } catch (_) {/* retried on the next load */}
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    final now = DateTime.now();
    // Mirrors the form's date encoding: date dims are written as
    // midnight DateTimes, which the engine codec stores as a plain
    // `YYYY-MM-DD` date value.
    final record = <String, Object?>{
      'id': const Uuid().v4(),
      'date': DateTime(now.year, now.month, now.day),
      'ts': now.toIso8601String(),
      'role': 'user',
      'kind': 'user',
      'thread': widget.threadId,
      'text': text,
    };
    // Optimistic: show the bubble immediately; the ledger create is
    // local and near-instant anyway.
    setState(() {
      _messages = [..._messages, record];
      _sending = true;
      _controller.clear();
    });
    try {
      await widget.repository.create(widget.view, record);
      // Sync the message out right away (bypasses the wifi-only gate —
      // explicit user intent) …
      unawaited(SyncScheduler.instance?.maybeSync(manual: true));
      // … and generate the coach's reply in-app.
      unawaited(_requestReply());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
      );
      setState(() => _messages =
          _messages.where((m) => !identical(m, record)).toList());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Generates and appends the coach's reply for the current history.
  /// No-op without a brain (LLM disabled) or while a reply is already
  /// in flight. Errors surface as a snackbar; the user message stays.
  Future<void> _requestReply() async {
    final brain = widget.brain;
    if (brain == null || _replying) return;
    setState(() => _replying = true);
    try {
      final text = await brain.reply(List.of(_messages));
      final now = DateTime.now();
      final record = <String, Object?>{
        'id': const Uuid().v4(),
        'date': DateTime(now.year, now.month, now.day),
        'ts': now.toIso8601String(),
        'role': 'coach',
        'kind': 'reply',
        'thread': widget.threadId,
        'text': text,
      };
      await widget.repository.create(widget.view, record);
      await _load();
      // Push the reply toward the sheet so it shows up everywhere else.
      unawaited(SyncScheduler.instance?.maybeSync(manual: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Coach reply failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _replying = false);
    }
  }

  bool get _awaitingReply =>
      _messages.isNotEmpty && !_isCoach(_messages.last) &&
      _messages.last['role']?.toString() == 'user';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          if (_replying)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'coach is thinking…',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                  ),
                ],
              ),
            )
          else if (_awaitingReply && widget.brain == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'in-app coach replies need LLM enabled',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (!_loaded && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_loaded && _error != null) {
      // Schema/view not synced to this device yet (or the store is
      // unreachable). Friendly guard rather than a stack trace.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Coach chat isn\'t available yet.\n'
                'It appears after the next schema sync.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    // reverse:true keeps the list pinned to the newest message at the
    // bottom (index 0 renders bottom-most, so we index from the end).
    return ListView.separated(
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: _messages.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) =>
          _ChatBubble(msg: _messages[_messages.length - 1 - i]),
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Message the coach…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}

/// One message bubble. Coach → left, surface-variant; user → right,
/// primary-tinted. Coach messages render markdown via MarkdownBody;
/// user messages stay plain SelectableText.
class _ChatBubble extends StatelessWidget {
  final Record msg;
  const _ChatBubble({required this.msg});

  static String _timeLabel(Record msg) {
    final v = msg['ts'];
    final dt = v is DateTime ? v : DateTime.tryParse(v?.toString() ?? '');
    if (dt == null) return '';
    final now = DateTime.now();
    final sameDay = dt.year == now.year &&
        dt.month == now.month &&
        dt.day == now.day;
    return sameDay
        ? DateFormat('h:mm a').format(dt)
        : DateFormat('MMM d, h:mm a').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = msg['role']?.toString() == 'user';
    final text = msg['text']?.toString() ?? '';
    final time = _timeLabel(msg);
    final bubbleColor =
        isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final textColor =
        isUser ? scheme.onPrimaryContainer : scheme.onSurface;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (isUser)
                SelectableText(
                  text,
                  style: TextStyle(color: textColor),
                )
              else
                MarkdownBody(
                  data: text,
                  selectable: true,
                  styleSheet:
                      MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                    p: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: textColor),
                    strong: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.bold,
                        ),
                    em: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          fontStyle: FontStyle.italic,
                        ),
                    listBullet: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: textColor),
                    h1: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.bold,
                        ),
                    h2: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.bold,
                        ),
                    h3: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
              if (time.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    time,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
