import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/log_event_bus.dart';
import '../../services/video_rpe.dart' show mediaIdFieldFor;
import '../../services/warehouse_connector.dart';
import 'video_preview.dart';

/// Today tab highlight strip: thumbnails of the clips attached to the
/// selected day's logged sets. Tap one to preview/play. Hidden when the
/// day has no videos.
class TodayClipsCard extends StatefulWidget {
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;
  final DateTime date;

  const TodayClipsCard({
    super.key,
    required this.strengthView,
    required this.strengthRepo,
    required this.date,
  });

  @override
  TodayClipsCardState createState() => TodayClipsCardState();
}

class _Clip {
  final String url;
  final String? mediaId;
  final String label;
  const _Clip(this.url, this.mediaId, this.label);
}

class TodayClipsCardState extends State<TodayClipsCard> {
  late Future<List<_Clip>> _future;
  StreamSubscription<LogEvent>? _logSub;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _logSub = LogEventBus.instance.stream.listen((_) => reload());
  }

  @override
  void didUpdateWidget(TodayClipsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameDay(oldWidget.date, widget.date)) reload();
  }

  @override
  void dispose() {
    _logSub?.cancel();
    super.dispose();
  }

  void reload() {
    if (mounted) setState(() => _future = _load());
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  Future<List<_Clip>> _load() async {
    final sv = widget.strengthView;
    final sr = widget.strengthRepo;
    if (sv == null || sr == null) return const [];
    // The video field + its sibling media-id field.
    String? videoField;
    for (final d in sv.dimensions) {
      if (d.input?.widget == WidgetType.video) {
        videoField = d.name;
        break;
      }
    }
    if (videoField == null) return const [];
    final idField = mediaIdFieldFor(videoField);
    final out = <_Clip>[];
    try {
      for (final r in await sr.list(sv)) {
        final d = _date(r['date']);
        if (d == null || !_sameDay(d, widget.date)) continue;
        final url = r[videoField]?.toString().trim();
        if (url == null || url.isEmpty) continue;
        final mid = r[idField]?.toString().trim();
        final label = r['exercise']?.toString().trim() ?? 'Clip';
        out.add(_Clip(url, (mid == null || mid.isEmpty) ? null : mid, label));
      }
    } catch (_) {/* honest empty */}
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_Clip>>(
      future: _future,
      builder: (context, snap) {
        final clips = snap.data ?? const <_Clip>[];
        if (clips.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 0, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CLIPS',
                    style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 0.8,
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 122,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 16),
                    itemCount: clips.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => VideoThumb(
                      url: clips[i].url,
                      mediaId: clips[i].mediaId,
                      label: clips[i].label,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
