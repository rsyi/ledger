import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/photos_link.dart';
import '../services/sheets_repository.dart' show Record;
import '../services/video_ref.dart';
import '../services/warehouse_connector.dart';
import 'design/design.dart';

/// "Link clips to Google Photos" (2026-10-14): retroactively gives
/// attached clips a durable photos.google.com link. Online and
/// user-initiated — attach itself stays offline. The user multi-selects
/// the clips in the Google Photos picker; photos_link.dart matches each
/// to its row (recording time, else the set's logged time), links the
/// clear matches, and lists the rest here for a choose-or-skip review.
/// Never downloads or uploads video; only small thumbnails for rows
/// that have no synced one.
class PhotosLinkScreen extends StatefulWidget {
  const PhotosLinkScreen({
    super.key,
    required this.view,
    required this.repository,
    required this.videoField,
    this.service,
  });

  final ViewSchema view;
  final WarehouseConnector repository;
  final String videoField;

  /// Defaults to [PhotosLinkService.instance] (tests inject).
  final PhotosLinkService? service;

  /// The view's `widget: video` field when it can hold a Photos link
  /// (declares the `<base>_photos_url` sibling); null otherwise.
  static String? linkableVideoField(ViewSchema view) {
    for (final d in view.dimensions) {
      if (d.input?.widget != WidgetType.video) continue;
      return view.dimensionByName(photosUrlFieldFor(d.name)) == null
          ? null
          : d.name;
    }
    return null;
  }

  @override
  State<PhotosLinkScreen> createState() => _PhotosLinkScreenState();
}

enum _Phase { loading, ready, picking, linking, review }

class _PhotosLinkScreenState extends State<PhotosLinkScreen> {
  _Phase _phase = _Phase.loading;
  List<Record> _rows = const [];
  List<ClipCandidate> _clips = const [];
  String? _error;
  LinkMatchResult? _result;
  final _linked = <ClipMatch>[];
  final _decided = <String>{}; // ambiguous item ids chosen/skipped
  final _takenClips = <String>{};
  final _linkedIds = <String>{};
  final _thumbs = <String, Uint8List?>{};

