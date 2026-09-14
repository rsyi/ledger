import 'dart:convert';

import '../models/coach_proposal.dart';
import '../models/view_schema.dart';
import 'chat_runner.dart';
import 'template_loader.dart';

/// Receives a validated proposal. The chat screen persists it as a
/// `kind=proposal` coach_chat row; tests just collect it.
typedef ProposalSink = Future<void> Function(CoachProposal proposal);

/// Tools for the coach chat's reply turn. Unlike [ChatToolset] (scoped
/// to one open view), the coach spans views, so every tool takes an
/// explicit `view` input. propose_schedule never writes PlanStore or
/// the ledger — the user confirms in the UI.
class CoachToolset {
  /// Views the coach may propose plans for.
  static const plannableViews = ['strength', 'cardio'];

  final Map<String, ViewSchema> views;
  final ProposalSink onProposal;

  /// Clock override for testing. Reserved for a future guard that
  /// rejects proposals placed too far in the past. Not yet consumed.
  final DateTime Function() now;

  CoachToolset({
    required this.views,
    required this.onProposal,
    this.now = DateTime.now,
  });

  List<ChatTool> build() =>
      [_listTemplates(), _readTemplate(), _proposeSchedule()];

  ViewSchema _plannableView(Map<String, dynamic> input) {
    final name = (input['view'] as String?)?.trim() ?? '';
    final view = views[name];
    if (!plannableViews.contains(name) || view == null) {
      throw StateError(
          'view must be one of: ${plannableViews.join(', ')} (got "$name")');
    }
    return view;
  }

  ChatTool _listTemplates() {
    return ChatTool(
      name: 'list_templates',
      description: 'Lists workout templates for a view — name, '
          'description, entry count, variables. view is "strength" or '
          '"cardio". Use before propose_schedule to pick the right '
          'template (e.g. strength.cut_press_heavy for a combined '
          'bench+OHP day).',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'view': {'type': 'string', 'description': 'strength | cardio'},
        },
        'required': ['view'],
      },
      run: (input) async {
        final view = _plannableView(input);
        final templates = await TemplateLoader.loadForView(view.name);
        return const JsonEncoder.withIndent('  ').convert([
          for (final t in templates)
            {
              'name': t.name,
              if (t.description != null) 'description': t.description,
              'entry_count': t.entries.length,
              'variables': t.variables
                  .map((v) => {
                        'name': v.name,
                        'type': v.type.name,
                        if (v.label != v.name) 'label': v.label,
                        if (v.defaultValue != null) 'default': v.defaultValue,
                      })
                  .toList(),
            },
        ]);
      },
    );
  }

  ChatTool _readTemplate() {
    return ChatTool(
      name: 'read_template',
      description: 'Full content of one template (variables + entry '
          'rows, Jinja unrendered). Use before propose_schedule so the '
          'entries you propose mirror the template with concrete '
          'numbers filled in from the ledger data.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'view': {'type': 'string', 'description': 'strength | cardio'},
          'name': {'type': 'string', 'description': 'Template name.'},
        },
        'required': ['view', 'name'],
      },
      run: (input) async {
        final view = _plannableView(input);
        final name = (input['name'] as String).trim();
        final templates = await TemplateLoader.loadForView(view.name);
        final t = templates.where((t) => t.name == name).firstOrNull;
        if (t == null) {
          throw StateError('Template "$name" not found for ${view.name}. '
              'Known: ${templates.map((t) => t.name).join(', ')}');
        }
        return const JsonEncoder.withIndent('  ').convert({
          'name': t.name,
          'view': t.view,
          if (t.description != null) 'description': t.description,
          'variables': t.variables
              .map((v) => {
                    'name': v.name,
                    'type': v.type.name,
                    if (v.label != v.name) 'label': v.label,
                    if (v.defaultValue != null) 'default': v.defaultValue,
                  })
              .toList(),
          'entries': t.entries,
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
          'field→value rows (numbers already filled in — no Jinja). '
          'Include a template name when the plan follows one, so the '
          'timeline groups the entries under it. After calling, do not '
          'claim anything was scheduled; the card handles it.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'view': {'type': 'string', 'description': 'strength | cardio'},
          'date': {
            'type': 'string',
            'description': 'Target day, ISO yyyy-MM-dd.',
          },
          'template': {
            'type': 'string',
            'description': 'Template this plan follows (optional).',
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
        final proposal = CoachProposal(
          view: view.name,
          date: DateTime(parsed.year, parsed.month, parsed.day),
          template: (input['template'] as String?)?.trim(),
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
