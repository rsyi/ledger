import 'dart:convert';

import '../models/coach_proposal.dart';
import '../models/view_schema.dart';
import 'chat_runner.dart';
import 'moves_validation.dart';
import 'program_moves.dart' show EffectiveItem;

/// Receives a validated proposal. The chat screen persists it as a
/// `kind=proposal` coach_chat row; tests just collect it.
typedef ProposalSink = Future<void> Function(CoachProposal proposal);

/// Receives a validated moves proposal (missed-work carryover). The chat
/// screen persists it as a `kind=proposal` coach_chat row (type moves).
typedef MovesProposalSink = Future<void> Function(MovesProposal proposal);

/// Resolves the program's PRESCRIBED rows for [view] on [date] — the same
/// planned entries the routine screen + timeline show (built from the
/// program's routine week via `buildWeekPlannedEntries`, priced off the
/// working maxes). Returns an empty list when the day has no prescription
/// for that view (a rest day, or a non-lifting day for `strength`). The
/// coach grounds `propose_schedule` in this instead of a static template.
///
/// Null (constructed without a resolver — tests) disables `read_program_day`.
typedef ProgramDayResolver = Future<List<Map<String, Object?>>> Function(
    String view, DateTime date);

/// Tools for the coach chat's reply turn. Unlike [ChatToolset] (scoped
/// to one open view), the coach spans views, so every tool takes an
/// explicit `view` input. propose_schedule never writes PlanStore or
/// the ledger — the user confirms in the UI.
class CoachToolset {
  /// Views the coach may propose plans for.
  static const plannableViews = ['strength', 'cardio'];

  final Map<String, ViewSchema> views;
  final ProposalSink onProposal;

  /// Resolves the program's prescribed rows for a view+date. When null,
  /// `read_program_day` is omitted from [build] (the coach then proposes
  /// from the program slice already in its prompt).
  final ProgramDayResolver? programDay;

  /// Receives `propose_moves` results. When null, `propose_moves` is
  /// omitted from [build].
  final MovesProposalSink? onMovesProposal;

  /// Clock: `propose_moves` validates against this week.
  final DateTime Function() now;

  /// The effective (post-moves) week of [now] — plus next week's days, so
  /// a pulled-forward item's from day checks too — `propose_moves`
  /// checks each item exists on its from_date. Null, a null result or a
  /// throw skips the item check (dates are still validated).
  final Future<Map<DateTime, List<EffectiveItem>>?> Function()? movesWeek;

  /// The configured week start (week_start.dart), read AFTER [movesWeek]
  /// ran. Null → Monday.
  final int Function()? weekStartDay;

  CoachToolset({
    required this.views,
    required this.onProposal,
    this.programDay,
    this.onMovesProposal,
    this.now = DateTime.now,
    this.movesWeek,
    this.weekStartDay,
  });

  List<ChatTool> build() => [
        if (programDay != null) _readProgramDay(),
        _proposeSchedule(),
        if (onMovesProposal != null) _proposeMoves(),
      ];

  ViewSchema _plannableView(Map<String, dynamic> input) {
    final name = (input['view'] as String?)?.trim() ?? '';
    final view = views[name];
    if (!plannableViews.contains(name) || view == null) {
      throw StateError(
          'view must be one of: ${plannableViews.join(', ')} (got "$name")');
    }
    return view;
  }