  PhotosLinkService? get _svc => widget.service ?? PhotosLinkService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await widget.repository.list(widget.view);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _clips = linkCandidates(rows, widget.videoField,
            dateField: widget.view.dateField ?? 'date');
        _phase = _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn\'t load the log: $e';
        _phase = _Phase.ready;
      });
    }
  }

  Future<void> _pick() async {
    final svc = _svc;
    if (svc == null) return;
    setState(() {
      _phase = _Phase.picking;
      _error = null;
      _result = null;
      _linked.clear();
      _decided.clear();
      // Clips linked earlier in this screen stay linked (_rows is the
      // load-time snapshot; _takenClips / _linkedIds carry the delta).
    });
    try {
      final items = await svc.flow.pick();
      if (!mounted) return;
      final result = matchPickedClips(
          items,
          [
            for (final c in _clips)
              if (!_takenClips.contains(c.key)) c,
          ],
          alreadyLinkedIds: {
            ...linkedItemIds(_rows, widget.videoField),
            ..._linkedIds,
          });
      setState(() {
        _result = result;
        _phase = _Phase.linking;
      });
      for (final m in result.matched) {
        await _apply(m);
      }
      // Thumbnails for the review cards (the user needs to SEE the clip
      // to choose). The baseUrl lives ~60 min, so fetch now.
      for (final a in result.ambiguous) {
        _thumbs[a.item.id] ??= await svc.flow.fetchThumb(a.item);
      }
      if (!mounted) return;
      setState(() => _phase = _Phase.review);
    } on PhotosLinkCancelled {
      if (mounted) setState(() => _phase = _Phase.ready);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _phase = _Phase.ready;
      });
    }
  }

  /// Writes the link (+ a thumbnail where the row has none) to every row
  /// of the clip. The thumbnail fetch is the only network byte read.
  Future<void> _apply(ClipMatch m) async {
    final svc = _svc;
    String? thumbUri;
    if (!m.clip.hasThumb &&
        widget.view.dimensionByName(thumbFieldFor(widget.videoField)) !=
            null) {
      final bytes =
          _thumbs[m.item.id] ?? await svc?.flow.fetchThumb(m.item);
      if (bytes != null) thumbUri = encodeThumbDataUri(bytes);
    }
    final rows = linkedRows(m.clip, m.item, widget.videoField,
        hasDim: (f) => widget.view.dimensionByName(f) != null,
        thumbDataUri: thumbUri);
    for (final r in rows) {
      await widget.repository.update(widget.view, r);
    }
    _takenClips.add(m.clip.key);
    _linkedIds.add(m.item.id);
    _linked.add(m);
    if (mounted) setState(() {});
  }

  int get _remaining =>
      _clips.where((c) => !_takenClips.contains(c.key)).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Link clips to Google Photos')),
      body: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        _ => ListView(
            padding: const EdgeInsets.all(AppSpace.gutter),
            children: _body(context),
          ),
      },
    );
  }

  List<Widget> _body(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final svc = _svc;
    final busy = _phase == _Phase.picking || _phase == _Phase.linking;
    final n = _remaining;
    return [
      Text(
        n == 0
            ? 'All clips are linked'
            : '$n clip${n == 1 ? '' : 's'} not linked',
        style: t.titleLarge,
      ),
      const SizedBox(height: 8),
      Text(
        'Clips are attached from this phone (works offline). Linking '
        'them to their Google Photos backup keeps them playable after a '
        'reinstall, a new phone, or deleting them from the phone. Pick '
        'the lift clips in Google Photos (select several at once); each '
        'is matched to its set by recording time, else by the set\'s '
        'logged time. Nothing is uploaded or downloaded except small '
        'thumbnails.',
        style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 16),
      if (svc == null)
        Text(
          'Google sign-in isn\'t configured on this build '
          '(google.server_client_id), so linking is unavailable.',
          style: t.bodyMedium?.copyWith(color: scheme.error),
        )
      else
        Row(children: [
          FilledButton.icon(
            onPressed: busy || n == 0 ? null : _pick,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_link),
            label: Text(_phase == _Phase.picking
                ? 'Waiting for your selection…'
                : _phase == _Phase.linking
                    ? 'Linking…'
                    : 'Pick clips in Google Photos'),
          ),
          if (_phase == _Phase.picking) ...[
            const SizedBox(width: 8),
            TextButton(
                onPressed: () => svc.flow.cancel(),
                child: const Text('Cancel')),
          ],
        ]),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: t.bodyMedium?.copyWith(color: scheme.error)),
      ],
      if (_result != null) ..._resultSection(context, _result!),
    ];
  }

  List<Widget> _resultSection(BuildContext context, LinkMatchResult r) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final notes = <String>[
      if (r.alreadyLinked.isNotEmpty)
        '${r.alreadyLinked.length} already linked',
      if (r.nonVideo > 0) '${r.nonVideo} photo${r.nonVideo == 1 ? '' : 's'} ignored',
      if (r.unmatched.isNotEmpty)
        '${r.unmatched.length} with no logged clip nearby',
    ];
    final open = [
      for (final a in r.ambiguous)
        if (!_decided.contains(a.item.id)) a,
    ];
    return [
      const SizedBox(height: 20),
      Text('Linked ${_linked.length}', style: t.titleMedium),
      for (final m in _linked)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.link, color: scheme.primary),
          title: Text(m.clip.label),
          subtitle: Text(_basisLabel(m)),
        ),
      if (notes.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(notes.join(' · '),
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      for (final u in r.unmatched)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('· Picked ${_when(u.createTime)} — no unlinked clip '
              'logged near then', style: t.bodySmall),
        ),
      if (open.isNotEmpty) ...[
        const SizedBox(height: 20),
        Text('Needs your call (${open.length})', style: t.titleMedium),
        for (final a in open) _reviewCard(context, a),
      ],
    ];
  }

  Widget _reviewCard(BuildContext context, AmbiguousPick a) {
    final t = Theme.of(context).textTheme;
    final thumb = _thumbs[a.item.id];
    final cands = [
      for (final c in a.candidates)
        if (!_takenClips.contains(c.clip.key)) c,
    ];
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: thumb == null
                      ? const ColoredBox(
                          color: Colors.black12,
                          child: Icon(Icons.movie_outlined))
                      : Image.memory(thumb, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Clip recorded ${_when(a.item.createTime)}',
                    style: t.bodyMedium),
              ),
            ]),
            const SizedBox(height: 6),
            if (cands.isEmpty)
              Text('Its candidate sets were linked to other clips.',
                  style: t.bodySmall),
            for (final c in cands)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(c.clip.label),
                subtitle: Text(_basisLabel(c)),
                trailing: TextButton(
                  onPressed: () async {
                    setState(() => _decided.add(a.item.id));
                    await _apply(c);
                  },
                  child: const Text('Link'),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _decided.add(a.item.id)),
                child: const Text('Skip'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _when(DateTime? utc) => utc == null
      ? '(time unknown)'
      : DateFormat('MMM d, h:mm a').format(utc.toLocal());

  static String _basisLabel(ClipMatch m) {
    final d = m.delta;
    final dd = d == null
        ? ''
        : d.inMinutes >= 1
            ? ' (${d.inMinutes} min ${d.inSeconds % 60}s apart)'
            : ' (${d.inSeconds}s apart)';
    return switch (m.basis) {
      MatchBasis.metadata => 'recording time$dd',
      MatchBasis.loggedTime => 'logged set time$dd',
      MatchBasis.sameDay => 'same day (no time logged)',
    };
  }
}
