# Coach Scheduling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Coach docs teach the coach to plan from last week's actual workouts (Monday press anchor, carryover rule, deficit consequences); the coach chat gains a propose → confirm → schedule → highlight → undo loop.

**Architecture:** Part A edits `routine.md` in the schemas repo (injected into every coach prompt — one edit fixes briefing + replies). Part B moves `CoachBrain.reply` from single-shot `LlmClient.complete` onto the existing `ChatRunner` streaming tool loop with a new `CoachToolset` (`list_templates` / `read_template` / `propose_schedule`). Proposals persist as `kind=proposal` coach_chat rows whose `text` is JSON (no schema change); schedule/undo state + PlanStore localIds live device-local in SharedPreferences. The chat renders proposal rows as a card; Schedule writes PlanStore and pushes the timeline with new `initialDate`/`highlightKeys` params.

**Tech Stack:** Flutter/Dart, Anthropic messages API (via existing `ChatRunner`), SharedPreferences, existing PlanStore/TemplateLoader.

**Spec:** `docs/superpowers/specs/2026-09-13-coach-scheduling-design.md`

**Repos:** Task 1 in `~/repos/airledger-fitness`; all other tasks in `~/repos/ledger`. Commit style: conventional, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (all repos).

**Known-failure baseline:** `flutter test` has 7 pre-existing failures (3 live-DB integration suites + 4 schema_loader). `flutter analyze` baseline ~32 infos. Anything beyond those is a regression you introduced.

---

## File structure

| File | Responsibility |
|---|---|
| `~/repos/airledger-fitness/coach/routine.md` (modify) | Monday anchor, carryover rule, deficit consequences |
| `lib/models/coach_proposal.dart` (create) | Proposal payload: encode to / parse from a chat row's `text` |
| `lib/services/coach_proposal_store.dart` (create) | Device-local proposal status + localIds (SharedPreferences) |
| `lib/services/coach_tools.dart` (create) | `CoachToolset`: list_templates / read_template / propose_schedule |
| `lib/services/coach_brain.dart` (modify) | Reply turn via ChatRunner + CoachToolset; system prompt |
| `lib/ui/widgets/coach_proposal_card.dart` (create) | Proposal card widget (pending/scheduled/undone/dismissed) |
| `lib/ui/coach_chat_screen.dart` (modify) | Render proposal rows as cards; schedule/undo/dismiss handlers |
| `lib/ui/coach_threads_screen.dart` (modify) | Pass-through of the timeline opener |
| `lib/ui/timeline_screen.dart` (modify) | `initialDate` + `highlightKeys` params, highlight fade |
| `lib/ui/home_screen.dart` (modify) | CoachBrain constructor change; build + thread the opener |
| `test/coach_proposal_test.dart` (create) | Payload round-trip + malformed fallback |
| `test/coach_proposal_store_test.dart` (create) | State persistence |
| `test/coach_tools_test.dart` (create) | propose_schedule validation |
| `test/coach_proposal_card_test.dart` (create) | Card states widget test |
| `test/coach_brain_test.dart` (modify) | Constructor + prompt-structure updates |
| `CLAUDE.md` (modify) | Feature-state + docs notes |

---

### Task 1: routine.md — anchors, carryover, deficit (airledger-fitness)

**Files:**
- Modify: `~/repos/airledger-fitness/coach/routine.md`

- [ ] **Step 1: Edit the doc**

Change the dateline (line 3) from `(as of 2026-09-11 · templates live in `../views/`)` to `(as of 2026-09-13 · templates live in `../views/`)`.

Then insert the following three sections BETWEEN the end of "## The week, by rule" (after the "Net load…" paragraph) and "## Scheduling guidance for the coach":

```markdown
## Weekday anchors

- **Monday = press day** — bench + rows by default. The carryover rule
  below can upgrade it to the combined heavy press day.
- No other weekday is anchored; slot the rest of the week by the rules
  above and the scheduling guidance below.

## Carryover rule — check before proposing ANY session

Look at the trailing 7 days of the strength ledger and note which main
lifts (squat, deadlift, bench, OHP) were actually LOGGED — not planned,
logged. A main lift the rules called for that never got logged folds
into the next compatible day:

- Skipped OHP → the next press day (usually Monday) becomes the
  combined heavy press day (`strength.cut_press_heavy` — bench first,
  fresh; then OHP). Keep rows only if recovery allows.
- Skipped bench → same, combined press day, bench still first.
- Skipped squat or deadlift day → re-slot it per the week-parity
  algorithm below; squat and deadlift still never share a day.

State your carryover reasoning in one line (like the parity line) so
mistakes are visible — e.g. "OHP not logged since Tue → Monday is the
combined press day."

## Deficit consequences (cut phase)

The calorie deficit (goals.md) reduces recovery. Concretely:

- When folding a skipped lift forward, drop accessories before mains —
  NEVER stack extra volume onto a day to "catch up".
- Maintain loads; no PR chasing. A flat e1RM on the cut is a win.
- Low-energy / hunger / soreness flags in the daily notes outrank the
  default rotation AND this carryover rule.
```

- [ ] **Step 2: Sanity-check the render**

Run: `head -80 ~/repos/airledger-fitness/coach/routine.md`
Expected: the three new sections appear between "Net load…" and "## Scheduling guidance for the coach"; existing content untouched.

