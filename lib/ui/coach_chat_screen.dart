import 'dart:async';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../models/view_schema.dart';
import '../services/sheets_repository.dart' show Record;
import '../services/sync_scheduler.dart';
import '../services/warehouse_connector.dart';

/// Ledger meta key: `ts` of the newest coach message the user has seen.
/// Device-local (meta never syncs). Read by the home screen's Coach row
/// for its unread state; written here whenever a coach message renders.
const kCoachChatLastReadTsKey = 'coach_chat_last_read_ts';

/// Chat surface over the synced `coach_chat` view. Coach messages
/// (written by the Mac-side relay) render left; user messages right.
/// Sending appends a `role=user, kind=user` row via the normal
/// repository create and triggers a manual sync; replies arrive via the
/// relay within a couple of minutes, picked up by the sync listener +
/// a 30 s poll while the screen is open.
class CoachChatScreen extends StatefulWidget {
  final ViewSchema view;
  final WarehouseConnector repository;

  /// Ledger meta access for the read marker. Null when the build isn't
  /// local-first — mark-read becomes a no-op.
  final EngineLedgerRepository? ledger;

  const CoachChatScreen({
    super.key,
    required this.view,
    required this.repository,
    this.ledger,
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
      final rows = await widget.repository.list(widget.view);
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

  /// Writes the newest rendered coach `ts` to ledger meta so the home
  /// row's unread accent clears. Best-effort + deduped.
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
      await ledger.metaSet(kCoachChatLastReadTsKey, newest);
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
      // Push the message toward the Mac relay right away (bypasses the
      // wifi-only gate — explicit user intent).
      unawaited(SyncScheduler.instance?.maybeSync(manual: true));
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

  bool get _awaitingReply =>
      _messages.isNotEmpty && !_isCoach(_messages.last) &&
      _messages.last['role']?.toString() == 'user';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Coach'),
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
          if (_awaitingReply)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'coach replies in a minute or two (Mac relay)',
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
/// primary-tinted. Plain selectable text + a small time label — no
/// markdown, by design (keep the widget lean).
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
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color:
                isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              SelectableText(text),
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
