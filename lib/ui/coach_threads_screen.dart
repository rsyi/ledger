import 'dart:async';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/view_schema.dart';
import '../services/coach_brain.dart';
import '../services/sheets_repository.dart' show Record;
import '../services/sync_scheduler.dart';
import '../services/warehouse_connector.dart';
import 'coach_chat_screen.dart';

/// The route that opens the threads list. The screen is its own
/// Scaffold with the one app bar (back + "+" new thread) — never wrap it
/// in another Scaffold/AppBar.
Route<void> coachThreadsRoute(CoachThreadsScreen screen) =>
    MaterialPageRoute<void>(builder: (_) => screen);

/// Thread list over the synced `coach_chat` view: rows grouped by their
/// `thread` dimension (blank = the pre-threads `general` history), one
/// tile per thread with title, last-message preview, relative time, and
/// an unread dot (newest coach `ts` vs the thread's device-local read
/// marker). "Daily briefings" pins first; the rest sort by latest
/// activity. The app-bar "+" opens a chat for a fresh `t-xxxxxxxx` id —
/// the thread only exists once its first message is sent. Refreshes on
/// return from a chat and when a background sync completes.
///
/// Long-press a tile to delete its thread (confirm dialog → every
/// coach_chat row with that thread id is engine-tombstoned via
/// repository.delete, so the sheet rows disappear on next sync).
/// Long-press is the timeline's destructive idiom, and the trailing
/// slot already carries the unread dot + chevron.
class CoachThreadsScreen extends StatefulWidget {
  final ViewSchema view;
  final WarehouseConnector repository;

  /// Ledger meta access for read markers. Null when the build isn't
  /// local-first — every thread with a coach message shows unread.
  final EngineLedgerRepository? ledger;

  /// Passed through to the chat screen for in-app replies.
  final CoachBrain? brain;

  /// Passed through to the chat screen so proposal cards can open a
  /// timeline after scheduling. Null → Schedule shows a snackbar.
  final CoachTimelineOpener? openTimeline;

  /// Passed through to [CoachChatScreen] (moves proposals → program_moves).
  final ViewSchema? programMovesView;
  final WarehouseConnector? programMovesRepository;

  const CoachThreadsScreen({
    super.key,
    required this.view,
    required this.repository,
    this.ledger,
    this.brain,
    this.openTimeline,
    this.programMovesView,
    this.programMovesRepository,
  });

  @override
  State<CoachThreadsScreen> createState() => _CoachThreadsScreenState();
}

/// One thread's derived tile state.
class _ThreadInfo {
  final String id;
  final String title;
  final String preview;
  final String? lastTs;
  final bool unread;

  const _ThreadInfo({
    required this.id,
    required this.title,
    required this.preview,
    required this.lastTs,
    required this.unread,
  });
}

class _CoachThreadsScreenState extends State<CoachThreadsScreen> {
  List<_ThreadInfo> _threads = const [];
  bool _loaded = false;
  String? _error;
  Timer? _poll;
  ValueListenable<bool>? _syncing;

  /// Thread ids mid-delete: their tiles show a spinner and ignore taps.
  final Set<String> _deleting = {};

  @override
  void initState() {
    super.initState();
    _load();
    // Same refresh pattern as the chat screen: re-list when a sync
    // completes (a nightly briefing may have landed) + a 30 s poll
    // while the screen is visible.
    _syncing = SyncScheduler.instance?.syncing;
    _syncing?.addListener(_onSyncStateChanged);
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _syncing?.removeListener(_onSyncStateChanged);
    super.dispose();
  }

  void _onSyncStateChanged() {
    if (_syncing?.value == false) _load();
  }

  static String _firstLine(String text, {int max = 80}) {
    final stripped = stripMarkdownPreview(text);
    final line = stripped.trimLeft().split('\n').first.trim();
    return line.length > max ? '${line.substring(0, max)}…' : line;
  }

