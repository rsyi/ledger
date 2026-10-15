import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/integrations/photos_picker_gateway.dart';
import '../services/photos_link.dart';
import '../services/photos_verify.dart';
import '../services/sheets_repository.dart' show Record;
import '../services/video_ref.dart';
import '../services/warehouse_connector.dart';
import 'design/design.dart';
import 'linked_clips_screen.dart';
import 'widgets/clip_link_widgets.dart';
import 'widgets/clip_media_access.dart';

/// "Link clips to Google Photos" (2026-10-14): retroactively gives
/// attached clips a durable photos.google.com link. Online and
/// user-initiated — attach itself stays offline. The user multi-selects
/// the clips in the Google Photos picker; photos_link.dart matches each
/// to its row by the VIDEO's recording time (never the set's logged
/// time), photos_verify.dart compares the item's thumbnail with frames
/// of the local clip, and only time + image agreement links
/// automatically. Everything else — image mismatch, ties, clips with no
/// readable recording time — lands in a review with both images.
///
/// On open, clips attached before recording metadata existed get their
/// `<base>_taken_at` backfilled from the local file. Picking an item
/// that is ALREADY linked re-verifies that link ("Re-check links").
/// Never downloads or uploads video; only small thumbnails.
class PhotosLinkScreen extends StatefulWidget {
  const PhotosLinkScreen({
    super.key,
    required this.view,
    required this.repository,
    required this.videoField,
    this.service,
    this.media,
    this.autoPick = false,
  });

  final ViewSchema view;
  final WarehouseConnector repository;
  final String videoField;

  /// Defaults to [PhotosLinkService.instance] (tests inject).
  final PhotosLinkService? service;

  /// Defaults to [DeviceClipMediaAccess] (tests inject).
  final ClipMediaAccess? media;

  /// Open the picker right away ("Re-check links" from the review).
  final bool autoPick;

  /// The view's first `widget: video` field (the link icon shows for any
  /// view with one — even before the durable dims sync in; the screen
  /// then explains what's missing). Null when the view has none.
  static String? videoFieldOf(ViewSchema view) {
    for (final d in view.dimensions) {
      if (d.input?.widget == WidgetType.video) return d.name;
    }
    return null;
  }

  /// The video field when it can hold a Photos link (declares the
  /// `<base>_photos_url` sibling); null otherwise.
  static String? linkableVideoField(ViewSchema view) {
    final f = videoFieldOf(view);
    if (f == null) return null;
    return view.dimensionByName(photosUrlFieldFor(f)) == null ? null : f;
  }

  @override
  State<PhotosLinkScreen> createState() => _PhotosLinkScreenState();
}

enum _Phase { loading, ready, picking, linking, review }

/// A linked clip in this session's results.
class _Linked {
  _Linked(this.clip, this.check, this.basis);
  final ClipCandidate clip;
  final LinkCheck? check;
  final String basis;
}

/// A recording-time match whose images disagree — not linked.
class _Mismatch {
  _Mismatch(this.match, this.check, this.evidence);
  final ClipMatch match;
  final LinkCheck check;
  final VerifyEvidence evidence;
}

class _PhotosLinkScreenState extends State<PhotosLinkScreen> {
  _Phase _phase = _Phase.loading;
  List<Record> _rows = const [];
  List<ClipCandidate> _clips = const [];
  String? _error;
  String? _backfillNote;
  LinkMatchResult? _result;
  final _linked = <_Linked>[];
  final _rechecked = <_Linked>[];
  final _mismatches = <_Mismatch>[];
  final _decided = <String>{}; // item ids chosen/skipped in review
  final _takenClips = <String>{};
  final _linkedIds = <String>{};
  final _cloudThumbs = <String, Uint8List?>{};

  PhotosLinkService? get _svc => widget.service ?? PhotosLinkService.instance;
  late final ClipMediaAccess _media = widget.media ?? DeviceClipMediaAccess();

  bool _hasDim(String f) => widget.view.dimensionByName(f) != null;
  bool get _schemaReady => _hasDim(photosUrlFieldFor(widget.videoField));
  String get _dateField => widget.view.dateField ?? 'date';

