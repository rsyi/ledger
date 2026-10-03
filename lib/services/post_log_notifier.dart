import 'dart:async';

import 'day_synthesis_service.dart';
import 'log_event_bus.dart';
import 'notification_service.dart';

/// Feature 3: fires a local notification after a big log event (a meal or
/// a workout set) summarising how the day stands. Debounced so a batch of
/// set logs collapses into ONE notification.
///
/// Listens on [LogEventBus] rather than the entry form, so it never touches
/// form code. The summary reuses the day-synthesis context tally (lifts hit
/// / planned + climb-to-come) — honest, never claiming unlogged work.
///
/// A boot-time singleton: [start] once after bootstrap; [dispose] on
/// teardown. No-op when notifications are unavailable.
class PostLogNotifier {
  final DaySynthesisService synthesis;

  /// Views whose creates are notification-worthy (meals + training).
  static const _watched = {'meals', 'strength', 'cardio', 'climbing'};

  static const _debounce = Duration(seconds: 3);

  StreamSubscription<LogEvent>? _sub;
  Timer? _timer;
  final List<LogEvent> _pending = [];

  PostLogNotifier({required this.synthesis});

  static PostLogNotifier? instance;

  /// Begins listening. Idempotent.
  void start() {
    _sub ??= LogEventBus.instance.stream.listen(_onEvent);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
  }

  void _onEvent(LogEvent e) {
    if (!_watched.contains(e.view)) return;
    _pending.add(e);
    _timer?.cancel();
    _timer = Timer(_debounce, _flush);
  }

  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    final batch = List<LogEvent>.of(_pending);
    _pending.clear();
    final notifier = NotificationService.instance;
    if (notifier == null) return;

    final what = describeLogBatch(batch);

    // Best-effort day tally; a failure degrades to a plain "Logged: …".
    int? liftsHit;
    int? liftsPlanned;
    var climbToCome = false;
    try {
      final ctx = await synthesis.buildContext();
      liftsHit = ctx.liftsHit;
      liftsPlanned = ctx.liftsPlanned;
      climbToCome = ctx.climbToCome;
    } catch (_) {/* plain summary */}

    final body = composePostLogNotification(
      what: what,
      liftsHit: liftsHit,
      liftsPlanned: liftsPlanned,
      climbToCome: climbToCome,
    );
    await notifier.showCoachUpdate('Nice work', body);
  }

}

/// A short description of a logged batch: the single row's detail, or a
/// "N sets" / domain roll-up. Pure — tested in post_log_notifier_test.
String describeLogBatch(List<LogEvent> batch) {
  if (batch.isEmpty) return 'an entry';
  if (batch.length == 1) return _describeOne(batch.first);
  final strengthCount = batch.where((e) => e.view == 'strength').length;
  if (strengthCount == batch.length && strengthCount > 1) {
    final ex = _exercise(batch.first);
    return ex == null ? '$strengthCount sets' : '$strengthCount sets ($ex)';
  }
  final views = batch.map((e) => e.view).toSet().toList()..sort();
  return views.join(' + ');
}

String _describeOne(LogEvent e) {
  switch (e.view) {
    case 'strength':
      final ex = _exercise(e);
      final reps = _int(e.record['reps']);
      final weight = _num(e.record['weight']);
      if (ex != null && reps != null && weight != null) {
        final setText = '$reps×${_trim(weight)}';
        return '$ex $setText';
      }
      return ex ?? 'a set';
    case 'meals':
      final meal = e.record['meal']?.toString().trim();
      final kcal = _num(e.record['calories']);
      if (meal != null && meal.isNotEmpty && kcal != null) {
        return '$meal — ${kcal.round()} kcal';
      }
      if (kcal != null) return 'a meal — ${kcal.round()} kcal';
      return 'a meal';
    case 'cardio':
      final type = e.record['type']?.toString().trim();
      return type != null && type.isNotEmpty ? type : 'cardio';
    case 'climbing':
      return 'a climb';
    default:
      return e.view;
  }
}

String? _exercise(LogEvent e) {
  final ex = e.record['exercise']?.toString().trim();
  return ex == null || ex.isEmpty ? null : ex;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Renders a weight without a trailing ".0" (260.0 → "260").
String _trim(double v) {
  final s = v.toString();
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
