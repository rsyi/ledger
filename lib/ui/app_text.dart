/// App-wide type scale — the ONE place user-facing surfaces (home
/// dashboard, domain/program screens, timeline, coach chat, cards and
/// bottom sheets) get their shared TextStyles. Started as the HOME
/// readability pass (2026-09-25; user: "generally fonts are too small
/// too on the homepage… probably fonts everywhere too small") and now
/// applies everywhere.
///
/// Rules, enforced here so future surfaces can't drift back to tiny
/// hand-set sizes:
///
///   * PRIMARY VALUES (weights, Wilks, rates, quota counts) → [value]:
///     titleMedium (16sp) w700 with tabular figures.
///   * SECONDARY labels / units / when-tags → [tag]: labelMedium —
///     13sp under the app theme, in onSurfaceVariant, never
///     outline-on-dark.
///   * CARD TITLES + row overlines → [title]: letter-spaced caps at
///     labelMedium w700 (one style for every card/section header).
///   * VERDICT/STATUS CHIPS → [chip]: labelMedium w800 — chips size
///     up with their text; give them layout room, don't shrink them.
///   * DENSE METADATA (timeline tile provenance, chart footnotes) →
///     [micro]: 12sp, the absolute floor. NOTHING user-facing goes
///     below 12sp — the old hand-set 8/9/10/11sp styles are exactly
///     what this file exists to prevent.
///
/// Layout rule that travels with the scale: prefer reflow (Wrap,
/// extra lines, Expanded) over ellipsis when the bigger text needs
/// room.
library;

import 'package:flutter/material.dart';

abstract final class AppText {
  /// Card/section titles ("STRENGTH", "THIS WEEK") and hero row
  /// overlines — letter-spaced caps, muted but legible.
  static TextStyle? title(BuildContext context) =>
      Theme.of(context).textTheme.labelMedium?.copyWith(
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );

  /// Primary values — the one number a row exists to show.
  static TextStyle? value(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Secondary labels, units, when-tags, muted context lines.
  static TextStyle? tag(BuildContext context) =>
      Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Verdict/status chip text — caller supplies the chip's fg color.
  static TextStyle? chip(BuildContext context, {required Color color}) =>
      Theme.of(context).textTheme.labelMedium?.copyWith(
        letterSpacing: 0.5,
        fontWeight: FontWeight.w800,
        color: color,
      );

  /// Densest allowed style — 12sp (labelSmall) in onSurfaceVariant.
  /// For timeline tile metadata, chart footnotes, provenance lines.
  /// If 12sp doesn't fit, reflow the layout; don't go smaller.
  static TextStyle? micro(BuildContext context) =>
      Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