  ChatTool _readProgramDay() {
    return ChatTool(
      name: 'read_program_day',
      description: 'Returns the program\'s PRESCRIBED workout for a given '
          'day — the concrete exercises, sets/reps, and weights the '
          'routine calls for on that date (priced off the current working '
          'maxes). view is "strength" or "cardio", date is ISO '
          'yyyy-MM-dd. Use this to ground propose_schedule in the actual '
          'program day (by weekday) instead of inventing a plan. An empty '
          'list means the program schedules nothing for that view that day '
          '(a rest day, or a non-lifting day).',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'view': {'type': 'string', 'description': 'strength | cardio'},
          'date': {
            'type': 'string',
            'description': 'Target day, ISO yyyy-MM-dd.',
          },
        },
        'required': ['view', 'date'],
      },
      run: (input) async {
        final view = _plannableView(input);
        final dateStr = (input['date'] as String?)?.trim() ?? '';
        final parsed = DateTime.tryParse(dateStr);
        if (parsed == null) {
          throw StateError('date must be ISO yyyy-MM-dd (got "$dateStr")');
        }
        final resolver = programDay;
        if (resolver == null) {
          throw StateError('program day resolution is unavailable');
        }
        final day = DateTime(parsed.year, parsed.month, parsed.day);
        final entries = await resolver(view.name, day);
        return const JsonEncoder.withIndent('  ').convert({
          'view': view.name,
          'date': dateStr,
          'entry_count': entries.length,
          'entries': entries,
        });
      },
    );
  }

  ChatTool _proposeSchedule() {
    return ChatTool(
      name: 'propose_schedule',
      description: 'Presents a concrete workout plan to the user as an '
          'in-chat card with Schedule / Not now buttons. Writes '
          'NOTHING — the user confirms in the UI. entries are concrete '
          'field→value rows (numbers already filled in). Ground the plan '
          'in the program day: call read_program_day first and mirror its '
          'prescribed exercises/weights, adjusting only as the '
          'conversation warrants. Pass a `group` label (e.g. the day\'s '
          'name) so the timeline groups the entries under one header. '
          'After calling, do not claim anything was scheduled; the card '
          'handles it.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'view': {'type': 'string', 'description': 'strength | cardio'},
          'date': {
            'type': 'string',
            'description': 'Target day, ISO yyyy-MM-dd.',
          },
          'group': {
            'type': 'string',
            'description': 'Group label for the timeline header, e.g. the '
                'program day\'s name (optional).',
          },
          'summary': {
            'type': 'string',
            'description': 'One-line description shown on the card.',
          },
          'entries': {
            'type': 'array',
            'items': {'type': 'object'},
            'description': 'Field→value map per planned row.',
          },
        },
        'required': ['view', 'date', 'entries'],
      },
      run: (input) async {
        final view = _plannableView(input);
        final dateStr = (input['date'] as String?)?.trim() ?? '';
        final parsed = DateTime.tryParse(dateStr);
        if (parsed == null) {
          throw StateError('date must be ISO yyyy-MM-dd (got "$dateStr")');
        }
        final rawEntries = input['entries'];
        if (rawEntries is! List || rawEntries.isEmpty) {
          throw StateError('entries must be a non-empty array of objects');
        }
        final dimNames = {
          for (final d in view.dimensions)
            if (d.name != 'id') d.name,
        };
        final requiredFields = [
          for (final d in view.dimensions)
            if ((d.input?.required ?? false) && d.name != view.dateField)
              d.name,
        ];
        final entries = <Map<String, Object?>>[];
        for (final raw in rawEntries) {
          if (raw is! Map) {
            throw StateError('each entry must be an object');
          }
          final entry = raw.map((k, v) => MapEntry(k.toString(), v));
          // Date lives at the proposal level; strip a redundant date key
          // rather than rejecting it.
          if (view.dateField != null) entry.remove(view.dateField);
          for (final key in entry.keys) {
            if (!dimNames.contains(key)) {
              throw StateError('unknown field "$key" for ${view.name}. '
                  'Valid: ${dimNames.join(', ')}');
            }
          }
          for (final req in requiredFields) {
            final v = entry[req];
            if (v == null || v.toString().trim().isEmpty) {
              throw StateError(
                  'required field "$req" missing in entry: $entry');
            }
          }
          entries.add(entry);
        }
        // `group` is the timeline group label (was `template`). Accept the
        // legacy `template` key too so an older tool call still groups.
        final group = ((input['group'] ?? input['template']) as String?)
            ?.trim();
        final proposal = CoachProposal(
          view: view.name,
          date: DateTime(parsed.year, parsed.month, parsed.day),
          template: (group?.isEmpty ?? true) ? null : group,
          summary: (input['summary'] as String?)?.trim() ?? '',
          entries: entries,
        );
        await onProposal(proposal);
        return 'Proposal presented to the user — they will confirm or '
            'decline in the UI. Do not claim it is scheduled.';
      },
    );
  }

  ChatTool _proposeMoves() {
    return ChatTool(
      name: 'propose_moves',
      description: 'Proposes moving program items between days of THIS '
          'week (missed-work carryover; the week runs on the user\'s '
          'configured start day — see the moves section). Shows him a card with '
          'Schedule / Not now; Schedule records the moves. Writes NOTHING '
          'itself. Copy `item`, `from_date` and `period` EXACTLY from the '
          'missed list (from_date = the program\'s original day, even if '
          'the item was already moved once). to_date must be a remaining '
          'day of this week (today..the week\'s last day) and differ from '
          'from_date; it may PULL an item from next week up to 7 days '
          'earlier, never push one past the week end. '
          'Items you let expire are simply left out. After calling, never '
          'claim anything moved; the card handles it.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'summary': {
            'type': 'string',
            'description': 'One line shown on the card, e.g. '
                '"Bench top set Wed → Fri".',
          },
          'moves': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'item': {'type': 'string'},
                'from_date': {
                  'type': 'string',
                  'description': 'Program\'s original day, yyyy-MM-dd.',
                },
                'to_date': {
                  'type': 'string',
                  'description': 'Target day, yyyy-MM-dd.',
                },
                'period': {'type': 'string', 'description': 'AM | PM'},
                'note': {'type': 'string'},
              },
              'required': ['item', 'from_date', 'to_date'],
            },
          },
        },
        'required': ['summary', 'moves'],
      },
      run: (input) async {
        Map<DateTime, List<EffectiveItem>>? week;
        try {
          week = await movesWeek?.call();
        } catch (_) {/* program unavailable: dates-only validation */}
        final proposal = validateMovesInput(input, now(),
            week: week, weekStartDay: weekStartDay?.call() ?? DateTime.monday);
        await onMovesProposal!(proposal);
        return 'Moves proposal presented to the user — they will confirm '
            'or decline on the card. Do not claim anything moved.';
      },
    );
  }

  /// Validates a `propose_moves` input against [now]'s [weekStartDay] week
  /// via the shared [checkProposedMove]: every move needs an item,
  /// parseable yyyy-MM-dd dates, from AND to inside the week, to not
  /// before today, to != from and — when [week] is given — an item that
  /// exists on from_date (canonical name; re-keyed to its home day when
  /// it was moved there). Throws a [StateError] naming the bad move (the
  /// tool loop reports it to the model, which can retry).
  static MovesProposal validateMovesInput(
      Map<String, dynamic> input, DateTime now,
      {Map<DateTime, List<EffectiveItem>>? week,
      int weekStartDay = DateTime.monday}) {
    final rawMoves = input['moves'];
    if (rawMoves is! List || rawMoves.isEmpty) {
      throw StateError('moves must be a non-empty array of objects');
    }
    DateTime parse(Object? raw, String field, int i) {
      final s = raw?.toString().trim() ?? '';
      final d = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)
          ? DateTime.tryParse(s)
          : null;
      if (d == null) {
        throw StateError('moves[$i].$field must be yyyy-MM-dd (got "$s")');
      }
      return DateTime(d.year, d.month, d.day);
    }

    final moves = <ProposedMove>[];
    for (var i = 0; i < rawMoves.length; i++) {
      final raw = rawMoves[i];
      if (raw is! Map) throw StateError('moves[$i] must be an object');
      final item = raw['item']?.toString().trim() ?? '';
      if (item.isEmpty) throw StateError('moves[$i].item is required');
      moves.add(checkProposedMove(
        ProposedMove(
          item: item,
          from: parse(raw['from_date'], 'from_date', i),
          to: parse(raw['to_date'], 'to_date', i),
          period: raw['period']?.toString().trim() ?? '',
          note: raw['note']?.toString().trim() ?? '',
        ),
        today: now,
        week: week,
        label: 'moves[$i]',
        weekStartDay: weekStartDay,
      ));
    }
    return MovesProposal(
      summary: (input['summary'] as String?)?.trim() ?? '',
      moves: moves,
    );
  }
}
