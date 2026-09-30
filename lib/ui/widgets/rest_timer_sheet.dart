import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/notification_service.dart';
import '../../services/rest_timer.dart';

/// A rest-timer bottom sheet: pick 3 or 5 min, watch a countdown ring, and
/// get a sound/vibration + notification when it finishes. The countdown is
/// wall-clock anchored ([RestTimer]) so it stays correct if the app is
/// backgrounded; the notification fires even if the sheet is gone.
///
/// Launched via [showRestTimer] — the strength timeline exposes it from an
/// app-bar action (a launch point that doesn't touch the entry form).
Future<void> showRestTimer(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _RestTimerSheet(),
  );
}

class _RestTimerSheet extends StatefulWidget {
  const _RestTimerSheet();

  @override
  State<_RestTimerSheet> createState() => _RestTimerSheetState();
}

class _RestTimerSheetState extends State<_RestTimerSheet> {
  final _timer = RestTimer();
  Timer? _ticker;
  bool _fired = false;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _start(int seconds) {
    _fired = false;
    _timer.start(Duration(seconds: seconds), now: DateTime.now());
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    setState(() {});
  }

  void _tick() {
    final now = DateTime.now();
    if (!_fired && _timer.isComplete(now)) {
      _fired = true;
      _ticker?.cancel();
      unawaited(
        NotificationService.instance?.showRestTimerDone(
          restDoneBody(_timer.total),
        ),
      );
    }
    if (mounted) setState(() {});
  }

  void _cancel() {
    _ticker?.cancel();
    _timer.stop();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final running = _timer.state == RestTimerState.running;
    final done = _timer.state == RestTimerState.done;
    final remaining = _timer.remaining(now);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Rest timer',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            if (running || done)
              SizedBox(
                width: 160,
                height: 160,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 160,
                      height: 160,
                      child: CircularProgressIndicator(
                        value: done ? 1 : _timer.progress(now),
                        strokeWidth: 8,
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: done ? scheme.primary : scheme.tertiary,
                      ),
                    ),
                    Text(
                      done ? 'Done' : formatRestRemaining(remaining),
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                  ],
                ),
              )
            else
              _presetRow(context),
            const SizedBox(height: 24),
            if (running)
              OutlinedButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop),
                label: const Text('Cancel'),
              )
            else if (done)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final sec in kRestTimerPresetsSec) ...[
                    FilledButton.tonal(
                      onPressed: () => _start(sec),
                      child: Text(restPresetLabel(sec)),
                    ),
                    const SizedBox(width: 12),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _presetRow(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final sec in kRestTimerPresetsSec) ...[
          FilledButton(
            onPressed: () => _start(sec),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
            ),
            child: Text(
              restPresetLabel(sec),
              style: const TextStyle(fontSize: 18),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ],
    );
  }
}
