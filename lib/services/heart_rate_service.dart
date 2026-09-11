import 'dart:async';
import 'dart:math';

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
///
/// On unexpected drops it reconnects with exponential backoff (3s → 30s
/// cap) and keeps retrying while the app is backgrounded — by design, so
/// a workout keeps recording with the screen off.
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
  Timer? _retryTimer;
  int _retryAttempt = 0;

  /// Bumped by [connectTo]/[disconnect] to invalidate in-flight
  /// [_openAndSubscribe] attempts, so exactly one attempt can win.
  int _attemptGen = 0;

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
    _attemptGen++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
    state.value = HrState.connecting;
    await _connSub?.cancel();
    _connSub = device.connectionState.listen((s) {
      // Note: FBP replays the current value (disconnected for a fresh
      // device) to every new listener, so only treat this as a drop
      // when we actually got connected first.
      if (s == BluetoothConnectionState.disconnected &&
          _wantConnected &&
          state.value == HrState.connected) {
        // Unexpected drop (out of range): flag + retry until told to stop.
        state.value = HrState.reconnecting;
        lastBpm.value = null;
        _scheduleRetry(attempt: _retryAttempt++);
      }
    });
    await _openAndSubscribe();
  }

  Future<void> _openAndSubscribe() async {
    final device = _device;
    if (device == null) return;
    final gen = _attemptGen;
    try {
      if (!device.isConnected) {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 15),
        );
      }
      if (gen != _attemptGen || !_wantConnected) return;
      final services = await device.discoverServices();
      if (gen != _attemptGen || !_wantConnected) return;
      final hr = services.firstWhere((s) => s.uuid == serviceHr);
      final measurement = hr.characteristics
          .firstWhere((c) => c.uuid == charHrMeasurement);
      await _valueSub?.cancel();
      if (gen != _attemptGen || !_wantConnected) return;
      // Subscribe before enabling notifications so no packet is missed.
      _valueSub = measurement.onValueReceived.listen(_onData);
      await measurement.setNotifyValue(true);
      if (gen != _attemptGen || !_wantConnected) return;
      _retryAttempt = 0;
      state.value = HrState.connected;
    } catch (e) {
      debugPrint('HR connect failed: $e');
      if (gen != _attemptGen || !_wantConnected) return;
      state.value = HrState.reconnecting;
      _scheduleRetry(attempt: _retryAttempt++);
    }
  }

  /// Schedule a single reconnect attempt with exponential backoff:
  /// 3s, 6s, 12s, 24s, then capped at 30s. Replaces any pending timer,
  /// so exactly one retry is ever queued.
  void _scheduleRetry({required int attempt}) {
    _retryTimer?.cancel();
    final delay = Duration(seconds: min(30, 3 << min(attempt, 4)));
    _retryTimer = Timer(delay, () {
      if (!_wantConnected || state.value == HrState.connected) return;
      _openAndSubscribe();
    });
  }

  void _onData(List<int> data) {
    final v = decodeHeartRate(data);
    if (v == null) return;
    lastBpm.value = v;
    _bpmController.add(v);
  }

  Future<void> disconnect() async {
    _wantConnected = false;
    _attemptGen++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
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