- [ ] **Step 3: Commit AND PUSH (trap #2 — unpushed coach docs are invisible to the app)**

```bash
cd ~/repos/airledger-fitness
git add coach/routine.md
git commit -m "coach: Monday press anchor, skipped-lift carryover rule, deficit consequences

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 2: CoachProposal model

**Files:**
- Create: `lib/models/coach_proposal.dart`
- Test: `test/coach_proposal_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/coach_proposal.dart';

void main() {
  test('encode/parse round-trip', () {
    final p = CoachProposal(
      view: 'strength',
      date: DateTime(2026, 9, 14),
      template: 'cut_press_heavy',
      summary: 'Combined press day',
      entries: [
        {'exercise': 'Bench Press', 'weight': 185, 'reps': 5},
        {'exercise': 'Overhead Press', 'weight': 115, 'reps': 5},
      ],
    );
    final parsed = CoachProposal.tryParse(p.encode());
    expect(parsed, isNotNull);
    expect(parsed!.view, 'strength');
    expect(parsed.date, DateTime(2026, 9, 14));
    expect(parsed.template, 'cut_press_heavy');
    expect(parsed.summary, 'Combined press day');
    expect(parsed.entries, hasLength(2));
    expect(parsed.entries.first['weight'], 185);
  });

  test('optional template/summary survive as null/empty', () {
    final p = CoachProposal(
      view: 'cardio',
      date: DateTime(2026, 9, 15),
      summary: '',
      entries: [
        {'type': '4x4'},
      ],
    );
    final parsed = CoachProposal.tryParse(p.encode())!;
    expect(parsed.template, isNull);
    expect(parsed.summary, '');
  });

  test('tryParse rejects malformed payloads', () {
    expect(CoachProposal.tryParse('plain chat text'), isNull);
    expect(CoachProposal.tryParse('{"v":1}'), isNull); // missing keys
    expect(CoachProposal.tryParse('{"v":2,"view":"strength","date":"2026-09-14","entries":[{}]}'),
        isNull); // wrong version
    expect(CoachProposal.tryParse('{"v":1,"view":"strength","date":"not-a-date","entries":[{}]}'),
        isNull);
    expect(CoachProposal.tryParse('{"v":1,"view":"strength","date":"2026-09-14","entries":[]}'),
        isNull); // empty entries
    expect(CoachProposal.tryParse('[]'), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/repos/ledger && flutter test test/coach_proposal_test.dart`
Expected: FAIL — `Target of URI doesn't exist ... coach_proposal.dart`

- [ ] **Step 3: Write the model**

```dart
import 'dart:convert';

/// A schedule proposal the coach made in chat. Serialized into the
/// `text` of a `role=coach, kind=proposal` coach_chat row — no schema
/// change, so no engine work. `tryParse` returning null is the
/// malformed-payload fallback: the row renders as a plain bubble.
class CoachProposal {
  static const version = 1;

  /// Target view name (e.g. `strength`).
  final String view;

  /// Date-only target day for the planned entries.
  final DateTime date;

  /// Template attribution for timeline grouping. Null for ad-hoc plans.
  final String? template;

  /// One-line human summary shown on the card header.
  final String summary;

  /// Field→value maps, one per planned entry. Values are plain JSON
  /// types (num/String/bool) matching the view's dimensions.
  final List<Map<String, Object?>> entries;

  CoachProposal({
    required this.view,
    required this.date,
    this.template,
    required this.summary,
    required this.entries,
  });

  String encode() => jsonEncode({
        'v': version,
        'view': view,
        'date': _fmtDate(date),
        if (template != null) 'template': template,
        'summary': summary,
        'entries': entries,
      });

  /// Null unless [text] is a valid v1 proposal payload.
  static CoachProposal? tryParse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['v'] != version) return null;
    final view = decoded['view'];
    final rawDate = decoded['date'];
    final rawEntries = decoded['entries'];
    if (view is! String || view.isEmpty) return null;
    if (rawDate is! String) return null;
    final date = DateTime.tryParse(rawDate);
    if (date == null) return null;
    if (rawEntries is! List || rawEntries.isEmpty) return null;
    final entries = <Map<String, Object?>>[];
    for (final e in rawEntries) {
      if (e is! Map) return null;
      entries.add(e.map((k, v) => MapEntry(k.toString(), v)));
    }
    return CoachProposal(
      view: view,
      date: DateTime(date.year, date.month, date.day),
      template: decoded['template'] as String?,
      summary: decoded['summary']?.toString() ?? '',
      entries: entries,
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/coach_proposal_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/models/coach_proposal.dart test/coach_proposal_test.dart
git commit -m "feat(coach): CoachProposal payload model for kind=proposal chat rows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: CoachProposalStore (device-local state)

**Files:**
- Create: `lib/services/coach_proposal_store.dart`
- Test: `test/coach_proposal_store_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:airledger/services/coach_proposal_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('absent row id loads null (pending)', () async {
    expect(await CoachProposalStore.load('row-1'), isNull);
  });

  test('save/load round-trip with localIds', () async {
    await CoachProposalStore.save(
      'row-1',
      const CoachProposalState(
        status: CoachProposalStatus.scheduled,
        localIds: ['a', 'b'],
      ),
    );
    final st = await CoachProposalStore.load('row-1');
    expect(st!.status, CoachProposalStatus.scheduled);
    expect(st.localIds, ['a', 'b']);
  });

  test('overwrite moves scheduled -> undone', () async {
    await CoachProposalStore.save(
      'row-1',
      const CoachProposalState(
        status: CoachProposalStatus.scheduled,
        localIds: ['a'],
      ),
    );
    await CoachProposalStore.save(
      'row-1',
      const CoachProposalState(
        status: CoachProposalStatus.undone,
        localIds: [],
      ),
    );
    final st = await CoachProposalStore.load('row-1');
    expect(st!.status, CoachProposalStatus.undone);
    expect(st.localIds, isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/coach_proposal_store_test.dart`
Expected: FAIL — `Target of URI doesn't exist ... coach_proposal_store.dart`

- [ ] **Step 3: Write the store**

```dart
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Lifecycle of a coach proposal on THIS device. Absent from the store
/// means pending (never acted on).
enum CoachProposalStatus { scheduled, undone, dismissed }

class CoachProposalState {
  final CoachProposalStatus status;

  /// PlanStore localIds created by the last Schedule tap — what Undo
  /// removes. Empty for undone/dismissed.
  final List<String> localIds;

  const CoachProposalState({required this.status, required this.localIds});
}

/// Device-local proposal state, one SharedPreferences key per proposal
/// chat row: `coach_proposal:<rowId>`. Local by design — planned
/// entries themselves are device-local (PlanStore), so their
/// bookkeeping is too.
class CoachProposalStore {
  static String _key(String rowId) => 'coach_proposal:$rowId';

  static Future<CoachProposalState?> load(String rowId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(rowId));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map;
      final status = CoachProposalStatus.values
          .where((s) => s.name == map['status'])
          .firstOrNull;
      if (status == null) return null;
      final ids = (map['local_ids'] as List? ?? const [])
          .map((e) => e.toString())
          .toList();
      return CoachProposalState(status: status, localIds: ids);
    } catch (_) {
      return null; // corrupt entry → treat as pending
    }
  }

  static Future<void> save(String rowId, CoachProposalState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(rowId),
      jsonEncode({'status': state.status.name, 'local_ids': state.localIds}),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/coach_proposal_store_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/services/coach_proposal_store.dart test/coach_proposal_store_test.dart
git commit -m "feat(coach): device-local proposal status + localId store

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: CoachToolset — list_templates / read_template / propose_schedule

**Files:**
- Create: `lib/services/coach_tools.dart`
- Test: `test/coach_tools_test.dart`

Reference: `lib/services/chat_tools.dart` (`ChatToolset`) has the single-view versions of the template tools; `lib/services/chat_runner.dart` defines `ChatTool`. The coach versions take an explicit `view` input instead of being scoped to one view. `propose_schedule` NEVER writes PlanStore or the ledger — it validates, then hands a `CoachProposal` to an injected sink (the chat screen persists the row; see Task 6).

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/coach_tools.dart';

ViewSchema _view(String name, List<String> dims,
        {Set<String> required = const {}}) =>
    ViewSchema(
      name: name,
      datasource: 'gsheets',
      table: name,
      entities: const [],
      measures: const [],
      dateField: dims.contains('date') ? 'date' : null,
      dimensions: [
        for (final d in dims)
          Dimension(
            name: d,
            type: d == 'date' ? DimensionType.date : DimensionType.string,
            expr: d,
            input: required.contains(d)
                ? InputSpec(widget: WidgetType.text, required: true)
                : null,
          ),
      ],
    );

void main() {
  late List<CoachProposal> sunk;

  CoachToolset toolset() {
    sunk = [];
    return CoachToolset(
      views: {
        'strength': _view('strength', ['id', 'date', 'exercise', 'weight', 'reps'],
            required: {'exercise'}),
        'cardio': _view('cardio', ['id', 'date', 'type']),
        'coach_chat': _view('coach_chat', ['id', 'date', 'ts', 'text']),
      },
      onProposal: (p) async => sunk.add(p),
      now: () => DateTime(2026, 9, 13),
    );
  }

  Future<String> run(CoachToolset t, Map<String, dynamic> input) =>
      t.build().firstWhere((tool) => tool.name == 'propose_schedule').run(input);

  test('happy path sinks a proposal and returns confirmation', () async {
    final t = toolset();
    final result = await run(t, {
      'view': 'strength',
      'date': '2026-09-14',
      'template': 'cut_press_heavy',
      'summary': 'Combined press day',
      'entries': [
        {'exercise': 'Bench Press', 'weight': 185, 'reps': 5},
      ],
    });
    expect(sunk, hasLength(1));
    expect(sunk.first.view, 'strength');
    expect(sunk.first.date, DateTime(2026, 9, 14));
    expect(sunk.first.entries.single['exercise'], 'Bench Press');
    expect(result, contains('confirm'));
  });

  test('rejects non-plannable view', () async {
    final t = toolset();
    await expectLater(
        run(t, {
          'view': 'coach_chat',
          'date': '2026-09-14',
          'entries': [
            {'text': 'hi'}
          ],
        }),
        throwsStateError);
    expect(sunk, isEmpty);
  });

  test('rejects bad date, empty entries, unknown field, missing required',
      () async {
    final t = toolset();
    await expectLater(
        run(t, {
          'view': 'strength',
          'date': 'next monday',
          'entries': [
            {'exercise': 'Bench'}
          ],
        }),
        throwsStateError);
    await expectLater(
        run(t, {'view': 'strength', 'date': '2026-09-14', 'entries': []}),
        throwsStateError);
    await expectLater(
        run(t, {
          'view': 'strength',
          'date': '2026-09-14',
          'entries': [
            {'exercise': 'Bench', 'wieght': 185}
          ],
        }),
        throwsStateError);
    await expectLater(
        run(t, {
          'view': 'strength',
          'date': '2026-09-14',
          'entries': [
            {'weight': 185}
          ],
        }),
        throwsStateError);
    expect(sunk, isEmpty);
  });

  test('date dim inside an entry is stripped, not rejected', () async {
    final t = toolset();
    await run(t, {
      'view': 'strength',
      'date': '2026-09-14',
      'entries': [
        {'date': '2026-09-14', 'exercise': 'Bench'},
      ],
    });
    expect(sunk.single.entries.single.containsKey('date'), isFalse);
  });
}
```

Note: check `ViewSchema`'s actual constructor in `lib/models/view_schema.dart` while writing — if `dateField` is derived rather than a constructor param, set it the way `test/coach_brain_test.dart`'s `_view` helper does and adapt.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/coach_tools_test.dart`
Expected: FAIL — `Target of URI doesn't exist ... coach_tools.dart`

- [ ] **Step 3: Write the toolset**

```dart
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
        final required = [
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
          for (final req in required) {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/coach_tools_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/services/coach_tools.dart test/coach_tools_test.dart
git commit -m "feat(coach): CoachToolset — template read tools + validating propose_schedule

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: CoachBrain on the ChatRunner tool loop

**Files:**
- Modify: `lib/services/coach_brain.dart`
- Modify: `test/coach_brain_test.dart`
- Modify: `lib/ui/home_screen.dart:389-397` (CoachBrain construction)

- [ ] **Step 1: Update the failing tests first**

In `test/coach_brain_test.dart`:
1. Add imports:
```dart
import 'package:airledger/models/model_config.dart';
```
2. Replace the `brain(...)` helper's constructor args `llm: LlmClient(const []), modelName: 'sonnet',` with:
```dart
        model: ModelConfig(
          name: 'sonnet',
          vendor: ModelVendor.anthropic,
          modelRef: 'claude-sonnet-4-6',
          apiKey: 'test-key',
          apiUrl: 'https://api.anthropic.com/v1',
        ),
```
3. Remove the now-unused `import ... llm_client.dart` line.
4. Add one new test asserting prompt split:
```dart
  test('buildSystemPrompt has docs+dump but no chat history; buildPrompt '
      'still appends history', () async {
    final b = brain();
    final system = await b.buildSystemPrompt(today);
    expect(system, contains('## Coach docs'));
    expect(system, contains('## Ledger data'));
    expect(system, isNot(contains('## Chat history')));
    final full = await b.buildPrompt([
      {'role': 'user', 'ts': '2026-09-13T10:00:00', 'text': 'hi'},
    ]);
    expect(full, contains('## Chat history'));
    expect(full, contains('[user] hi'));
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/coach_brain_test.dart`
Expected: FAIL — no `model` parameter / no `buildSystemPrompt`.

- [ ] **Step 3: Rework CoachBrain**

In `lib/services/coach_brain.dart`:

1. Replace imports of `llm_client.dart` usage with:
```dart
import '../models/coach_proposal.dart';
import '../models/model_config.dart';
import 'chat_runner.dart';
import 'coach_tools.dart';
```
(keep the other existing imports; drop `llm_client.dart`).

2. Replace the fields/constructor `llm` + `modelName` with:
```dart
  /// Anthropic model the reply turn runs on (ChatRunner requires
  /// anthropic vendor — home_screen's _chatModel already selects one).
  final ModelConfig model;
```
and in the constructor: `required this.model,` (delete `llm`/`modelName`).

3. Replace `reply` with:
```dart
  /// One full reply turn on the ChatRunner tool loop: system prompt =
  /// docs + ledger dump; the thread history rides in a single user
  /// turn (keeps Anthropic's user-first/alternation rules trivially
  /// satisfied). [onProposal] fires when the model calls
  /// propose_schedule — the caller persists the proposal row. Returns
  /// the assistant's text (all text blocks, tool-turn preambles
  /// included). Throws on API failure — the caller surfaces the error.
  Future<String> reply(
    List<Record> history, {
    required ProposalSink onProposal,
  }) async {
    final system = await buildSystemPrompt(now());
    final userTurn = '## Chat history (oldest first)\n\n'
        '${renderHistory(history)}\n\n'
        'Reply to the newest user message(s) now.';
    final tools =
        CoachToolset(views: views, onProposal: onProposal, now: now).build();
    final runner = ChatRunner(model);
    final texts = <String>[];
    await for (final ev in runner.runStream(
      systemPrompt: system,
      initialConversation: [ChatTurn(role: 'user', content: userTurn)],
      tools: tools,
    )) {
      if (ev is TurnComplete) {
        for (final turn in ev.conversation) {
          if (turn.role != 'assistant') continue;
          final t = turn.text;
          if (t.isNotEmpty) texts.add(t);
        }
      }
    }
    return texts.join('\n\n').trim();
  }
```

4. Update the system prompt constant — replace the final paragraph of `systemPrompt` (`Plain text, concise ... you cannot edit files from here.'''`) with:
```dart
Plain text, concise (this renders as a chat bubble on a phone). Light
markdown is fine — short lines, a few bullets. Do NOT output JSON in
your text.

You have tools. When he asks to plan or schedule a workout (or agrees
to a plan you suggested), use list_templates / read_template to ground
the plan in a template, fill in concrete numbers from the ledger data,
and call propose_schedule — it shows him a card with Schedule / Not
now buttons. Never claim something is scheduled; the card handles
confirmation. Follow routine.md's carryover rule and state your
reasoning in one line. If he asks to change goals or routine, describe
the change and note that editing coach/*.md happens in a desktop
Claude session — you cannot edit files from here.''';
```

5. Split prompt assembly — replace `buildPrompt` with:
```dart
  /// System-prompt half: instructions, TODAY, coach docs, ledger dump.
  Future<String> buildSystemPrompt(DateTime today) async {
    final docs = await _docsSection();
    final dump = await _ledgerDump(today);
    return [
      systemPrompt,
      'TODAY: ${_fmtDate(today)}',
      '## Coach docs\n\n$docs',
      '## Ledger data (last ${dumpWindow.inDays} days + planned)\n\n$dump',
    ].join('\n\n');
  }

  /// Full single-string prompt (system half + history). Kept for tests
  /// and prompt inspection; [reply] sends the halves separately.
  Future<String> buildPrompt(List<Record> history) async {
    final system = await buildSystemPrompt(now());
    return [
      system,
      '## Chat history (oldest first)\n\n${renderHistory(history)}',
      'Reply to the newest user message(s) now.',
    ].join('\n\n');
  }
```

6. In `lib/ui/home_screen.dart` (~line 389) update construction:
```dart
              final coachBrain = data.llm == null || chatModel == null
                  ? null
                  : CoachBrain(
                      model: chatModel,
                      repository: data.repository,
                      views: {for (final v in data.views) v.name: v},
                      fetchDoc: CoachBrain.githubFetcher(github),
                    );
```

- [ ] **Step 4: Fix the one remaining caller**

`lib/ui/coach_chat_screen.dart` `_requestReply` still calls `brain.reply(List.of(_messages))` — make it compile by passing a sink that will be fleshed out in Task 6:
```dart
      final text = await brain.reply(
        List.of(_messages),
        onProposal: _postProposal,
      );
```
and add a minimal `_postProposal` (full version replaces it in Task 6):
```dart
  /// Persists a propose_schedule result as a kind=proposal row in this
  /// thread — same shape as a reply row, JSON payload in `text`.
  Future<void> _postProposal(CoachProposal p) async {
    final now = DateTime.now();
    await widget.repository.create(widget.view, <String, Object?>{
      'id': const Uuid().v4(),
      'date': DateTime(now.year, now.month, now.day),
      'ts': now.toIso8601String(),
      'role': 'coach',
      'kind': 'proposal',
      'thread': widget.threadId,
      'text': p.encode(),
    });
  }
```
with import `import '../models/coach_proposal.dart';`.

- [ ] **Step 5: Run the suite + analyzer**

Run: `flutter test test/coach_brain_test.dart && flutter analyze`
Expected: coach_brain tests PASS; analyze at baseline (~32 infos, no new warnings/errors).

- [ ] **Step 6: Commit**

```bash
git add lib/services/coach_brain.dart lib/ui/home_screen.dart lib/ui/coach_chat_screen.dart test/coach_brain_test.dart
git commit -m "feat(coach): reply turn on ChatRunner tool loop with propose_schedule

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Proposal card widget + chat screen integration

**Files:**
- Create: `lib/ui/widgets/coach_proposal_card.dart`
- Test: `test/coach_proposal_card_test.dart`
- Modify: `lib/ui/coach_chat_screen.dart`
- Modify: `lib/ui/coach_threads_screen.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/services/coach_proposal_store.dart';
import 'package:airledger/ui/widgets/coach_proposal_card.dart';

void main() {
  final proposal = CoachProposal(
    view: 'strength',
    date: DateTime(2026, 9, 14),
    template: 'cut_press_heavy',
    summary: 'Combined press day',
    entries: [
      {'exercise': 'Bench Press', 'weight': 185, 'reps': 5},
      {'exercise': 'Overhead Press', 'weight': 115, 'reps': 5},
    ],
  );

  Future<void> pump(
    WidgetTester tester, {
    CoachProposalStatus? status,
    VoidCallback? onSchedule,
    VoidCallback? onUndo,
    VoidCallback? onDismiss,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CoachProposalCard(
          proposal: proposal,
          status: status,
          busy: false,
          onSchedule: onSchedule ?? () {},
          onUndo: onUndo ?? () {},
          onDismiss: onDismiss ?? () {},
        ),
      ),
    ));
  }

  testWidgets('pending shows entries + Schedule/Not now; tap fires',
      (tester) async {
    var scheduled = false;
    await pump(tester, onSchedule: () => scheduled = true);
    expect(find.textContaining('Mon, Sep 14'), findsOneWidget);
    expect(find.textContaining('cut_press_heavy'), findsOneWidget);
    expect(find.textContaining('Bench Press'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    await tester.tap(find.text('Schedule'));
    expect(scheduled, isTrue);
  });

  testWidgets('scheduled shows Undo; tap fires', (tester) async {
    var undone = false;
    await pump(tester,
        status: CoachProposalStatus.scheduled, onUndo: () => undone = true);
    expect(find.textContaining('Scheduled'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('Schedule'), findsNothing);
    await tester.tap(find.text('Undo'));
    expect(undone, isTrue);
  });

  testWidgets('undone/dismissed offer Schedule again', (tester) async {
    await pump(tester, status: CoachProposalStatus.undone);
    expect(find.textContaining('Undone'), findsOneWidget);
    expect(find.text('Schedule again'), findsOneWidget);
    await pump(tester, status: CoachProposalStatus.dismissed);
    expect(find.textContaining('Dismissed'), findsOneWidget);
    expect(find.text('Schedule again'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/coach_proposal_card_test.dart`
Expected: FAIL — `Target of URI doesn't exist ... coach_proposal_card.dart`

- [ ] **Step 3: Write the card widget**

```dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/coach_proposal.dart';
import '../../services/coach_proposal_store.dart';

/// In-bubble card for a `kind=proposal` coach message. Pure
/// presentation — the chat screen owns PlanStore writes, state
/// persistence, and navigation.
class CoachProposalCard extends StatelessWidget {
  final CoachProposal proposal;

  /// Null = pending (no action taken on this device yet).
  final CoachProposalStatus? status;

  /// Disables buttons while a schedule/undo write is in flight.
  final bool busy;

  final VoidCallback onSchedule;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  const CoachProposalCard({
    super.key,
    required this.proposal,
    required this.status,
    required this.busy,
    required this.onSchedule,
    required this.onUndo,
    required this.onDismiss,
  });

  static String _entryLine(Map<String, Object?> e) {
    final parts = <String>[];
    for (final v in e.values) {
      final s = v?.toString().trim();
      if (s == null || s.isEmpty) continue;
      parts.add(s);
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dateLabel = DateFormat('EEE, MMM d').format(proposal.date);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_note, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$dateLabel · ${proposal.view}',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          if (proposal.template != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                proposal.template!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          const SizedBox(height: 6),
          for (final e in proposal.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('• ${_entryLine(e)}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 6),
          _footer(context),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case null:
        return Row(
          children: [
            FilledButton(
              onPressed: busy ? null : onSchedule,
              child: const Text('Schedule'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: busy ? null : onDismiss,
              child: const Text('Not now'),
            ),
          ],
        );
      case CoachProposalStatus.scheduled:
        return Row(
          children: [
            Icon(Icons.check_circle, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            const Text('Scheduled'),
            const Spacer(),
            TextButton(
              onPressed: busy ? null : onUndo,
              child: const Text('Undo'),
            ),
          ],
        );
      case CoachProposalStatus.undone:
      case CoachProposalStatus.dismissed:
        return Row(
          children: [
            Text(
              status == CoachProposalStatus.undone ? 'Undone' : 'Dismissed',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            TextButton(
              onPressed: busy ? null : onSchedule,
              child: const Text('Schedule again'),
            ),
          ],
        );
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/coach_proposal_card_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Integrate into the chat screen**

In `lib/ui/coach_chat_screen.dart`:

1. Add imports:
```dart
import '../models/planned_entry.dart';
import '../services/coach_proposal_store.dart';
import '../services/plan_store.dart';
import 'widgets/coach_proposal_card.dart';
```
(`coach_proposal.dart` import exists from Task 5.)

2. Add the opener typedef (top level, near the other helpers):
```dart
/// Opens a timeline for [viewName] on [date] with [highlightKeys]
/// planned-entry localIds accented. Built by HomeScreen, which owns the
/// TimelineScreen dependency set. Null → Schedule buttons are disabled.
typedef CoachTimelineOpener = void Function(
  BuildContext context,
  String viewName,
  DateTime date,
  Set<String> highlightKeys,
);
```

3. Add to `CoachChatScreen`: `final CoachTimelineOpener? openTimeline;` and constructor param `this.openTimeline,`.

4. Add state fields to `_CoachChatScreenState`:
```dart
  /// Proposal state per kind=proposal row id (null = pending). Loaded
  /// alongside messages so cards render the right footer.
  final Map<String, CoachProposalState?> _proposalStates = {};

  /// Proposal row ids with a schedule/undo write in flight.
  final Set<String> _proposalBusy = {};
```

5. In `_load()`, after `rows.sort(...)` and before `setState`, load states:
```dart
      for (final r in rows) {
        if (r['kind']?.toString() != 'proposal') continue;
        final id = r['id']?.toString();
        if (id == null) continue;
        _proposalStates[id] = await CoachProposalStore.load(id);
      }
```

6. In `_buildBody()`'s `itemBuilder`, replace
`_ChatBubble(msg: _messages[_messages.length - 1 - i])` with
`_bubbleFor(_messages[_messages.length - 1 - i])` and add:
```dart
  Widget _bubbleFor(Record msg) {
    if (msg['kind']?.toString() == 'proposal') {
      final p = CoachProposal.tryParse(msg['text']?.toString() ?? '');
      if (p != null) return _proposalBubble(msg, p);
      // Malformed payload → plain bubble fallback.
    }
    return _ChatBubble(msg: msg);
  }

  Widget _proposalBubble(Record msg, CoachProposal p) {
    final rowId = msg['id']?.toString() ?? '';
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.summary.isNotEmpty)
                Text(p.summary,
                    style: TextStyle(color: scheme.onSurface)),
              CoachProposalCard(
                proposal: p,
                status: _proposalStates[rowId]?.status,
                busy: _proposalBusy.contains(rowId),
                onSchedule: () => _scheduleProposal(rowId, p),
                onUndo: () => _undoProposal(rowId, p),
                onDismiss: () => _dismissProposal(rowId),
              ),
            ],
          ),
        ),
      ),
    );
  }
```

7. Add the handlers:
```dart
  Future<void> _scheduleProposal(String rowId, CoachProposal p) async {
    final view = widget.brain?.views[p.view];
    if (view == null || widget.openTimeline == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Scheduling unavailable in this build')));
      return;
    }
    setState(() => _proposalBusy.add(rowId));
    try {
      final entries = [
        for (final e in p.entries)
          PlannedEntry.create(
            view: view,
            date: p.date,
            values: Map<String, Object?>.of(e),
            templateName: p.template,
          ),
      ];
      await PlanStore.addAll(view, entries);
      final ids = [for (final e in entries) e.localId];
      final st = CoachProposalState(
          status: CoachProposalStatus.scheduled, localIds: ids);
      await CoachProposalStore.save(rowId, st);
      if (!mounted) return;
      setState(() => _proposalStates[rowId] = st);
      widget.openTimeline!(context, p.view, p.date, ids.toSet());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Schedule failed: $e')));
    } finally {
      if (mounted) setState(() => _proposalBusy.remove(rowId));
    }
  }

  Future<void> _undoProposal(String rowId, CoachProposal p) async {
    final view = widget.brain?.views[p.view];
    final prior = _proposalStates[rowId];
    if (view == null || prior == null) return;
    setState(() => _proposalBusy.add(rowId));
    try {
      for (final localId in prior.localIds) {
        await PlanStore.remove(view, localId);
      }
      const st = CoachProposalState(
          status: CoachProposalStatus.undone, localIds: []);
      await CoachProposalStore.save(rowId, st);
      if (!mounted) return;
      setState(() => _proposalStates[rowId] = st);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Undo failed: $e')));
    } finally {
      if (mounted) setState(() => _proposalBusy.remove(rowId));
    }
  }

  Future<void> _dismissProposal(String rowId) async {
    const st = CoachProposalState(
        status: CoachProposalStatus.dismissed, localIds: []);
    await CoachProposalStore.save(rowId, st);
    if (mounted) setState(() => _proposalStates[rowId] = st);
  }
```

8. In `_postProposal` (added in Task 5), append `await _load();` after the `create` call so the card appears before the reply text lands.

9. In `lib/ui/coach_threads_screen.dart`: add `final CoachTimelineOpener? openTimeline;` to `CoachThreadsScreen` (+ constructor param `this.openTimeline,`), and pass `openTimeline: widget.openTimeline,` at every `CoachChatScreen(` construction site (search the file — the thread tile `onTap` and the "+" new-thread action).

- [ ] **Step 6: Run tests + analyzer**

Run: `flutter test test/coach_proposal_card_test.dart test/coach_proposal_test.dart test/coach_proposal_store_test.dart && flutter analyze`
Expected: PASS; analyze at baseline.

- [ ] **Step 7: Commit**

```bash
git add lib/ui/widgets/coach_proposal_card.dart test/coach_proposal_card_test.dart lib/ui/coach_chat_screen.dart lib/ui/coach_threads_screen.dart
git commit -m "feat(coach): proposal card in chat — schedule/undo/dismiss with local state

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Timeline initialDate + highlight

**Files:**
- Modify: `lib/ui/timeline_screen.dart` (constructor ~line 130; state ~line 149; `_RecordTile` ~line 1770 and its build ~line 1900-1975; instantiation ~line 680)

No good widget-test seam exists for this 2835-line screen (it hits PlanStore + repository on mount); verify by analyzer + on-device in Task 8. Keep the change surgical.

- [ ] **Step 1: Add the params**

In `TimelineScreen` add fields + constructor params:
```dart
  /// Initially selected date (defaults to today). Set when arriving
  /// from a coach proposal so the plan's day is already showing.
  final DateTime? initialDate;

  /// Planned-entry localIds to accent on arrival (coach "Schedule"
  /// hand-off). The accent fades a few seconds after first build.
  final Set<String> highlightKeys;
```
constructor: `this.initialDate,` and `this.highlightKeys = const {},`.

- [ ] **Step 2: Seed the date + highlight state**

In `_TimelineScreenState` replace `DateTime _selectedDate = _today();` with:
```dart
  late DateTime _selectedDate = widget.initialDate ?? _today();
```
and add:
```dart
  /// Live highlight set — starts as widget.highlightKeys, cleared by a
  /// one-shot timer so the accent reads as "here's what just landed".
  late final Set<String> _highlightKeys = {...widget.highlightKeys};
  Timer? _highlightTimer;
```
In the state's existing `initState`, append:
```dart
    if (_highlightKeys.isNotEmpty) {
      _highlightTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(_highlightKeys.clear);
      });
    }
```
In the existing `dispose`, append `_highlightTimer?.cancel();`.

- [ ] **Step 3: Accent the tile**

In `_RecordTile` add a field `final bool highlighted;` with constructor param `this.highlighted = false,`.

In `_RecordTile.build`, the tile is currently `final tile = ListTile(...)` followed by `if (selectionMode) return tile;` and a `Dismissible(... child: tile)`. Change `final tile` to `Widget tile` and, immediately after the ListTile assignment, add:
```dart
    // Coach hand-off accent: tinted while highlighted, animating back
    // to transparent when the screen clears the highlight set.
    tile = AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      color: highlighted
          ? scheme.tertiaryContainer.withValues(alpha: 0.55)
          : Colors.transparent,
      child: tile,
    );
```
(`scheme` already exists in that build method; if not, `final scheme = Theme.of(context).colorScheme;`.)

At the `_RecordTile(` instantiation (~line 680), add:
```dart
                              highlighted:
                                  _highlightKeys.contains(item.keyString),
```

- [ ] **Step 4: Analyzer gate**

Run: `flutter analyze`
Expected: baseline only (~32 infos), no new diagnostics.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/timeline_screen.dart
git commit -m "feat(timeline): initialDate + fading highlight for coach-scheduled entries

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Wire the opener in HomeScreen + full gates + deploy

**Files:**
- Modify: `lib/ui/home_screen.dart` (`_CoachRow` ~line 555 and its `_open()` ~line 665; the coach-row construction ~line 405)
- Modify: `CLAUDE.md`

- [ ] **Step 1: Build and thread the opener**

In `home_screen.dart`, where `_CoachRow` is constructed (inside the builder that has `data`, `chatModel`, `github` in scope), add an `openTimeline` argument:
```dart
                    _CoachRow(
                      view: coachView,
                      repository: data.registry.forView(coachView),
                      ledger: coachLedger,
                      brain: coachBrain,
                      openTimeline: (ctx, viewName, date, highlight) {
                        final view = data.views
                            .where((v) => v.name == viewName)
                            .firstOrNull;
                        if (view == null) return;
                        Navigator.of(ctx).push(
                          MaterialPageRoute(
                            builder: (_) => TimelineScreen(
                              view: view,
                              repository: data.registry.forView(view),
                              llm: data.llm,
                              llmCache: data.llmCache,
                              chatModel: chatModel,
                              github: github == null
                                  ? null
                                  : GithubClient(github),
                              analytics: data.analytics,
                              qboSpec: data.quickbooks?.specFor(view.name),
                              qboService:
                                  data.quickbooks?.specFor(view.name) == null
                                      ? null
                                      : data.qboService,
                              initialDate: date,
                              highlightKeys: highlight,
                            ),
                          ),
                        );
                      },
                    ),
```

In `_CoachRow`, add `final CoachTimelineOpener? openTimeline;` (+ constructor param `this.openTimeline,`; import is already satisfied via `coach_chat_screen.dart`'s export through `coach_threads_screen.dart` — if the analyzer complains, add `import 'coach_chat_screen.dart';`). In `_CoachRowState._open()`, pass it through:
```dart
        builder: (_) => CoachThreadsScreen(
          view: widget.view,
          repository: widget.repository,
          ledger: widget.ledger,
          brain: widget.brain,
          openTimeline: widget.openTimeline,
        ),
```

- [ ] **Step 2: Full test + analyzer gates**

Run: `flutter analyze && flutter test`
Expected: analyze at baseline; test failures are EXACTLY the 7 known pre-existing ones (3 live-DB integration + 4 schema_loader) — everything new passes.

- [ ] **Step 3: Update CLAUDE.md**

In the Coach section of "Current feature state", replace the "Interactive replies" bullet with:
```markdown
  - **Interactive replies: IN-APP via API credits** — CoachBrain on the
    ChatRunner tool loop (streaming Anthropic, max_tokens 4096; context
    = coach/*.md from GitHub (1h cache) + 28-day local ledger dump +
    last 40 thread messages). Tools: list_templates / read_template /
    propose_schedule. Proposals land as `kind=proposal` coach_chat rows
    (JSON in `text`, no schema change); the chat renders a card —
    Schedule writes PlanStore + opens the timeline with the entries
    highlighted (initialDate/highlightKeys params), Undo removes them;
    status + localIds are device-local (`coach_proposal:<rowId>`).
    routine.md carries the Monday press anchor + skipped-lift carryover
    rule + deficit consequences (2026-09-13).
```
Also delete the stale open follow-up line about LlmClient's 512-token cap if referenced ("Note: LlmClient hardcodes max_tokens 512" — keep it, LlmClient still has it for post-log; but remove any implication the coach uses it: change `LlmClient hardcodes max_tokens 512` to `LlmClient (post-log hooks) hardcodes max_tokens 512; the coach no longer uses it`).

- [ ] **Step 4: Commit**

```bash
git add lib/ui/home_screen.dart CLAUDE.md
git commit -m "feat(coach): thread timeline opener from home to chat; docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Build + deploy to device**

```bash
cd ~/repos/ledger
dart run tool/brand.dart --config ~/repos/airledger-fitness/ledger.yaml
```
Expected: builds, installs to Pixel (serial 66260DLKX00010), launches. No engine/dylib rebuild is needed — this feature is Dart-only (verify no `~/repos/airledger` files were touched).

- [ ] **Step 6: On-device smoke test (manual, with the user)**

1. Open Coach → a thread → ask: "plan Monday for me". Expect: reasoning mentions the carryover rule; a proposal card appears (bench-first combined press day if OHP is missing from the trailing week).
2. Tap Schedule → strength timeline opens on Monday's date, new entries tinted, tint fades ~4 s; template header groups them.
3. Back gesture → returns to chat; card shows "Scheduled · Undo".
4. Tap Undo → entries gone from the timeline (re-open to confirm); card shows "Undone · Schedule again".
5. Kill + reopen the app → card state survives (SharedPreferences).

---

## Self-review notes

- Spec coverage: Part A → Task 1; B1 → Tasks 4-5; B2 → Tasks 2-3; B3 → Task 6; B4 → Task 7; B5 → Task 8; testing section → Tasks 2/3/4/6 + gates in 8. Deficit note (user follow-up) → Task 1 section 3.
- The proposal row is created by the chat screen's `_postProposal` sink (Task 5 step 4 + Task 6 step 5.8), satisfying the spec's "only write is the kind=proposal chat row" via the same repository path reply rows use.
- Type names used across tasks: `CoachProposal` (Task 2) ← Tasks 4/5/6; `CoachProposalState`/`CoachProposalStatus`/`CoachProposalStore` (Task 3) ← Task 6; `ProposalSink` (Task 4) ← Task 5; `CoachTimelineOpener` (Task 6) ← Task 8; `highlightKeys`/`initialDate` (Task 7) ← Task 8. Consistent.
- ViewSchema constructor details in tests (`dateField`, `InputSpec`) must be checked against `lib/models/view_schema.dart` at implementation time (flagged inline in Task 4).
