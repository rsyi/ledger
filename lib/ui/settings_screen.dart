import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/config_source/config_source.dart';
import '../services/config_source/config_source_registry.dart';
import '../services/integrations/registry.dart';
import '../services/program_provider.dart';
import '../services/week_start.dart';
import 'connect_program_screen.dart';
import 'data_account_card.dart';
import 'design/design.dart';
import 'integrations_screen.dart' show IntegrationCard;

/// Settings (the home app bar's gear, 2026-10-03): PROGRAM CONFIG (the
/// active config source — repo@branch/path + account, Change / Sign out;
/// multi-user sub-project 1), then ACCOUNT & SPREADSHEET (the data
/// identity — Google sign-in + the user's spreadsheet; read-only on the
/// owner build; sub-project 2), then WEEK — "Week starts
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
    ConfigSourceRegistry.active.addListener(_changed);
    _loadProgram();
  }

  @override
  void dispose() {
    AppSettings.weekStartSetting.removeListener(_changed);
    ConfigSourceRegistry.active.removeListener(_changed);
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

  Future<void> _changeSource() async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(
      builder: (_) => ConnectProgramScreen(
        oauthClientId: ConfigSourceRegistry.oauthClientId,
        templateRepo: ConfigSourceRegistry.templateRepo,
      ),
    ));
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out of GitHub?'),
        content: Text(ConfigSourceRegistry.hasBaked
            ? 'Forgets the token on this phone and goes back to the '
                "build's built-in program config."
            : 'Forgets the token on this phone. The app will ask you to '
                'connect a program again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              key: const ValueKey('confirm-sign-out'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    await ConfigSourceRegistry.signOut();
    // No fallback source → the app root now shows "Connect your program".
    if (mounted && ConfigSourceRegistry.active.value == null) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Widget _programConfig(BuildContext context) {
    final ConfigSource? src = ConfigSourceRegistry.active.value;
    final baked = src != null && !src.canSignOut;
    final who = src == null
        ? 'Not connected — trackers and program config are unavailable.'
        : baked
            ? 'GitHub · built into this app'
            : 'GitHub · signed in as ${src.account ?? 'unknown'}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(src?.displayName ?? 'No program connected',
                key: const ValueKey('config-source-name'),
                style: AppText.row(context)),
            const SizedBox(height: 2),
            Text(who,
                key: const ValueKey('config-source-account'),
                style: AppText.meta(context)),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  key: const ValueKey('config-source-change'),
                  onPressed: _changeSource,
                  child: Text(src == null ? 'Connect' : 'Change'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey('config-source-sign-out'),
                  // The baked source has nothing to sign out of.
                  onPressed: src != null && src.canSignOut ? _signOut : null,
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
          const SectionHeader(label: 'Program config'),
          _programConfig(context),
          const SectionHeader(label: 'Account & spreadsheet'),
          const DataAccountCard(),
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
