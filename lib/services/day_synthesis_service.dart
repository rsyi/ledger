import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/model_config.dart';
import '../models/view_schema.dart';
import 'day_synthesis.dart';
import 'llm_client.dart';
import 'plan_store.dart';
import 'program_current.dart';
import 'program_provider.dart';
import 'today_program_call.dart';
import 'warehouse_connector.dart';

/// The synthesis plus the small tally the post-log notification reads. The
/// synthesis text is what the card shows; the tally lets a notification
/// say "2 of 4 lifts hit; climbing still to come" without re-running the
/// LLM.
class DaySynthesisResult {
  final String text;
  final DateTime generatedAt;
  final int liftsHit;
  final int liftsPlanned;
  final bool climbToCome;

  const DaySynthesisResult({
    required this.text,
    required this.generatedAt,
    required this.liftsHit,
    required this.liftsPlanned,
    required this.climbToCome,
  });

  Map<String, Object?> toJson() => {
        'text': text,
        'generated_at': generatedAt.toIso8601String(),
        'lifts_hit': liftsHit,
        'lifts_planned': liftsPlanned,
        'climb_to_come': climbToCome,
      };

  static DaySynthesisResult? tryFromJson(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, Object?>;
      return DaySynthesisResult(
        text: m['text'] as String,
        generatedAt: DateTime.parse(m['generated_at'] as String),
        liftsHit: (m['lifts_hit'] as num?)?.toInt() ?? 0,
        liftsPlanned: (m['lifts_planned'] as num?)?.toInt() ?? 0,
        climbToCome: m['climb_to_come'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Produces the day synthesis: assembles today's context from the ledger +
/// program, calls the LLM behind the existing [LlmClient] seam, and caches
/// the result per-day in `shared_preferences`. Never throws — every read
/// degrades to an honest empty/partial context, and an LLM failure returns
/// null (the card keeps showing the last synthesis + a hint).
///
/// Disabled when [llm] is null (disable_post_log / no Anthropic model).
class DaySynthesisService {
  final LlmClient? llm;
  final String? modelName;

  final ViewSchema? mealsView;
  final WarehouseConnector? mealsRepo;
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;
  final ViewSchema? cardioView;
  final WarehouseConnector? cardioRepo;
  final ViewSchema? climbingView;
  final WarehouseConnector? climbingRepo;
  final ProgramProvider? provider;
  final DateTime Function() now;

  DaySynthesisService({
    required this.llm,
    required this.modelName,
    required this.mealsView,
    required this.mealsRepo,
    required this.strengthView,
    required this.strengthRepo,
    required this.cardioView,
    required this.cardioRepo,
    required this.climbingView,
    required this.climbingRepo,
    required this.provider,
    this.now = DateTime.now,
  });

  bool get enabled => llm != null && modelName != null;

  static const _prefsKey = 'day_synthesis';

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// The cached synthesis for today, or null if none / a different day.
  Future<DaySynthesisResult?> cached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, Object?>;
      if (m['day'] != _dayKey(now())) return null; // stale — new day
      return DaySynthesisResult.tryFromJson(jsonEncode(m['result']));
    } catch (_) {
      return null;
    }
  }

  Future<void> _store(DaySynthesisResult r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({'day': _dayKey(now()), 'result': r.toJson()}),
      );
    } catch (_) {/* best-effort */}
  }

