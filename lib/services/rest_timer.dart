/// Rest-timer logic: a pure countdown clock, no Flutter / no IO. The
/// widget (ui/widgets/rest_timer_sheet.dart) owns the ticking Timer and
/// the notification; this class holds the state and answers "how much is
/// left?" from wall-clock deltas so it stays correct across app
/// backgrounding (the OS pauses Dart timers — we re-derive remaining from
/// the stored end time on resume, never from a tick count).
///
/// Two presets per the spec: 3 min and 5 min.
library;

/// The two presets the UI offers, in seconds.
const List<int> kRestTimerPresetsSec = [180, 300];

enum RestTimerState { idle, running, done }

/// A single rest countdown. Construct, [start] with a duration, then read
/// [remaining] against a clock each tick. [isComplete] flips true once the
/// end time passes — the widget fires its notification then and calls
/// [stop].
class RestTimer {
  /// Total duration of the current run.
  Duration _total = Duration.zero;

  /// Wall-clock instant the countdown ends. Null when idle.
  DateTime? _endsAt;

  RestTimerState _state = RestTimerState.idle;

  RestTimerState get state => _state;
  Duration get total => _total;
  DateTime? get endsAt => _endsAt;

  /// Begins a countdown of [duration] anchored to [now].
  void start(Duration duration, {required DateTime now}) {
    if (duration <= Duration.zero) {
      _state = RestTimerState.idle;
      _total = Duration.zero;
      _endsAt = null;
      return;
    }
    _total = duration;
    _endsAt = now.add(duration);
    _state = RestTimerState.running;
  }

  /// Clears the timer back to idle (called on user cancel).
  void stop() {
    _state = RestTimerState.idle;
    _total = Duration.zero;
    _endsAt = null;
  }

  /// Time left at [now], floored at zero. Zero when idle/done.
  Duration remaining(DateTime now) {
    final end = _endsAt;
    if (end == null) return Duration.zero;
    final left = end.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// Fraction elapsed 0..1 at [now] (for a progress ring). 0 when idle.
  double progress(DateTime now) {
    if (_total <= Duration.zero) return 0;
    final done = _total - remaining(now);
    final f = done.inMilliseconds / _total.inMilliseconds;
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
  }

  /// True once the end time has passed while running. Transitions the
  /// state to [RestTimerState.done] so [isComplete] fires exactly once
  /// worth of "just completed" can be detected by the caller comparing
  /// the returned value across ticks.
  bool isComplete(DateTime now) {
    if (_state != RestTimerState.running) return false;
    final end = _endsAt;
    if (end == null) return false;
    if (!now.isBefore(end)) {
      _state = RestTimerState.done;
      return true;
    }
    return false;
  }
}

/// Formats a countdown as M:SS (e.g. 180s → "3:00", 65s → "1:05").
String formatRestRemaining(Duration d) {
  final secs = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = secs ~/ 60;
  final s = secs % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Human label for a preset ("3 min", "5 min").
String restPresetLabel(int seconds) {
  if (seconds % 60 == 0) return '${seconds ~/ 60} min';
  return '${seconds}s';
}
