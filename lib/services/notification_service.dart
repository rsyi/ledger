import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications: post-log coach nudges and the rest-timer-done
/// alert. Immediate `show()` only — no zoned scheduling — so the timezone
/// database is never initialised.
///
/// Two channels: `coach_updates` (post-log summaries, default importance)
/// and `rest_timer` (timer-done, high importance + sound/vibration so it
/// cuts through while the phone's in a pocket between sets).
///
/// A thin singleton the app initialises once at boot; the pure message
/// composition lives in [composePostLogNotification] / [restDoneBody] so
/// it can be tested without the plugin.
class NotificationService {
  NotificationService._(this._plugin);

  static NotificationService? instance;

  final FlutterLocalNotificationsPlugin _plugin;

  static const _coachChannelId = 'coach_updates';
  static const _timerChannelId = 'rest_timer';

  // Fixed ids so a fresh notification of the same kind REPLACES the last
  // (a stream of logs shouldn't stack up a wall of stale nudges).
  static const _coachNotifId = 1001;
  static const _timerNotifId = 1002;

  /// Initialises the plugin + channels. Idempotent. Safe to call on any
  /// platform — construction failures are swallowed so the app never
  /// blocks on notifications being unavailable (desktop tests, etc.).
  static Future<void> init() async {
    if (instance != null) return;
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      const androidInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await plugin.initialize(initSettings);

      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        await android.createNotificationChannel(
          const AndroidNotificationChannel(
            _coachChannelId,
            'Coach updates',
            description: 'Short read on your day after you log a meal or set.',
            importance: Importance.defaultImportance,
          ),
        );
        await android.createNotificationChannel(
          const AndroidNotificationChannel(
            _timerChannelId,
            'Rest timer',
            description: 'Fires when a rest timer finishes.',
            importance: Importance.high,
          ),
        );
      }
      instance = NotificationService._(plugin);
    } catch (_) {
      // Notifications unavailable — the app carries on without them.
    }
  }

  /// Requests the Android 13+ POST_NOTIFICATIONS runtime grant. Returns
  /// true when granted (or not needed on older Android). Best-effort.
  Future<bool> requestPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true;
      return await android.requestNotificationsPermission() ?? true;
    } catch (_) {
      return false;
    }
  }

  /// Posts a post-log coach nudge. [body] is the pre-composed summary
  /// (see [composePostLogNotification]). No-op on failure.
  Future<void> showCoachUpdate(String title, String body) async {
    if (body.trim().isEmpty) return;
    await _show(
      _coachNotifId,
      _coachChannelId,
      'Coach updates',
      title,
      body,
      high: false,
    );
  }

  /// Posts the rest-timer-done alert (high importance, sound + vibration).
  Future<void> showRestTimerDone(String body) async {
    await _show(
      _timerNotifId,
      _timerChannelId,
      'Rest timer',
      'Rest over',
      body,
      high: true,
    );
  }

  Future<void> _show(
    int id,
    String channelId,
    String channelName,
    String title,
    String body, {
    required bool high,
  }) async {
    try {
      final details = AndroidNotificationDetails(
        channelId,
        channelName,
        importance: high ? Importance.high : Importance.defaultImportance,
        priority: high ? Priority.high : Priority.defaultPriority,
        playSound: true,
        enableVibration: true,
        styleInformation: BigTextStyleInformation(body),
      );
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(android: details),
      );
    } catch (_) {/* best-effort */}
  }
}

/// Composes the post-log notification body from the just-logged event and
/// a short training tally. Pure — no plugin, no IO. Keeps the wording
/// honest: it states what was logged and what's still to come, never
/// claims work that isn't done.
///
/// [what] is a short description of the logged thing ("squat 5×260",
/// "lunch — 620 kcal"). [liftsHit]/[liftsPlanned] give the day's main-lift
/// progress; [climbToCome] flags a still-pending PM climb. Any of these
/// may be null/absent and the sentence degrades gracefully.
String composePostLogNotification({
  required String what,
  int? liftsHit,
  int? liftsPlanned,
  bool climbToCome = false,
}) {
  final parts = <String>['Logged: $what.'];
  if (liftsHit != null && liftsPlanned != null && liftsPlanned > 0) {
    parts.add('$liftsHit of $liftsPlanned lifts hit today');
    if (climbToCome) parts.add('climbing still to come');
    return '${parts.first} ${parts.sublist(1).join('; ')}.';
  }
  if (climbToCome) {
    return '${parts.first} Climbing still to come.';
  }
  return parts.first;
}

/// The rest-timer-done body for the given preset length.
String restDoneBody(Duration total) {
  final min = total.inSeconds ~/ 60;
  if (min > 0 && total.inSeconds % 60 == 0) {
    return "Your $min-minute rest is up — back to it.";
  }
  return 'Rest is up — back to it.';
}
