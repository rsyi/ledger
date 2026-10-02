/// One Log-tab tracker row (UI redesign phase 5): icon · human name /
/// one-line meta below · chevron, on the shared [ExerciseRow] pattern so every
/// row is the same height. The meta is today's program call for the
/// domain when there is one (accent), else the view description's first
/// clause.
library;

import 'package:flutter/material.dart';

import '../../services/display_names.dart';
import '../../services/icon_resolver.dart';
import '../design/design.dart';

/// Meta line for a Log row: today's call (accent) wins, else the
/// declared summary, else the description's first clause. Null text = name only.
({String? text, bool accent}) logRowMeta({
  String? todayCall,
  bool waiting = false,
  String? summary,
  String? description,
}) {
  if (todayCall != null && todayCall.trim().isNotEmpty) {
    return (
      text: waiting
          ? 'Today: $todayCall · waiting to log'
          : 'Today: $todayCall',
      accent: true,
    );
  }
  final s = summary?.trim();
  if (s != null && s.isNotEmpty) return (text: s, accent: false);
  return (text: shortDescription(description, maxChars: 40), accent: false);
}

class LogListRow extends StatelessWidget {
  final String label;

  /// Lucide name / emoji / URL (IconResolver vocabulary).
  final String? icon;

  final String? todayCall;
  final bool waiting;

  /// Declared one-liner (dashboards.yaml domain `description:`), shown
  /// as-is.
  final String? summary;

  /// Schema description — cut to its first clause.
  final String? description;
  final VoidCallback onTap;

  const LogListRow({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.todayCall,
    this.waiting = false,
    this.summary,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = logRowMeta(
      todayCall: todayCall,
      waiting: waiting,
      summary: summary,
      description: description,
    );
    // Name on the first line, the meta below it (always present — an
    // empty line keeps every row the same height): the live "Today: …"
    // call is the row's most useful words and shouldn't be squeezed
    // into the name line.
    return ExerciseRow(
      name: label,
      subtitle: Text(
        meta.text ?? '',
        style: meta.accent
            ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w500)
            : null,
      ),
      leading: IconResolver.resolve(
        icon,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
