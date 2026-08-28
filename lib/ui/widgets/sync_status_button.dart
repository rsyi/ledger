import 'package:flutter/material.dart';

import '../../services/sync_scheduler.dart';

/// AppBar sync affordance for the local-first ledger: a cloud icon
/// with a pending-count badge, spinning state while a sync runs,
/// and a menu with "Sync now" + the `Sync on Wi-Fi only` toggle and
/// the last-synced stamp. Renders nothing when local-first is off.
class SyncStatusButton extends StatelessWidget {
  const SyncStatusButton({super.key});

  @override
  Widget build(BuildContext context) {
    final s = SyncScheduler.instance;
    if (s == null) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: s.syncing,
      builder: (context, syncing, _) => ValueListenableBuilder<int>(
        valueListenable: s.pending,
        builder: (context, pending, _) => ValueListenableBuilder<String?>(
          valueListenable: s.lastError,
          builder: (context, lastError, _) {
            final icon = syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    lastError != null
                        ? Icons.cloud_off_outlined
                        : pending > 0
                            ? Icons.cloud_upload_outlined
                            : Icons.cloud_done_outlined,
                  );
            return PopupMenuButton<String>(
              tooltip: _tooltip(s, pending, lastError),
              icon: Badge(
                isLabelVisible: pending > 0,
                label: Text('$pending'),
                child: icon,
              ),
              onSelected: (value) {
                if (value == 'sync') s.maybeSync(manual: true);
                if (value == 'wifi') s.setWifiOnly(!s.wifiOnly);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'sync',
                  enabled: !syncing,
                  child: const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.sync),
                    title: Text('Sync now'),
                  ),
                ),
                PopupMenuItem(
                  value: 'wifi',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      s.wifiOnly
                          ? Icons.check_box_outlined
                          : Icons.check_box_outline_blank,
                    ),
                    title: const Text('Sync on Wi-Fi only'),
                  ),
                ),
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    _statusLine(s, pending, lastError),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _statusLine(SyncScheduler s, int pending, String? lastError) {
    if (lastError != null) return 'Last sync failed: $lastError';
    final last = s.lastSync.value;
    final when = last == null
        ? 'never'
        : '${last.hour.toString().padLeft(2, '0')}:'
            '${last.minute.toString().padLeft(2, '0')}';
    final tail = pending > 0 ? ' · $pending pending' : '';
    return 'Last synced: $when$tail';
  }

  String _tooltip(SyncScheduler s, int pending, String? lastError) {
    if (lastError != null) return 'Sync error — tap for options';
    if (pending > 0) return '$pending unsynced change(s)';
    return 'Synced';
  }
}