  static String? _relativeTime(String? ts) {
    final dt = ts == null ? null : DateTime.tryParse(ts);
    if (dt == null) return null;
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays}d ago';
  }

  /// Display title for a thread's ts-sorted messages: fixed names for
  /// the two well-known ids, else the first line of the thread's first
  /// user message (fallback: first message of any role).
  static String _titleFor(String id, List<Record> sorted) {
    if (id == kCoachThreadBriefings) return 'Daily briefings';
    if (id == kCoachThreadGeneral) return 'General';
    final first = sorted.firstWhere(
      (r) => r['role']?.toString() == 'user',
      orElse: () => sorted.first,
    );
    final line = _firstLine(first['text']?.toString() ?? '', max: 40);
    return line.isEmpty ? id : line;
  }

  Future<void> _load() async {
    try {
      final rows = await widget.repository.list(widget.view);
      final byThread = <String, List<Record>>{};
      for (final r in rows) {
        byThread.putIfAbsent(coachThreadOf(r), () => []).add(r);
      }
      final threads = <_ThreadInfo>[];
      for (final entry in byThread.entries) {
        final msgs = entry.value
          // ISO `ts` strings — lexicographic compare is chronological.
          ..sort((a, b) => (a['ts']?.toString() ?? '')
              .compareTo(b['ts']?.toString() ?? ''));
        String? newestCoachTs;
        for (final m in msgs) {
          if (m['role']?.toString() != 'coach') continue;
          final ts = m['ts']?.toString();
          if (ts == null || ts.isEmpty) continue;
          if (newestCoachTs == null || ts.compareTo(newestCoachTs) > 0) {
            newestCoachTs = ts;
          }
        }
        var unread = false;
        if (newestCoachTs != null) {
          // Missing/unreadable marker → unread (a coach message exists
          // the user has provably never opened on this device).
          String? lastRead;
          if (widget.ledger != null) {
            try {
              lastRead =
                  await coachThreadLastRead(widget.ledger!, entry.key);
            } catch (_) {/* treat as missing */}
          }
          unread = lastRead == null ||
              lastRead.isEmpty ||
              newestCoachTs.compareTo(lastRead) > 0;
        }
        threads.add(_ThreadInfo(
          id: entry.key,
          title: _titleFor(entry.key, msgs),
          preview: _firstLine(msgs.last['text']?.toString() ?? ''),
          lastTs: msgs.last['ts']?.toString(),
          unread: unread,
        ));
      }
      // Briefings pins first; everything else by latest activity desc.
      threads.sort((a, b) {
        if (a.id == kCoachThreadBriefings) return -1;
        if (b.id == kCoachThreadBriefings) return 1;
        return (b.lastTs ?? '').compareTo(a.lastTs ?? '');
      });
      if (!mounted) return;
      setState(() {
        _threads = threads;
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (!_loaded) _error = e.toString();
      });
    }
  }

  Future<void> _openThread(String threadId, String title) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CoachChatScreen(
          view: widget.view,
          repository: widget.repository,
          threadId: threadId,
          title: title,
          ledger: widget.ledger,
          brain: widget.brain,
          openTimeline: widget.openTimeline,
          programMovesView: widget.programMovesView,
          programMovesRepository: widget.programMovesRepository,
        ),
      ),
    );
    // The chat marks its thread read (and the user may have sent a
    // message) — refresh tiles on return.
    if (mounted) _load();
  }

  /// Fresh thread id; the thread persists only once its first message
  /// row is created, so backing out of an empty chat leaves no trace.
  void _newThread() {
    final id = 't-${const Uuid().v4().replaceAll('-', '').substring(0, 8)}';
    _openThread(id, 'New thread');
  }

  /// Confirm-then-delete every row in [t]'s thread. Blank-`thread` rows
  /// belong to `general` (coachThreadOf), so deleting General removes
  /// the pre-threads history too. Rows delete sequentially through the
  /// normal repository API — the engine tombstones each one and the
  /// next sync removes them from the sheet; a failure mid-loop leaves a
  /// partial thread, surfaced by the refresh + snackbar below.
  Future<void> _deleteThread(_ThreadInfo t) async {
    final List<Record> rows;
    try {
      final all = await widget.repository.list(widget.view);
      rows = all.where((r) => coachThreadOf(r) == t.id).toList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      return;
    }
    if (rows.isEmpty) {
      // Already gone (deleted elsewhere / synced away) — just refresh.
      _load();
      return;
    }
    if (!mounted) return;
    final n = rows.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this thread?'),
        content: Text(
          'Its $n message${n == 1 ? ' is' : 's are'} removed from the '
          'ledger and the sheet on next sync.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _deleting.add(t.id));
    try {
      // Sequential on purpose: briefings can hold months of daily rows
      // and the engine store serializes writes anyway.
      for (final r in rows) {
        await widget.repository.delete(widget.view, r);
      }
      // Same post-write trigger as sends — push the tombstones out.
      unawaited(SyncScheduler.instance?.maybeSync(manual: true));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e — refreshing')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deleting.remove(t.id));
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Coach'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _newThread,
            tooltip: 'New thread',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final scheme = Theme.of(context).colorScheme;
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
    if (_threads.isEmpty) {
      return Center(
        child: Text(
          'No threads yet.\nTap + to start one.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: _threads.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final t = _threads[i];
        final deleting = _deleting.contains(t.id);
        final rel = _relativeTime(t.lastTs);
        final subtitle = [t.preview, ?rel]
            .where((s) => s.isNotEmpty)
            .join(' · ');
        return ListTile(
          enabled: !deleting,
          title: Text(
            t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: t.unread ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (t.unread && !deleting)
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              if (deleting)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.chevron_right),
            ],
          ),
          onTap: deleting ? null : () => _openThread(t.id, t.title),
          onLongPress: deleting ? null : () => _deleteThread(t),
        );
      },
    );
  }
}
