import 'package:flutter/material.dart';

import '../services/integrations/integration.dart';
import '../services/integrations/registry.dart';
import '../services/sync_scheduler.dart';
import '../services/wm_store.dart';
import '../services/wm_tabs.dart';
import '../services/working_max.dart' show defaultVariantByLift;

/// Integrations page — one card per source: status, Connect/Sync
/// now, and an overflow with Full reconcile / Disconnect. When [wmStore]
/// is present, a "Working maxes" card leads the list: current controller
/// values per lift, Confirm buttons for pending §5 seeds (appends a
/// confirmed duplicate row — the tabs stay append-only), and a manual
/// "Set working max…" override in the card menu.
class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({super.key, this.wmStore});

  final WmStore? wmStore;

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> {
  @override
  Widget build(BuildContext context) {
    final integrations = IntegrationRegistry.instance?.integrations ?? const [];
    final wmStore = widget.wmStore;
    if (wmStore == null && integrations.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Integrations')),
        body: const Center(child: Text('No integrations available.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Integrations')),
      body: ListView(
        children: [
          if (wmStore != null) ...[
            _WorkingMaxCard(store: wmStore),
            const Divider(height: 1),
          ],
          for (final it in integrations) ...[
            _IntegrationCard(
                integration: it,
                onChanged: () {
                  if (mounted) setState(() {});
                }),
            const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

/// "Working maxes" card — reads the append-only `working_max` tab via
/// [WmStore]. Every action APPENDS (seed confirmation = duplicate row
/// with confirmed=true; manual override = source=manual row); nothing is
/// ever edited in place.
class _WorkingMaxCard extends StatefulWidget {
  const _WorkingMaxCard({required this.store});

  final WmStore store;

  @override
  State<_WorkingMaxCard> createState() => _WorkingMaxCardState();
}

class _WorkingMaxCardState extends State<_WorkingMaxCard> {
  WmSnapshot? _snap;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final s = await widget.store.snapshot(force: force);
    if (mounted) {
      setState(() {
        _snap = s;
        _loaded = true;
      });
    }
  }

  Future<void> _run(Future<void> Function() op) async {
    setState(() => _busy = true);
    try {
      await op();
      await _load(force: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setWorkingMaxDialog() async {
    var lift = 'bench';
    final valueCtl = TextEditingController();
    final reasonCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Set working max'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: lift,
                decoration: const InputDecoration(labelText: 'Lift'),
                items: [
                  for (final l in defaultVariantByLift.keys)
                    DropdownMenuItem(value: l, child: Text(l)),
                ],
                onChanged: (v) => setLocal(() => lift = v ?? lift),
              ),
              TextField(
                controller: valueCtl,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Working max (lb)'),
              ),
              TextField(
                controller: reasonCtl,
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    final value = double.tryParse(valueCtl.text.trim());
    if (ok != true || value == null || value <= 0) return;
    await _run(() => widget.store.setWorkingMax(
          lift: lift,
          valueLb: value,
          reason: reasonCtl.text,
        ));
  }

  static String _n(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snap = _snap;
    final rows = <(String, WorkingMaxRow, bool)>[
      if (snap != null)
        for (final lift in defaultVariantByLift.keys)
          if (currentWorkingMax(snap.workingMax, lift) != null)
            (
              lift,
              currentWorkingMax(snap.workingMax, lift)!,
              needsConfirmation(snap.workingMax, lift),
            ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('Working maxes → prescriptions'),
          subtitle: Text(!_loaded
              ? '…'
              : rows.isEmpty
                  ? 'No working maxes yet — the nightly job seeds them.'
                  : rows.any((r) => r.$3)
                      ? 'Seed values pending confirmation'
                      : 'Controller active'),
          trailing: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'set') _setWorkingMaxDialog();
                    if (v == 'refresh') _run(() async {});
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'set', child: Text('Set working max…')),
                    PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                  ],
                ),
        ),
        for (final (lift, row, pending) in rows)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$lift  ${_n(row.valueLb)} lb · ${row.variant} · '
                    '${row.source}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                if (pending)
                  _busy
                      ? Text('…',
                          style: TextStyle(color: scheme.onSurfaceVariant))
                      : TextButton(
                          onPressed: () =>
                              _run(() => widget.store.confirmSeed(lift)),
                          child: const Text('Confirm'),
                        ),
              ],
            ),
          ),
      ],
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
