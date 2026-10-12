/// Design tokens for the 2026-10-02 UI redesign
/// (docs/superpowers/specs/2026-10-02-ui-redesign-design.md).
///
/// Three type roles (title / row / meta) plus a letter-spaced section
/// label; one spacing scale (≈44 px rows, 12 px section gap, 16 px
/// gutter); one card style; four status colours. Every redesigned
/// surface reads these instead of ad-hoc sizes so the same information
/// always looks the same.
library;

import 'package:flutter/material.dart';

/// Spacing scale.
abstract final class AppSpace {
  /// Side gutter for every list/card.
  static const double gutter = 16;

  /// Vertical gap between sections.
  static const double sectionGap = 12;

  /// Target height of a single-line list row.
  static const double row = 44;

  /// Vertical padding inside a list row.
  static const double rowV = 6;

  /// Width reserved for a row's leading status mark.
  static const double lead = 24;

  /// Gap between the leading mark and the row text.
  static const double leadGap = 12;

  /// Gap between set chips.
  static const double chip = 6;
}

/// Corner radii.
abstract final class AppRadius {
  static const double card = 12;
  static const double chip = 8;
}

/// The three type roles + section label. Colours come from the ambient
/// [ColorScheme] so the styles follow the app theme.
abstract final class AppText {
  /// Screen/card title — 16 / 600.
  static TextStyle title(BuildContext context) => TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.25,
    color: Theme.of(context).colorScheme.onSurface,
  );

  /// Row name (exercise, item) — 14 / 500.
  static TextStyle row(BuildContext context) => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
    color: Theme.of(context).colorScheme.onSurface,
  );

  /// Meta line (sets×reps · load, notes) — 12 / 400 muted.
  static TextStyle meta(BuildContext context) => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Section label — 11 / 600, letter-spaced, muted, upper-cased by the
  /// caller ([SectionHeader] does it).
  static TextStyle section(BuildContext context) => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.0,
    height: 1.2,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
}

/// Item status — drives [StatusColors.of] and the status marks.
enum ItemStatus {
  /// Not started (planned, nothing logged).
  pending,

  /// Some of it done.
  partial,

  /// All done.
  done,

  /// A real problem (missed, failed, over a cap). Red is reserved for this.
  problem,

  /// De-emphasised (warm-ups, skipped).
  muted,
}

/// Status colours as a [ThemeExtension] so the theme owns them; widgets
/// fall back to [StatusColors.dark] when the extension isn't installed
/// (bare widget tests).
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  final Color done;
  final Color partial;
  final Color problem;
  final Color muted;

  const StatusColors({
    required this.done,
    required this.partial,
    required this.problem,
    required this.muted,
  });

  /// The app's dark palette (green / amber / rose / grey).
  static const dark = StatusColors(
    done: Color(0xFF4ADE80),
    partial: Color(0xFFFBBF24),
    problem: Color(0xFFFB7185),
    muted: Color(0xFF71717A),
  );

  static const light = StatusColors(
    done: Color(0xFF16A34A),
    partial: Color(0xFFD97706),
    problem: Color(0xFFE11D48),
    muted: Color(0xFF71717A),
  );

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  /// Colour for [status]; pending reads as the muted outline colour.
  Color forStatus(BuildContext context, ItemStatus status) =>
      switch (status) {
        ItemStatus.done => done,
        ItemStatus.partial => partial,
        ItemStatus.problem => problem,
        ItemStatus.muted => muted,
        ItemStatus.pending => Theme.of(context).colorScheme.onSurfaceVariant,
      };

  @override
  StatusColors copyWith({
    Color? done,
    Color? partial,
    Color? problem,
    Color? muted,
  }) => StatusColors(
    done: done ?? this.done,
    partial: partial ?? this.partial,
    problem: problem ?? this.problem,
    muted: muted ?? this.muted,
  );

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      done: Color.lerp(done, other.done, t)!,
      partial: Color.lerp(partial, other.partial, t)!,
      problem: Color.lerp(problem, other.problem, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
    );
  }
}

/// The one card style: surfaceContainer, radius 12, no outline.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  /// Accent outline (the current item in a list of cards — e.g. today's
  /// day on the Program screen).
  final bool highlighted;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.gutter),
    this.margin = EdgeInsets.zero,
    this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.card);
    return Padding(
      padding: margin,
      child: Material(
        color: scheme.surfaceContainer,
        // No outline by default; [highlighted] adds the accent one.
        borderRadius: highlighted ? null : radius,
        shape: highlighted
            ? RoundedRectangleBorder(
                borderRadius: radius,
                side: BorderSide(color: scheme.primary, width: 1.5),
              )
            : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A strength set's `set_type` (the schema's dropdown options). Drives
/// [SetTypeColors] and the [SetTypeTag] pill.
enum SetType {
  warmup('warm-up'),
  heavy('heavy'),
  hypertrophy('hypertrophy'),
  skill('skill'),
  rehab('rehab');

  /// The pill's text — spelled out, never abbreviated.
  final String label;
  const SetType(this.label);
}

/// Parses a stored `set_type` value; blank / unknown → null (no tag —
/// never a guessed type).
SetType? parseSetType(Object? raw) {
  final s = raw?.toString().trim().toLowerCase();
  return switch (s) {
    'warmup' || 'warm-up' || 'warm up' => SetType.warmup,
    'heavy' => SetType.heavy,
    'hypertrophy' => SetType.hypertrophy,
    'skill' => SetType.skill,
    'rehab' => SetType.rehab,
    _ => null,
  };
}

/// Set-type tag hues: heavy red, hypertrophy orange, skill blue, rehab
/// green. Warm-up has no hue — it keeps the muted grey tag. The dark
/// palette uses light tints and the light palette deep shades so the
/// label clears 4.5:1 on its own translucent pill over the surface.
@immutable
class SetTypeColors {
  final Color heavy;
  final Color hypertrophy;
  final Color skill;
  final Color rehab;

  const SetTypeColors({
    required this.heavy,
    required this.hypertrophy,
    required this.skill,
    required this.rehab,
  });

  static const dark = SetTypeColors(
    heavy: Color(0xFFFCA5A5), // red-300
    hypertrophy: Color(0xFFFDBA74), // orange-300
    skill: Color(0xFF93C5FD), // blue-300
    rehab: Color(0xFF86EFAC), // green-300
  );

  static const light = SetTypeColors(
    heavy: Color(0xFFB91C1C), // red-700
    hypertrophy: Color(0xFF9A3412), // orange-800
    skill: Color(0xFF1D4ED8), // blue-700
    rehab: Color(0xFF166534), // green-800
  );

  static SetTypeColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// The hue for [type]; null for warm-up (rendered muted grey).
  Color? forType(SetType type) => switch (type) {
        SetType.heavy => heavy,
        SetType.hypertrophy => hypertrophy,
        SetType.skill => skill,
        SetType.rehab => rehab,
        SetType.warmup => null,
      };
}