  ClipVerifier? _verifier;
  ClipVerifier? get _verify {
    final svc = _svc;
    if (svc == null) return null;
    return _verifier ??= ClipVerifier(
      frames: _media.frames,
      download: svc.flow.gateway.download,
      thumbStore: _media.cloudThumbs,
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      var rows = await widget.repository.list(widget.view);
      if (_schemaReady) {
        final filled = await _backfillTimestamps(rows);
        if (filled > 0) rows = await widget.repository.list(widget.view);
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _clips = linkCandidates(rows, widget.videoField, dateField: _dateField);
        _phase = _Phase.ready;
      });
      if (widget.autoPick && _svc != null && _schemaReady) unawaited(_pick());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn\'t load the log: $e';
        _phase = _Phase.ready;
      });
    }
  }

  /// Clips with no recording time (attached before the metadata
  /// existed): read it from the local file / app copy and save it to the
  /// rows. Returns how many clips were filled.
  Future<int> _backfillTimestamps(List<Record> rows) async {
    if (!_hasDim(takenAtFieldFor(widget.videoField))) return 0;
    var filled = 0, missing = 0;
    for (final c in linkCandidates(rows, widget.videoField,
        dateField: _dateField)) {
      if (c.takenAt != null) continue;
      String? src;
      try {
        src = await _media.localSource(c.rows.first, widget.videoField);
      } catch (_) {}
      final meta =
          src == null ? null : await probeClipMetadata(_media.frames, src);
      final out = timestampBackfillRows(c, meta, widget.videoField,
          hasDim: _hasDim);
      if (out == null) {
        missing++;
        continue;
      }
      for (final r in out) {
        await widget.repository.update(widget.view, r);
      }
      filled++;
    }
    _backfillNote = [
      if (filled > 0)
        'Read the recording time of $filled older clip${filled == 1 ? '' : 's'} '
            'from the phone.',
      if (missing > 0)
        '$missing clip${missing == 1 ? ' has' : 's have'} no video timestamp '
            '(the file isn\'t on this phone any more) — pick them and link '
            'by hand in the review; they never link automatically.',
    ].join(' ');
    if (_backfillNote!.isEmpty) _backfillNote = null;
    return filled;
  }

  Future<String?> _localSourceOf(ClipCandidate c) async {
    for (final r in c.rows) {
      try {
        final s = await _media.localSource(r, widget.videoField);
        if (s != null) return s;
      } catch (_) {}
    }
    return null;
  }

  Future<VerifyEvidence> _evidence(PickedMediaItem item, ClipCandidate c) async {
    final v = _verify!;
    final e = await v.evidence(item,
        localSource: await _localSourceOf(c), durationMs: c.durationMs);
    _cloudThumbs[item.id] = e.cloudThumb;
    return e;
  }

  Future<void> _pick() async {
    final svc = _svc;
    if (svc == null) return;
    setState(() {
      _phase = _Phase.picking;
      _error = null;
      _result = null;
      _linked.clear();
      _rechecked.clear();
      _mismatches.clear();
      _decided.clear();
    });
    try {
      final items = await svc.flow.pick();
      if (!mounted) return;
      setState(() => _phase = _Phase.linking);
      final linked = linkedClipsByItemId(_rows, widget.videoField,
          dateField: _dateField);

      // 1. Re-check: an already-linked item picked again → verify by
      // EXACT id (the link is kept; only its check changes).
      final seen = <String>{};
      for (final it in items) {
        final clip = linked[it.id];
        if (!it.isVideo || clip == null || !seen.add(it.id)) continue;
        final e = await _evidence(it, clip);
        final check = recheckResult(
            itemId: it.id, comparison: e.comparison, previous: clip.check);
        for (final r in checkedRows(clip, widget.videoField, check,
            hasDim: _hasDim)) {
          await widget.repository.update(widget.view, r);
        }
        _rechecked.add(_Linked(clip, check, 're-checked'));
      }

      // 2. New links: recording-time match, then image verification.
      final result = matchPickedClips(
          items,
          [
            for (final c in _clips)
              if (!_takenClips.contains(c.key)) c,
          ],
          alreadyLinkedIds: {...linked.keys, ..._linkedIds});
      if (mounted) setState(() => _result = result);
      for (final m in result.matched) {
        final e = await _evidence(m.item, m.clip);
        final d = decideLink(
            timeMatched: true, itemId: m.item.id, comparison: e.comparison);
        if (d.action == LinkAction.link) {
          await _apply(m.clip, m.item, d.check, _basisLabel(m));
        } else {
          // Persist the mismatch (unlinked) so it survives this screen.
          for (final r in checkedRows(m.clip, widget.videoField, d.check,
              hasDim: _hasDim)) {
            await widget.repository.update(widget.view, r);
          }
          _mismatches.add(_Mismatch(m, d.check!, e));
        }
      }
      // Cloud thumbnails for the choose-or-skip cards (the user needs to
      // SEE the clip). The baseUrl lives ~60 min, so fetch now.
      for (final a in result.ambiguous) {
        _cloudThumbs[a.item.id] ??= await _verify!.cloudThumb(a.item);
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

  /// Writes the link + its check (+ a synced thumbnail where the row has
  /// none) to every row of the clip.
  Future<void> _apply(ClipCandidate clip, PickedMediaItem item,
      LinkCheck? check, String basis) async {
    final svc = _svc;
    String? thumbUri;
    if (!clip.hasThumb && _hasDim(thumbFieldFor(widget.videoField))) {
      final bytes = await svc?.flow.fetchThumb(item);
      if (bytes != null) thumbUri = encodeThumbDataUri(bytes);
    }
    final rows = linkedRows(clip, item, widget.videoField,
        hasDim: _hasDim, thumbDataUri: thumbUri, check: check);
    for (final r in rows) {
      await widget.repository.update(widget.view, r);
    }
    _takenClips.add(clip.key);
    _linkedIds.add(item.id);
    _linked.add(_Linked(clip, check, basis));
    if (mounted) setState(() {});
  }

  int get _remaining =>
      _clips.where((c) => !_takenClips.contains(c.key)).length;

  Future<void> _openReview() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LinkedClipsScreen(
        view: widget.view,
        repository: widget.repository,
        videoField: widget.videoField,
        service: widget.service,
        media: widget.media,
      ),
    ));
    if (mounted) {
      setState(() => _phase = _Phase.loading);
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link clips to Google Photos'),
        actions: [
          if (_schemaReady)
            IconButton(
              icon: const Icon(Icons.fact_check_outlined),
              tooltip: 'Review linked clips',
              onPressed: _openReview,
            ),
        ],
      ),
      body: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        _ => ListView(
            padding: const EdgeInsets.all(AppSpace.gutter),
            children: _schemaReady ? _body(context) : _schemaMissing(context),
          ),
      },
    );
  }

  /// The link icon shows for any view with a video field; until the
  /// durable dims arrive this explains what's needed instead of hiding.
  List<Widget> _schemaMissing(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return [
      Text('Linking isn\'t available yet', style: t.titleLarge),
      const SizedBox(height: 8),
      Text(
        'This log doesn\'t have the "${photosUrlFieldFor(widget.videoField)}" '
        'column yet, so there\'s nowhere to store a Google Photos link. It '
        'arrives with the strength schema update: the app pulls schemas '
        'from GitHub every few minutes (pull to refresh on Home to check '
        'now), and the update needs this app version installed first. '
        'Once it lands, come back here — clips you attached in the '
        'meantime can still be linked.',
        style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
    ];
  }

  List<Widget> _body(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final svc = _svc;
    final busy = _phase == _Phase.picking || _phase == _Phase.linking;
    final n = _remaining;
    final linkedCount =
        linkedClipsByItemId(_rows, widget.videoField).length + _linked.length;
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
        'the lift clips in Google Photos (select several at once). Each '
        'is matched by the video\'s recording time, then its Google '
        'Photos thumbnail is compared with frames of the clip on this '
        'phone: only when both agree is it linked automatically; '
        'anything else waits for your call below. Picking a clip that\'s '
        'already linked re-checks that link. Nothing is uploaded or '
        'downloaded except small thumbnails.',
        style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      if (_backfillNote != null) ...[
        const SizedBox(height: 8),
        Text(_backfillNote!, style: t.bodySmall),
      ],
      const SizedBox(height: 16),
      if (svc == null)
        Text(
          'Google sign-in isn\'t configured on this build '
          '(google.server_client_id), so linking is unavailable.',
          style: t.bodyMedium?.copyWith(color: scheme.error),
        )
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: busy ? null : _pick,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_link),
            label: Text(_phase == _Phase.picking
                ? 'Waiting for your selection…'
                : _phase == _Phase.linking
                    ? 'Linking + verifying…'
                    : 'Pick clips in Google Photos'),
          ),
          if (_phase == _Phase.picking)
            TextButton(
                onPressed: () => svc.flow.cancel(),
                child: const Text('Cancel')),
        ]),
      if (linkedCount > 0 && !busy) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _openReview,
            icon: const Icon(Icons.fact_check_outlined),
            label: Text('Review $linkedCount linked '
                'clip${linkedCount == 1 ? '' : 's'}'),
          ),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: t.bodyMedium?.copyWith(color: scheme.error)),
      ],
      if (_result != null) ..._resultSection(context, _result!),
    ];
  }

  Widget _linkedTile(BuildContext context, _Linked l) {
    final t = Theme.of(context).textTheme;
    final detail = LinkStatusChip.detailFor(l.check);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.rowV),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.clip.label, style: t.bodyMedium),
                Text(
                  [l.basis, ?detail].join(' · '),
                  style: t.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          LinkStatusChip(check: l.check),
        ],
      ),
    );
  }

  List<Widget> _resultSection(BuildContext context, LinkMatchResult r) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final notes = <String>[
      if (r.nonVideo > 0)
        '${r.nonVideo} photo${r.nonVideo == 1 ? '' : 's'} ignored',
      if (r.unmatched.isNotEmpty)
        '${r.unmatched.length} with no unlinked clip recorded near then',
    ];
    final mism = [
      for (final m in _mismatches)
        if (!_decided.contains(m.match.item.id)) m,
    ];
    final open = [
      for (final a in r.ambiguous)
        if (!_decided.contains(a.item.id)) a,
    ];
    return [
      const SizedBox(height: 20),
      _section(context, 'Linked', _linked.length),
      for (final l in _linked) _linkedTile(context, l),
      if (_rechecked.isNotEmpty) ...[
        const SizedBox(height: 12),
        _section(context, 'Re-checked', _rechecked.length),
        for (final l in _rechecked) _linkedTile(context, l),
      ],
      if (notes.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(notes.join(' · '),
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      for (final u in r.unmatched)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
              '· Picked ${_when(u.createTime)} — no unlinked clip '
              'recorded near then',
              style: t.bodySmall),
        ),
      if (mism.isNotEmpty || open.isNotEmpty) ...[
        const SizedBox(height: 20),
        _section(context, 'Needs your call', mism.length + open.length),
        for (final m in mism) _mismatchCard(context, m),
        for (final a in open) _reviewCard(context, a),
      ],
    ];
  }

  Widget _section(BuildContext context, String label, int n) => Padding(
        padding: const EdgeInsets.only(top: AppSpace.sectionGap, bottom: 4),
        child: Text('${label.toUpperCase()}  $n',
            style: AppText.section(context)),
      );

  /// Recording times agree but the pictures don't: show both, the user
  /// decides. Skip leaves it flagged for the review screen.
  Widget _mismatchCard(BuildContext context, _Mismatch m) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(m.match.clip.label, style: t.bodyMedium)),
            LinkStatusChip(check: m.check),
          ]),
          const SizedBox(height: 4),
          Text(
            'Recorded ${_when(m.match.item.createTime)} '
            '(${_basisLabel(m.match)}) but the pictures don\'t match — '
            '${LinkStatusChip.detailFor(m.check)}. Not linked.',
            style: t.bodySmall,
          ),
          const SizedBox(height: 8),
          ClipImagePair(
            local: m.evidence.bestLocalFrame,
            cloud: m.evidence.cloudThumb,
            cloudPlaceholder: 'thumbnail unavailable',
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(spacing: 4, children: [
              TextButton(
                onPressed: () =>
                    setState(() => _decided.add(m.match.item.id)),
                child: const Text('Skip'),
              ),
              TextButton(
                onPressed: () async {
                  setState(() => _decided.add(m.match.item.id));
                  await _apply(
                      m.match.clip,
                      m.match.item,
                      LinkCheck(LinkStatus.manual, bits: m.check.bits),
                      'linked by hand');
                },
                child: const Text('Link anyway'),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _reviewCard(BuildContext context, AmbiguousPick a) {
    final t = Theme.of(context).textTheme;
    final cands = [
      for (final c in a.candidates)
        if (!_takenClips.contains(c.clip.key)) c,
    ];
    return AppCard(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipImageBox(
              caption: 'Google Photos',
              bytes: _cloudThumbs[a.item.id],
              placeholder: 'thumbnail unavailable',
              size: 88,
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
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FutureBuilder<Uint8List?>(
                    future: _media.localThumb(c.clip.rows.first, widget.videoField),
                    builder: (_, snap) => ClipImageBox(
                      caption: 'On this phone',
                      bytes: snap.data,
                      placeholder: 'no preview',
                      size: 88,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.clip.label, style: t.bodyMedium),
                        Text(_basisLabel(c), style: t.bodySmall),
                        TextButton(
                          onPressed: () async {
                            setState(() => _decided.add(a.item.id));
                            await _apply(c.clip, a.item,
                                const LinkCheck(LinkStatus.manual),
                                'linked by hand');
                          },
                          child: const Text('Link'),
                        ),
                      ],
                    ),
                  ),
                ],
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
      MatchBasis.noTimestamp => 'no video timestamp — same day',
    };
  }
}
