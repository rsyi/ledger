import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/integrations/photos_picker_gateway.dart';
import '../services/photos_link.dart';
import '../services/photos_verify.dart';
import '../services/sheets_repository.dart' show Record;
import '../services/warehouse_connector.dart';
import 'design/design.dart';
import 'photos_link_screen.dart';
import 'widgets/clip_link_widgets.dart';
import 'widgets/clip_media_access.dart';

/// "Linked clips" (2026-10-14) — the user's "I want to be able to review
/// the links made and preview the videos both locally and on cloud to
/// ensure they're the same". One card per clip (rows sharing a clip are
/// grouped): the set, the local frame next to the saved Google Photos
/// thumbnail, the verification status, and Play local / Open in Google
/// Photos / Unlink. Persisted image mismatches (not linked) show here
/// too, with Link anyway / Dismiss. "Re-check links" re-opens the picker:
/// re-picked linked items are re-verified by exact id.
class LinkedClipsScreen extends StatefulWidget {
  const LinkedClipsScreen({
    super.key,
    required this.view,
    required this.repository,
    required this.videoField,
    this.service,
    this.media,
  });

  final ViewSchema view;
  final WarehouseConnector repository;
  final String videoField;
  final PhotosLinkService? service;
  final ClipMediaAccess? media;

  @override
  State<LinkedClipsScreen> createState() => _LinkedClipsScreenState();
}

class _LinkedClipsScreenState extends State<LinkedClipsScreen> {
  bool _loading = true;
  String? _error;
  List<LinkReviewEntry> _entries = const [];
  bool _needsReviewOnly = false;

