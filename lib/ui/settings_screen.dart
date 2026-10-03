import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/integrations/registry.dart';
import '../services/program_provider.dart';
import '../services/week_start.dart';
import 'design/design.dart';
import 'integrations_screen.dart' show IntegrationCard;

/// Settings (the home app bar's gear, 2026-10-03): WEEK — "Week starts
/// on" (the synced `app_settings` row every surface, the nightly coach
/// and the MCP read; program.yaml's `week_start` is only the default) —
/// then the INTEGRATIONS cards.
class SettingsScreen extends StatefulWidget {
  /// Loads program.yaml for the default's label; null → no program
  /// default known (Monday fallback shown).
  final ProgramProvider? programProvider;

  const SettingsScreen({super.key, this.programProvider});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// "from program default" / "set here" / "default" — the source line.
String weekStartSourceLabel(WeekStartSource s) => switch (s) {
      WeekStartSource.setting => 'set here',
      WeekStartSource.program => 'from program default',
      WeekStartSource.fallback => 'default',
    };

class _SettingsScreenState extends State<SettingsScreen> {
  Map<Object?, Object?>? _program;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    AppSettings.weekStartSetting.addListener(_changed);
    _loadProgram();
  }

  @override
  void dispose() {
    AppSettings.weekStartSetting.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadProgram() async {
    try {
      final docs = await widget.programProvider?.load();
      if (mounted && docs?.program != null) {
        setState(() => _program = docs!.program);
      }
    } catch (_) {/* program default unknown — shown as such */}
  }

  Future<void> _set(int day) async {
    setState(() => _busy = true);
    try {
      await AppSettings.setWeekStart(day);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Couldn't save the week start: $e")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eff = effectiveWeekStart(_program);
    final end = weekEndDay(eff.day);
    final integrations = IntegrationRegistry.instance?.integrations ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SectionHeader(label: 'Week'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Week starts on',
                                style: AppText.row(context)),
                            const SizedBox(height: 2),
                            Text(
                              '${weekdayName(eff.day)} · '
                              '${weekStartSourceLabel(eff.source)}',
                              key: const ValueKey('week-start-source'),
                              style: AppText.meta(context),
                            ),
                          ],
                        ),
                      ),
                      _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : DropdownButton<int>(
                              key: const ValueKey('week-start-picker'),
                              value: eff.day,
                              underline: const SizedBox.shrink(),
                              items: [
                                for (var d = DateTime.monday;
                                    d <= DateTime.sunday;
                                    d++)
                                  DropdownMenuItem(
                                    value: d,
                                    child: Text(weekdayName(d)),
                                  ),
                              ],
                              onChanged: (d) {
                                if (d != null) _set(d);
                              },
                            ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Weeks run ${weekdayName(eff.day)}–${weekdayName(end)}: '
                    'goals, program sets, moves and missed work all count '
                    'this week, and unplaced work expires at the end of '
                    '${weekdayName(end)}. Synced — the nightly coach and '
                    'the Claude connector use it too.',
                    style: AppText.meta(context),
                  ),
                ],
              ),
            ),
          ),
          const SectionHeader(label: 'Integrations'),
          if (integrations.isEmpty)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
              child: Text('No integrations available.',
                  style: AppText.meta(context)),
            ),
          for (final it in integrations)
            IntegrationCard(
              integration: it,
              onChanged: () {
                if (mounted) setState(() {});
              },
            ),
        ],
      ),
    );
  }
}
