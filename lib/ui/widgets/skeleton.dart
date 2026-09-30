/// Shared loading-skeleton widgets for the Progress tab (2026-09-30
/// staggered-load fix). The progress cards and the AI day-synthesis card
/// each resolve their own future at its own pace; without a stable
/// placeholder a card pops from a bare "…" straight to its filled value
/// and REFLOWS, producing the jarring cascade the user reported. These
/// greyed bars are SIZED like the final content so nothing jumps as data
/// arrives, and they pulse gently so the state reads as "loading", not
/// "broken".
///
/// Per-card (not one Future.wait gate): STRENGTH's WmStore network read
/// is much slower than the local-row cards, and a unified gate would make
/// every fast card wait on the slow one. Stable skeletons give a coherent
/// loading LOOK without coupling the futures' timing.
library;

import 'package:flutter/material.dart';

/// A greyed placeholder BLOCK, sized like a line of card content. Rounded
/// bar in the surface-variant tint at a faint alpha.
class SkeletonBar extends StatelessWidget {
  final double width;
  final double height;
  const SkeletonBar({super.key, required this.width, this.height = 12});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// Fixed-height skeleton for a loading card — a stack of [bars] (widths +
/// heights approximating the real content) that gently pulses. Nothing
/// reflows on the loading→data swap because the bars occupy roughly the
/// final content's height.
class CardSkeleton extends StatelessWidget {
  final List<({double width, double height})> bars;
  const CardSkeleton({super.key, required this.bars});

  /// A generic three-line card (value line + two tag lines) — the shape
  /// most progress cards land on.
  const CardSkeleton.card({super.key})
      : bars = const [
          (width: 90, height: 18),
          (width: 140, height: 12),
          (width: 110, height: 12),
        ];

  @override
  Widget build(BuildContext context) {
    return PulsingOpacity(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < bars.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            SkeletonBar(width: bars[i].width, height: bars[i].height),
          ],
        ],
      ),
    );
  }
}

/// Slow opacity pulse — a subtle "loading" heartbeat that never reflows
/// layout (opacity only). Repeats until disposed.
class PulsingOpacity extends StatefulWidget {
  final Widget child;
  const PulsingOpacity({super.key, required this.child});

  @override
  State<PulsingOpacity> createState() => _PulsingOpacityState();
}

class _PulsingOpacityState extends State<PulsingOpacity>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);
  late final Animation<double> _a = Tween(begin: 0.45, end: 1.0).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _a, child: widget.child);
}
