import 'dart:async';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'hr_session.dart';

/// Connection lifecycle for the live BLE heart-rate feed.
enum HrState { disconnected, connecting, connected, reconnecting }

/// Generic BLE heart-rate client (standard Heart Rate Service 0x180D —
/// Whoop broadcast, Polar/Garmin straps, anything). One instance per
/// app, created at bootstrap next to the IntegrationRegistry.
///
/// Ledger meta keys (shared with the Whoop integration card):
///   - `integration_whoop_device_id` — remembered BLE remote id
///   - `user_max_hr` — user's max HR; drives zone thresholds
class HeartRateService {
  HeartRateService({required this.repo});

  static HeartRateService? instance;

  final EngineLedgerRepository repo;

  static const kDeviceIdKey = 'integration_whoop_device_id';
  static const kMaxHrKey = 'user_max_hr';

  static final serviceHr = Guid('180D');
  static final charHrMeasurement = Guid('2A37');

  final state = ValueNotifier<HrState>(HrState.disconnected);
  final lastBpm = ValueNotifier<int?>(null);

  /// User's max HR, mirrored from ledger meta at [init] and kept in
  /// sync by [setMaxHr]. Widgets read this instead of touching meta.
  final maxHr = ValueNotifier<int?>(null);

  final _bpmController = StreamController<int>.broadcast();
  Stream<int> get bpm => _bpmController.stream;

  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _wantConnected = false;
  bool _retryPending = false;

  /// Load meta-backed state. Call once at bootstrap.
  Future<void> init() async {
    maxHr.value = int.tryParse(await repo.metaGet(kMaxHrKey) ?? '');
  }

  Future<String?> rememberedDeviceId() async {
    final id = await repo.metaGet(kDeviceIdKey);
    return (id == null || id.isEmpty) ? null : id;
  }

  Future<void> rememberDevice(String remoteId) =>
      repo.metaSet(kDeviceIdKey, remoteId);

  Future<void> setMaxHr(int? value) async {
    await repo.metaSet(kMaxHrKey, value?.toString() ?? '');
    maxHr.value = value;
  }

  /// Connect to the remembered device. Returns false when none is
  /// paired yet (caller sends the user to the Integrations page).
  Future<bool> connectRemembered() async {
    final id = await rememberedDeviceId();
    if (id == null) return false;
    await connectTo(BluetoothDevice.fromId(id));
    return true;
  }

  Future<void> connectTo(BluetoothDevice device) async {
    _wantConnected = true;
    _device = device;
    state.value = HrState.connecting;
    await _connSub?.cancel();
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && _wantConnected) {
        // Unexpected drop (out of range): flag + retry until told to stop.
        state.value = HrState.reconnecting;
        _retryLater();
      }
    });
    await _openAndSubscribe();
  }

  Future<void> _openAndSubscribe() async {
    final device = _device;
    if (device == null) return;
    try {
      if (!device.isConnected) {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 15),
        );
      }
      final services = await device.discoverServices();
      final hr = services.firstWhere((s) => s.uuid == serviceHr);
      final measurement = hr.characteristics
          .firstWhere((c) => c.uuid == charHrMeasurement);
      await _valueSub?.cancel();
      // Subscribe before enabling notifications so no packet is missed.
      _valueSub = measurement.onValueReceived.listen(_onData);
      await measurement.setNotifyValue(true);
      state.value = HrState.connected;
    } catch (e) {
      debugPrint('HR connect failed: $e');
      if (_wantConnected) {
        state.value = HrState.reconnecting;
        _retryLater();
      }
    }
  }

  Future<void> _retryLater() async {
    // Collapse concurrent retry chains (each drop event schedules one).
    if (_retryPending) return;
    _retryPending = true;
    await Future<void>.delayed(const Duration(seconds: 3));
    _retryPending = false;
    if (!_wantConnected || state.value == HrState.connected) return;
    await _openAndSubscribe();
  }

  void _onData(List<int> data) {
    final v = decodeHeartRate(data);
    if (v == null) return;
    lastBpm.value = v;
    _bpmController.add(v);
  }

  Future<void> disconnect() async {
    _wantConnected = false;
    await _valueSub?.cancel();
    _valueSub = null;
    await _connSub?.cancel();
    _connSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    lastBpm.value = null;
    state.value = HrState.disconnected;
  }

  /// Disconnect and drop the pairing (Whoop card's Disconnect action).
  /// `user_max_hr` intentionally survives.
  Future<void> forget() async {
    await disconnect();
    await repo.metaSet(kDeviceIdKey, '');
  }
}
