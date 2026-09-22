import 'package:flutter/material.dart';

import '../models/github_config.dart';
import '../models/model_config.dart';
import '../services/analytics_engine.dart';
import '../services/chat_store.dart';
import '../services/github_client.dart';
import '../services/warehouse_connector.dart';
import 'chat_screen.dart';

/// Lists past chat sessions newest-first. Tap to resume; swipe-left to
/// delete. Opens with the same dependencies the parent screen already
/// has (model + github + repo + analytics) so resumed sessions get the
/// same tool set as fresh ones.
class ChatHistoryScreen extends StatefulWidget {
  final ModelConfig model;
  final GithubConfig? github;
  final WarehouseConnector? repository;
  final AnalyticsEngine? analytics;

  const ChatHistoryScreen({
    super.key,
    required this.model,
    this.github,
    this.repository,
    this.analytics,
  });

  @override
  State<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

class _ChatHistoryScreenState extends State<ChatHistoryScreen> {
  late Future<List<ChatSessionSummary>> _list;

  @override
  void initState() {
    super.initState();
    _list = ChatStore.listAll();
  }

  Future<void> _refresh() async {
    setState(() => _list = ChatStore.listAll());
  }

  Future<void> _open(ChatSessionSummary summary) async {
    final session = await ChatStore.load(summary.id);
    if (session == null || !mounted) {
      // Index out of sync with the full blob — refresh.
      await _refresh();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          model: widget.model,
          github: widget.github == null ? null : GithubClient(widget.github!),
          repository: widget.repository,
          analytics: widget.analytics,
          resume: session,
        ),
      ),
    );
    if (mounted) _refresh();
  }

  Future<void> _delete(ChatSessionSummary s) async {
    await ChatStore.delete(s.id);
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat history')),
      body: FutureBuilder<List<ChatSessionSummary>>(
        future: _list,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final sessions = snap.data ?? const [];
          if (sessions.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No past chats yet.\nStart one and it shows up here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: sessions.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final s = sessions[i];
              return Dismissible(
                key: ValueKey(s.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) => _delete(s),
                child: ListTile(
                  title: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Row(
                    children: [
                      if (s.viewName != null) ...[
                        Text(
                          s.viewName!,
                          style: TextStyle(color: scheme.primary),
                        ),
                        const Text(' · '),
                      ],
                      Text(s.updatedAtLabel),
                    ],
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(s),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
