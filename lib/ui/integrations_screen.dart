import 'package:flutter/material.dart';

import '../services/integrations/integration.dart';
import '../services/integrations/registry.dart';
import '../services/sync_scheduler.dart';

/// Integrations page — one card per source: status, Connect/Sync
/// now, and an overflow with Full reconcile / Disconnect.
class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> {
  @override
  Widget build(BuildContext context) {
    final integrations = IntegrationRegistry.instance?.integrations ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Integrations')),
      body: integrations.isEmpty
          ? const Center(child: Text('No integrations available.'))
          : ListView.separated(
              itemCount: integrations.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) =>
                  _IntegrationCard(integration: integrations[i], onChanged: () {
                if (mounted) setState(() {});
              }),
            ),
    );
  }
}

class _IntegrationCard extends StatefulWidget {
  const _IntegrationCard({required this.integration, required this.onChanged});

  final Integration integration;
  final VoidCallback onChanged;

  @override
  State<_IntegrationCard> createState() => _IntegrationCardState();
}

class _IntegrationCardState extends State<_IntegrationCard> {
  bool _busy = false;

  Integration get it => widget.integration;

  Future<void> _run(Future<void> Function() op) async {
    setState(() => _busy = true);
    try {
      await op();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: it.isConnected,
      builder: (context, connectedSnap) {
        final connected = connectedSnap.data ?? false;
        return ListTile(
          title: Text('${it.displayName} ${it.targetDescription}'),
          subtitle: FutureBuilder<String>(
            future: it.statusLine,
            builder: (context, s) => Text(s.data ?? '…'),
          ),
          trailing: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : !it.isConfigured
                  ? null
                  : !connected
                      ? TextButton(
                          onPressed: () =>
                              _run(() => it.connect(context)),
                          child: const Text('Connect'),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () => _run(() async {
                                await it.pull(force: true);
                                SyncScheduler.instance
                                    ?.maybeSync(manual: true);
                              }),
                              child: const Text('Sync now'),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'reconcile') {
                                  _run(() => it.pull(
                                      force: true, fullReconcile: true));
                                }
                                if (v == 'disconnect') {
                                  _confirmDisconnect();
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'reconcile',
                                  child: Text('Full reconcile'),
                                ),
                                PopupMenuItem(
                                  value: 'disconnect',
                                  child: Text('Disconnect'),
                                ),
                              ],
                            ),
                          ],
                        ),
        );
      },
    );
  }

  Future<void> _confirmDisconnect() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect ${it.displayName}?'),
        content: const Text(
            'Stops syncing. Data already in the ledger stays; you can '
            'reconnect any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (yes == true) await _run(it.disconnect);
  }
}