  late final ClipMediaAccess _media = widget.media ?? DeviceClipMediaAccess();
  bool _hasDim(String f) => widget.view.dimensionByName(f) != null;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<Record> rows = await widget.repository.list(widget.view);
      if (!mounted) return;
      setState(() {
        _entries = linkReviewEntries(rows, widget.videoField,
            dateField: widget.view.dateField ?? 'date');
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn\'t load the log: $e';
        _loading = false;
      });
    }
  }

  Future<void> _write(List<Map<String, Object?>> rows) async {
    for (final r in rows) {
      await widget.repository.update(widget.view, r);
    }
    await _load();
  }

  Future<void> _unlink(LinkReviewEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink this clip?'),
        content: Text('${e.clip.label}\n\nRemoves the Google Photos link from '
            '${e.clip.rows.length == 1 ? 'this set' : 'these ${e.clip.rows.length} sets'}. '
            'The clip on the phone and in Google Photos is untouched; you '
            'can link it again later.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Unlink')),
        ],
      ),
    );
    if (ok != true) return;
    await _write(unlinkedRows(e.clip, widget.videoField, hasDim: _hasDim));
  }

  Future<void> _linkAnyway(LinkReviewEntry e) => _write(linkedRows(
        e.clip,
        PickedMediaItem(id: e.itemId, isVideo: true),
        widget.videoField,
        hasDim: _hasDim,
        check: LinkCheck(LinkStatus.manual, bits: e.check?.bits),
      ));

  Future<void> _dismiss(LinkReviewEntry e) =>
      _write(checkedRows(e.clip, widget.videoField, null, hasDim: _hasDim));

  Future<void> _recheck() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PhotosLinkScreen(
        view: widget.view,
        repository: widget.repository,
        videoField: widget.videoField,
        service: widget.service,
        media: widget.media,
        autoPick: true,
      ),
    ));
    if (mounted) {
      setState(() => _loading = true);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = _entries.where((e) => e.needsReview).length;
    final shown =
        _needsReviewOnly ? _entries.where((e) => e.needsReview).toList() : _entries;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Linked clips'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-check links',
            onPressed: _loading ? null : _recheck,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpace.gutter),
              children: [
                if (_error != null)
                  Text(_error!,
                      style: t.bodyMedium?.copyWith(color: scheme.error)),
                Wrap(spacing: 8, children: [
                  ChoiceChip(
                    label: Text('All (${_entries.length})'),
                    selected: !_needsReviewOnly,
                    onSelected: (_) => setState(() => _needsReviewOnly = false),
                  ),
                  ChoiceChip(
                    label: Text('Needs review ($review)'),
                    selected: _needsReviewOnly,
                    onSelected: (_) => setState(() => _needsReviewOnly = true),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(
                  'Each clip shows a frame from this phone next to what '
                  'Google Photos has. Verified = recording time and '
                  'picture both match. Unverified links (made without the '
                  'clip on this phone, or before checking existed) can be '
                  're-checked: tap ↻ and pick those clips again in Google '
                  'Photos.',
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Text(
                      _entries.isEmpty
                          ? 'No clips are linked yet.'
                          : 'Nothing needs review.',
                      style: t.bodyMedium,
                    ),
                  ),
                for (final e in shown) _card(context, e),
              ],
            ),
    );
  }

  Widget _card(BuildContext context, LinkReviewEntry e) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final detail = e.linked
        ? LinkStatusChip.detailFor(e.check)
        : '${LinkStatusChip.detailFor(e.check)} — NOT linked';
    final url = photosProductUrl(e.itemId);
    final row = e.clip.rows.first;
    return AppCard(
      key: ValueKey('clip-${e.clip.key}'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(_title(e), style: t.titleSmall)),
            const SizedBox(width: 8),
            LinkStatusChip(check: e.check),
          ]),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(detail,
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          const SizedBox(height: 8),
          FutureBuilder<(Uint8List?, Uint8List?)>(
            future: _images(row, e.itemId),
            builder: (_, snap) => ClipImagePair(
              local: snap.data?.$1,
              cloud: snap.data?.$2,
            ),
          ),
          const SizedBox(height: 4),
          FutureBuilder<String?>(
            future: _media.localSource(row, widget.videoField),
            builder: (ctx, snap) => Wrap(spacing: 4, children: [
              TextButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play local'),
                onPressed: snap.data == null
                    ? null
                    : () => _media.playLocal(ctx, snap.data!,
                        title: e.clip.label),
              ),
              TextButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open in Google Photos'),
                onPressed: () => _media.openPhotos(ctx, url),
              ),
              if (e.linked && !e.legacy)
                TextButton.icon(
                  icon: const Icon(Icons.link_off),
                  label: const Text('Unlink'),
                  onPressed: () => _unlink(e),
                ),
              if (!e.linked) ...[
                TextButton(
                    onPressed: () => _linkAnyway(e),
                    child: const Text('Link anyway')),
                TextButton(
                    onPressed: () => _dismiss(e),
                    child: const Text('Dismiss')),
              ],
            ]),
          ),
        ],
      ),
    );
  }

  Future<(Uint8List?, Uint8List?)> _images(
      Map<String, Object?> row, String itemId) async {
    final local = await _media.localThumb(row, widget.videoField);
    final cloud = await _media.cloudThumbs.load(itemId);
    return (local, cloud);
  }

  /// "Oct 12 · Barbell Squat 315×3" (+ set count when grouped).
  static String _title(LinkReviewEntry e) {
    final c = e.clip;
    final when = c.takenAt ?? c.date;
    final r = c.rows.first;
    final ex = r['exercise']?.toString().trim() ?? '';
    String n(Object? v) =>
        v is double && v == v.roundToDouble() ? '${v.toInt()}' : '${v ?? ''}'.trim();
    final w = n(r['weight']), reps = n(r['reps']);
    final load = w.isNotEmpty && reps.isNotEmpty ? ' $w×$reps' : '';
    final sets = c.rows.length > 1 ? ' · ${c.rows.length} sets' : '';
    final day = when == null ? '' : '${DateFormat('MMM d').format(when)} · ';
    return '$day${ex.isEmpty ? 'Clip' : ex}$load$sets';
  }
}