  /// Assembles today's context. Public so the notification driver can read
  /// the tally without an LLM call.
  Future<DaySynthesisContext> buildContext() async {
    final clock = now();
    final dayStart = DateTime(clock.year, clock.month, clock.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    final meals = <SynthMeal>[];
    if (mealsView != null && mealsRepo != null) {
      try {
        for (final r in await mealsRepo!.list(mealsView!)) {
          final eaten = _date(r['eaten_at']);
          if (eaten == null) continue;
          if (eaten.isBefore(dayStart) || !eaten.isBefore(dayEnd)) continue;
          meals.add(SynthMeal(
            calories: _num(r['calories']),
            proteinG: _num(r['protein_g']),
            carbsG: _num(r['carbs_g']),
            fatG: _num(r['fat_g']),
            atHour: eaten.hour,
          ));
        }
      } catch (_) {/* honest empty */}
    }

    final sets = <SynthSet>[];
    if (strengthView != null && strengthRepo != null) {
      try {
        for (final r in await strengthRepo!.list(strengthView!)) {
          if (!_sameDay(_date(r['date']), dayStart)) continue;
          final ex = r['exercise']?.toString().trim();
          if (ex == null || ex.isEmpty) continue;
          sets.add(SynthSet(
            exercise: ex,
            weight: _num(r['weight']),
            reps: _num(r['reps'])?.round(),
          ));
        }
      } catch (_) {/* honest empty */}
    }

    var did4x4 = false;
    if (cardioView != null && cardioRepo != null) {
      try {
        for (final r in await cardioRepo!.list(cardioView!)) {
          if (!_sameDay(_date(r['date']), dayStart)) continue;
          final type = r['type']?.toString().toLowerCase() ?? '';
          if (type.contains('4x4') || type.contains('4 x 4')) did4x4 = true;
        }
      } catch (_) {/* honest empty */}
    }

    var climbCount = 0;
    if (climbingView != null && climbingRepo != null) {
      try {
        for (final r in await climbingRepo!.list(climbingView!)) {
          if (_sameDay(_date(r['date']), dayStart)) climbCount++;
        }
      } catch (_) {/* honest empty */}
    }

    // Program call + routine prose + targets from the slice.
    var program = const SynthProgramDay();
    var targets = const SynthTargets();
    var phase = '';
    final p = provider;
    if (p != null) {
      try {
        final docs = await p.load();
        if (docs.program != null) {
          final slice = programCurrent(docs.program!, docs.phase, clock);
          if (slice != null) {
            targets = SynthTargets(
              proteinGDay: _pair(slice.targetsInForce['protein_g_day']),
              carbsGDay: _pair(slice.targetsInForce['carbs_g_day']),
              fatGDayMin: _num(slice.targetsInForce['fat_g_day_min']),
            );
            phase = slice.block['emphasis']?.toString() ?? '';
            final call = todayProgramCallByView(
              docs.program!,
              docs.phase,
              clock,
            );
            final planned = <String>[];
            if (strengthView != null) {
              try {
                for (final e in await PlanStore.loadForDate(
                  strengthView!,
                  clock,
                )) {
                  final ex = e.values['exercise']?.toString().trim();
                  if (ex != null && ex.isNotEmpty) planned.add(ex);
                }
              } catch (_) {/* honest empty */}
            }
            program = SynthProgramDay(
              morning: slice.todayTemplate['morning']?.toString() ?? '',
              afternoon: slice.todayTemplate['afternoon']?.toString() ?? '',
              plannedLifts: planned,
              wants4x4: call.containsKey('cardio'),
              climbCall: call['climbing'],
            );
          }
        }
      } catch (_) {/* no program → still synthesize what's logged */}
    }

    return DaySynthesisContext(
      hour: clock.hour,
      phase: phase,
      program: program,
      logged: SynthLogged(
        meals: meals,
        sets: sets,
        did4x4: did4x4,
        climbCount: climbCount,
      ),
      targets: targets,
    );
  }

  /// Runs the synthesis: builds context, calls the LLM, caches + returns
  /// the result. Returns null when disabled or the call fails (the card
  /// keeps the previous synthesis). [context] may be supplied to reuse an
  /// already-built context.
  Future<DaySynthesisResult?> generate({DaySynthesisContext? context}) async {
    if (!enabled) return null;
    final c = context ?? await buildContext();
    final prompt = buildDaySynthesisPrompt(c);
    String text;
    try {
      text = await llm!.complete(modelName!, prompt);
    } catch (_) {
      return null;
    }
    if (text.trim().isEmpty) return null;
    final result = DaySynthesisResult(
      text: text.trim(),
      generatedAt: now(),
      liftsHit: c.liftsDone.length,
      liftsPlanned: c.liftsPlanned.length,
      climbToCome: c.climbToCome,
    );
    await _store(result);
    return result;
  }

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  static bool _sameDay(DateTime? d, DateTime day) =>
      d != null && d.year == day.year && d.month == day.month && d.day == day.day;

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static List<double>? _pair(Object? v) {
    if (v is List && v.length >= 2) {
      final a = _num(v[0]);
      final b = _num(v[1]);
      if (a != null && b != null) return [a, b];
    }
    return null;
  }
}

/// Convenience: which chat/vision Anthropic model to synthesize with.
/// Mirrors home_screen's `_chatModel` selection.
String? synthesisModelName(List<ModelConfig> models) {
  for (final m in models) {
    if (m.vendor == ModelVendor.anthropic) return m.name;
  }
  return null;
}
