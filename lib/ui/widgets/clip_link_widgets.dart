import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/photos_verify.dart';
import '../design/design.dart';

/// Status pill for a clip's Google Photos link check: verified ✓ green,
/// unverified amber, manual blue, mismatch red. [check] null = a link
/// made before verification existed → shown as unverified.
class LinkStatusChip extends StatelessWidget {
  const LinkStatusChip({super.key, required this.check});
  final LinkCheck? check;

  static String labelFor(LinkCheck? c) => switch (c?.status) {
        LinkStatus.verified => 'verified ✓',
        LinkStatus.manual => 'linked by hand',
        LinkStatus.mismatch => 'images differ',
        LinkStatus.unverified || null => 'unverified',
      };

  /// "image match 4 of 64 bits differ" / null when there's no distance.
  static String? detailFor(LinkCheck? c) {
    final b = c?.bits;
    if (c == null) return 'not checked yet — re-check to verify';
    if (c.status == LinkStatus.mismatch && b == null) {
      return 'different shape (portrait vs landscape)';
    }
    if (b == null) {
      return c.status == LinkStatus.unverified
          ? 'no local clip to compare — linked by recording time'
          : null;
    }
    return '$b of 64 image bits differ (≤ $kVerifyMaxBits = same clip)';
  }

  @override
  Widget build(BuildContext context) {
    final s = StatusColors.of(context);
    final color = switch (check?.status) {
      LinkStatus.verified => s.done,
      LinkStatus.manual => SetTypeColors.of(context).skill,
      LinkStatus.mismatch => s.problem,
      LinkStatus.unverified || null => s.partial,
    };
    final label = labelFor(check);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color, height: 1.3),
      ),
    );
  }
}

/// One captioned square image (or a placeholder message).
class ClipImageBox extends StatelessWidget {
  const ClipImageBox({
    super.key,
    required this.caption,
    this.bytes,
    this.placeholder = 'no image',
    this.size = 112,
  });

  final String caption;
  final Uint8List? bytes;
  final String placeholder;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: size,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.chip),
            child: SizedBox(
              width: size,
              height: size,
              child: bytes != null
                  ? Image.memory(bytes!, fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => _ph(scheme, t))
                  : _ph(scheme, t),
            ),
          ),
          const SizedBox(height: 4),
          Text(caption,
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _ph(ColorScheme scheme, TextTheme t) => ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(placeholder,
                textAlign: TextAlign.center,
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ),
      );
}

/// Local vs cloud side by side — the "are these the same clip?" view.
class ClipImagePair extends StatelessWidget {
  const ClipImagePair({
    super.key,
    this.local,
    this.cloud,
    this.cloudPlaceholder = 're-link to fetch',
  });

  final Uint8List? local;
  final Uint8List? cloud;
  final String cloudPlaceholder;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipImageBox(
              caption: 'On this phone',
              bytes: local,
              placeholder: 'clip not on this phone'),
          const SizedBox(width: AppSpace.leadGap),
          ClipImageBox(
              caption: 'Google Photos',
              bytes: cloud,
              placeholder: cloudPlaceholder),
        ],
      );
}
