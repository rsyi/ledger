/// Shared components for the 2026-10-02 UI redesign. Every redesigned
/// screen builds its lists from these — no ad-hoc ListTiles for the same
/// patterns. Styling comes only from tokens.dart.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Leading status glyph: hollow circle (pending), half-filled (partial),
/// check (done), alert (problem), small dot (muted).
class StatusMark extends StatelessWidget {
  final ItemStatus status;
  final double size;

  const StatusMark({super.key, required this.status, this.size = 18});

  @override
  Widget build(BuildContext context) {
    final color = StatusColors.of(context).forStatus(context, status);
    final IconData icon = switch (status) {
      ItemStatus.pending => Icons.radio_button_unchecked,
      ItemStatus.partial => Icons.contrast,
      ItemStatus.done => Icons.check_circle,
      ItemStatus.problem => Icons.error_outline,
      ItemStatus.muted => Icons.circle,
    };
    return Icon(
      icon,
      size: status == ItemStatus.muted ? size * 0.45 : size,
      color: color,
      semanticLabel: status.name,
    );
  }
}

/// One set as a tappable chip, e.g. `105×6`. Tap and long-press are
/// separate actions (the timeline: tap = log, long-press = edit).
class SetChip extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Rendered with a check + muted text (already logged).
  final bool done;

  /// De-emphasised (warm-up sets).
  final bool muted;

  /// Accent outline (e.g. selected in selection mode).
  final bool selected;

  const SetChip({
    super.key,
    required this.label,
    this.onTap,
    this.onLongPress,
    this.done = false,
    this.muted = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = StatusColors.of(context);
    final radius = BorderRadius.circular(AppRadius.chip);
    final fg = done || muted ? scheme.onSurfaceVariant : scheme.onSurface;
    return Material(
      color: done ? Colors.transparent : scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: selected
            ? BorderSide(color: scheme.secondary, width: 1.5)
            : (done
                  ? BorderSide(color: scheme.outlineVariant)
                  : BorderSide.none),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          // 32 px visual, comfortably tappable in a dense row.
          constraints: const BoxConstraints(minHeight: 32, minWidth: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (done) ...[
                  Icon(Icons.check, size: 13, color: status.done),
                  const SizedBox(width: 3),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: fg,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The shared list row: status mark · name · one meta line · optional
/// chips row · trailing action. Name and meta share the first line (the
/// Program screen's dense `Bench 4×8 · 165 lb` style); chips wrap below.
class ExerciseRow extends StatelessWidget {
  final String name;
  final String? meta;
  final ItemStatus status;

  /// Replaces the status mark (e.g. a selection checkbox).
  final Widget? leading;

  final List<Widget> chips;

  /// Trailing action — typically a ⋮ [IconButton].
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Muted styling for the whole row (warm-ups, skipped).
  final bool muted;

  /// Accent tint (fades when cleared — the timeline's hand-off flash).
  final bool highlighted;

  /// Selection tint.
  final bool selected;

  const ExerciseRow({
    super.key,
    required this.name,
    this.meta,
    this.status = ItemStatus.pending,
    this.leading,
    this.chips = const [],
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.muted = false,
    this.highlighted = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rowStyle = AppText.row(context);
    final metaStyle = AppText.meta(context);
    final mutedColor = StatusColors.of(context).muted;
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: name,
            style: muted
                ? rowStyle.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
                  )
                : rowStyle,
          ),
          if (meta != null && meta!.isNotEmpty)
            TextSpan(
              text: '  $meta',
              style: muted ? metaStyle.copyWith(color: mutedColor) : metaStyle,
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final body = Padding(
      padding: const EdgeInsets.only(
        left: AppSpace.gutter,
        right: AppSpace.gutter / 2,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpace.row),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: AppSpace.lead,
              height: AppSpace.row,
              child: Center(child: leading ?? StatusMark(status: status)),
            ),
            const SizedBox(width: AppSpace.leadGap),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    text,
                    if (chips.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: AppSpace.chip,
                        runSpacing: AppSpace.chip,
                        children: chips,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (trailing != null)
              SizedBox(
                height: AppSpace.row,
                child: Center(child: trailing),
              ),
          ],
        ),
      ),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      color: highlighted
          ? scheme.tertiaryContainer.withValues(alpha: 0.55)
          : (selected
                ? scheme.primaryContainer.withValues(alpha: 0.4)
                : Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: onTap, onLongPress: onLongPress, child: body),
      ),
    );
  }
}

/// Section header at list density: letter-spaced label, optional count,
/// trailing action icons.
class SectionHeader extends StatelessWidget {
  final String label;

  /// Small muted text after the label (e.g. `3 / 21`).
  final String? count;

  final List<Widget> actions;

  /// Upper-case the label (default) — false for user-authored names.
  final bool upperCase;

  const SectionHeader({
    super.key,
    required this.label,
    this.count,
    this.actions = const [],
    this.upperCase = true,
  });

  @override
  Widget build(BuildContext context) {
    final style = AppText.section(context);
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.gutter,
        right: actions.isEmpty ? AppSpace.gutter : 4,
        top: AppSpace.sectionGap,
      ),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Flexible(
              child: Text(
                upperCase ? label.toUpperCase() : label,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 8),
              Text(
                count!,
                style: style.copyWith(
                  letterSpacing: 0.2,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            const Spacer(),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// One label/value pair in a [StatStrip].
class StatItem {
  final String label;
  final String value;
  final ItemStatus? status;

  const StatItem(this.label, this.value, {this.status});
}

/// Compact horizontal label/value pairs (`Sleep 7.2h · HRV 61 · …`).
/// Wraps rather than scrolls on narrow screens.
class StatStrip extends StatelessWidget {
  final List<StatItem> items;

  const StatStrip({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final meta = AppText.meta(context);
    final value = AppText.row(context);
    final colors = StatusColors.of(context);
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        for (final it in items)
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '${it.label} ', style: meta),
                TextSpan(
                  text: it.value,
                  style: it.status == null
                      ? value
                      : value.copyWith(
                          color: colors.forStatus(context, it.status!),
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Small pill with a status colour (`on track`, `2 of 3`, `missed`).
class StatusChip extends StatelessWidget {
  final String label;
  final ItemStatus status;

  const StatusChip({super.key, required this.label, required this.status});

  @override
  Widget build(BuildContext context) {
    final c = StatusColors.of(context).forStatus(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: c,
          height: 1.3,
        ),
      ),
    );
  }
}

/// One action in a [showDetailSheet].
class DetailAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Problem-coloured (destructive).
  final bool destructive;

  const DetailAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });
}

/// The shared bottom sheet: title, optional subtitle, optional body,
/// then a list of actions. Tapping an action pops the sheet first, then
/// runs it.
Future<void> showDetailSheet({
  required BuildContext context,
  required String title,
  String? subtitle,
  Widget? body,
  List<DetailAction> actions = const [],
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => DetailSheet(
      title: title,
      subtitle: subtitle,
      body: body,
      actions: [
        for (final a in actions)
          DetailAction(
            icon: a.icon,
            label: a.label,
            destructive: a.destructive,
            onTap: () {
              Navigator.of(ctx).pop();
              a.onTap();
            },
          ),
      ],
    ),
  );
}

/// Sheet content (exposed for tests / embedding).
class DetailSheet extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? body;
  final List<DetailAction> actions;

  const DetailSheet({
    super.key,
    required this.title,
    this.subtitle,
    this.body,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final problem = StatusColors.of(context).problem;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
              child: Text(title, style: AppText.title(context)),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter,
                  4,
                  AppSpace.gutter,
                  0,
                ),
                child: Text(subtitle!, style: AppText.meta(context)),
              ),
            if (body != null)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.gutter,
                    AppSpace.sectionGap,
                    AppSpace.gutter,
                    0,
                  ),
                  child: body,
                ),
              ),
            if (actions.isNotEmpty) const SizedBox(height: 8),
            for (final a in actions)
              InkWell(
                onTap: a.onTap,
                child: SizedBox(
                  height: AppSpace.row + 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.gutter,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          a.icon,
                          size: 20,
                          color: a.destructive
                              ? problem
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: AppSpace.leadGap + 4),
                        Text(
                          a.label,
                          style: AppText.row(context).copyWith(
                            color: a.destructive ? problem : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
