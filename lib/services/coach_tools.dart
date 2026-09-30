import 'dart:convert';

import '../models/coach_proposal.dart';
import '../models/view_schema.dart';
import 'chat_runner.dart';

/// Receives a validated proposal. The chat screen persists it as a
/// `kind=proposal` coach_chat row; tests just collect it.
typedef ProposalSink = Future<void> Function(CoachProposal proposal);

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

  /// Clock override for testing. Reserved for a future guard that
  /// rejects proposals placed too far in the past. Not yet consumed.
  final DateTime Function() now;

  CoachToolset({
    required this.views,
    required this.onProposal,
    this.programDay,
    this.now = DateTime.now,
  });

  List<ChatTool> build() => [
        if (programDay != null) _readProgramDay(),
        _proposeSchedule(),
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
}
