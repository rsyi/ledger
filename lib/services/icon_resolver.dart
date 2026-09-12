import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Resolves an `icon:` field value from a `.input.yml` into a Widget.
///
/// Three accepted shapes:
///  - **lucide name** (e.g. `dumbbell`, `heart-pulse`, `utensils`) — looked
///    up in [_lucideByName]; renders as a single-line glyph in the
///    oxy/airlayer aesthetic.
///  - **emoji / single grapheme** (e.g. `💪`, `🍱`) — rendered as text.
///  - **URL** (`http://` or `https://`) — fetched + displayed as an image.
///
/// A curated lucide map is used instead of reflection because
/// `lucide_icons_flutter` exposes ~3000 icons as static const fields with
/// no runtime name lookup. Hand-curating means our supported set is
/// explicit and small. Add icons here as needed.
class IconResolver {
  static const Map<String, IconData> _lucideByName = {
    // Fitness / strength
    'dumbbell': LucideIcons.dumbbell,
    'heart-pulse': LucideIcons.heartPulse,
    'heart': LucideIcons.heart,
    'activity': LucideIcons.activity,
    'flame': LucideIcons.flame,
    'sparkles': LucideIcons.sparkles,
    'medal': LucideIcons.medal,
    'trophy': LucideIcons.trophy,
    'footprints': LucideIcons.footprints,
    // Meals / food
    'utensils': LucideIcons.utensils,
    'apple': LucideIcons.apple,
    'salad': LucideIcons.salad,
    'beef': LucideIcons.beef,
    'cooking-pot': LucideIcons.cookingPot,
    'coffee': LucideIcons.coffee,
    // Inventory / commerce
    'package': LucideIcons.package,
    'package-open': LucideIcons.packageOpen,
    'box': LucideIcons.box,
    'shopping-cart': LucideIcons.shoppingCart,
    'shopping-bag': LucideIcons.shoppingBag,
    'archive': LucideIcons.archive,
    'warehouse': LucideIcons.warehouse,
    // Sauces / ingredients / liquids
    'droplet': LucideIcons.droplet,
    'droplets': LucideIcons.droplets,
    'flask-conical': LucideIcons.flaskConical,
    'test-tube': LucideIcons.testTube,
    // Assistants
    'bot': LucideIcons.bot,
    // General data / logs
    'list': LucideIcons.list,
    'list-checks': LucideIcons.listChecks,
    'clipboard': LucideIcons.clipboard,
    'clipboard-list': LucideIcons.clipboardList,
    'book': LucideIcons.book,
    'book-open': LucideIcons.bookOpen,
    'notebook': LucideIcons.notebook,
    'file-text': LucideIcons.fileText,
    'database': LucideIcons.database,
    'table': LucideIcons.table,
    // Time / tracking
    'calendar': LucideIcons.calendar,
    'calendar-check': LucideIcons.calendarCheck,
    'clock': LucideIcons.clock,
    'timer': LucideIcons.timer,
  };

  /// Returns a widget rendering [value], sized to fit [size]px. Falls back
  /// to [fallback] (or [LucideIcons.list]) when value is null/empty.
  static Widget resolve(
    String? value, {
    double size = 24,
    Color? color,
    IconData fallback = LucideIcons.list,
  }) {
    if (value == null || value.trim().isEmpty) {
      return Icon(fallback, size: size, color: color);
    }
    final v = value.trim();
    if (v.startsWith('http://') || v.startsWith('https://')) {
      return _UrlIcon(url: v, size: size);
    }
    final lucide = _lucideByName[v];
    if (lucide != null) {
      return Icon(lucide, size: size, color: color);
    }
    // Fallback: render as text (emoji or arbitrary unicode).
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          v,
          style: TextStyle(fontSize: size * 0.85, height: 1),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _UrlIcon extends StatelessWidget {
  final String url;
  final double size;
  const _UrlIcon({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.16),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(
          LucideIcons.imageOff,
          size: size,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}
