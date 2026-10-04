import 'package:flutter/material.dart';

import '../services/app_config.dart';
import '../services/config_source/config_source.dart';
import '../services/config_source/config_source_registry.dart';
import 'connect_program_screen.dart';

/// App root (multi-user sub-project 1): resolves the active
/// [ConfigSource] before the home screen bootstraps.
///
///   baked / user-connected source → [home] (re-created, keyed on the
///     source id, whenever the source changes — a full re-bootstrap so no
///     config from the old location leaks through);
///   no source (and not a kiosk build) → [ConnectProgramScreen], the
///     minimal onboarding placeholder ("Continue without a program" lets
///     the user in with every config-driven surface inert, as builds
///     without `github:` always behaved).
class ConfigGate extends StatefulWidget {
  final Widget Function(Key key) home;

  /// Test seams.
  final Future<AppConfig> Function() loadConfig;
  final SecretStore? store;

  const ConfigGate({
    super.key,
    required this.home,
    this.loadConfig = AppConfig.load,
    this.store,
  });

  @override
  State<ConfigGate> createState() => _ConfigGateState();
}

class _ConfigGateState extends State<ConfigGate> {
  bool _ready = false;
  bool _skipped = false;
  bool _kiosk = false;

  @override
  void initState() {
    super.initState();
    ConfigSourceRegistry.active.addListener(_changed);
    _init();
  }

  @override
  void dispose() {
    ConfigSourceRegistry.active.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    try {
      final cfg = await widget.loadConfig();
      _kiosk = cfg.kioskView != null;
      await ConfigSourceRegistry.init(
        baked: cfg.github,
        store: widget.store,
        oauthClientId: cfg.githubOAuthClientId,
        templateRepo: cfg.githubTemplateRepo,
      );
    } catch (_) {
      // Unreadable assets config: let the home screen bootstrap and show
      // its own error view (same failure surface as before the gate).
      _skipped = true;
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final source = ConfigSourceRegistry.active.value;
    if (source == null && !_kiosk && !_skipped) {
      return ConnectProgramScreen(
        key: const ValueKey('connect-program'),
        oauthClientId: ConfigSourceRegistry.oauthClientId,
        templateRepo: ConfigSourceRegistry.templateRepo,
        onSkip: () => setState(() => _skipped = true),
      );
    }
    return widget.home(ValueKey('home:${source?.id ?? 'none'}'));
  }
}
