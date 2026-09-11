/// Whoop → live heart rate integration.
///
/// Whoop bands expose the standard BLE Heart Rate service (0x180D) when
/// "HR Broadcast" is enabled in the Whoop app. This integration is
/// live-only: data flows into the cardio form during the workout
/// through the normal form-save path — there is nothing to pull, so no
/// ingest and no provenance. The card just pairs a device (remembered
/// in ledger meta) and sets the user's max HR for zone stamps.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../heart_rate_service.dart';
import '../../ui/widgets/hr_max_dialog.dart';
import 'integration.dart';

class WhoopIntegration implements Integration {
  WhoopIntegration({required this.hr});

  final HeartRateService hr;

  @override
  String get id => 'whoop';
  @override
  String get displayName => 'Whoop';
  @override
  String get targetDescription => '→ live heart rate';

  /// Always configured: BLE pairing, no API credentials involved.
  @override
  bool get isConfigured => true;

  @override
  Future<bool> get isConnected async =>
      (await hr.rememberedDeviceId()) != null;

  @override
  Future<String> get statusLine async {
    if (!await isConnected) {
      return 'Not paired · turn on HR Broadcast in the Whoop app first';
    }
    final max = hr.maxHr.value;
    return max == null
        ? 'Paired · max HR not set'
        : 'Paired · max HR $max';
  }

  @override
  Future<void> connect(BuildContext context) async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Bluetooth permission is needed to find your '
              'Whoop. Enable it in system Settings > Apps.'),
        ));
      }
      return;
    }
    if (!context.mounted) return;
    final device = await showDialog<BluetoothDevice>(
      context: context,
      builder: (_) => const _HrScanDialog(),
    );
    if (device == null) return;
    await hr.rememberDevice(device.remoteId.str);
    if (!context.mounted) return;
    await promptMaxHr(context, hr);
    unawaited(hr.connectTo(device));
  }

  @override
  Future<void> disconnect() => hr.forget();

  /// Live-only source: nothing to pull. Interface contract: never throw.
  @override
  Future<void> pull({bool force = false, bool fullReconcile = false}) async {}
}

/// Scans for BLE devices advertising the Heart Rate service and pops
/// with the picked [BluetoothDevice] (or null on cancel).
class _HrScanDialog extends StatefulWidget {
  const _HrScanDialog();

  @override
  State<_HrScanDialog> createState() => _HrScanDialogState();
}

class _HrScanDialogState extends State<_HrScanDialog> {
  List<ScanResult> _results = const [];
  StreamSubscription<List<ScanResult>>? _sub;
  StreamSubscription<bool>? _scanningSub;
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _sub = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) setState(() => _results = results);
    });
    // Note: the startScan future resolves when the scan *starts*, not
    // when the timeout ends it — the isScanning stream is what flips
    // false then. skip(1) drops the stream's replayed pre-scan value.
    _scanningSub = FlutterBluePlus.isScanning.skip(1).listen((scanning) {
      if (mounted) setState(() => _scanning = scanning);
    });
    FlutterBluePlus.startScan(
      withServices: [HeartRateService.serviceHr],
      timeout: const Duration(seconds: 15),
    ).catchError((Object _) {
      if (mounted) setState(() => _scanning = false);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scanningSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Find heart rate source'),
      content: SizedBox(
        width: double.maxFinite,
        child: _results.isEmpty
            ? Text(_scanning
                ? 'Scanning… enable HR Broadcast in the Whoop app '
                    '(Device Settings) and keep the band nearby.'
                : 'Nothing found. Is HR Broadcast on?')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final r in _results)
                    ListTile(
                      leading: const Icon(Icons.monitor_heart_outlined),
                      title: Text(r.device.platformName.isEmpty
                          ? r.device.remoteId.str
                          : r.device.platformName),
                      subtitle: Text('${r.rssi} dBm'),
                      onTap: () => Navigator.of(context).pop(r.device),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
