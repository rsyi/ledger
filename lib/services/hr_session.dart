import '../models/view_schema.dart';

/// Decodes a standard BLE Heart Rate Measurement (characteristic
/// 0x2A37) payload. Flags byte bit 0 selects the BPM width: clear =
/// uint8 at byte 1, set = uint16 little-endian at bytes 1-2. Returns
/// null on malformed data.
int? decodeHeartRate(List<int> data) {
  if (data.isEmpty) return null;
  final wide = data[0] & 0x01 != 0;
  if (wide) {
    if (data.length < 3) return null;
    return data[1] | (data[2] << 8);
  }
  if (data.length < 2) return null;
  return data[1];
}

/// Per-workout HR tracking: session max BPM plus one-shot zone-crossing
/// detection for ladders that declare `hr_pct`. Pure logic — the timer
/// widget feeds it samples and decides what to do with the results
/// (the caller still skips targets whose field already has a value).
class HrSession {
  HrSession({
    required this.maxHr,
    required List<TimerLadder> ladders,
    this.hrMaxTarget,
  }) : ladders =
            ladders.where((l) => l.hrPct != null).toList(growable: false);

  /// User's max heart rate (ledger meta `user_max_hr`). Null disables
  /// zone detection; session max still tracks.
  final int? maxHr;

  /// Only the HR-driven ladders (hr_pct != null).
  final List<TimerLadder> ladders;
  final String? hrMaxTarget;

  int? sessionMax;
  final Set<String> _fired = {};

  /// Feed one BPM sample; returns the ladders whose threshold this
  /// sample crosses for the first time this session.
  List<TimerLadder> onSample(int bpm) {
    if (sessionMax == null || bpm > sessionMax!) sessionMax = bpm;
    final max = maxHr;
    if (max == null || max <= 0) return const [];
    final due = <TimerLadder>[];
    for (final l in ladders) {
      if (_fired.contains(l.target)) continue;
      if (bpm >= max * l.hrPct! / 100) {
        _fired.add(l.target);
        due.add(l);
      }
    }
    return due;
  }
}
