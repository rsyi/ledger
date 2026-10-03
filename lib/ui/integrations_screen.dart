import 'package:flutter/material.dart';

import '../services/integrations/integration.dart';
import '../services/integrations/registry.dart';
import '../services/sync_scheduler.dart';
import 'design/design.dart';

/// Integrations page — one card per source: status, Connect/Sync
/// now, and an overflow with Full reconcile / Disconnect. (Training
/// maxes moved to the top of the Program screen — see
/// ui/program_screen.dart's TRAINING MAXES section.)
class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> {
  @override
  Widget build(BuildContext context) {
    final integrations = IntegrationRegistry.instance?.integrations ?? const [];
    if (integrations.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Integrations')),
        body: const Center(child: Text('No integrations available.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Integrations')),
      body: ListView(
        padding: const EdgeInsets.only(top: 4),
        children: [
          for (final it in integrations)
            IntegrationCard(
                integration: it,
                onChanged: () {
                  if (mounted) setState(() {});
                }),
        ],
      ),
    );
  }
}

/// One integration's row (status · Connect / Sync now · ⋮) — shared by
/// this screen and the Settings screen's Integrations section.
class IntegrationCard extends StatefulWidget {
  const IntegrationCard(
      {super.key, required this.integration, required this.onChanged});

  final Integration integration;
  final VoidCallback onChanged;

  @override
  State<IntegrationCard> createState() => _IntegrationCardState();
}

class _IntegrationCardState extends State<IntegrationCard> {
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
        // Guided integrations (Kaya) replace the Sync button's quiet
        // pull() with a user-guided flow and surface its progress in
        // place of the status line while it runs.
        final integration = widget.integration;
        final guided =
            integration is GuidedSyncIntegration ? integration : null;
        final statusText = FutureBuilder<String>(
          future: it.statusLine,
          builder: (context, s) => Text(s.data ?? '…'),
        );
        // Shared row pattern: status mark · name + target (meta) · one
        // status line below · Sync now + ⋮.
        return ExerciseRow(
          name: it.displayName,
          meta: it.targetDescription,
          status: !it.isConfigured
              ? ItemStatus.muted
              : connected
                  ? ItemStatus.done
                  : ItemStatus.pending,
          subtitle: guided == null
              ? statusText
              : ValueListenableBuilder<String?>(
                  valueListenable: guided.syncProgress,
                  builder: (context, progress, _) =>
                      progress == null ? statusText : Text(progress),
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
                                if (guided != null) {
                                  // Guided flow owns its own UI; no
                                  // ledger sync after — these sources
                                  // don't write ledger rows.
                                  await guided.guidedSync(context);
                                  return;
                                }
                                await it.pull(force: true);
                                SyncScheduler.instance
                                    ?.maybeSync(manual: true);
                              }),
                              child: const Text('Sync now'),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (v) {
                                final extra = it.extraMenuActions[v];
                                if (extra != null) {
                                  _run(() => extra(context));
                                  return;
                                }
                                if (v == 'reconcile') {
                                  _run(() => it.pull(
                                      force: true, fullReconcile: true));
                                }
                                if (v == 'disconnect') {
                                  _confirmDisconnect();
                                }
                              },
                              itemBuilder: (_) => [
                                for (final label
                                    in it.extraMenuActions.keys)
                                  PopupMenuItem(
                                    value: label,
                                    child: Text(label),
                                  ),
                                // Guided sources don't reconcile a
                                // ledger window — hide the generic item
                                // (Kaya's equivalent is "Import latest
                                // export" above).
                                if (guided == null)
                                  const PopupMenuItem(
                                    value: 'reconcile',
                                    child: Text('Full reconcile'),
                                  ),
                                const PopupMenuItem(
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
