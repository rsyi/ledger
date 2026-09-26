/// Home-surface type scale — the ONE place the HOME tab's dashboard
/// cards and list sections get their TextStyles (readability pass
/// 2026-09-25; user: "generally fonts are too small too on the
/// homepage. adjust so it's a more readable layout.").
///
/// Rules, enforced here so future cards can't drift back to tiny
/// hand-set sizes:
///
///   * PRIMARY VALUES (weights, Wilks, rates, quota counts) → [value]:
///     titleMedium (16sp) w700 with tabular figures.
///   * SECONDARY labels / units / when-tags → [tag]: labelMedium —
///     the 12sp floor (13sp under the app theme) in onSurfaceVariant,
///     never outline-on-dark.
///   * CARD TITLES + row overlines → [title]: letter-spaced caps at
///     labelMedium w700 (one style for every card header).
///   * VERDICT/STATUS CHIPS → [chip]: labelMedium w800 — chips size
///     up with their text; give them layout room, don't shrink them.
///
/// NOTHING on the home surfaces goes below 12sp — the old hand-set
/// 9/9.5/11sp tags are exactly what this file exists to prevent.
library;

import 'package:flutter/material.dart';

abstract final class HomeText {
  /// Card titles ("STRENGTH", "THIS WEEK") and hero row overlines —
  /// letter-spaced caps, muted but legible.
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
}
