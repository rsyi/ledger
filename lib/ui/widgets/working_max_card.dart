import 'package:flutter/material.dart';

import '../../services/wm_store.dart';
import '../../services/wm_tabs.dart';
import '../../services/working_max.dart' show defaultVariantByLift;

/// "Working maxes" card — reads the append-only `working_max` tab via
/// [WmStore]. Every action APPENDS (seed confirmation = duplicate row
/// with confirmed=true; manual override = source=manual row); nothing is
/// ever edited in place.
///
/// Lives in the Program screen's CONFIGURATION section (moved out of
/// Integrations 2026-09-21 — working maxes are program configuration,
/// not a data source).
class WorkingMaxCard extends StatefulWidget {
  const WorkingMaxCard({super.key, required this.store});

  final WmStore store;

  @override
  State<WorkingMaxCard> createState() => _WorkingMaxCardState();
}

class _WorkingMaxCardState extends State<WorkingMaxCard> {
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
